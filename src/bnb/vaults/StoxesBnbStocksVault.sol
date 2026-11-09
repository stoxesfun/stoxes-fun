// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";
import {IUniswapV3PoolMinimal, IPancakeV3SwapCallback} from "../../interfaces/IUniswapV3.sol";
import {TickMath} from "../../vendor/TickMath.sol";
import {IStoxesBnbBalanceHook} from "../IStoxesBnb.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";

contract StoxesBnbStocksVault is
    StoxesBnbVaultBase,
    IStoxesBnbBalanceHook,
    IPancakeV3SwapCallback
{
    using SafeERC20Lite for address;

    uint256 public constant MAGNITUDE = 2 ** 128;
    uint256 public constant MAX_IMPACT_BPS = 300;
    uint32 public constant TWAP_WINDOW = 1800;
    uint32 public constant MIN_TWAP_WINDOW = 120;
    uint16 public constant ORACLE_CARDINALITY = 200;

    address public immutable dividendStock;
    uint256 public immutable minHolding;
    address public immutable swapPool;
    uint24 public immutable swapFee;

    uint256 public totalShares;
    uint256 public magnifiedDividendPerShare;
    uint256 public unaccountedStock;
    uint256 private _trackedStockBalance;
    address private _activePool;

    mapping(address => bool) public excluded;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) private _rewardDebt;
    mapping(address => uint256) private _pending;
    mapping(address => uint256) public withdrawnDividends;
    address[] private _holders;
    mapping(address => uint256) private _holderIndexPlusOne;
    uint256 public processIndex;

    event DividendsFunded(uint256 amount, uint256 totalShares);
    event DividendClaimed(address indexed holder, uint256 amount);
    event QuoteConverted(uint256 quoteSpent, uint256 stockReceived);
    event ExclusionSynced(address indexed pool);

    error OnlyToken();
    error NothingToConvert();
    error InvalidMarket();
    error OracleNotReady();
    error ImpactTooHigh();

    constructor(
        address token_,
        address quoteToken_,
        address creator_,
        address wrappedNative_,
        address stock_,
        uint256 minHolding_,
        address pool_,
        uint24 fee_,
        address[] memory systemExcluded_
    ) StoxesBnbVaultBase(token_, quoteToken_, creator_, wrappedNative_) {
        if (stock_ == address(0) || (stock_ != quoteToken_ && pool_ == address(0))) revert InvalidParams();
        dividendStock = stock_;
        minHolding = minHolding_;
        swapPool = pool_;
        swapFee = fee_;
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
        excluded[address(this)] = true;
        excluded[token_] = true;
        for (uint256 i; i < systemExcluded_.length; ++i) {
            if (systemExcluded_[i] != address(0)) excluded[systemExcluded_[i]] = true;
        }
        _trackedStockBalance = IERC20BnbVault(stock_).balanceOf(address(this));
    }

    /// @dev This path deliberately performs no calls. Every arithmetic branch is
    /// bounded by token balances and previously funded dividends.
    function onBalanceChange(address from, uint256 fromBalanceAfter, address to, uint256 toBalanceAfter)
        external
    {
        if (msg.sender != token) revert OnlyToken();
        _syncHolder(from, fromBalanceAfter);
        if (to != from) _syncHolder(to, toBalanceAfter);
    }

    /// @notice Grows the selected market's observation ring for the adaptive TWAP.
    function growOracle() external {
        if (swapPool == address(0)) return;
        IUniswapV3PoolMinimal(swapPool).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
    }

    /// @notice Defensively learns and removes the token's canonical pool.
    /// @dev The factory pre-excludes the V2 pair. This also covers a future migration
    ///      that assigns a different canonical pool.
    function syncExclusions() external {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("mainPool()"));
        if (!ok || data.length != 32) revert InvalidMarket();
        address pool = abi.decode(data, (address));
        if (pool == address(0)) return;
        if (!excluded[pool]) {
            _settle(pool);
            uint256 oldShares = sharesOf[pool];
            if (oldShares != 0) {
                totalShares -= oldShares;
                sharesOf[pool] = 0;
                _rewardDebt[pool] = 0;
                _removeHolder(pool);
            }
            excluded[pool] = true;
            emit ExclusionSynced(pool);
        }
    }

    function ping() public override {
        if (vaultQuoteToken != dividendStock) {
            super.ping();
            return;
        }
        uint256 balance = IERC20BnbVault(dividendStock).balanceOf(address(this));
        if (balance <= _trackedStockBalance) return;
        uint256 delta = balance - _trackedStockBalance;
        _trackedStockBalance = balance;
        accountedQuote += delta;
        _afterQuoteAccounted(delta);
        emit QuoteAccounted(delta, accountedQuote);
    }

    function convert() external nonReentrant returns (uint256 quoteSpent, uint256 stockReceived) {
        ping();
        _creditCarry();
        if (vaultQuoteToken == dividendStock) return (0, 0);
        uint256 amountIn = accountedQuote;
        if (amountIn == 0) {
            if (unaccountedStock == 0) revert NothingToConvert();
            return (0, 0);
        }

        uint256 quoteBefore = IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        uint256 stockBefore = IERC20BnbVault(dividendStock).balanceOf(address(this));
        (uint160 twapSqrt, int24 twapTick) = _twap();
        bool zeroForOne = IUniswapV3PoolMinimal(swapPool).token0() == vaultQuoteToken;
        uint160 limit = TickMath.getSqrtRatioAtTick(_limitTick(twapTick, zeroForOne));
        (uint160 current,,,,,,) = IUniswapV3PoolMinimal(swapPool).slot0();
        if ((zeroForOne && current <= limit) || (!zeroForOne && current >= limit)) revert ImpactTooHigh();

        _activePool = swapPool;
        IUniswapV3PoolMinimal(swapPool).swap(address(this), zeroForOne, int256(amountIn), limit, "");
        _activePool = address(0);
        quoteSpent = quoteBefore - IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        stockReceived = IERC20BnbVault(dividendStock).balanceOf(address(this)) - stockBefore;
        if (quoteSpent == 0 || stockReceived == 0) revert ImpactTooHigh();
        // A TWAP-derived price limit constrains every filled unit, including partial fills.
        twapSqrt;
        _consume(quoteSpent);
        _trackedStockBalance += stockReceived;
        _fund(stockReceived);
        emit QuoteConverted(quoteSpent, stockReceived);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _activePool || _activePool == address(0)) revert InvalidMarket();
        if (amount0Delta <= 0 && amount1Delta <= 0) revert InvalidMarket();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        vaultQuoteToken.safeTransfer(msg.sender, owed);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = _pending[msg.sender];
        if (amount == 0) return 0;
        _pending[msg.sender] = 0;
        if (!_pay(msg.sender, amount)) {
            _pending[msg.sender] = amount;
            return 0;
        }
        withdrawnDividends[msg.sender] += amount;
        emit DividendClaimed(msg.sender, amount);
    }

    function process(uint256 maxGas) external nonReentrant returns (uint256 iterations, uint256 claims) {
        uint256 count = _holders.length;
        if (count == 0 || maxGas == 0) return (0, 0);
        uint256 used;
        uint256 last = gasleft();
        while (used < maxGas && iterations < count) {
            if (processIndex >= _holders.length) processIndex = 0;
            address holder = _holders[processIndex++];
            _settle(holder);
            uint256 amount = _pending[holder];
            if (amount != 0) {
                _pending[holder] = 0;
                if (_pay(holder, amount)) {
                    withdrawnDividends[holder] += amount;
                    ++claims;
                    emit DividendClaimed(holder, amount);
                } else {
                    _pending[holder] = amount;
                }
            }
            ++iterations;
            uint256 nowGas = gasleft();
            used += last - nowGas;
            last = nowGas;
        }
    }

    function withdrawableOf(address holder) public view returns (uint256) {
        uint256 earned = FixedPointMathLib.mulDiv(sharesOf[holder], magnifiedDividendPerShare, MAGNITUDE);
        uint256 fresh = earned > _rewardDebt[holder] ? earned - _rewardDebt[holder] : 0;
        return _pending[holder] + fresh;
    }

    function accumulativeOf(address holder) external view returns (uint256) {
        return withdrawnDividends[holder] + withdrawableOf(holder);
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    function _afterQuoteAccounted(uint256 delta) internal override {
        if (vaultQuoteToken == dividendStock) {
            _consume(delta);
            _fund(delta);
        }
    }

    function _fund(uint256 amount) private {
        if (amount == 0) return;
        if (totalShares == 0) {
            unaccountedStock += amount;
            return;
        }
        amount += unaccountedStock;
        unaccountedStock = 0;
        magnifiedDividendPerShare += FixedPointMathLib.mulDiv(amount, MAGNITUDE, totalShares);
        emit DividendsFunded(amount, totalShares);
    }

    function _creditCarry() private {
        if (unaccountedStock != 0 && totalShares != 0) {
            uint256 carry = unaccountedStock;
            unaccountedStock = 0;
            magnifiedDividendPerShare += FixedPointMathLib.mulDiv(carry, MAGNITUDE, totalShares);
            emit DividendsFunded(carry, totalShares);
        }
    }

    function _syncHolder(address holder, uint256 balanceAfter) private {
        if (holder == address(0)) return;
        _settle(holder);
        uint256 oldShares = sharesOf[holder];
        uint256 newShares = !excluded[holder] && balanceAfter >= minHolding ? balanceAfter : 0;
        if (oldShares == newShares) return;
        if (newShares > oldShares) totalShares += newShares - oldShares;
        else totalShares -= oldShares - newShares;
        sharesOf[holder] = newShares;
        _rewardDebt[holder] = FixedPointMathLib.mulDiv(newShares, magnifiedDividendPerShare, MAGNITUDE);
        if (oldShares == 0 && newShares != 0) _addHolder(holder);
        else if (oldShares != 0 && newShares == 0) _removeHolder(holder);
    }

    function _settle(address holder) private {
        uint256 earned = FixedPointMathLib.mulDiv(sharesOf[holder], magnifiedDividendPerShare, MAGNITUDE);
        uint256 debt = _rewardDebt[holder];
        if (earned > debt) _pending[holder] += earned - debt;
        _rewardDebt[holder] = earned;
    }

    function _addHolder(address holder) private {
        if (_holderIndexPlusOne[holder] != 0) return;
        _holders.push(holder);
        _holderIndexPlusOne[holder] = _holders.length;
    }

    function _removeHolder(address holder) private {
        uint256 indexPlusOne = _holderIndexPlusOne[holder];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 last = _holders.length - 1;
        if (index != last) {
            address moved = _holders[last];
            _holders[index] = moved;
            _holderIndexPlusOne[moved] = index + 1;
        }
        _holders.pop();
        delete _holderIndexPlusOne[holder];
        if (processIndex > _holders.length) processIndex = 0;
    }

    function _pay(address holder, uint256 amount) private returns (bool) {
        if (dividendStock == vaultQuoteToken && vaultQuoteToken == wrappedNative) {
            _payoutQuote(holder, amount);
            if (_trackedStockBalance >= amount) _trackedStockBalance -= amount;
            else _trackedStockBalance = 0;
            return true;
        }
        (bool ok, bytes memory data) =
            dividendStock.call(abi.encodeWithSelector(0xa9059cbb, holder, amount));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) return false;
        if (_trackedStockBalance >= amount) _trackedStockBalance -= amount;
        else _trackedStockBalance = 0;
        return true;
    }

    function _twap() private view returns (uint160 sqrtPriceX96, int24 tick) {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolMinimal(swapPool).slot0();
        if (cardinality == 0) revert OracleNotReady();
        uint256 oldestIndex = (uint256(index) + 1) % cardinality;
        (uint32 oldest,,, bool initialized) = IUniswapV3PoolMinimal(swapPool).observations(oldestIndex);
        if (!initialized) (oldest,,, initialized) = IUniswapV3PoolMinimal(swapPool).observations(0);
        if (!initialized || oldest > block.timestamp) revert OracleNotReady();
        uint32 age = uint32(block.timestamp) - oldest;
        uint32 window = age < TWAP_WINDOW ? age : TWAP_WINDOW;
        if (window < MIN_TWAP_WINDOW) revert OracleNotReady();
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        try IUniswapV3PoolMinimal(swapPool).observe(secondsAgos) returns (
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

    function _limitTick(int24 twapTick, bool zeroForOne) private view returns (int24) {
        int24 limitTicks = _impactLimitTicks();
        int256 candidate =
            int256(twapTick) + (zeroForOne ? -int256(limitTicks) : int256(limitTicks));
        if (candidate <= TickMath.MIN_TICK) return TickMath.MIN_TICK + 1;
        if (candidate >= TickMath.MAX_TICK) return TickMath.MAX_TICK - 1;
        return int24(candidate);
    }

    /// @dev Rounded-to-nearest tick distances for ln(1 + (fee bps + 300) / 10_000)
    ///      / ln(1.0001): 297, 301, 320, and 393 for the supported fee tiers.
    function _impactLimitTicks() private view returns (int24) {
        if (swapFee == 100) return 297;
        if (swapFee == 500) return 301;
        if (swapFee == 2500) return 320;
        if (swapFee == 10_000) return 393;
        revert InvalidMarket();
    }

    function description() external pure override returns (string memory) {
        return "Converts vault proceeds into a selected stock and distributes it to eligible holders.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return '{"type":"tuple","fields":[{"name":"dividendStock","type":"address"},{"name":"minHoldingForEligibility","type":"uint256"}]}';
    }
}