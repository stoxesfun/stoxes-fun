// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3PoolMinimal, IPancakeV3SwapCallback} from "../../../../src/interfaces/IUniswapV3.sol";
import {TickMath} from "../../../../src/vendor/TickMath.sol";
import {SafeERC20Lite} from "../../../../src/base/Common.sol";

/// @dev TEST FIXTURE ONLY. Moves a real forked pool through an actual swap.
/// Never deployed to a public chain. Not a replacement router or vault.
contract BurnSizingPriceMover is IPancakeV3SwapCallback {
    using SafeERC20Lite for address;
    address private activePool;
    address private input;

    function move(address pool, address input_, int24 targetTick) external {
        require(activePool == address(0));
        activePool = pool;
        input = input_;
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        p.swap(address(this), input_ == p.token0(), 1e33, TickMath.getSqrtRatioAtTick(targetTick), "");
        activePool = address(0);
    }

    function pancakeV3SwapCallback(int256 a, int256 b, bytes calldata) external {
        require(msg.sender == activePool && activePool != address(0));
        input.safeTransfer(msg.sender, uint256(a > 0 ? a : b));
    }
}
