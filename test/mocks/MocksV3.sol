// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {TickMath} from "../../src/vendor/TickMath.sol";

interface IERC20Lite {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IPancakeSwapCallback {
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Minimal V3 pool stand-in: static slot0 + a sweep the mock router
///         uses to pay swap output straight from the pool's token inventory,
///         PLUS a configurable direct `swap` (with callback) and a TWAP
///         `observe`/cardinality oracle so the X V3 locker's OKB-only sale path
///         and its anti-sandwich floor can be exercised.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public liquidity;

    // --- oracle (TWAP) config ---
    int24 public twapTick; // tick reported by the TWAP window
    bool public twapUsable = true; // when false, observe() reverts (unwarmed oracle)
    uint16 public observationCardinalityNext;
    uint16 public observationIndex;
    uint16 public observationCardinality = 1;
    struct Observation {
        uint32 timestamp;
        bool initialized;
    }
    mapping(uint256 => Observation) private _observations;
    bool public enforceObservationRing;

    // --- swap config ---
    // WOKB out per 1 token-in, scaled 1e18. Lets tests simulate a fair price or
    // a sandwiched (crashed) execution price.
    uint256 public wokbOutPerTokenWad;
    bool public failSwap; // when true, swap() reverts (hostile pool)
    bool public usePancakeCallback;
    bool public repriceEmptyPool;

    constructor(address t0, address t1, uint24 fee_, uint160 sqrtPriceX96_, int24 tick_) {
        token0 = t0;
        token1 = t1;
        fee = fee_;
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        twapTick = tick_;
        _observations[0] = Observation(uint32(block.timestamp), true);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (
            sqrtPriceX96,
            tick,
            observationIndex,
            observationCardinality,
            observationCardinalityNext,
            0,
            true
        );
    }

    /// @dev Mock-only escape hatch so the mock router can pay swap output.
    function sweep(address token, address to, uint256 amount) external {
        require(IERC20Lite(token).transfer(to, amount), "sweep");
    }

    /// @dev Mock-only: simulate the pool price being arbed back in band.
    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    /// @dev Mock-only: simulate pre-existing (attacker) pool liquidity.
    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    // ---------------- oracle ----------------

    function setTwapTick(int24 t) external {
        twapTick = t;
    }

    function setTwapUsable(bool usable) external {
        twapUsable = usable;
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > observationCardinalityNext) observationCardinalityNext = next;
    }

    function setObservationState(
        uint16 index,
        uint16 cardinality,
        uint32 oldestTimestamp,
        bool oldestInitialized
    ) external {
        require(cardinality != 0 && index < cardinality, "ring");
        observationIndex = index;
        observationCardinality = cardinality;
        enforceObservationRing = true;
        uint16 oldest = uint16((uint256(index) + 1) % cardinality);
        _observations[oldest] = Observation(oldestTimestamp, oldestInitialized);
        _observations[0] = Observation(oldestTimestamp, true);
    }

    function observations(uint256 index) external view returns (uint32, int56, uint160, bool) {
        Observation memory o = _observations[index];
        return (o.timestamp, 0, 0, o.initialized);
    }

    /// @dev Returns tick cumulatives such that (tc[1]-tc[0]) / window == twapTick.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(twapUsable, "OLD");
        if (enforceObservationRing) {
            uint16 oldestIndex = uint16((uint256(observationIndex) + 1) % observationCardinality);
            Observation memory oldest = _observations[oldestIndex];
            if (!oldest.initialized) oldest = _observations[0];
            require(
                oldest.initialized && oldest.timestamp <= block.timestamp
                    && secondsAgos[0] <= uint32(block.timestamp) - oldest.timestamp,
                "OLD"
            );
        }
        uint32 window = secondsAgos[0] - secondsAgos[1];
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(twapTick) * int56(uint56(window));
    }

    // ---------------- swap ----------------

    // When >0 and <10000, the swap simulates a V3 PARTIAL FILL: the pool stops
    // at the price limit after consuming only this bps fraction of the requested
    // input. The callback is then owed only the consumed amount.
    uint256 public partialFillBps;
    int24 public liquidityCliffTick;

    function setWokbOutPerTokenWad(uint256 wad) external {
        wokbOutPerTokenWad = wad;
    }

    function setFailSwap(bool fail) external {
        failSwap = fail;
    }

    function setPancakeCallback(bool enabled) external {
        usePancakeCallback = enabled;
    }

    function setRepriceEmptyPool(bool enabled) external {
        repriceEmptyPool = enabled;
    }

    function setPartialFillBps(uint256 bps) external {
        partialFillBps = bps;
    }

    function setLiquidityCliff(int24 cliffTick, uint256 fillBps) external {
        liquidityCliffTick = cliffTick;
        partialFillBps = fillBps;
    }

    /// @dev Faithful-enough direct swap: sells the launch token for WOKB at the
    ///      configured rate. Pays WOKB to `recipient` first, then invokes the
    ///      caller's callback to collect the token input owed (exact-input, so
    ///      `amountSpecified > 0`). `tokenIsWokb0`: which side is WOKB. When
    ///      `partialFillBps` is set the pool consumes only that fraction of the
    ///      requested input (a V3 swap stopping at the price limit).
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96_,
        bytes calldata data
    )
        external
        returns (int256 amount0, int256 amount1)
    {
        require(!failSwap, "hostile");
        require(amountSpecified > 0, "exact-in only");
        // Core V3 moves an initialized empty pool directly to the supplied
        // limit without consuming input. This permits safe launch recovery.
        if (liquidity == 0 && repriceEmptyPool) {
            sqrtPriceX96 = sqrtPriceLimitX96_;
            tick = _tickAt(sqrtPriceLimitX96_);
            // Core V3 still invokes the swap callback with zero deltas.
            if (usePancakeCallback) IPancakeSwapCallback(msg.sender).pancakeV3SwapCallback(0, 0, data);
            else IV3SwapCallback(msg.sender).uniswapV3SwapCallback(0, 0, data);
            return (0, 0);
        }
        uint256 requested = uint256(amountSpecified);
        uint256 tokenIn = partialFillBps == 0 ? requested : (requested * partialFillBps) / 10_000;
        uint256 wokbOut = (tokenIn * wokbOutPerTokenWad) / 1e18;

        // Determine which token is WOKB by elimination is not possible here, so
        // the token being SOLD is the one on the zeroForOne side.
        // zeroForOne == true  => selling token0, receiving token1
        // zeroForOne == false => selling token1, receiving token0
        address wokbSide = zeroForOne ? token1 : token0;

        // Pay WOKB out to recipient from the pool's inventory.
        require(IERC20Lite(wokbSide).transfer(recipient, wokbOut), "wokb-out");

        // Signed deltas: positive = owed to pool (input), negative = paid out.
        if (zeroForOne) {
            amount0 = int256(tokenIn);
            amount1 = -int256(wokbOut);
        } else {
            amount1 = int256(tokenIn);
            amount0 = -int256(wokbOut);
        }

        // Pull the token input via the callback.
        if (usePancakeCallback) {
            IPancakeSwapCallback(msg.sender).pancakeV3SwapCallback(amount0, amount1, data);
        } else {
            IV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        }
        if (partialFillBps != 0 && sqrtPriceLimitX96_ != 0) {
            tick = repriceEmptyPool ? _tickAt(sqrtPriceLimitX96_) : liquidityCliffTick;
            sqrtPriceX96 = sqrtPriceLimitX96_;
            liquidity = 0;
        }
    }

    function _tickAt(uint160 price) private pure returns (int24) {
        int24 low = TickMath.MIN_TICK;
        int24 high = TickMath.MAX_TICK;
        while (low < high) {
            int24 mid = low + int24((int256(high) - low + 1) / 2);
            if (TickMath.getSqrtRatioAtTick(mid) <= price) low = mid;
            else high = mid - 1;
        }
        return low;
    }
}

/// @notice Minimal NonfungiblePositionManager stand-in: creates MockV3Pools,
///         pulls the desired amounts into the pool on mint (minus an optional
///         holdback to simulate rounding dust), notifies the ERC-721 receiver,
///         and pays configurable fee amounts on collect from its own balance.
contract MockNonfungiblePositionManager {
    int24 public nextTick; // tick reported by the next created pool
    uint256 public mintHoldback; // simulated rounding dust left with the payer

    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => mapping(uint24 => address))) public poolOf;

    struct Position {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
    }

    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256) public collectable0;
    mapping(uint256 => uint256) public collectable1;

    function setNextTick(int24 t) external {
        nextTick = t;
    }

    function setMintHoldback(uint256 amount) external {
        mintHoldback = amount;
    }

    function setCollectable(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectable0[tokenId] = amount0;
        collectable1[tokenId] = amount1;
    }

    /// @dev Doubles as the mock IUniswapV3FactoryMinimal (tests pass this
    ///      contract's address as `v3Factory`). Order-insensitive lookup.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return poolOf[t0][t1][fee];
    }

    function factory() external view returns (address) { return address(this); }

    function createPool(address token0, address token1, uint24 fee) external returns (address pool) {
        require(poolOf[token0][token1][fee] == address(0), "exists");
        pool = address(new MockV3Pool(token0, token1, fee, 0, 0));
        poolOf[token0][token1][fee] = pool;
    }

    /// @dev Mock-only: registers a route-hop pool (with a controllable TWAP
    ///      tick) so the dividend vault's in-contract WOKB->stock route quoting
    ///      can be exercised. Returns the created pool for further knob-setting.
    function setRoutePool(address tokenA, address tokenB, uint24 fee, int24 twapTick)
        external
        returns (address pool)
    {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = poolOf[t0][t1][fee];
        if (pool == address(0)) {
            // sqrtPriceX96 at the given tick isn't needed by the vault's TWAP
            // path (it reads observe()); pass tick as both slot0 tick and TWAP.
            pool = address(new MockV3Pool(t0, t1, fee, uint160(1 << 96), twapTick));
            poolOf[t0][t1][fee] = pool;
        }
        MockV3Pool(pool).setTwapTick(twapTick);
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool) {
        pool = poolOf[token0][token1][fee];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(token0, token1, fee, sqrtPriceX96, nextTick));
            poolOf[token0][token1][fee] = pool;
        } else if (MockV3Pool(pool).sqrtPriceX96() == 0) {
            MockV3Pool(pool).setSqrtPriceX96(sqrtPriceX96);
            MockV3Pool(pool).setTick(nextTick);
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = poolOf[params.token0][params.token1][params.fee];
        require(pool != address(0), "no pool");
        amount0 = params.amount0Desired > mintHoldback
            ? params.amount0Desired - mintHoldback
            : params.amount0Desired;
        amount1 = params.amount1Desired > mintHoldback
            ? params.amount1Desired - mintHoldback
            : params.amount1Desired;
        if (params.amount0Desired == 0) amount0 = 0;
        if (params.amount1Desired == 0) amount1 = 0;
        // Mirror V3 slippage protection so callers' strict mins are honored.
        require(amount0 >= params.amount0Min, "Price slippage check");
        require(amount1 >= params.amount1Min, "Price slippage check");
        if (amount0 > 0) {
            require(IERC20Lite(params.token0).transferFrom(msg.sender, pool, amount0), "t0");
        }
        if (amount1 > 0) {
            require(IERC20Lite(params.token1).transferFrom(msg.sender, pool, amount1), "t1");
        }
        tokenId = nextTokenId++;
        liquidity = 1;
        ownerOf[tokenId] = params.recipient;
        positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            amount0: amount0,
            amount1: amount1
        });
        if (params.recipient.code.length > 0) {
            require(
                IERC721Receiver(params.recipient).onERC721Received(msg.sender, address(0), tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        require(ownerOf[params.tokenId] == msg.sender, "not owner");
        Position memory p = positions[params.tokenId];
        amount0 = collectable0[params.tokenId];
        amount1 = collectable1[params.tokenId];
        collectable0[params.tokenId] = 0;
        collectable1[params.tokenId] = 0;
        if (amount0 > 0) require(IERC20Lite(p.token0).transfer(params.recipient, amount0), "c0");
        if (amount1 > 0) require(IERC20Lite(p.token1).transfer(params.recipient, amount1), "c1");
    }
}

/// @notice Minimal SwapRouter02 stand-in: pulls tokenIn from the caller and
///         pays tokenOut from the token's V3 pool inventory at a fixed rate.
contract MockSwapRouter02 {
    /// @dev tokenOut => its mock pool (swap output is swept from here).
    mapping(address => address) public poolFor;
    /// @dev Optional fallback: when poolFor[tokenOut] is unset, resolve the LAST
    ///      hop's pool via this MockNonfungiblePositionManager (used by the
    ///      atomic dev buy, where the token/pool don't exist pre-launch).
    address public nfpm;

    function setNfpm(address nfpm_) external {
        nfpm = nfpm_;
    }
    /// @dev tokenOut => output per 1e18 of input.

    mapping(address => uint256) public rateFor;
    /// @dev When true, every swap reverts (tests the locker's buyback carry).
    bool public failSwaps;

    function setPool(address tokenOut, address pool) external {
        poolFor[tokenOut] = pool;
    }

    function setFailSwaps(bool fail) external {
        failSwaps = fail;
    }

    function setRate(address tokenOut, uint256 outPerInWad) external {
        rateFor[tokenOut] = outPerInWad;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!failSwaps, "swap failed");
        require(IERC20Lite(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "in");
        amountOut = (params.amountIn * rateFor[params.tokenOut]) / 1e18;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        MockV3Pool(poolFor[params.tokenOut]).sweep(params.tokenOut, params.recipient, amountOut);
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @dev Multi-hop stand-in: tokenIn = first 20 bytes of the path, tokenOut =
    ///      last 20 bytes; the whole route is priced by `rateFor[tokenOut]`.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        require(!failSwaps, "swap failed");
        require(params.path.length >= 43, "bad path");
        address tokenIn = address(bytes20(params.path[0:20]));
        address tokenOut = address(bytes20(params.path[params.path.length - 20:]));
        require(IERC20Lite(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "in");
        amountOut = (params.amountIn * rateFor[tokenOut]) / 1e18;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        address pool = poolFor[tokenOut];
        if (pool == address(0) && nfpm != address(0)) {
            // Resolve the LAST hop's pool: …[tokenSecondLast(20)][fee(3)][tokenOut(20)]
            address secondLast =
                address(bytes20(params.path[params.path.length - 43:params.path.length - 23]));
            uint24 lastFee = uint24(bytes3(params.path[params.path.length - 23:params.path.length - 20]));
            pool = MockNonfungiblePositionManager(nfpm).getPool(secondLast, tokenOut, lastFee);
        }
        MockV3Pool(pool).sweep(tokenOut, params.recipient, amountOut);
    }
}
