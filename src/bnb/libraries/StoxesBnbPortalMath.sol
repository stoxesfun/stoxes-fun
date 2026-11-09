// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";

library StoxesBnbPortalMath {
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    int24 private constant MAX_ALIGNED_TICK = 887_200;
    int24 private constant TICK_SPACING = 200;
    int24 private constant TEN_THOUSAND_X_TICKS = 92_100;

    function taxAmounts(
        uint256 tax,
        uint256 volume,
        uint16 commissionBps,
        uint16 vaultBps,
        uint16 creatorBps,
        uint16 burnBps
    )
        public
        pure
        returns (
            uint256 protocolAmount,
            uint256 commissionAmount,
            uint256 vaultAmount,
            uint256 creatorAmount,
            uint256 burnAmount,
            uint256 liquidityAmount
        )
    {
        protocolAmount = volume * 30 / 10_000;
        if (protocolAmount > tax) protocolAmount = tax;
        uint256 remainder = tax - protocolAmount;
        commissionAmount = remainder * commissionBps / 10_000;
        remainder -= commissionAmount;
        vaultAmount = remainder * vaultBps / 10_000;
        creatorAmount = remainder * creatorBps / 10_000;
        burnAmount = remainder * burnBps / 10_000;
        liquidityAmount = remainder - vaultAmount - creatorAmount - burnAmount;
    }

    function sqrtPrice(uint256 tokenAmount, uint256 quoteAmount, bool token0Side)
        public
        pure
        returns (uint160)
    {
        (uint256 num, uint256 den) = token0Side ? (quoteAmount, tokenAmount) : (tokenAmount, quoteAmount);
        uint256 ratioX36 = FixedPointMathLib.mulDiv(num, 1e36, den);
        uint256 value = FixedPointMathLib.sqrt(ratioX36) * (1 << 96) / 1e18;
        if (value <= MIN_SQRT_RATIO) return MIN_SQRT_RATIO + 1;
        if (value >= MAX_SQRT_RATIO) return MAX_SQRT_RATIO - 1;
        return uint160(value);
    }

    function sqrtPriceFromCurve(uint256 price, uint8 quoteDecimals, bool token0Side)
        public
        pure
        returns (uint160)
    {
        uint256 quoteRaw = price / (10 ** (18 - quoteDecimals));
        if (quoteRaw == 0) quoteRaw = 1;
        return sqrtPrice(1e18, quoteRaw, token0Side);
    }

    function sqrtInBand(uint160 actual, uint160 expected, uint256 toleranceBps)
        public
        pure
        returns (bool)
    {
        if (actual == 0 || expected == 0) return false;
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        return diff * 10_000 <= uint256(expected) * toleranceBps;
    }

    function simpleTicks(
        uint256 initialPrice,
        uint256 currentPrice,
        uint8 quoteDecimals,
        bool token0Side
    )
        public
        pure
        returns (int24 low, int24 high)
    {
        int24 initialTick = _curveTick(initialPrice, quoteDecimals, token0Side);
        int24 currentTick = _curveTick(currentPrice, quoteDecimals, token0Side);
        low = _floorTick(token0Side ? initialTick : currentTick - TEN_THOUSAND_X_TICKS);
        high = _ceilTick(token0Side ? currentTick + TEN_THOUSAND_X_TICKS : initialTick);
        if (low < -MAX_ALIGNED_TICK) low = -MAX_ALIGNED_TICK;
        if (high > MAX_ALIGNED_TICK) high = MAX_ALIGNED_TICK;
    }

    function _curveTick(uint256 price, uint8 quoteDecimals, bool token0Side)
        private
        pure
        returns (int24)
    {
        uint256 quoteRaw = price / (10 ** (18 - quoteDecimals));
        if (quoteRaw == 0) quoteRaw = 1;
        uint256 ratioWad =
            token0Side ? quoteRaw : FixedPointMathLib.fullMulDiv(1e18, 1e18, quoteRaw);
        return int24(
            FixedPointMathLib.lnWad(int256(ratioWad))
                / FixedPointMathLib.lnWad(1_000_100_000_000_000_000)
        );
    }

    function _floorTick(int24 tick) private pure returns (int24) {
        int24 rounded = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) rounded -= TICK_SPACING;
        return rounded;
    }

    function _ceilTick(int24 tick) private pure returns (int24) {
        int24 rounded = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick > 0 && tick % TICK_SPACING != 0) rounded += TICK_SPACING;
        return rounded;
    }
}