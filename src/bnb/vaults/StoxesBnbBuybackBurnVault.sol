// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {IUniswapV2Pair} from "../../interfaces/IUniswapV2Pair.sol";
import {
    IUniswapV3PoolMinimal,
    IPancakeV3SwapCallback
} from "../../interfaces/IUniswapV3.sol";
import {V3SpotQuote} from "../../libraries/V3SpotQuote.sol";
import {TickMath} from "../../vendor/TickMath.sol";
import {BnbLaunchKind, IStoxesBnbPortal, IStoxesBnbSimpleToken, IStoxesBnbTaxToken} from "../IStoxesBnb.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";

contract StoxesBnbBuybackBurnVault is StoxesBnbVaultBase, IPancakeV3SwapCallback {
    using SafeERC20Lite for address;

    uint256 public constant MAX_IMPACT_BPS = 300;
    uint256 public constant V2_FEE_BPS = 25;
    uint24 public constant V3_FEE = 10_000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable portal;
    address public immutable swapRouter;
    uint32 public constant TWAP_WINDOW = 1800;
    uint32 public constant MIN_TWAP_WINDOW = 120;
    int24 private constant IMPACT_LIMIT_TICKS = 409;
    uint256 private constant Q112 = 2 ** 112;

    struct Observation {
        uint256 cumulative;
        uint32 timestamp;
        bool set;
    }

    struct V2Vars {
        address pair;
        bool quoteIs0;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 cumulative;
        uint32 nowTs;
        uint256 amountIn;
    }

    Observation public v2Observation;
    address private _activePool;

    event BuybackBurned(uint256 quoteSpent, uint256 tokensBurned, bool graduated);

    error NothingToExecute();
    error ImpactTooHigh();
    error InvalidMarket();
    error GraduationNotFinalized();
    error OracleNotReady();

    constructor(
        address token_,
        address quoteToken_,
        address creator_,
        address portal_,
        address swapRouter_,
        address wrappedNative_
    ) StoxesBnbVaultBase(token_, quoteToken_, creator_, wrappedNative_) {
        if (portal_ == address(0) || swapRouter_ == address(0) || wrappedNative_ == address(0)) {
            revert InvalidParams();
        }
        portal = portal_;
        swapRouter = swapRouter_;
        wrappedNative = wrappedNative_;
    }

    function execute() external nonReentrant returns (uint256 quoteSpent, uint256 tokensBurned) {
        ping();
        uint256 amount = accountedQuote;
        if (amount == 0) revert NothingToExecute();
        (,, bool graduated, bool finalized,,) = IStoxesBnbPortal(portal).tokenState(token);
        if (graduated && !finalized) revert GraduationNotFinalized();
        uint256 quoteBefore = IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        address tokenRecipient = graduated ? address(this) : BURN_ADDRESS;
        uint256 tokenBefore = IERC20BnbVault(token).balanceOf(tokenRecipient);

        if (!graduated) {
            if (vaultQuoteToken == wrappedNative) {
                _unwrap(amount);
                IStoxesBnbPortal(portal).buyFor{value: amount}(token, BURN_ADDRESS, address(this), amount, 0);
            } else {
                _approve(vaultQuoteToken, portal, amount);
                IStoxesBnbPortal(portal).buyFor(token, BURN_ADDRESS, address(this), amount, 0);
            }
        } else {
            (BnbLaunchKind kind,,,,,) = IStoxesBnbPortal(portal).tokenState(token);
            if (kind == BnbLaunchKind.Tax) {
                if (!_buyV2(amount)) return (0, 0);
            }
            else if (kind == BnbLaunchKind.Simple) _buyV3(amount);
            else revert InvalidMarket();
        }

        uint256 quoteAfter = IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        quoteSpent = quoteBefore - quoteAfter;
        _consume(quoteSpent);
        tokensBurned = IERC20BnbVault(token).balanceOf(tokenRecipient) - tokenBefore;
        if (tokensBurned == 0) revert ImpactTooHigh();
        if (graduated) token.safeTransfer(BURN_ADDRESS, tokensBurned);
        emit BuybackBurned(quoteSpent, tokensBurned, graduated);
    }

    function _buyV2(uint256 amountIn) private returns (bool traded) {
        V2Vars memory v;
        v.pair = IStoxesBnbTaxToken(token).mainPool();
        v.amountIn = amountIn;
        if (v.pair == address(0)) revert InvalidMarket();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(v.pair).getReserves();
        v.quoteIs0 = IUniswapV2Pair(v.pair).token0() == vaultQuoteToken;
        if (
            (!v.quoteIs0 && IUniswapV2Pair(v.pair).token1() != vaultQuoteToken)
                || (v.quoteIs0 ? IUniswapV2Pair(v.pair).token1() : IUniswapV2Pair(v.pair).token0())
                    != token
        ) revert InvalidMarket();
        v.reserveIn = v.quoteIs0 ? reserve0 : reserve1;
        v.reserveOut = v.quoteIs0 ? reserve1 : reserve0;
        if (v.reserveIn == 0 || v.reserveOut == 0) revert InvalidMarket();
        v.nowTs = uint32(block.timestamp);
        v.cumulative = v.quoteIs0
            ? IUniswapV2Pair(v.pair).price0CumulativeLast()
            : IUniswapV2Pair(v.pair).price1CumulativeLast();
        (,, uint32 last) = IUniswapV2Pair(v.pair).getReserves();
        if (last != v.nowTs) {
            uint32 elapsed;
            unchecked { elapsed = v.nowTs - last; }
            v.cumulative += v.reserveOut * Q112 / v.reserveIn * elapsed;
        }
        Observation memory observation = v2Observation;
        if (!observation.set) {
            v2Observation = Observation(v.cumulative, v.nowTs, true);
            return false;
        }
        uint32 window;
        unchecked { window = v.nowTs - observation.timestamp; }
        if (window < TWAP_WINDOW) return false;
        uint256 impact = MAX_IMPACT_BPS;
        uint256 fee = V2_FEE_BPS;
        uint256 cap =
            v.reserveIn * (impact - fee) * 10_000 / ((10_000 - impact) * (10_000 - fee));
        if (v.amountIn > cap) v.amountIn = cap;
        uint256 withFee = v.amountIn * (10_000 - V2_FEE_BPS);
        uint256 amountOut = withFee * v.reserveOut / (v.reserveIn * 10_000 + withFee);
        uint256 floor = _v2Floor(v.amountIn, v.cumulative, observation.cumulative, window);
        if (amountOut < floor) revert ImpactTooHigh();
        v2Observation = Observation(v.cumulative, v.nowTs, true);
        vaultQuoteToken.safeTransfer(v.pair, v.amountIn);
        IUniswapV2Pair(v.pair).swap(
            v.quoteIs0 ? 0 : amountOut, v.quoteIs0 ? amountOut : 0, address(this), ""
        );
        return true;
    }

    function _v2Floor(uint256 amount, uint256 cumulative, uint256 previous, uint32 window)
        private
        pure
        returns (uint256)
    {
        uint256 twapX112 = (cumulative - previous) / window;
        return amount * twapX112 / Q112 * (10_000 - V2_FEE_BPS)
            / 10_000 * (10_000 - MAX_IMPACT_BPS) / 10_000;
    }

    function _buyV3(uint256 amountIn) private {
        address pool = _portalPool();
        if (pool == address(0)) revert InvalidMarket();
        bool quoteIs0 = IUniswapV3PoolMinimal(pool).token0() == vaultQuoteToken;
        if (
            (!quoteIs0 && IUniswapV3PoolMinimal(pool).token1() != vaultQuoteToken)
                || (quoteIs0 ? IUniswapV3PoolMinimal(pool).token1() : IUniswapV3PoolMinimal(pool).token0())
                    != token
        ) revert InvalidMarket();
        (uint160 twapSqrt, int24 twapTick) = _v3Twap(pool);
        uint256 expected = V3SpotQuote.quoteAtSqrtRatio(twapSqrt, amountIn, quoteIs0);
        int24 limitTick = _limitTick(twapTick, quoteIs0);
        uint160 limit = TickMath.getSqrtRatioAtTick(limitTick);
        (uint160 current,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        if ((quoteIs0 && current <= limit) || (!quoteIs0 && current >= limit)) {
            revert ImpactTooHigh();
        }
        _activePool = pool;
        (int256 amount0, int256 amount1) = IUniswapV3PoolMinimal(pool).swap(
            address(this),
            quoteIs0,
            int256(amountIn),
            limit,
            ""
        );
        _activePool = address(0);
        uint256 consumed = uint256(quoteIs0 ? amount0 : amount1);
        uint256 out = uint256(-(quoteIs0 ? amount1 : amount0));
        uint256 floor = expected * consumed / amountIn
            * (10_000 - V3_FEE / 100 - MAX_IMPACT_BPS) / 10_000;
        if (out < floor) revert ImpactTooHigh();
    }

    function _v3Twap(address pool) private view returns (uint160 sqrtPriceX96, int24 tick) {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolMinimal(pool).slot0();
        if (cardinality == 0) revert OracleNotReady();
        uint256 oldestIndex = (uint256(index) + 1) % cardinality;
        (uint32 oldest,,, bool initialized) = IUniswapV3PoolMinimal(pool).observations(oldestIndex);
        if (!initialized) (oldest,,, initialized) = IUniswapV3PoolMinimal(pool).observations(0);
        if (!initialized || oldest > block.timestamp) revert OracleNotReady();
        uint32 age = uint32(block.timestamp) - oldest;
        uint32 window = age < TWAP_WINDOW ? age : TWAP_WINDOW;
        if (window < MIN_TWAP_WINDOW) revert OracleNotReady();
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try IUniswapV3PoolMinimal(pool).observe(secondsAgos) returns (
            int56[] memory cumulatives, uint160[] memory
        ) {
            int56 delta = cumulatives[1] - cumulatives[0];
            tick = int24(delta / int56(uint56(window)));
            if (delta < 0 && delta % int56(uint56(window)) != 0) --tick;
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        } catch {
            revert OracleNotReady();
        }
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _activePool || _activePool == address(0)) revert InvalidMarket();
        if (amount0Delta <= 0 && amount1Delta <= 0) revert InvalidMarket();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        vaultQuoteToken.safeTransfer(msg.sender, owed);
    }

    function _limitTick(int24 twapTick, bool zeroForOne) private pure returns (int24) {
        int256 candidate =
            int256(twapTick) + (zeroForOne ? -int256(IMPACT_LIMIT_TICKS) : int256(IMPACT_LIMIT_TICKS));
        if (candidate <= TickMath.MIN_TICK) return TickMath.MIN_TICK + 1;
        if (candidate >= TickMath.MAX_TICK) return TickMath.MAX_TICK - 1;
        return int24(candidate);
    }

    function _portalPool() private view returns (address pool) {
        (bool ok, bytes memory data) =
            portal.staticcall(abi.encodeWithSignature("stateDetails(address)", token));
        if (!ok || data.length < 320) revert InvalidMarket();
        (,,,, pool,,,,,) = abi.decode(
            data, (BnbLaunchKind, address, address, address, address, uint128, uint128, bool, bool, bool)
        );
    }

    function description() external pure override returns (string memory) {
        return "Permissionlessly buys the launch token and permanently burns it.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return '{"type":"null","description":"No vault-specific launch parameters"}';
    }
}
