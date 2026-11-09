// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "../vendor/FixedPointMathLib.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3.sol";

/// @title  V3SpotQuote — full-precision Uniswap V3 spot/sqrt-price quoting
/// @notice Shared quote helpers for the X Layer RWA-paired launch path. The
///         quote math mirrors Uniswap v3-periphery `OracleLibrary.getQuoteAtTick`
///         (splitting on whether the Q64.96 ratio fits 128 bits so squaring can
///         never overflow), applied to an arbitrary sqrt price.
library V3SpotQuote {
    error PoolUnavailable(address tokenA, address tokenB, uint24 fee);

    /// @notice How much `quote` token for `baseAmount` of the base token at
    ///         `sqrtRatioX96`, where `baseIsToken0` says which side the base is.
    function quoteAtSqrtRatio(uint160 sqrtRatioX96, uint256 baseAmount, bool baseIsToken0)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * uint256(sqrtRatioX96);
            quoteAmount = baseIsToken0
                ? FixedPointMathLib.fullMulDiv(ratioX192, baseAmount, 1 << 192)
                : FixedPointMathLib.fullMulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FixedPointMathLib.fullMulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseIsToken0
                ? FixedPointMathLib.fullMulDiv(ratioX128, baseAmount, 1 << 128)
                : FixedPointMathLib.fullMulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice Spot-quotes `amountIn` of `tokenIn` into `tokenOut` off the
    ///         `fee`-tier pool's current sqrt price. REVERTS (fail closed) when
    ///         the pool does not exist — a missing route pool must never be
    ///         silently priced at zero.
    function spotQuote(address v3Factory, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        address pool = IUniswapV3FactoryMinimal(v3Factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) revert PoolUnavailable(tokenIn, tokenOut, fee);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
        amountOut = quoteAtSqrtRatio(sqrtPriceX96, amountIn, tokenIn < tokenOut);
    }
}
