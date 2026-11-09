// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite, ReentrancyGuardLite, SafeERC20Lite} from "../base/Common.sol";
import {BnbLaunchKind, BnbTaxAllocation, IStoxesBnbTaxToken, IStoxesBnbVault} from "./IStoxesBnb.sol";
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {BnbQuotePayout} from "./libraries/BnbQuotePayout.sol";

interface IBnbTaxAccounting is IStoxesBnbTaxToken {
    function protocolPending() external view returns (uint256);
}

interface IBnbTrustedPortal {
    function tokenState(address token)
        external
        view
        returns (BnbLaunchKind, address, bool, bool, uint256, uint256);
}

contract StoxesBnbTaxProcessor is OwnableLite, ReentrancyGuardLite {
    using SafeERC20Lite for address;

    uint16 public constant DYNAMIC_THRESHOLD_BPS = 10;
    uint16 public constant MAX_IMPACT_BPS = 300;
    uint16 public constant V2_FEE_BPS = 25;
    uint32 public constant TWAP_WINDOW = 1800;
    uint256 private constant Q112 = 2 ** 112;
    address public constant DEAD = address(0xdead);

    address public immutable treasury;
    address public immutable wrappedNative;
    address public portal;
    uint256 public minThreshold;
    uint256 public creatorDispatchThreshold = 0.006 ether;
    mapping(address => uint256) public creatorPending;
    mapping(address => uint256) public burnQuotePending;

    struct Observation {
        uint256 cumulative;
        uint32 timestamp;
        bool set;
    }

    mapping(address => Observation) public observationOf;
    mapping(address => uint256) public quoteBalanceCheckpoint;

    event Processed(address indexed token, uint256 tokensHarvested, uint256 quoteOut, uint256 protocolQuote);
    event CreatorDispatched(address indexed token, address indexed creator, uint256 amount);
    event ThresholdsSet(uint256 minThreshold, uint256 creatorDispatchThreshold);
    event BurnQuoteNotified(address indexed token, uint256 amount);
    event BuyAndBurn(address indexed token, uint256 quoteSpent, uint256 tokensBurned);
    event OracleWarmed(address indexed token, uint256 cumulative, uint32 timestamp);

    error InvalidParams();
    error BelowThreshold();
    error NoLiquidity();
    error FloorNotMet();
    error NothingPending();
    error NotPortal();
    error WrongPhase();
    error PortalAlreadySet();
    error UnregisteredToken();
    error QuoteTransferShortfall();

    struct ProcessVars {
        address pair;
        address quote;
        uint256 reserveToken;
        uint256 reserveQuote;
        uint256 pending;
        uint256 amount;
        uint256 protocolTokens;
        uint256 harvested;
        uint256 commissionTokens;
        uint256 bucketTokens;
        uint256 burnTokens;
        uint256 liquidityRetain;
        uint256 sellAmount;
        uint256 protocolQuote;
        uint256 commissionQuote;
        uint256 vaultQuote;
        uint256 creatorQuote;
        uint256 liquidityQuote;
    }

    struct BurnVars {
        address pair;
        address quote;
        uint256 pendingAmount;
        uint256 reserveToken;
        uint256 reserveQuote;
        uint256 amount;
        uint256 floor;
        uint256 out;
    }

    constructor(address wrappedNative_, address treasury_, uint256 minThreshold_, address admin_) {
        if (wrappedNative_ == address(0) || treasury_ == address(0)) revert InvalidParams();
        wrappedNative = wrappedNative_;
        treasury = treasury_;
        minThreshold = minThreshold_;
        _initOwner(admin_);
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert InvalidParams();
    }

    function setThresholds(uint256 minThreshold_, uint256 creatorDispatchThreshold_) external onlyOwner {
        minThreshold = minThreshold_;
        creatorDispatchThreshold = creatorDispatchThreshold_;
        emit ThresholdsSet(minThreshold_, creatorDispatchThreshold_);
    }

    function setPortal(address portal_) external onlyOwner {
        if (portal != address(0)) revert PortalAlreadySet();
        if (portal_ == address(0) || portal_.code.length == 0) revert InvalidParams();
        portal = portal_;
    }

    function process(address token) external nonReentrant returns (uint256 quoteOut) {
        IBnbTaxAccounting t = IBnbTaxAccounting(token);
        _validateToken(token, t);
        ProcessVars memory v;
        v.pair = t.mainPool();
        v.quote = t.quoteToken();
        if (v.pair == address(0) || v.quote == address(0)) revert InvalidParams();
        (v.reserveToken, v.reserveQuote) = _reserves(token, v.pair);
        if (v.reserveToken == 0 || v.reserveQuote == 0) revert NoLiquidity();
        (uint256 twapPriceX112, bool ready) =
            _twap(token, v.pair, v.reserveToken, v.reserveQuote, true);
        if (!ready) return 0;

        v.pending = t.pendingTax();
        uint256 dynamic = v.reserveToken * DYNAMIC_THRESHOLD_BPS / 10_000;
        uint256 threshold = dynamic > minThreshold ? dynamic : minThreshold;
        if (v.pending < threshold) revert BelowThreshold();
        uint256 maxAmount = _v2Cap(v.reserveToken);
        v.amount = v.pending > maxAmount ? maxAmount : v.pending;

        uint256 protocolBefore = t.protocolPending();
        v.protocolTokens = protocolBefore * v.amount / v.pending;
        v.harvested = t.harvestTax(v.amount);
        BnbTaxAllocation memory a = t.allocation();
        v = _calculate(t, a, v);
        if (v.burnTokens != 0) token.safeTransfer(DEAD, v.burnTokens);
        uint256 floor = v.sellAmount * twapPriceX112 / Q112 * (10_000 - V2_FEE_BPS)
            / 10_000 * (10_000 - MAX_IMPACT_BPS) / 10_000;
        quoteOut = _sell(token, v.quote, v.pair, v.sellAmount, v.reserveToken, v.reserveQuote, floor);
        v = _calculateQuote(a, v, quoteOut);
        _route(token, t, v, quoteOut);
        quoteBalanceCheckpoint[v.quote] = _balance(v.quote);
    }

    function notifyBurnQuote(address token, uint256 amount) external {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        if (msg.sender != portal) revert NotPortal();
        _validateToken(token, t);
        if (amount == 0) revert InvalidParams();
        address quote = t.quoteToken();
        uint256 current = _balance(quote);
        uint256 previous = quoteBalanceCheckpoint[quote];
        if (current < previous || current - previous < amount) revert QuoteTransferShortfall();
        quoteBalanceCheckpoint[quote] = current;
        burnQuotePending[token] += amount;
        emit BurnQuoteNotified(token, amount);
    }

    function buyAndBurn(address token) external nonReentrant returns (uint256 burned) {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        _validateToken(token, t);
        if (t.phase() != IStoxesBnbTaxToken.Phase.TaxEnforced) revert WrongPhase();
        BurnVars memory v;
        v.pair = t.mainPool();
        v.quote = t.quoteToken();
        v.pendingAmount = burnQuotePending[token];
        if (v.pendingAmount == 0) revert NothingPending();
        (v.reserveToken, v.reserveQuote) = _reserves(token, v.pair);
        if (v.reserveToken == 0 || v.reserveQuote == 0) revert NoLiquidity();
        (uint256 tokenPerQuoteX112, bool ready) =
            _twap(token, v.pair, v.reserveToken, v.reserveQuote, false);
        if (!ready) return 0;
        uint256 cap = _v2Cap(v.reserveQuote);
        v.amount = v.pendingAmount < cap ? v.pendingAmount : cap;
        v.floor = v.amount * tokenPerQuoteX112 / Q112 * (10_000 - V2_FEE_BPS)
            / 10_000 * (10_000 - MAX_IMPACT_BPS) / 10_000;
        uint256 amountWithFee = v.amount * (10_000 - V2_FEE_BPS);
        v.out = amountWithFee * v.reserveToken / (v.reserveQuote * 10_000 + amountWithFee);
        burnQuotePending[token] = v.pendingAmount - v.amount;
        v.quote.safeTransfer(v.pair, v.amount);
        uint256 beforeBal = _balance(token);
        bool quote0 = IUniswapV2Pair(v.pair).token0() == v.quote;
        IUniswapV2Pair(v.pair).swap(quote0 ? 0 : v.out, quote0 ? v.out : 0, address(this), "");
        burned = _balance(token) - beforeBal;
        if (burned < v.floor) revert FloorNotMet();
        token.safeTransfer(DEAD, burned);
        quoteBalanceCheckpoint[v.quote] = _balance(v.quote);
        emit BuyAndBurn(token, v.amount, burned);
    }

    function warmObservation(address token) external {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        _validateToken(token, t);
        if (msg.sender != portal) {
            bytes32 sellKey = keccak256(abi.encodePacked(token, true));
            if (!observationOf[address(uint160(uint256(sellKey)))].set) revert NotPortal();
        }
        address pair = t.mainPool();
        (uint256 reserveToken, uint256 reserveQuote) = _reserves(token, pair);
        if (reserveToken == 0 || reserveQuote == 0) revert NoLiquidity();
        _twap(token, pair, reserveToken, reserveQuote, true);
        _twap(token, pair, reserveToken, reserveQuote, false);
    }

    function _calculate(IBnbTaxAccounting t, BnbTaxAllocation memory a, ProcessVars memory v)
        internal
        view
        returns (ProcessVars memory)
    {
        uint256 nonProtocol = v.harvested - v.protocolTokens;
        v.commissionTokens = nonProtocol * t.commissionBps() / 10_000;
        v.bucketTokens = nonProtocol - v.commissionTokens;
        v.burnTokens = v.bucketTokens * a.burnBps / 10_000;
        uint256 liquidityTokens = v.bucketTokens * a.liquidityBps / 10_000;
        uint256 liquiditySell = liquidityTokens / 2;
        v.liquidityRetain = liquidityTokens - liquiditySell;
        v.sellAmount = v.harvested - v.burnTokens - v.liquidityRetain;
        return v;
    }

    function _calculateQuote(BnbTaxAllocation memory a, ProcessVars memory v, uint256 quoteOut)
        internal
        pure
        returns (ProcessVars memory)
    {
        v.protocolQuote = quoteOut * v.protocolTokens / v.sellAmount;
        v.commissionQuote = quoteOut * v.commissionTokens / v.sellAmount;
        uint256 distributableQuote = quoteOut - v.protocolQuote - v.commissionQuote;
        uint256 allocationSoldTokens = v.sellAmount - v.protocolTokens - v.commissionTokens;
        v.vaultQuote = allocationSoldTokens == 0
            ? 0
            : distributableQuote * (v.bucketTokens * a.vaultBps / 10_000) / allocationSoldTokens;
        v.creatorQuote = allocationSoldTokens == 0
            ? 0
            : distributableQuote * (v.bucketTokens * a.creatorBps / 10_000) / allocationSoldTokens;
        v.liquidityQuote =
            quoteOut - v.protocolQuote - v.commissionQuote - v.vaultQuote - v.creatorQuote;
        return v;
    }

    function _route(address token, IBnbTaxAccounting t, ProcessVars memory v, uint256 quoteOut) internal {
        if (v.protocolQuote != 0) {
            BnbQuotePayout.payoutQuote(v.quote, wrappedNative, treasury, v.protocolQuote);
        }
        if (v.commissionQuote != 0) {
            address receiver = t.commissionReceiver();
            if (receiver == address(0)) v.creatorQuote += v.commissionQuote;
            else BnbQuotePayout.payoutQuote(v.quote, wrappedNative, receiver, v.commissionQuote);
        }
        if (v.vaultQuote != 0) {
            address targetVault = t.vault();
            if (targetVault == address(0)) revert InvalidParams();
            v.quote.safeTransfer(targetVault, v.vaultQuote);
            IStoxesBnbVault(targetVault).ping();
        }
        if (v.creatorQuote != 0) creatorPending[token] += v.creatorQuote;
        if (creatorPending[token] >= creatorDispatchThreshold) _dispatch(token, v.quote, t.creator());

        if (v.liquidityRetain != 0 && v.liquidityQuote != 0) {
            token.safeTransfer(v.pair, v.liquidityRetain);
            v.quote.safeTransfer(v.pair, v.liquidityQuote);
            IUniswapV2Pair(v.pair).mint(DEAD);
        } else if (v.liquidityQuote != 0) {
            BnbQuotePayout.payoutQuote(v.quote, wrappedNative, treasury, v.liquidityQuote);
        }
        emit Processed(token, v.harvested, quoteOut, v.protocolQuote);
    }

    function dispatch(address token) external nonReentrant {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        _validateToken(token, t);
        _dispatch(token, t.quoteToken(), t.creator());
        quoteBalanceCheckpoint[t.quoteToken()] = _balance(t.quoteToken());
    }

    function _dispatch(address token, address quote, address creator) internal {
        uint256 amount = creatorPending[token];
        if (amount == 0) revert NothingPending();
        creatorPending[token] = 0;
        BnbQuotePayout.payoutQuote(quote, wrappedNative, creator, amount);
        emit CreatorDispatched(token, creator, amount);
    }

    function _sell(
        address token,
        address quote,
        address pair,
        uint256 amount,
        uint256 reserveToken,
        uint256 reserveQuote,
        uint256 floor
    ) internal returns (uint256 out) {
        token.safeTransfer(pair, amount);
        uint256 amountWithFee = amount * (10_000 - V2_FEE_BPS);
        out = amountWithFee * reserveQuote / (reserveToken * 10_000 + amountWithFee);
        uint256 beforeBal = _balance(quote);
        bool token0 = IUniswapV2Pair(pair).token0() == token;
        IUniswapV2Pair(pair).swap(token0 ? 0 : out, token0 ? out : 0, address(this), "");
        uint256 received = _balance(quote) - beforeBal;
        if (received < floor) revert FloorNotMet();
        out = received;
    }

    function _twap(
        address token,
        address pair,
        uint256 reserveToken,
        uint256 reserveQuote,
        bool tokenToQuote
    ) internal returns (uint256 priceX112, bool ready) {
        bool token0 = IUniswapV2Pair(pair).token0() == token;
        uint256 cumulative = tokenToQuote
            ? (token0 ? IUniswapV2Pair(pair).price0CumulativeLast() : IUniswapV2Pair(pair).price1CumulativeLast())
            : (token0 ? IUniswapV2Pair(pair).price1CumulativeLast() : IUniswapV2Pair(pair).price0CumulativeLast());
        (,, uint32 last) = IUniswapV2Pair(pair).getReserves();
        uint32 nowTs = uint32(block.timestamp);
        if (last != nowTs) {
            uint32 elapsed;
            unchecked { elapsed = nowTs - last; }
            uint256 spot = tokenToQuote
                ? reserveQuote * Q112 / reserveToken
                : reserveToken * Q112 / reserveQuote;
            cumulative += spot * elapsed;
        }
        bytes32 key = keccak256(abi.encodePacked(token, tokenToQuote));
        address observationKey = address(uint160(uint256(key)));
        Observation memory o = observationOf[observationKey];
        if (!o.set) {
            observationOf[observationKey] = Observation(cumulative, nowTs, true);
            emit OracleWarmed(token, cumulative, nowTs);
            return (0, false);
        }
        uint32 elapsedWindow;
        unchecked { elapsedWindow = nowTs - o.timestamp; }
        if (elapsedWindow < TWAP_WINDOW) return (0, false);
        priceX112 = (cumulative - o.cumulative) / elapsedWindow;
        observationOf[observationKey] = Observation(cumulative, nowTs, true);
        ready = priceX112 != 0;
    }

    function _reserves(address token, address pair) internal view returns (uint256 rt, uint256 rq) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (rt, rq) = IUniswapV2Pair(pair).token0() == token ? (r0, r1) : (r1, r0);
    }

    function _v2Cap(uint256 reserveIn) internal pure returns (uint256) {
        uint256 impact = MAX_IMPACT_BPS;
        uint256 fee = V2_FEE_BPS;
        if (fee >= impact) {
            return reserveIn * impact / (2 * (10_000 - impact));
        }
        return reserveIn * (impact - fee) * 10_000 / ((10_000 - impact) * (10_000 - fee));
    }

    function _balance(address token) internal view returns (uint256 amount) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) revert InvalidParams();
        amount = abi.decode(data, (uint256));
    }

    function _validateToken(address token, IStoxesBnbTaxToken t) internal view {
        if (portal == address(0) || t.taxProcessor() != address(this)) revert UnregisteredToken();
        (BnbLaunchKind kind, address quote,,,,) = IBnbTrustedPortal(portal).tokenState(token);
        if (kind != BnbLaunchKind.Tax || quote == address(0) || quote != t.quoteToken()) {
            revert UnregisteredToken();
        }
    }
}