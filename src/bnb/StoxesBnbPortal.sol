// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite, ReentrancyGuardLite, SafeERC20Lite} from "../base/Common.sol";
import {LibCurve} from "../libraries/LibCurve.sol";
import {FixedPointMathLib} from "../vendor/FixedPointMathLib.sol";
import {StoxesBnbPortalMath} from "./libraries/StoxesBnbPortalMath.sol";
import {BnbQuotePayout} from "./libraries/BnbQuotePayout.sol";
import {
    BnbFeeMode,
    BnbLaunchKind,
    BnbTaxAllocation,
    IStoxesBnbPortal,
    IStoxesBnbSimpleToken,
    IStoxesBnbTaxToken,
    IStoxesBnbVault
} from "./IStoxesBnb.sol";
import {IWETH} from "../interfaces/IWETH.sol";

interface IERC20BnbPortal {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStoxesBnbLocker {
    function register(
        address token,
        uint256 tokenId,
        BnbFeeMode feeMode,
        uint16 creatorShareBps,
        address creator,
        address quote
    ) external;
}

interface IStoxesBnbGraduator {
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

    function beginSimple(SimpleParams calldata p)
        external
        returns (bool, address, uint256, uint256, uint256);
    function beginTax(address token, address quote, address pair, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (bool);
    function finalize(address token) external returns (address, uint256, uint256, uint256, bool, bool);
    function prepareSimplePool(address token, address quote) external returns (address);
}

interface IStoxesBnbTaxProcessorNotify {
    function notifyBurnQuote(address token, uint256 amount) external;
    function warmObservation(address token) external;
}

/// @notice Bonding-curve venue for native and registered stock-quoted launches.
contract StoxesBnbPortal is IStoxesBnbPortal, OwnableLite, ReentrancyGuardLite {
    using LibCurve for LibCurve.Curve;
    using SafeERC20Lite for address;

    uint256 public constant CURVE_FEE_BPS = 100;
    uint256 public constant PROTOCOL_BPS_OF_TAXED_VOLUME = 30;
    // Compatibility getters for older clients. No per-wallet purchase limit is enforced.
    uint256 public constant MAX_BUY_BPS_OF_CURVE = type(uint256).max;
    uint256 public constant MAX_ORIGIN_TOKENS = type(uint256).max;
    uint256 public constant CURVE_SALE_SUPPLY = 800_000_000 ether;

    struct QuoteParams {
        uint128 r;
        uint128 h;
        uint256 k;
        uint128 graduationQuote;
        uint8 decimals;
        bool allowed;
    }

    struct State {
        BnbLaunchKind kind;
        address quoteToken;
        address creator;
        address vault;
        address pool;
        uint128 sold;
        uint128 quoteReserve;
        bool graduated;
        bool pendingGraduation;
    }

    struct TaxEscrow {
        uint128 burn;
        uint128 liquidity;
    }

    struct TokenCurve {
        uint128 r;
        uint128 h;
        uint256 k;
        uint128 graduationQuote;
        uint8 decimals;
    }

    struct TaxAmounts {
        uint256 protocolAmount;
        uint256 commissionAmount;
        uint256 vaultAmount;
        uint256 creatorAmount;
        uint256 burnAmount;
        uint256 liquidityAmount;
        address commissionReceiver;
    }

    struct BuyAmounts {
        uint256 tokensOut;
        uint256 quoteSpent;
        uint256 fee;
        uint256 tax;
        uint256 principal;
    }

    address public immutable WBNB;
    address public immutable treasury;
    address public immutable graduator;
    address public factory;
    address public locker;
    uint256 public creatorDispatchThreshold = 0.006 ether;

    mapping(address => QuoteParams) public quoteParams;
    mapping(address => State) private _states;
    mapping(address => mapping(address => uint256)) public originBought;
    mapping(address => uint256) public creatorBucket;
    mapping(address => TaxEscrow) public taxEscrow;
    // Recipient guard only: public pool/phase semantics remain unchanged until
    // V3 graduation. Reserve even the not-yet-initialized canonical V3 address.
    mapping(address => address) private _curvePool;
    mapping(address => TokenCurve) public tokenCurve;

    event QuoteParamsSet(
        address indexed quote, uint256 r, uint256 h, uint256 k, uint256 graduationQuote, bool allowed
    );
    event FactorySet(address indexed factory);
    event LockerSet(address indexed locker);
    event CreatorDispatchThresholdSet(uint256 threshold);
    event TokenRegistered(
        address indexed token,
        address indexed quoteToken,
        BnbLaunchKind kind,
        address indexed creator,
        address vault,
        address pair
    );
    event Bought(
        address indexed token,
        address indexed buyer,
        address indexed origin,
        uint256 quoteSpent,
        uint256 fee,
        uint256 tax,
        uint256 tokensOut,
        uint256 refund
    );
    event Sold(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 grossQuote,
        uint256 fee,
        uint256 tax,
        uint256 quoteOut
    );
    event TaxRouted(
        address indexed token,
        uint256 protocolAmount,
        uint256 commissionAmount,
        uint256 vaultAmount,
        uint256 creatorAmount,
        uint256 burnAmount,
        uint256 liquidityAmount
    );
    event CreatorDispatched(address indexed token, address indexed creator, uint256 amount);
    event GraduationDeferred(
        address indexed token, address indexed pool, uint256 tokenAmount, uint256 quoteAmount
    );
    event Graduated(
        address indexed token,
        address indexed pool,
        BnbLaunchKind kind,
        uint256 tokenAmount,
        uint256 quoteAmount
    );

    error InvalidParams();
    error NotFactory();
    error FactoryAlreadySet();
    error NotBonding();
    error ZeroTrade();
    error SlippageExceeded();
    error NativeValueMismatch();
    error NativeTransferFailed();
    error NothingToDispatch();
    error NoPendingGraduation();
    error UnexpectedNative();
    error LockerAlreadySet();
    error QuoteTransferShortfall();

    constructor(address wbnb_, address treasury_, address graduator_, address admin_) {
        if (wbnb_ == address(0) || treasury_ == address(0) || graduator_ == address(0)) {
            revert InvalidParams();
        }
        WBNB = wbnb_;
        treasury = treasury_;
        graduator = graduator_;
        _initOwner(admin_);
    }

    receive() external payable {
        if (msg.sender != WBNB) revert UnexpectedNative();
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert InvalidParams();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setLocker(address locker_) external onlyOwner {
        if (locker != address(0)) revert LockerAlreadySet();
        if (locker_ == address(0) || locker_.code.length == 0) revert InvalidParams();
        locker = locker_;
        emit LockerSet(locker_);
    }

    function setCreatorDispatchThreshold(uint256 threshold) external onlyOwner {
        creatorDispatchThreshold = threshold;
        emit CreatorDispatchThresholdSet(threshold);
    }

    function setQuoteParams(
        address quote,
        uint256 r,
        uint256 h,
        uint256 k,
        uint256 graduationQuote,
        bool allowed
    ) external onlyOwner {
        address normalized = quote == address(0) ? WBNB : quote;
        uint8 decimals = IERC20BnbPortal(normalized).decimals();
        if (decimals > 18 || r == 0 || k == 0 || graduationQuote == 0) revert InvalidParams();
        quoteParams[normalized] = QuoteParams({
            r: uint128(r),
            h: uint128(h),
            k: k,
            graduationQuote: uint128(graduationQuote),
            decimals: decimals,
            allowed: allowed
        });
        emit QuoteParamsSet(normalized, r, h, k, graduationQuote, allowed);
    }

    function registerToken(Registration calldata reg) external {
        _registerToken(reg, 0);
    }

    /// @notice Only the trusted factory's authorized test path may call this.
    /// Quote amounts are raw asset units; r/k are scaled together so this is a
    /// smaller/larger curve, not premature graduation on the public curve.
    function registerTestToken(Registration calldata reg, uint256 graduationQuote) external {
        if (graduationQuote == 0 || graduationQuote > type(uint128).max) revert InvalidParams();
        _registerToken(reg, graduationQuote);
    }

    function _registerToken(Registration calldata reg, uint256 graduationQuote) private {
        if (msg.sender != factory) revert NotFactory();
        QuoteParams memory qp = quoteParams[reg.quoteToken];
        if (
            reg.token == address(0) || reg.creator == address(0) || !qp.allowed
                || _states[reg.token].kind != BnbLaunchKind.Unknown
        ) revert InvalidParams();
        if (graduationQuote != 0) {
            uint256 r = FixedPointMathLib.fullMulDiv(qp.r, graduationQuote, qp.graduationQuote);
            uint256 k = FixedPointMathLib.fullMulDiv(qp.k, graduationQuote, qp.graduationQuote);
            // Reject precision collapse and truncation rather than install a
            // degenerate curve. h and asset decimals remain unchanged.
            if (r == 0 || r > type(uint128).max || k == 0) revert InvalidParams();
            qp.r = uint128(r);
            qp.k = k;
            qp.graduationQuote = uint128(graduationQuote);
        }
        if (reg.kind != BnbLaunchKind.Simple && reg.kind != BnbLaunchKind.Tax) revert InvalidParams();
        if (reg.kind == BnbLaunchKind.Tax && reg.pair == address(0)) revert InvalidParams();
        if (reg.kind == BnbLaunchKind.Simple && (reg.pair != address(0) || locker == address(0))) {
            revert InvalidParams();
        }
        if (reg.kind == BnbLaunchKind.Tax) {
            BnbTaxAllocation memory a = IStoxesBnbTaxToken(reg.token).allocation();
            if (a.vaultBps != 0 && reg.vault == address(0)) revert InvalidParams();
        }
        _states[reg.token] = State({
            kind: reg.kind,
            quoteToken: reg.quoteToken,
            creator: reg.creator,
            vault: reg.vault,
            pool: reg.pair,
            sold: 0,
            quoteReserve: 0,
            graduated: false,
            pendingGraduation: false
        });
        tokenCurve[reg.token] = TokenCurve(qp.r, qp.h, qp.k, qp.graduationQuote, qp.decimals);
        _curvePool[reg.token] = reg.kind == BnbLaunchKind.Tax
            ? reg.pair
            : IStoxesBnbGraduator(graduator).prepareSimplePool(reg.token, reg.quoteToken);
        emit TokenRegistered(reg.token, reg.quoteToken, reg.kind, reg.creator, reg.vault, reg.pair);
    }

    function buy(address token, uint256 minOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 quoteSpent)
    {
        if (_states[token].quoteToken != WBNB) revert NativeValueMismatch();
        return _buy(token, msg.sender, msg.sender, msg.value, minOut, true);
    }

    function buyWithQuote(address token, uint256 quoteAmount, uint256 minOut)
        external
        nonReentrant
        returns (uint256 tokensOut, uint256 quoteSpent)
    {
        if (_states[token].quoteToken == WBNB) revert NativeValueMismatch();
        return _buy(token, msg.sender, msg.sender, quoteAmount, minOut, false);
    }

    function buyFor(
        address token,
        address recipient,
        address refundTo,
        uint256 quoteAmount,
        uint256 minTokensOut
    ) external payable nonReentrant returns (uint256 tokensOut, uint256 quoteSpent) {
        if (recipient == address(0) || refundTo == address(0)) revert InvalidParams();
        bool native = _states[token].quoteToken == WBNB;
        if ((native && msg.value != quoteAmount) || (!native && msg.value != 0)) revert NativeValueMismatch();
        return _buy(token, recipient, refundTo, quoteAmount, minTokensOut, native);
    }

    function _buy(
        address token,
        address recipient,
        address refundTo,
        uint256 offered,
        uint256 minOut,
        bool native
    ) internal returns (uint256 tokensOut, uint256 quoteSpent) {
        State memory s = _states[token];
        if (s.kind == BnbLaunchKind.Unknown || s.graduated) revert NotBonding();
        // Forwarded delivery/refunds must not seed the canonical DEX pool
        // through the Portal's otherwise permitted pre-graduation transfers.
        if (recipient == _curvePool[token] || refundTo == _curvePool[token]) revert InvalidParams();
        if (offered == 0) revert ZeroTrade();
        if (native) {
            IWETH(WBNB).deposit{value: offered}();
        } else {
            uint256 beforeBalance = IERC20BnbPortal(s.quoteToken).balanceOf(address(this));
            s.quoteToken.safeTransferFrom(msg.sender, address(this), offered);
            if (IERC20BnbPortal(s.quoteToken).balanceOf(address(this)) - beforeBalance != offered) {
                revert QuoteTransferShortfall();
            }
        }
        BuyAmounts memory x = _buyAmounts(token, s, offered);
        tokensOut = x.tokensOut;
        quoteSpent = x.quoteSpent;
        if (tokensOut < minOut) revert SlippageExceeded();
        s.sold += uint128(tokensOut);
        s.quoteReserve += uint128(x.principal);
        _states[token] = s;
        originBought[token][tx.origin] += tokensOut;
        token.safeTransfer(recipient, tokensOut);
        BnbQuotePayout.payoutQuote(s.quoteToken, WBNB, treasury, x.fee);
        if (x.tax != 0) _routeTax(token, s, x.tax, quoteSpent);

        uint256 refund = offered - quoteSpent;
        if (refund != 0) _refund(s.quoteToken, refundTo, refund, native);
        emit Bought(token, recipient, tx.origin, quoteSpent, x.fee, x.tax, tokensOut, refund);

        TokenCurve memory qp = tokenCurve[token];
        if (s.quoteReserve >= qp.graduationQuote || s.sold >= CURVE_SALE_SUPPLY) {
            _beginGraduation(token, s);
        }
    }

    function _buyAmounts(address token, State memory s, uint256 offered)
        internal
        view
        returns (BuyAmounts memory x)
    {
        TokenCurve memory qp = tokenCurve[token];
        uint256 taxBps = s.kind == BnbLaunchKind.Tax ? IStoxesBnbTaxToken(token).buyTaxBps() : 0;
        (uint256 tokenRoom, uint256 principalLimit) = _buyCaps(token, s, qp);
        uint256 denominator = 10_000 - CURVE_FEE_BPS - taxBps;
        uint256 maxGross = FixedPointMathLib.mulDivUp(principalLimit, 10_000, denominator);
        x.quoteSpent = offered < maxGross ? offered : maxGross;
        x.fee = x.quoteSpent * CURVE_FEE_BPS / 10_000;
        x.tax = x.quoteSpent * taxBps / 10_000;
        x.principal = x.quoteSpent - x.fee - x.tax;
        if (x.principal > principalLimit) {
            x.principal = principalLimit;
            x.quoteSpent = FixedPointMathLib.mulDivUp(x.principal, 10_000, denominator);
            x.fee = x.quoteSpent * CURVE_FEE_BPS / 10_000;
            x.tax = x.quoteSpent * taxBps / 10_000;
            x.quoteSpent = x.principal + x.fee + x.tax;
        }
        uint256 newSupply =
            LibCurve.fromRHK(qp.r, qp.h, qp.k).estimateSupplyV2(s.quoteReserve + x.principal, qp.decimals);
        x.tokensOut = newSupply - s.sold;
        if (x.tokensOut > tokenRoom) x.tokensOut = tokenRoom;
        if (x.tokensOut == 0) revert ZeroTrade();
    }

    function _buyCaps(address token, State memory s, TokenCurve memory qp)
        internal
        view
        returns (uint256 tokenRoom, uint256 principalLimit)
    {
        // Only market-wide inventory and the graduation reserve constrain a buy.
        // originBought is historical accounting, never a wallet quota.
        tokenRoom = CURVE_SALE_SUPPLY - s.sold;
        if (tokenRoom == 0) revert ZeroTrade();
        LibCurve.Curve memory curve = LibCurve.fromRHK(qp.r, qp.h, qp.k);
        uint256 reserveLimit = curve.estimateReserveV2(s.sold + tokenRoom, qp.decimals);
        principalLimit = reserveLimit - s.quoteReserve;
        uint256 reserveRoom = qp.graduationQuote - s.quoteReserve;
        if (principalLimit > reserveRoom) principalLimit = reserveRoom;
    }

    function sell(address token, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        return _sell(token, msg.sender, amount, minQuoteOut);
    }

    /// @notice Sell `amount` tokens (pulled from msg.sender) and pay the quote
    ///         proceeds to `recipient` instead of the caller. For integrators.
    function sellFor(address token, address recipient, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (recipient == address(0)) revert InvalidParams();
        return _sell(token, recipient, amount, minQuoteOut);
    }

    struct SellMath {
        uint256 newSold;
        uint256 newReserve;
        uint256 gross;
        uint256 fee;
        uint256 tax;
    }

    function _sellMath(address token, State memory s, uint256 amount) internal view returns (SellMath memory m) {
        TokenCurve memory qp = tokenCurve[token];
        m.newSold = s.sold - amount;
        m.newReserve = LibCurve.fromRHK(qp.r, qp.h, qp.k).estimateReserveV2(m.newSold, qp.decimals);
        m.gross = s.quoteReserve - m.newReserve;
        m.fee = m.gross * CURVE_FEE_BPS / 10_000;
        uint256 taxBps = s.kind == BnbLaunchKind.Tax ? IStoxesBnbTaxToken(token).sellTaxBps() : 0;
        m.tax = m.gross * taxBps / 10_000;
    }

    function _sell(address token, address recipient, uint256 amount, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        State memory s = _states[token];
        if (s.kind == BnbLaunchKind.Unknown || s.graduated) revert NotBonding();
        if (recipient == _curvePool[token]) revert InvalidParams();
        if (amount == 0 || amount > s.sold) revert ZeroTrade();
        SellMath memory m = _sellMath(token, s, amount);
        quoteOut = m.gross - m.fee - m.tax;
        if (quoteOut == 0) revert ZeroTrade();
        if (quoteOut < minQuoteOut) revert SlippageExceeded();

        token.safeTransferFrom(msg.sender, address(this), amount);
        s.sold = uint128(m.newSold);
        s.quoteReserve = uint128(m.newReserve);
        _states[token] = s;
        BnbQuotePayout.payoutQuote(s.quoteToken, WBNB, treasury, m.fee);
        if (m.tax != 0) _routeTax(token, s, m.tax, m.gross);
        BnbQuotePayout.payoutQuote(s.quoteToken, WBNB, recipient, quoteOut);
        emit Sold(token, msg.sender, amount, m.gross, m.fee, m.tax, quoteOut);
    }

    function _routeTax(address token, State memory s, uint256 tax, uint256 volume) internal {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        TaxAmounts memory x = _taxAmounts(t, tax, volume);
        if (x.protocolAmount != 0) {
            BnbQuotePayout.payoutQuote(s.quoteToken, WBNB, treasury, x.protocolAmount);
        }
        if (x.commissionAmount != 0) {
            BnbQuotePayout.payoutQuote(
                s.quoteToken, WBNB, x.commissionReceiver, x.commissionAmount
            );
        }
        if (x.vaultAmount != 0) {
            s.quoteToken.safeTransfer(s.vault, x.vaultAmount);
            IStoxesBnbVault(s.vault).ping();
        }
        creatorBucket[token] += x.creatorAmount;
        taxEscrow[token].burn += uint128(x.burnAmount);
        taxEscrow[token].liquidity += uint128(x.liquidityAmount);
        emit TaxRouted(
            token,
            x.protocolAmount,
            x.commissionAmount,
            x.vaultAmount,
            x.creatorAmount,
            x.burnAmount,
            x.liquidityAmount
        );
        if (_normalized(creatorBucket[token], tokenCurve[token].decimals) >= creatorDispatchThreshold)
        {
            _dispatchCreator(token, s);
        }
    }

    function _taxAmounts(IStoxesBnbTaxToken t, uint256 tax, uint256 volume)
        internal
        view
        returns (TaxAmounts memory x)
    {
        x.commissionReceiver = t.commissionReceiver();
        BnbTaxAllocation memory a = t.allocation();
        uint16 commission = x.commissionReceiver == address(0) ? 0 : t.commissionBps();
        (
            x.protocolAmount,
            x.commissionAmount,
            x.vaultAmount,
            x.creatorAmount,
            x.burnAmount,
            x.liquidityAmount
        ) = StoxesBnbPortalMath.taxAmounts(tax, volume, commission, a.vaultBps, a.creatorBps, a.burnBps);
    }

    function dispatchCreator(address token) external nonReentrant returns (uint256 amount) {
        State memory s = _states[token];
        amount = _dispatchCreator(token, s);
    }

    function _dispatchCreator(address token, State memory s) internal returns (uint256 amount) {
        amount = creatorBucket[token];
        if (amount == 0) revert NothingToDispatch();
        creatorBucket[token] = 0;
        BnbQuotePayout.payoutQuote(s.quoteToken, WBNB, s.creator, amount);
        emit CreatorDispatched(token, s.creator, amount);
    }

    function _beginGraduation(address token, State memory s) internal {
        s.graduated = true;
        if (s.kind == BnbLaunchKind.Simple) {
            _graduateSimple(token, s);
        } else {
            _graduateTax(token, s);
        }
    }

    function _graduateTax(address token, State memory s) internal {
        IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
        t.setMigrationOperator(graduator);
        t.startMigration();
        uint256 tokenAmount = IERC20BnbPortal(token).balanceOf(address(this));
        TaxEscrow memory escrow = taxEscrow[token];
        uint256 quoteAmount = uint256(s.quoteReserve) + escrow.liquidity;
        if (escrow.burn != 0) {
            address processor = t.taxProcessor();
            s.quoteToken.safeTransfer(processor, escrow.burn);
            IStoxesBnbTaxProcessorNotify(processor).notifyBurnQuote(token, escrow.burn);
        }
        _approveGraduator(token, s.quoteToken, tokenAmount, quoteAmount);
        bool complete =
            IStoxesBnbGraduator(graduator).beginTax(token, s.quoteToken, s.pool, tokenAmount, quoteAmount);
        delete taxEscrow[token];
        s.pendingGraduation = !complete;
        if (complete) {
            s.quoteReserve = 0;
            t.finalizeMigration(s.pool);
            IStoxesBnbTaxProcessorNotify(t.taxProcessor()).warmObservation(token);
            emit Graduated(token, s.pool, s.kind, tokenAmount, quoteAmount);
        } else {
            emit GraduationDeferred(token, s.pool, tokenAmount, quoteAmount);
        }
        _states[token] = s;
    }

    function _graduateSimple(address token, State memory s) internal {
        IStoxesBnbSimpleToken(token).setMigrationOperator(graduator);
        IStoxesBnbSimpleToken(token).startMigration();
        uint256 tokenAmount = IERC20BnbPortal(token).balanceOf(address(this));
        uint256 quoteAmount = s.quoteReserve;
        TokenCurve memory q = tokenCurve[token];
        uint256 initialPrice = LibCurve.fromRHK(q.r, q.h, q.k).price(0);
        uint256 currentPrice = LibCurve.fromRHK(q.r, q.h, q.k).price(s.sold);
        _approveGraduator(token, s.quoteToken, tokenAmount, quoteAmount);
        (bool complete, address pool, uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed) =
        IStoxesBnbGraduator(graduator).beginSimple(
            IStoxesBnbGraduator.SimpleParams(
                token, s.quoteToken, locker, tokenAmount, quoteAmount, initialPrice, currentPrice, q.decimals
            )
        );
        s.pool = pool;
        s.pendingGraduation = !complete;
        if (!complete) {
            emit GraduationDeferred(token, pool, tokenAmount, quoteAmount);
        } else {
            s.quoteReserve = 0;
            _registerPosition(token, s, tokenId);
            IStoxesBnbSimpleToken(token).finalizeMigration();
            emit Graduated(token, pool, s.kind, tokenUsed, quoteUsed);
        }
        _states[token] = s;
    }

    function finalizeGraduation(address token) external nonReentrant {
        State memory s = _states[token];
        if (!s.pendingGraduation) revert NoPendingGraduation();
        (address pool, uint256 tokenId, uint256 tokenUsed, uint256 quoteUsed, bool simple, bool complete) =
            IStoxesBnbGraduator(graduator).finalize(token);
        if (!complete) {
            emit GraduationDeferred(token, pool, 0, 0);
            return;
        }
        s.pendingGraduation = false;
        s.quoteReserve = 0;
        s.pool = pool;
        _states[token] = s;
        if (simple) {
            _registerPosition(token, s, tokenId);
            IStoxesBnbSimpleToken(token).finalizeMigration();
        } else {
            IStoxesBnbTaxToken(token).finalizeMigration(pool);
            IStoxesBnbTaxProcessorNotify(IStoxesBnbTaxToken(token).taxProcessor()).warmObservation(token);
        }
        emit Graduated(token, pool, s.kind, tokenUsed, quoteUsed);
    }

    function _registerPosition(address token, State memory s, uint256 tokenId) internal {
        IStoxesBnbSimpleToken simple = IStoxesBnbSimpleToken(token);
        IStoxesBnbLocker(locker).register(
            token, tokenId, simple.feeMode(), simple.creatorFeeShareBps(), s.creator, s.quoteToken
        );
    }

    function _approveGraduator(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        internal
    {
        if (!IERC20BnbPortal(token).approve(graduator, tokenAmount)) revert InvalidParams();
        if (!IERC20BnbPortal(quote).approve(graduator, quoteAmount)) revert InvalidParams();
    }

    function _refund(address quote, address to, uint256 amount, bool) internal {
        BnbQuotePayout.payoutQuote(quote, WBNB, to, amount);
    }

    function _normalized(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return decimals == 18 ? amount : amount * (10 ** (18 - decimals));
    }

    function tokenState(address token)
        external
        view
        returns (
            BnbLaunchKind kind,
            address quoteToken,
            bool graduated,
            bool finalized,
            uint256 sold,
            uint256 quoteReserve
        )
    {
        State memory s = _states[token];
        return (s.kind, s.quoteToken, s.graduated, s.graduated && !s.pendingGraduation, s.sold, s.quoteReserve);
    }

    /// @notice Full lifecycle record used by the Lens and launch-bound vaults.
    function stateDetails(address token)
        external
        view
        returns (
            BnbLaunchKind kind,
            address quoteToken,
            address creator,
            address vault,
            address pool,
            uint128 sold,
            uint128 quoteReserve,
            bool graduated,
            bool pendingGraduation,
            bool finalized
        )
    {
        State memory s = _states[token];
        return (
            s.kind,
            s.quoteToken,
            s.creator,
            s.vault,
            s.pool,
            s.sold,
            s.quoteReserve,
            s.graduated,
            s.pendingGraduation,
            s.graduated && !s.pendingGraduation
        );
    }

    function curvePrice(address token) external view returns (uint256) {
        return _curvePrice(token);
    }

    function _curvePrice(address token) internal view returns (uint256) {
        State memory s = _states[token];
        TokenCurve memory q = tokenCurve[token];
        return LibCurve.fromRHK(q.r, q.h, q.k).price(s.sold);
    }
}
