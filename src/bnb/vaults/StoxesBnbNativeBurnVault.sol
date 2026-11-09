// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {TickMath} from "../../vendor/TickMath.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal, IPancakeV3SwapCallback} from "../../interfaces/IUniswapV3.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

/// @notice Ownerless native-BNB sink. No changes to token/portal/processor contracts.
/// @dev Stock conversions are deliberately NOT executed inside a trade's ping.
/// Counters include donations; public trading-attribution must use receipt evidence.
contract StoxesBnbNativeBurnVault is StoxesBnbVaultBase, IPancakeV3SwapCallback {
    using SafeERC20Lite for address;
    struct Route {
        address v3Factory;
        address bridge;
        address pool0;
        address pool1;
        uint256 maxAmountIn;
    }
    address public constant DEAD = address(0xdead);
    uint32 public constant TWAP_WINDOW = 1800;
    address public immutable v3Factory;
    address public immutable bridge;
    address public immutable pool0;
    address public immutable pool1;
    uint24 public immutable fee0;
    uint24 public immutable fee1;
    uint256 public immutable maxAmountIn;
    uint256 public totalBnbBurned;
    address private activePool;
    address private activeInput;
    bool private activeDirection;
    uint256 private remainingPayment;

    event BurnFunding(uint256 quoteAmount);
    event BnbBurned(uint256 quoteSpent, uint256 bnbBurned);
    error InvalidRoute();
    error OracleNotReady();
    error ImpactTooHigh();
    error IncompleteFill();
    error NothingToConvert();
    error BurnFailed();

    constructor(address token_, address quote_, address creator_, address wrapped_, Route memory r)
        StoxesBnbVaultBase(token_, quote_, creator_, wrapped_)
    {
        v3Factory = r.v3Factory;
        bridge = r.bridge;
        pool0 = r.pool0;
        pool1 = r.pool1;
        maxAmountIn = r.maxAmountIn;
        if (quote_ != wrapped_) {
            if (r.maxAmountIn == 0 || r.maxAmountIn > uint256(type(int256).max)) revert InvalidRoute();
            fee0 = validatePool(r.v3Factory, r.pool0, quote_, r.pool1 == address(0) ? wrapped_ : r.bridge);
            if (r.pool1 != address(0)) fee1 = validatePool(r.v3Factory, r.pool1, r.bridge, wrapped_);
        } else if (r.pool0 != address(0) || r.pool1 != address(0) || r.maxAmountIn != 0) revert InvalidRoute();
    }

    function ping() public override nonReentrant {
        _account();
    }

    function _account() private {
        uint256 balance = IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        if (balance <= accountedQuote) return;
        uint256 delta = balance - accountedQuote;
        accountedQuote = balance;
        emit BurnFunding(delta);
        emit QuoteAccounted(delta, accountedQuote);
        if (vaultQuoteToken == wrappedNative) {
            _consume(balance);
            _burn(balance, balance);
        }
    }

    /// @notice Permissionless; fixed route, no arbitrary target/calldata or recipient.
    /// Whole conversion reverts on oracle, fill, callback or burn failure.
    function convertAndBurn() external nonReentrant returns (uint256 quoteSpent, uint256 bnbBurned) {
        _account();
        if (vaultQuoteToken == wrappedNative) return (0, 0);
        quoteSpent = accountedQuote > maxAmountIn ? maxAmountIn : accountedQuote;
        if (quoteSpent == 0) revert NothingToConvert();
        if (pool1 == address(0)) {
            bnbBurned = _swap(pool0, vaultQuoteToken, wrappedNative, quoteSpent, fee0);
        } else {
            uint256 intermediate = _swap(pool0, vaultQuoteToken, bridge, quoteSpent, fee0);
            bnbBurned = _swap(pool1, bridge, wrappedNative, intermediate, fee1);
        }
        _consume(quoteSpent);
        _burn(quoteSpent, bnbBurned);
    }

    function _burn(uint256 quoteSpent, uint256 amount) private {
        IWETH(wrappedNative).withdraw(amount);
        (bool ok,) = DEAD.call{value: amount}("");
        if (!ok) revert BurnFailed();
        totalBnbBurned += amount;
        emit BnbBurned(quoteSpent, amount);
    }

    function validatePool(address factory, address pool, address input, address output)
        public view returns (uint24 fee)
    {
        if (pool.code.length == 0 || input == output || input == address(0) || output == address(0)) revert InvalidRoute();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        fee = p.fee();
        if (fee != 100 && fee != 500 && fee != 2500 && fee != 10_000) revert InvalidRoute();
        (address a, address b) = input < output ? (input, output) : (output, input);
        if (p.token0() != a || p.token1() != b || p.liquidity() == 0 ||
            IUniswapV3FactoryMinimal(factory).getPool(a, b, fee) != pool) revert InvalidRoute();
    }

    function _limit(IUniswapV3PoolMinimal p, bool direction, uint24 fee) private view returns (uint160 limit) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        int24 tick;
        try p.observe(ago) returns (int56[] memory cumulatives, uint160[] memory) {
            if (cumulatives.length != 2) revert OracleNotReady();
            int56 delta;
            unchecked { delta = cumulatives[1] - cumulatives[0]; }
            tick = int24(delta / int56(uint56(TWAP_WINDOW)));
            if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) --tick;
        } catch { revert OracleNotReady(); }
        // Conservative 3% price movement including fee, per hop.
        int24 feeTicks = fee == 100 ? int24(2) : fee == 500 ? int24(6) : fee == 2500 ? int24(26) : int24(101);
        int256 bound = int256(tick) + (direction ? -int256(295 - feeTicks) : int256(295 - feeTicks));
        if (bound <= TickMath.MIN_TICK || bound >= TickMath.MAX_TICK) revert ImpactTooHigh();
        limit = TickMath.getSqrtRatioAtTick(int24(bound));
        (uint160 current,,,,,,) = p.slot0();
        if ((direction && current <= limit) || (!direction && current >= limit)) revert ImpactTooHigh();
    }

    function _swap(address pool, address input, address output, uint256 amount, uint24 fee) private returns (uint256 received) {
        if (amount == 0 || amount > uint256(type(int256).max) || validatePool(v3Factory, pool, input, output) != fee) revert InvalidRoute();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        bool direction = input < output;
        uint160 limit = _limit(p, direction, fee);
        uint256 beforeIn = IERC20BnbVault(input).balanceOf(address(this));
        uint256 beforeOut = IERC20BnbVault(output).balanceOf(address(this));
        activePool = pool;
        activeInput = input;
        activeDirection = direction;
        remainingPayment = amount;
        p.swap(address(this), direction, int256(amount), limit, "");
        activePool = address(0);
        activeInput = address(0);
        if (remainingPayment != 0 || beforeIn - IERC20BnbVault(input).balanceOf(address(this)) != amount) revert IncompleteFill();
        received = IERC20BnbVault(output).balanceOf(address(this)) - beforeOut;
        if (received == 0) revert ImpactTooHigh();
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (activePool == address(0) || msg.sender != activePool) revert InvalidRoute();
        int256 owed = activeDirection ? amount0Delta : amount1Delta;
        int256 out = activeDirection ? amount1Delta : amount0Delta;
        if (owed <= 0 || out >= 0 || uint256(owed) > remainingPayment) revert InvalidRoute();
        remainingPayment -= uint256(owed);
        activeInput.safeTransfer(msg.sender, uint256(owed));
    }

    function description() external pure override returns (string memory) {
        return "Native BNB burned on receipt; bStocks use a fixed TWAP-protected conversion before immediate BNB burning.";
    }
    function vaultUISchema() external pure override returns (string memory) { return '{"type":"tuple","fields":[]}'; }
}
