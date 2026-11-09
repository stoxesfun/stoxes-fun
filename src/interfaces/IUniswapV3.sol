// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Minimal Uniswap V3 periphery/core interfaces for stoxes.fun
/// @notice Hand-written minimal interfaces for the EXISTING verified Uniswap V3
///         stack on Robinhood Chain (chain id 4663):
///           - UniswapV3Factory        0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
///           - NonfungiblePositionManager 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3
///           - SwapRouter02            0xCaf681a66D020601342297493863E78C959E5cb2
///         The canonical sources are Solidity 0.7.6; these mirrors carry only the
///         functions the stoxes.fun non-taxed launch stack calls, compiled 0.8.26.

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimal {
    /// @dev `feeProtocol` is declared uint32 (PancakeSwap V3's width). Uniswap
    ///      V3 pools return a uint8 there — ABI words are 32 bytes either way,
    ///      so decoding as uint32 is safe for BOTH; decoding Pancake's value
    ///      (protocol fee enabled, packed uint16s > 255) as uint8 would revert.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);

    /// @notice Cumulative tick/seconds-per-liquidity oracle. `secondsAgos` are
    ///         seconds-ago timestamps; returns the accumulators at each. Used to
    ///         derive a short TWAP tick for the anti-sandwich floor.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );

    /// @notice Grows the oracle ring buffer so `observe` over the TWAP window can
    ///         succeed. Called once at registration; cheap no-op if already large.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    /// @notice Core swap. For an exact-input token->WOKB sale the locker sets
    ///         `amountSpecified > 0` (exact input of the input token) and pays the
    ///         owed input inside `uniswapV3SwapCallback`.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice The callback the V3 pool invokes on `swap` to collect the input owed.
interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IPancakeV3SwapCallback {
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice PoolInitializer: creates + initializes the pool if it does not exist.
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice SwapRouter02 — NOTE: unlike the original SwapRouter, the SwapRouter02
///         `ExactInputSingleParams` struct has NO `deadline` field.
interface ISwapRouter02 {
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
        returns (uint256 amountOut);

    /// @dev Multi-hop exact-input swap along an ABI-packed `token(20) fee(3)
    ///      token(20) …` path. Like the single-hop variant, SwapRouter02's
    ///      struct carries NO `deadline` field.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
