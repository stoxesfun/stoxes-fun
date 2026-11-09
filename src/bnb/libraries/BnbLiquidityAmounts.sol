// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";

/// @notice Concentrated-liquidity amount math using Q64.96 square-root prices.
library BnbLiquidityAmounts {
    uint256 internal constant Q96 = 1 << 96;

    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint256 l0;
        uint256 l1;
        if (sqrtPriceX96 <= sqrtLowerX96) {
            l0 = liquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0);
            liquidity = _to128(l0);
        } else if (sqrtPriceX96 >= sqrtUpperX96) {
            l1 = liquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount1);
            liquidity = _to128(l1);
        } else {
            l0 = liquidityForAmount0(sqrtPriceX96, sqrtUpperX96, amount0);
            l1 = liquidityForAmount1(sqrtLowerX96, sqrtPriceX96, amount1);
            liquidity = _to128(l0 < l1 ? l0 : l1);
        }
    }

    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = amount0ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            amount0 = amount0ForLiquidity(sqrtPriceX96, sqrtUpperX96, liquidity);
            amount1 = amount1ForLiquidity(sqrtLowerX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = amount1ForLiquidity(sqrtLowerX96, sqrtUpperX96, liquidity);
        }
    }

    function liquidityForAmount0(uint160 a, uint160 b, uint256 amount) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        uint256 intermediate = FixedPointMathLib.fullMulDiv(a, b, Q96);
        return FixedPointMathLib.fullMulDiv(amount, intermediate, uint256(b) - a);
    }

    function liquidityForAmount1(uint160 a, uint160 b, uint256 amount) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        return FixedPointMathLib.fullMulDiv(amount, Q96, uint256(b) - a);
    }

    function amount0ForLiquidity(uint160 a, uint160 b, uint128 liquidity) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        return FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(liquidity, uint256(b) - a, b), Q96, a
        );
    }

    function amount1ForLiquidity(uint160 a, uint160 b, uint128 liquidity) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        return FixedPointMathLib.fullMulDiv(liquidity, uint256(b) - a, Q96);
    }

    function _to128(uint256 x) private pure returns (uint128) {
        require(x <= type(uint128).max && x != 0, "LIQ");
        return uint128(x);
    }
}