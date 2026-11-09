// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../base/Common.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3FactoryMinimal,
    IUniswapV3PoolMinimal,
    IPancakeV3SwapCallback
} from "../interfaces/IUniswapV3.sol";
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {StoxesBnbPortalMath} from "./libraries/StoxesBnbPortalMath.sol";
import {BnbLiquidityAmounts} from "./libraries/BnbLiquidityAmounts.sol";
import {TickMath} from "../vendor/TickMath.sol";
import {BnbQuotePayout} from "./libraries/BnbQuotePayout.sol";

interface IERC20Graduator {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBnbV3PoolFactory {
    function createPool(address token0, address token1, uint24 fee) external returns (address);
}

/// @notice Asset-handling periphery for curve graduation. Token lifecycle calls
/// remain in the Portal; this contract can only move assets supplied by it.
contract StoxesBnbGraduator is IPancakeV3SwapCallback {
    using SafeERC20Lite for address;

    uint24 public constant V3_POOL_FEE = 10_000;
    uint256 public constant TOLERANCE_BPS = 100;
    uint256 public constant MINT_MIN_BPS = 9_900;
    uint16 public constant ORACLE_CARDINALITY = 200;
    uint16 public constant REPRICE_BUDGET_BPS = 200;
    // Canonical PancakeSwap V2 pair fee. Not a configurable router quote.
    uint256 private constant V2_FEE_FACTOR = 9_975;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Pending {
        address quote;
        address pool;
        address locker;
        uint128 tokenAmount;
        uint128 quoteAmount;
        uint160 expectedSqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        bool simple;
    }

    struct SimpleParams {
        address token;
        address quote;
        address locker;
        uint256 tokenAmount;
        uint256 quoteAmount;
        uint256 initialPrice;
        uint256 currentPrice;
        uint8 quoteDecimals;
    }

    struct MintRequest {
        address token;
        address quote;
        address locker;
        uint256 tokenAmount;
        uint256 quoteAmount;
        int24 low;
        int24 high;
    }

    address public portal;
    address public immutable positionManager;
    address public immutable wrappedNative;
    address public immutable treasury;
    address public immutable admin;
    mapping(address => Pending) public pending;
    mapping(address => uint256) public correctiveBudgetRemaining;
    mapping(address => address) public correctiveBudgetAsset;
    address private _activePool;
    address private _activeToken;

    error NotPortal();
    error InvalidParams();
    error NoPending();
    error PriceOutOfBand();
    event V2DonationRemoved(address indexed token, address indexed pair, uint256 quoteRemoved, uint256 quoteLeft);

    modifier onlyPortal() {
        if (msg.sender != portal) revert NotPortal();
        _;
    }

    constructor(address wrappedNative_, address positionManager_, address treasury_, address admin_) {
        if (
            wrappedNative_ == address(0) || positionManager_ == address(0)
                || treasury_ == address(0) || admin_ == address(0)
        ) {
            revert InvalidParams();
        }
        wrappedNative = wrappedNative_;
        positionManager = positionManager_;
        treasury = treasury_;
        admin = admin_;
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert InvalidParams();
    }

    function setPortal(address portal_) external {
        if (msg.sender != admin || portal != address(0) || portal_ == address(0)) revert InvalidParams();
        portal = portal_;
    }

    function beginSimple(SimpleParams calldata p)
        external
        onlyPortal
        returns (bool complete, address pool, uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed)
    {
        p.token.safeTransferFrom(msg.sender, address(this), p.tokenAmount);
        p.quote.safeTransferFrom(msg.sender, address(this), p.quoteAmount);
        bool token0Side = p.token < p.quote;
        uint160 expected;
        int24 low;
        int24 high;
        (pool, expected, low, high) = _simplePool(p, token0Side);
        if (!StoxesBnbPortalMath.sqrtInBand(_poolSqrt(pool), expected, TOLERANCE_BPS)) {
            pending[p.token] = Pending(
                p.quote,
                pool,
                p.locker,
                uint128(p.tokenAmount),
                uint128(p.quoteAmount),
                expected,
                low,
                high,
                true
            );
            _initializeCorrectiveBudget(p.token, p.quote);
            return (false, pool, 0, 0, 0);
        }
        (tokenId, tokenUsed, quoteUsed) =
            _mint(p.token, p.quote, p.locker, p.tokenAmount, p.quoteAmount, low, high);
        return (true, pool, tokenId, tokenUsed, quoteUsed);
    }

    /// @notice Resolves the canonical simple-token pool before a clone is deployed.
    /// @dev Production position managers expose `factory()`. The direct lookup is
    /// retained for minimal position-manager implementations.
    function simplePool(address token, address quote) external view returns (address pool) {
        (address token0, address token1) = token < quote ? (token, quote) : (quote, token);
        (bool ok, bytes memory data) = positionManager.staticcall(
            abi.encodeWithSelector(IUniswapV3FactoryMinimal.getPool.selector, token0, token1, V3_POOL_FEE)
        );
        if (ok && data.length >= 32) return abi.decode(data, (address));
        (ok, data) = positionManager.staticcall(abi.encodeWithSignature("factory()"));
        if (!ok || data.length < 32) return address(0);
        address factory = abi.decode(data, (address));
        if (factory == address(0)) return address(0);
        return IUniswapV3FactoryMinimal(factory).getPool(token0, token1, V3_POOL_FEE);
    }

    /// @notice Reserve the canonical V3 address before the first curve purchase.
    /// @dev Do NOT initialize its price or add liquidity. Creating now prevents
    /// buyFor from pre-funding a predictable address while getPool still returns
    /// zero. The ordinary graduation price remains initialized at graduation.
    function prepareSimplePool(address token, address quote) external onlyPortal returns (address pool) {
        (address token0, address token1) = token < quote ? (token, quote) : (quote, token);
        (bool ok, bytes memory data) = positionManager.staticcall(abi.encodeWithSignature("factory()"));
        if (!ok || data.length < 32) revert InvalidParams();
        address factory = abi.decode(data, (address));
        pool = IUniswapV3FactoryMinimal(factory).getPool(token0, token1, V3_POOL_FEE);
        if (pool == address(0)) pool = IBnbV3PoolFactory(factory).createPool(token0, token1, V3_POOL_FEE);
        if (pool == address(0) || pool.code.length == 0) revert InvalidParams();
    }

    function _simplePool(SimpleParams calldata p, bool token0Side)
        internal
        returns (address pool, uint160 expected, int24 low, int24 high)
    {
        (address token0, address token1) = token0Side ? (p.token, p.quote) : (p.quote, p.token);
        expected = StoxesBnbPortalMath.sqrtPriceFromCurve(p.currentPrice, p.quoteDecimals, token0Side);
        pool = INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
            token0, token1, V3_POOL_FEE, expected
        );
        IUniswapV3PoolMinimal(pool).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        (low, high) = StoxesBnbPortalMath.simpleTicks(
            p.initialPrice, p.currentPrice, p.quoteDecimals, token0Side
        );
    }

    function beginTax(
        address token,
        address quote,
        address pair,
        uint256 tokenAmount,
        uint256 quoteAmount
    ) external onlyPortal returns (bool complete) {
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        quote.safeTransferFrom(msg.sender, address(this), quoteAmount);
        if (!_v2Ready(pair, token, quote, tokenAmount, quoteAmount)) {
            pending[token] =
                Pending(quote, pair, address(0), uint128(tokenAmount), uint128(quoteAmount), 0, 0, 0, false);
            return false;
        }
        _mintV2(token, quote, pair, tokenAmount, quoteAmount);
        return true;
    }

    function finalize(address token)
        external
        onlyPortal
        returns (address pool, uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed, bool simple, bool complete)
    {
        Pending memory p = pending[token];
        if (p.pool == address(0)) revert NoPending();
        simple = p.simple;
        pool = p.pool;
        if (simple) {
            if (!_repriceIfNeeded(p, token)) return (pool, 0, 0, 0, true, false);
            p = pending[token];
            if (!StoxesBnbPortalMath.sqrtInBand(_poolSqrt(pool), p.expectedSqrtPriceX96, TOLERANCE_BPS)) {
                return (pool, 0, 0, 0, true, false);
            }
            (, int24 currentTick,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (currentTick <= p.tickLower || currentTick >= p.tickUpper) revert PriceOutOfBand();
            IUniswapV3PoolMinimal(pool).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
            (tokenId, tokenUsed, quoteUsed) = _mint(
                token, p.quote, p.locker, p.tokenAmount, p.quoteAmount, p.tickLower, p.tickUpper
            );
        } else {
            if (!_v2Ready(pool, token, p.quote, p.tokenAmount, p.quoteAmount)) revert PriceOutOfBand();
            _mintV2(token, p.quote, pool, p.tokenAmount, p.quoteAmount);
            tokenUsed = p.tokenAmount;
            quoteUsed = p.quoteAmount;
        }
        delete pending[token];
        delete correctiveBudgetRemaining[token];
        delete correctiveBudgetAsset[token];
        complete = true;
    }

    function _repriceIfNeeded(Pending memory p, address token) internal returns (bool) {
        uint160 current = _poolSqrt(p.pool);
        if (StoxesBnbPortalMath.sqrtInBand(current, p.expectedSqrtPriceX96, TOLERANCE_BPS)) return true;
        bool zeroForOne = current > p.expectedSqrtPriceX96;
        address inputAsset =
            zeroForOne ? IUniswapV3PoolMinimal(p.pool).token0() : IUniswapV3PoolMinimal(p.pool).token1();
        if (inputAsset != correctiveBudgetAsset[token]) return false;
        uint256 remaining = correctiveBudgetRemaining[token];
        if (remaining == 0) return false;
        bool empty = IUniswapV3PoolMinimal(p.pool).liquidity() == 0;
        uint256 amount = empty ? 1 : remaining;
        _swapToPrice(p.pool, zeroForOne, amount, p.expectedSqrtPriceX96);
        if (
            empty
                && (
                    _abs(_activeAmount0) > 1 || _abs(_activeAmount1) > 1
                        || _poolSqrt(p.pool) != p.expectedSqrtPriceX96
                )
        ) revert PriceOutOfBand();
        uint256 spent = uint256(zeroForOne ? _activeAmount0 : _activeAmount1);
        if (spent > remaining) revert InvalidParams();
        correctiveBudgetRemaining[token] = remaining - spent;
        _applySwap(token, _activeAmount0, _activeAmount1);
        return StoxesBnbPortalMath.sqrtInBand(_poolSqrt(p.pool), p.expectedSqrtPriceX96, TOLERANCE_BPS);
    }

    function _initializeCorrectiveBudget(address token, address quote) private {
        Pending storage p = pending[token];
        uint160 current = _poolSqrt(p.pool);
        bool zeroForOne = current > p.expectedSqrtPriceX96;
        bool inputIsToken = zeroForOne == (token < quote);
        correctiveBudgetAsset[token] = inputIsToken ? token : quote;
        correctiveBudgetRemaining[token] =
            (inputIsToken ? p.tokenAmount : p.quoteAmount) * REPRICE_BUDGET_BPS / 10_000;
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    int256 private _activeAmount0;
    int256 private _activeAmount1;

    function _swapToPrice(address pool, bool zeroForOne, uint256 amount, uint160 limit) private {
        _activePool = pool;
        _activeToken = zeroForOne ? IUniswapV3PoolMinimal(pool).token0() : IUniswapV3PoolMinimal(pool).token1();
        _activeAmount0 = 0;
        _activeAmount1 = 0;
        (_activeAmount0, _activeAmount1) =
            IUniswapV3PoolMinimal(pool).swap(address(this), zeroForOne, int256(amount), limit, "");
        _activePool = address(0);
        _activeToken = address(0);
    }

    function _applySwap(address token, int256 amount0, int256 amount1) private {
        Pending storage p = pending[token];
        bool token0 = token < p.quote;
        uint256 tokenAmount = p.tokenAmount;
        uint256 quoteAmount = p.quoteAmount;
        p.tokenAmount = uint128(_afterSwap(tokenAmount, token0 ? amount0 : amount1));
        p.quoteAmount = uint128(_afterSwap(quoteAmount, token0 ? amount1 : amount0));
    }

    function _afterSwap(uint256 amount, int256 delta) private pure returns (uint256) {
        return delta >= 0 ? amount - uint256(delta) : amount + uint256(-delta);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _activePool || _activePool == address(0)) revert InvalidParams();
        // Core V3 invokes the callback even when a zero-liquidity swap moved the
        // price to the limit without consuming input; nothing is owed then.
        if (amount0Delta <= 0 && amount1Delta <= 0) return;
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (owed > 1 && IUniswapV3PoolMinimal(msg.sender).liquidity() == 0) revert InvalidParams();
        _activeToken.safeTransfer(msg.sender, owed);
    }

    function _mint(
        address token,
        address quote,
        address locker,
        uint256 tokenAmount,
        uint256 quoteAmount,
        int24 low,
        int24 high
    ) internal returns (uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed) {
        if (!IERC20Graduator(token).approve(positionManager, tokenAmount)) revert InvalidParams();
        if (!IERC20Graduator(quote).approve(positionManager, quoteAmount)) revert InvalidParams();
        (tokenId, tokenUsed, quoteUsed) = _mintPosition(
            MintRequest(token, quote, locker, tokenAmount, quoteAmount, low, high)
        );
        IERC20Graduator(token).approve(positionManager, 0);
        IERC20Graduator(quote).approve(positionManager, 0);
        _sweepResidue(token, quote, tokenAmount, quoteAmount, tokenUsed, quoteUsed);
    }

    function _mintPosition(MintRequest memory r)
        internal
        returns (uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed)
    {
        bool token0Side = r.token < r.quote;
        (address token0, address token1) = token0Side ? (r.token, r.quote) : (r.quote, r.token);
        (uint256 amount0, uint256 amount1) = _desiredAmounts(r);
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: V3_POOL_FEE,
            tickLower: r.low,
            tickUpper: r.high,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 * MINT_MIN_BPS / 10_000,
            amount1Min: amount1 * MINT_MIN_BPS / 10_000,
            recipient: r.locker,
            deadline: block.timestamp
        });
        uint256 used0;
        uint256 used1;
        (tokenId,, used0, used1) = INonfungiblePositionManager(positionManager).mint(mp);
        tokenUsed = token0Side ? used0 : used1;
        quoteUsed = token0Side ? used1 : used0;
    }

    function _desiredAmounts(MintRequest memory r) internal returns (uint256 amount0, uint256 amount1) {
        bool token0Side = r.token < r.quote;
        (address token0, address token1) = token0Side ? (r.token, r.quote) : (r.quote, r.token);
        uint256 available0 = token0Side ? r.tokenAmount : r.quoteAmount;
        uint256 available1 = token0Side ? r.quoteAmount : r.tokenAmount;
        address pool = INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
            token0, token1, V3_POOL_FEE, TickMath.getSqrtRatioAtTick(r.low)
        );
        uint160 current = _poolSqrt(pool);
        uint160 lower = TickMath.getSqrtRatioAtTick(r.low);
        uint160 upper = TickMath.getSqrtRatioAtTick(r.high);
        uint128 liquidity =
            BnbLiquidityAmounts.liquidityForAmounts(current, lower, upper, available0, available1);
        (amount0, amount1) = BnbLiquidityAmounts.amountsForLiquidity(current, lower, upper, liquidity);
        // Rounding in the liquidity conversion must never make the position
        // manager pull more than the graduation assets remaining after a
        // corrective swap.
        if (amount0 > available0) amount0 = available0;
        if (amount1 > available1) amount1 = available1;
    }

    function _sweepResidue(
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 tokenUsed,
        uint256 quoteUsed
    ) internal {
        if (tokenAmount > tokenUsed) token.safeTransfer(DEAD, tokenAmount - tokenUsed);
        if (quoteAmount > quoteUsed) {
            BnbQuotePayout.payoutQuote(quote, wrappedNative, treasury, quoteAmount - quoteUsed);
        }
    }

    function _mintV2(address token, address quote, address pair, uint256 tokenAmount, uint256 quoteAmount)
        internal
    {
        uint256 donation = IERC20Graduator(quote).balanceOf(pair);
        uint256 left = donation;
        uint256 seeded;
        if (donation > 1) {
            // With no LP and no launched tokens in the pair, all existing quote
            // is unsolicited. Pancake requires BOTH reserves to be nonzero even
            // for a one-sided swap: establish a one-base-unit token reserve.
            token.safeTransfer(pair, 1);
            IUniswapV2Pair(pair).sync();
            uint256 input = tokenAmount / 2;
            left = _v2DonationLeft(donation, input);
            token.safeTransfer(pair, input);
            seeded = input + 1;
            bool token0Side = IUniswapV2Pair(pair).token0() == token;
            // Every migration token stays in this pair. ONLY pre-existing quote
            // leaves it, to the immutable treasury, never to the caller. No LP
            // exists to capture either leg. The remaining assets are minted in
            // this same transaction and all issued LP goes to DEAD.
            IUniswapV2Pair(pair).swap(
                token0Side ? 0 : donation - left,
                token0Side ? donation - left : 0,
                treasury,
                ""
            );
            emit V2DonationRemoved(token, pair, donation - left, left);
        }
        token.safeTransfer(pair, tokenAmount - seeded);
        quote.safeTransfer(pair, quoteAmount);
        IUniswapV2Pair(pair).mint(DEAD);
        // Fail atomically on transfer shortfalls or unexpected pair behavior.
        // The price is determined by the migration allocation, not donated spot
        // reserves. The only surplus permitted is the bounded rounding residue.
        if (
            IERC20Graduator(token).balanceOf(pair) != tokenAmount
                || IERC20Graduator(quote).balanceOf(pair) != quoteAmount + left
        ) revert InvalidParams();
    }

    function _v2Ready(
        address pair,
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount
    ) internal view returns (bool) {
        IUniswapV2Pair pool = IUniswapV2Pair(pair);
        bool token0Side = pool.token0() == token;
        if (
            token == quote || (token0Side ? pool.token1() != quote : pool.token0() != quote || pool.token1() != token)
                || pool.totalSupply() != 0
        ) return false;
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        // Holder transfers cannot reach the pair before graduation. Do not
        // generalize this recovery to funded/two-sided or LP-owned pools.
        if ((token0Side ? r0 : r1) != 0 || IERC20Graduator(token).balanceOf(pair) != 0) return false;
        uint256 donation = IERC20Graduator(quote).balanceOf(pair);
        if (
            tokenAmount < 4 || tokenAmount > type(uint112).max || quoteAmount == 0
                || quoteAmount > type(uint112).max || donation > type(uint112).max
        ) return false;
        uint256 left = donation > 1 ? _v2DonationLeft(donation, tokenAmount / 2) : donation;
        // Bound the FINAL price error (vs quoteAmount/tokenAmount), not the
        // arbitrary pre-migration spot price. Also leave room in V2 reserves.
        return left <= type(uint112).max - quoteAmount
            && left * 10_000 <= quoteAmount * (2 * TOLERANCE_BPS);
    }

    function _v2DonationLeft(uint256 donation, uint256 input) private pure returns (uint256) {
        // ceil(donation * 10000 / (10000 + input * 9975)).
        // For initial reserves (1, donation), this is the smallest quote
        // remainder satisfying Pancake's fee-adjusted constant-product check.
        uint256 denominator = 10_000 + input * V2_FEE_FACTOR;
        return (donation * 10_000 + denominator - 1) / denominator;
    }

    function _poolSqrt(address pool) internal view returns (uint160 value) {
        (value,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }
}