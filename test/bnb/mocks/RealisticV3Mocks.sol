// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {INonfungiblePositionManager} from "../../../src/interfaces/IUniswapV3.sol";
import {FixedPointMathLib} from "../../../src/vendor/FixedPointMathLib.sol";
import {TickMath} from "../../../src/vendor/TickMath.sol";
import {MockV3Pool} from "../../mocks/MocksV3.sol";

interface IRealisticMockToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IRealisticNftReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @notice BNB-lane position-manager mock which derives liquidity and consumed
/// amounts from the initialized price and range rather than blindly pulling
/// desired amounts.
contract RealisticBnbV3PositionManager {
    uint256 private constant Q96 = 1 << 96;
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => mapping(uint24 => address))) public poolOf;

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        return poolOf[token0][token1][fee];
    }

    function factory() external view returns (address) { return address(this); }

    function createPool(address token0, address token1, uint24 fee) external returns (address pool) {
        require(poolOf[token0][token1][fee] == address(0), "exists");
        pool = address(new MockV3Pool(token0, token1, fee, 0, 0));
        MockV3Pool(pool).setPancakeCallback(true);
        MockV3Pool(pool).setRepriceEmptyPool(true);
        poolOf[token0][token1][fee] = pool;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool)
    {
        pool = poolOf[token0][token1][fee];
        if (pool == address(0)) {
            pool = address(new MockV3Pool(token0, token1, fee, sqrtPriceX96, _tickAt(sqrtPriceX96)));
            MockV3Pool(pool).setPancakeCallback(true);
            MockV3Pool(pool).setRepriceEmptyPool(true);
            poolOf[token0][token1][fee] = pool;
        } else if (MockV3Pool(pool).sqrtPriceX96() == 0) {
            MockV3Pool(pool).setSqrtPriceX96(sqrtPriceX96);
            MockV3Pool(pool).setTick(_tickAt(sqrtPriceX96));
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = poolOf[p.token0][p.token1][p.fee];
        require(pool != address(0), "pool");
        (uint160 current,,,,,,) = MockV3Pool(pool).slot0();
        uint160 lower = TickMath.getSqrtRatioAtTick(p.tickLower);
        uint160 upper = TickMath.getSqrtRatioAtTick(p.tickUpper);
        uint256 l0 = current < upper ? _l0(current > lower ? current : lower, upper, p.amount0Desired) : 0;
        uint256 l1 = current > lower ? _l1(lower, current < upper ? current : upper, p.amount1Desired) : 0;
        uint256 chosen = current <= lower ? l0 : current >= upper ? l1 : (l0 < l1 ? l0 : l1);
        require(chosen != 0 && chosen <= type(uint128).max, "liquidity");
        liquidity = uint128(chosen);
        if (current < upper) amount0 = _a0(current > lower ? current : lower, upper, liquidity);
        if (current > lower) amount1 = _a1(lower, current < upper ? current : upper, liquidity);
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");
        require(amount0 <= p.amount0Desired && amount1 <= p.amount1Desired, "desired");
        if (amount0 != 0) require(IRealisticMockToken(p.token0).transferFrom(msg.sender, pool, amount0), "t0");
        if (amount1 != 0) require(IRealisticMockToken(p.token1).transferFrom(msg.sender, pool, amount1), "t1");
        MockV3Pool(pool).setLiquidity(liquidity);
        tokenId = nextTokenId++;
        ownerOf[tokenId] = p.recipient;
        if (p.recipient.code.length != 0) {
            require(
                IRealisticNftReceiver(p.recipient).onERC721Received(msg.sender, address(0), tokenId, "")
                    == IRealisticNftReceiver.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function collect(INonfungiblePositionManager.CollectParams calldata)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {}

    function _l0(uint160 a, uint160 b, uint256 amount) private pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            amount, FixedPointMathLib.fullMulDiv(a, b, Q96), uint256(b) - a
        );
    }

    function _l1(uint160 a, uint160 b, uint256 amount) private pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amount, Q96, uint256(b) - a);
    }

    function _a0(uint160 a, uint160 b, uint128 liquidity) private pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(liquidity, uint256(b) - a, b), Q96, a
        );
    }

    function _a1(uint160 a, uint160 b, uint128 liquidity) private pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(liquidity, uint256(b) - a, Q96);
    }

    function _tickAt(uint160 sqrtPriceX96) private pure returns (int24) {
        int24 low = TickMath.MIN_TICK;
        int24 high = TickMath.MAX_TICK;
        while (low < high) {
            int24 mid = low + int24((int256(high) - low + 1) / 2);
            if (TickMath.getSqrtRatioAtTick(mid) <= sqrtPriceX96) low = mid;
            else high = mid - 1;
        }
        return low;
    }
}