// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite, ReentrancyGuardLite, SafeERC20Lite} from "../base/Common.sol";
import {BnbFeeMode} from "./IStoxesBnb.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3FactoryMinimal,
    IUniswapV3PoolMinimal,
    IPancakeV3SwapCallback
} from "../interfaces/IUniswapV3.sol";
import {TickMath} from "../vendor/TickMath.sol";
import {V3SpotQuote} from "../libraries/V3SpotQuote.sol";
import {BnbQuotePayout} from "./libraries/BnbQuotePayout.sol";

contract StoxesBnbV3Locker is OwnableLite, ReentrancyGuardLite, IPancakeV3SwapCallback {
    using SafeERC20Lite for address;

    uint24 public constant V3_POOL_FEE = 10_000;
    uint16 public constant MAX_CREATOR_FEE_SHARE_BPS = 5_000;
    uint16 public constant BUYBACK_FLOOR_TOLERANCE_BPS = 300;
    uint32 public constant TWAP_WINDOW = 1800;
    uint32 public constant MIN_TWAP_WINDOW = 120;
    uint16 public constant ORACLE_CARDINALITY = 200;
    uint16 public constant MAX_ORACLE_GROW_STEP = 500;
    int24 private constant IMPACT_LIMIT_TICKS = 409;
    address public constant DEAD = address(0xdead);

    address public immutable portal;
    address public immutable wrappedNative;
    address public immutable positionManager;
    address public immutable v3Factory;
    address public immutable swapRouter;
    address public immutable treasury;
    uint256 public dispatchThreshold = 0.006 ether;

    struct FeeRecord {
        uint256 tokenId;
        address pool;
        address quote;
        address creator;
        BnbFeeMode mode;
        uint16 creatorShareBps;
        uint256 creatorPending;
        uint256 treasuryPending;
        uint256 holdersPending;
        uint256 tokenPending;
        uint256 totalCollected;
        uint256 totalDispatched;
    }

    struct SwapVars {
        bool zeroForOne;
        uint160 limit;
        int256 amount0;
        int256 amount1;
    }

    mapping(address => FeeRecord) private _fees;
    mapping(uint256 => bool) public tokenIdUsed;
    address private _activePool;
    address private _activeToken;

    event PositionRegistered(
        address indexed token,
        uint256 indexed tokenId,
        address indexed creator,
        address quote,
        BnbFeeMode mode,
        uint16 creatorShareBps
    );
    event FeesCollected(address indexed token, uint256 tokenFees, uint256 quoteFees);
    event Dispatched(
        address indexed token, uint256 creatorAmount, uint256 treasuryAmount, uint256 buybackQuote, uint256 burned
    );
    event DispatchThresholdSet(uint256 threshold);

    error NotPortal();
    error InvalidParams();
    error AlreadyRegistered();
    error UnknownToken();
    error PositionNotOwned();
    error NothingPending();

    constructor(
        address portal_,
        address wrappedNative_,
        address positionManager_,
        address v3Factory_,
        address swapRouter_,
        address treasury_,
        address admin_
    ) {
        if (
            portal_ == address(0) || wrappedNative_ == address(0) || positionManager_ == address(0) || v3Factory_ == address(0)
                || swapRouter_ == address(0) || treasury_ == address(0)
        ) revert InvalidParams();
        portal = portal_;
        wrappedNative = wrappedNative_;
        positionManager = positionManager_;
        v3Factory = v3Factory_;
        swapRouter = swapRouter_;
        treasury = treasury_;
        _initOwner(admin_);
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert InvalidParams();
    }

    function setDispatchThreshold(uint256 threshold) external onlyOwner {
        dispatchThreshold = threshold;
        emit DispatchThresholdSet(threshold);
    }

    function growOracle(address token, uint16 step) external {
        FeeRecord storage f = _fees[token];
        if (f.creator == address(0)) revert UnknownToken();
        if (step == 0 || step > MAX_ORACLE_GROW_STEP) revert InvalidParams();
        (,,,, uint16 next,,) = IUniswapV3PoolMinimal(f.pool).slot0();
        uint256 target = uint256(next) + step;
        if (target > type(uint16).max) target = type(uint16).max;
        IUniswapV3PoolMinimal(f.pool).increaseObservationCardinalityNext(uint16(target));
    }

    function register(
        address token,
        uint256 tokenId,
        BnbFeeMode feeMode,
        uint16 creatorShareBps,
        address creator,
        address quote
    ) external {
        if (msg.sender != portal) revert NotPortal();
        if (
            token == address(0) || quote == address(0) || creator == address(0)
                || creatorShareBps > MAX_CREATOR_FEE_SHARE_BPS
        ) revert InvalidParams();
        if (_fees[token].creator != address(0) || tokenIdUsed[tokenId]) revert AlreadyRegistered();
        if (INonfungiblePositionManager(positionManager).ownerOf(tokenId) != address(this)) {
            revert PositionNotOwned();
        }
        address pool = IUniswapV3FactoryMinimal(v3Factory).getPool(token, quote, V3_POOL_FEE);
        if (pool == address(0)) revert InvalidParams();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        if (
            p.fee() != V3_POOL_FEE
                || !(
                    (p.token0() == token && p.token1() == quote)
                        || (p.token0() == quote && p.token1() == token)
                )
        ) revert InvalidParams();
        tokenIdUsed[tokenId] = true;
        p.increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        _fees[token] = FeeRecord({
            tokenId: tokenId,
            pool: pool,
            quote: quote,
            creator: creator,
            mode: feeMode,
            creatorShareBps: creatorShareBps,
            creatorPending: 0,
            treasuryPending: 0,
            holdersPending: 0,
            tokenPending: 0,
            totalCollected: 0,
            totalDispatched: 0
        });
        emit PositionRegistered(token, tokenId, creator, quote, feeMode, creatorShareBps);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert InvalidParams();
        return this.onERC721Received.selector;
    }

    function collect(address token) external nonReentrant returns (uint256 quoteFees) {
        FeeRecord storage f = _fees[token];
        if (f.creator == address(0)) revert UnknownToken();
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: f.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        bool token0 = IUniswapV3PoolMinimal(f.pool).token0() == token;
        uint256 tokenFees = (token0 ? amount0 : amount1) + f.tokenPending;
        quoteFees = token0 ? amount1 : amount0;

        if (tokenFees != 0) {
            (uint160 twapSqrt, int24 twapTick, bool ready) = _tryTwap(f.pool);
            if (!ready) {
                f.tokenPending = tokenFees;
                _accountQuote(f, quoteFees);
                emit FeesCollected(token, tokenFees, quoteFees);
                if (f.creatorPending + f.treasuryPending + f.holdersPending >= dispatchThreshold) {
                    _dispatch(token, f);
                }
                return quoteFees;
            }
            (uint256 consumed, uint256 out) =
                _poolSwap(f.pool, token, address(this), tokenFees, twapSqrt, twapTick);
            f.tokenPending = tokenFees - consumed;
            quoteFees += out;
        }
        _accountQuote(f, quoteFees);
        emit FeesCollected(token, tokenFees, quoteFees);
        if (f.creatorPending + f.treasuryPending + f.holdersPending >= dispatchThreshold) {
            _dispatch(token, f);
        }
    }

    function _accountQuote(FeeRecord storage f, uint256 quoteFees) internal {
        if (quoteFees == 0) return;
        uint256 creatorPart = quoteFees * f.creatorShareBps / 10_000;
        if (f.mode == BnbFeeMode.Creator) f.creatorPending += creatorPart;
        else f.holdersPending += creatorPart;
        f.treasuryPending += quoteFees - creatorPart;
        f.totalCollected += quoteFees;
    }

    function dispatch(address token) external nonReentrant returns (uint256 burned) {
        FeeRecord storage f = _fees[token];
        if (f.creator == address(0)) revert UnknownToken();
        burned = _dispatch(token, f);
    }

    function feeInfo(address token) external view returns (FeeRecord memory) {
        return _fees[token];
    }

    function _dispatch(address token, FeeRecord storage f) internal returns (uint256 burned) {
        uint256 creatorAmount = f.creatorPending;
        uint256 treasuryAmount = f.treasuryPending;
        uint256 buyback = f.holdersPending;
        if (creatorAmount + treasuryAmount + buyback == 0) revert NothingPending();
        f.creatorPending = 0;
        f.treasuryPending = 0;
        f.holdersPending = 0;

        if (creatorAmount != 0) {
            BnbQuotePayout.payoutQuote(f.quote, wrappedNative, f.creator, creatorAmount);
        }
        if (treasuryAmount != 0) {
            BnbQuotePayout.payoutQuote(f.quote, wrappedNative, treasury, treasuryAmount);
        }
        if (buyback != 0) {
            (uint160 twapSqrt, int24 twapTick, bool ready) = _tryTwap(f.pool);
            if (ready) {
                (uint256 consumed, uint256 out) =
                    _poolSwap(f.pool, f.quote, DEAD, buyback, twapSqrt, twapTick);
                f.holdersPending = buyback - consumed;
                burned = out;
            } else {
                f.holdersPending = buyback;
            }
        }
        uint256 buybackSpent = buyback - f.holdersPending;
        f.totalDispatched += creatorAmount + treasuryAmount + buybackSpent;
        emit Dispatched(token, creatorAmount, treasuryAmount, buybackSpent, burned);
    }

    function _tryTwap(address pool)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, bool ready)
    {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolMinimal(pool).slot0();
        if (cardinality == 0) return (0, 0, false);
        uint256 oldestIndex = (uint256(index) + 1) % cardinality;
        (uint32 oldest,,, bool initialized) = IUniswapV3PoolMinimal(pool).observations(oldestIndex);
        if (!initialized) (oldest,,, initialized) = IUniswapV3PoolMinimal(pool).observations(0);
        if (!initialized || oldest > block.timestamp) return (0, 0, false);
        uint32 age = uint32(block.timestamp) - oldest;
        uint32 window = age < TWAP_WINDOW ? age : TWAP_WINDOW;
        if (window < MIN_TWAP_WINDOW) return (0, 0, false);
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
            ready = true;
        } catch {}
    }

    function _poolSwap(
        address pool,
        address tokenIn,
        address recipient,
        uint256 requested,
        uint160 twapSqrt,
        int24 twapTick
    )
        internal
        returns (uint256 consumed, uint256 amountOut)
    {
        SwapVars memory v;
        v.zeroForOne = IUniswapV3PoolMinimal(pool).token0() == tokenIn;
        v.limit = TickMath.getSqrtRatioAtTick(_limitTick(twapTick, v.zeroForOne));
        (uint160 current,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        if ((v.zeroForOne && current <= v.limit) || (!v.zeroForOne && current >= v.limit)) {
            return (0, 0);
        }
        _activePool = pool;
        _activeToken = tokenIn;
        (v.amount0, v.amount1) = IUniswapV3PoolMinimal(pool).swap(
            recipient, v.zeroForOne, int256(requested), v.limit, ""
        );
        _activePool = address(0);
        _activeToken = address(0);
        consumed = uint256(v.zeroForOne ? v.amount0 : v.amount1);
        amountOut = uint256(-(v.zeroForOne ? v.amount1 : v.amount0));
        uint256 expected = _quoteAtSqrt(pool, tokenIn, consumed, twapSqrt);
        uint256 feeBps = IUniswapV3PoolMinimal(pool).fee() / 100;
        if (
            amountOut
                < expected * (10_000 - feeBps - BUYBACK_FLOOR_TOLERANCE_BPS) / 10_000
        ) revert InvalidParams();
    }

    function _quoteAtSqrt(address pool, address tokenIn, uint256 amount, uint160 sqrtPriceX96)
        private
        view
        returns (uint256)
    {
        return V3SpotQuote.quoteAtSqrtRatio(
            sqrtPriceX96, amount, IUniswapV3PoolMinimal(pool).token0() == tokenIn
        );
    }

    function _limitTick(int24 twapTick, bool zeroForOne) private pure returns (int24) {
        int256 candidate =
            int256(twapTick) + (zeroForOne ? -int256(IMPACT_LIMIT_TICKS) : int256(IMPACT_LIMIT_TICKS));
        if (candidate <= TickMath.MIN_TICK) return TickMath.MIN_TICK + 1;
        if (candidate >= TickMath.MAX_TICK) return TickMath.MAX_TICK - 1;
        return int24(candidate);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _activePool || _activePool == address(0)) revert InvalidParams();
        if (amount0Delta <= 0 && amount1Delta <= 0) revert InvalidParams();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        _activeToken.safeTransfer(msg.sender, owed);
    }
}