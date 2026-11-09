// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";
import {TickMath} from "../../vendor/TickMath.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal, IPancakeV3SwapCallback} from "../../interfaces/IUniswapV3.sol";
import {IStoxesBnbBalanceHook} from "../IStoxesBnb.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";

/// @notice Immutable, ownerless route snapshot. Deliberately independent of legacy vault code.
contract StoxesBnbRoutedStocksVault is StoxesBnbVaultBase, IStoxesBnbBalanceHook, IPancakeV3SwapCallback {
    using SafeERC20Lite for address;
    struct RouteConfig {
        address v3Factory;
        address usdt;
        address pool0;
        address pool1;
        uint256 maxAmountIn;
    }

    uint256 public constant MAGNITUDE = 2 ** 128;
    uint256 public constant MAX_IMPACT_BPS = 300;
    uint32 public constant TWAP_WINDOW = 1800;
    uint16 public constant ORACLE_CARDINALITY = 200;
    address public immutable dividendStock;
    uint256 public immutable minHolding;
    address public immutable v3Factory;
    address public immutable usdt;
    address public immutable pool0;
    address public immutable pool1;
    uint24 public immutable fee0;
    uint24 public immutable fee1;
    uint256 public immutable maxAmountIn;

    uint256 public totalShares;
    uint256 public magnifiedDividendPerShare;
    uint256 public unaccountedStock;
    uint256 private _trackedStockBalance;
    address private _activePool;
    address private _activeInput;
    bool private _activeZeroForOne;
    uint256 private _remainingPayment;
    bool private _converting;

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
    error IncompleteFill();

    constructor(
        address token_, address quoteToken_, address creator_, address wrappedNative_,
        address stock_, uint256 minHolding_, RouteConfig memory route, address[] memory systemExcluded_
    ) StoxesBnbVaultBase(token_, quoteToken_ == address(0) ? wrappedNative_ : quoteToken_, creator_, wrappedNative_) {
        if (stock_ == address(0) || stock_ == wrappedNative_ || stock_ == route.usdt) revert InvalidParams();
        dividendStock = stock_;
        minHolding = minHolding_;
        v3Factory = route.v3Factory;
        usdt = route.usdt;
        pool0 = route.pool0;
        pool1 = route.pool1;
        maxAmountIn = route.maxAmountIn;
        if (vaultQuoteToken == stock_) {
            if (route.pool0 != address(0) || route.pool1 != address(0) || route.maxAmountIn != 0) revert InvalidParams();
        } else {
            if (vaultQuoteToken != wrappedNative_ || route.maxAmountIn == 0 || route.maxAmountIn > uint256(type(int256).max)) {
                revert InvalidParams();
            }
            fee0 = validatePool(route.v3Factory, route.pool0, wrappedNative_, route.pool1 == address(0) ? stock_ : route.usdt);
            if (route.pool1 != address(0)) fee1 = validatePool(route.v3Factory, route.pool1, route.usdt, stock_);
        }
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
        excluded[address(this)] = true;
        excluded[token_] = true;
        for (uint256 i; i < systemExcluded_.length; ++i) excluded[systemExcluded_[i]] = true;
        _trackedStockBalance = IERC20BnbVault(stock_).balanceOf(address(this));
    }

    function routeVersion() external pure returns (uint16) { return 2; }
    function stock() external view returns (address) { return dividendStock; }
    function quoteToken() external view returns (address) { return vaultQuoteToken; }
    function swapPool() external view returns (address) { return pool0; }
    function swapFee() external view returns (uint24) { return fee0; }

    /// @dev Canonical membership, exact endpoints and supported fee are checked again at execution.
    function validatePool(address factory, address pool, address input, address output) public view returns (uint24 fee) {
        if (factory.code.length == 0 || pool.code.length == 0 || input == output || input == address(0) || output == address(0)) {
            revert InvalidMarket();
        }
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        fee = p.fee();
        if (fee != 100 && fee != 500 && fee != 2500 && fee != 10_000) revert InvalidMarket();
        (address a, address b) = input < output ? (input, output) : (output, input);
        if (p.token0() != a || p.token1() != b || IUniswapV3FactoryMinimal(factory).getPool(a, b, fee) != pool) {
            revert InvalidMarket();
        }
        if (p.liquidity() == 0) revert InvalidMarket();
    }

    function growOracle() external {
        if (pool0 != address(0)) IUniswapV3PoolMinimal(pool0).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        if (pool1 != address(0)) IUniswapV3PoolMinimal(pool1).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
    }

    function onBalanceChange(address from, uint256 fromBalanceAfter, address to, uint256 toBalanceAfter) external {
        if (msg.sender != token) revert OnlyToken();
        _syncHolder(from, fromBalanceAfter);
        if (to != from) _syncHolder(to, toBalanceAfter);
    }

    function syncExclusions() external {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("mainPool()"));
        if (!ok || data.length != 32) revert InvalidMarket();
        address pool = abi.decode(data, (address));
        if (pool == address(0) || excluded[pool]) return;
        _settle(pool);
        totalShares -= sharesOf[pool];
        sharesOf[pool] = 0;
        _rewardDebt[pool] = 0;
        _removeHolder(pool);
        excluded[pool] = true;
        emit ExclusionSynced(pool);
    }

    function ping() public override {
        // Prevent token callbacks from observing a transient two-hop balance.
        if (_converting) revert InvalidMarket();
        if (vaultQuoteToken != dividendStock) { super.ping(); return; }
        uint256 balance = IERC20BnbVault(dividendStock).balanceOf(address(this));
        if (balance <= _trackedStockBalance) return;
        uint256 delta = balance - _trackedStockBalance;
        _trackedStockBalance = balance;
        _fund(delta);
        emit QuoteAccounted(delta, 0);
    }

    function convert() external nonReentrant returns (uint256 quoteSpent, uint256 stockReceived) {
        ping();
        uint256 carryBefore = unaccountedStock;
        _creditCarry();
        if (vaultQuoteToken == dividendStock) return (0, 0);
        uint256 amount = accountedQuote;
        if (amount == 0) {
            if (carryBefore == 0) revert NothingToConvert();
            return (0, 0);
        }
        if (amount > maxAmountIn) amount = maxAmountIn;
        _converting = true;
        if (pool1 == address(0)) {
            stockReceived = _swap(pool0, vaultQuoteToken, dividendStock, amount, fee0);
        } else {
            uint256 intermediate = _swap(pool0, vaultQuoteToken, usdt, amount, fee0);
            stockReceived = _swap(pool1, usdt, dividendStock, intermediate, fee1);
        }
        _converting = false;
        quoteSpent = amount;
        _consume(amount);
        _trackedStockBalance += stockReceived;
        _fund(stockReceived);
        emit QuoteConverted(quoteSpent, stockReceived);
    }

    function _swap(address pool, address input, address output, uint256 amount, uint24 fee) private returns (uint256 received) {
        if (amount == 0 || amount > uint256(type(int256).max)) revert InvalidMarket();
        if (validatePool(v3Factory, pool, input, output) != fee) revert InvalidMarket();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        bool zeroForOne = input < output;
        int24 tick = _twap(p);
        // ln(1.03)/ln(1.0001) > 295. A 295-tick symmetric bound is conservative
        // in both directions. Subtract rounded-up fee ticks (also conservative):
        // exp(-distance*ln(1.0001))*(1-fee) >= 0.97.
        int24 feeTicks = fee == 100 ? int24(2) : fee == 500 ? int24(6) : fee == 2500 ? int24(26) : int24(101);
        int256 limitTick = int256(tick) + (zeroForOne ? -int256(295 - feeTicks) : int256(295 - feeTicks));
        if (limitTick <= TickMath.MIN_TICK || limitTick >= TickMath.MAX_TICK) revert ImpactTooHigh();
        uint160 limit = TickMath.getSqrtRatioAtTick(int24(limitTick));
        (uint160 current,,,,,,) = p.slot0();
        if ((zeroForOne && current <= limit) || (!zeroForOne && current >= limit)) revert ImpactTooHigh();
        uint256 beforeIn = IERC20BnbVault(input).balanceOf(address(this));
        uint256 beforeOut = IERC20BnbVault(output).balanceOf(address(this));
        _activePool = pool;
        _activeInput = input;
        _activeZeroForOne = zeroForOne;
        _remainingPayment = amount;
        p.swap(address(this), zeroForOne, int256(amount), limit, "");
        _activePool = address(0);
        _activeInput = address(0);
        if (_remainingPayment != 0 || beforeIn - IERC20BnbVault(input).balanceOf(address(this)) != amount) revert IncompleteFill();
        received = IERC20BnbVault(output).balanceOf(address(this)) - beforeOut;
        if (received == 0) revert ImpactTooHigh();
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (!_converting || msg.sender != _activePool || _activePool == address(0)) revert InvalidMarket();
        int256 owedDelta = _activeZeroForOne ? amount0Delta : amount1Delta;
        int256 outDelta = _activeZeroForOne ? amount1Delta : amount0Delta;
        if (owedDelta <= 0 || outDelta >= 0 || uint256(owedDelta) > _remainingPayment) revert InvalidMarket();
        _remainingPayment -= uint256(owedDelta);
        _activeInput.safeTransfer(msg.sender, uint256(owedDelta));
    }

    function _twap(IUniswapV3PoolMinimal p) private view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        try p.observe(ago) returns (int56[] memory cumulatives, uint160[] memory) {
            if (cumulatives.length != 2) revert OracleNotReady();
            // V3 tick cumulatives are signed modular int56 counters.
            int56 delta;
            unchecked { delta = cumulatives[1] - cumulatives[0]; }
            tick = int24(delta / int56(uint56(TWAP_WINDOW)));
            if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) --tick;
        } catch { revert OracleNotReady(); }
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = _pending[msg.sender];
        if (amount == 0) return 0;
        _pending[msg.sender] = 0;
        if (!_pay(msg.sender, amount)) { _pending[msg.sender] = amount; return 0; }
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
                } else { _pending[holder] = amount; }
            }
            ++iterations;
            uint256 nowGas = gasleft();
            used += last - nowGas;
            last = nowGas;
        }
    }

    function withdrawableOf(address holder) public view returns (uint256) {
        uint256 earned = FixedPointMathLib.fullMulDiv(sharesOf[holder], magnifiedDividendPerShare, MAGNITUDE);
        return _pending[holder] + (earned > _rewardDebt[holder] ? earned - _rewardDebt[holder] : 0);
    }
    function accumulativeOf(address holder) external view returns (uint256) { return withdrawnDividends[holder] + withdrawableOf(holder); }
    function holderCount() external view returns (uint256) { return _holders.length; }
    function holderAt(uint256 index) external view returns (address) { return _holders[index]; }

    function _fund(uint256 amount) private {
        if (amount == 0) return;
        if (totalShares == 0) { unaccountedStock += amount; return; }
        amount += unaccountedStock;
        unaccountedStock = 0;
        // Full-width intermediate is essential when a one-wei shareholder receives funding.
        // Accumulator overflow reverts funding atomically; it cannot poison later hooks.
        // Launch supply (1e27) < MAGNITUDE, so share*accumulator/MAGNITUDE fits uint256
        // for every reachable accumulator and launch-token balance.
        magnifiedDividendPerShare += FixedPointMathLib.fullMulDiv(amount, MAGNITUDE, totalShares);
        emit DividendsFunded(amount, totalShares);
    }
    function _creditCarry() private {
        if (unaccountedStock == 0 || totalShares == 0) return;
        uint256 carry = unaccountedStock;
        unaccountedStock = 0;
        _fund(carry);
    }
    function _syncHolder(address holder, uint256 balanceAfter) private {
        if (holder == address(0)) return;
        _settle(holder);
        uint256 old = sharesOf[holder];
        uint256 next = !excluded[holder] && balanceAfter >= minHolding ? balanceAfter : 0;
        if (old == next) return;
        totalShares = totalShares - old + next;
        sharesOf[holder] = next;
        _rewardDebt[holder] = FixedPointMathLib.fullMulDiv(next, magnifiedDividendPerShare, MAGNITUDE);
        if (old == 0 && next != 0) {
            _holders.push(holder);
            _holderIndexPlusOne[holder] = _holders.length;
        } else if (old != 0 && next == 0) { _removeHolder(holder); }
    }
    function _settle(address holder) private {
        uint256 earned = FixedPointMathLib.fullMulDiv(sharesOf[holder], magnifiedDividendPerShare, MAGNITUDE);
        if (earned > _rewardDebt[holder]) _pending[holder] += earned - _rewardDebt[holder];
        _rewardDebt[holder] = earned;
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
        // Freeze balance accounting across token callbacks, including same-asset payouts.
        uint256 tracked = _trackedStockBalance;
        _trackedStockBalance = tracked >= amount ? tracked - amount : 0;
        _converting = true;
        (bool ok, bytes memory data) = dividendStock.call(abi.encodeWithSelector(0xa9059cbb, holder, amount));
        _converting = false;
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            _trackedStockBalance = tracked;
            return false;
        }
        return true;
    }
    function description() external pure override returns (string memory) {
        return "Immutable TWAP-protected WBNB dividend route, or same-stock distributions.";
    }
    function vaultUISchema() external pure override returns (string memory) {
        return '{"type":"tuple","fields":[{"name":"dividendStock","type":"address"},{"name":"minHoldingForEligibility","type":"uint256"}]}';
    }
}