// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbStocksVaultFactory} from "../../../src/bnb/vaults/StoxesBnbStocksVaultFactory.sol";
import {IUniswapV3PoolMinimal} from "../../../src/interfaces/IUniswapV3.sol";
import {TickMath} from "../../../src/vendor/TickMath.sol";

contract ForkTokenFactoryStub {
    address public immutable WBNB;

    constructor(address wrappedNative) {
        WBNB = wrappedNative;
    }
}

contract StoxesBnbStocksForkTest is Test {
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function testLivePoolObservationAndLimitMath() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        ForkTokenFactoryStub tokenFactory = new ForkTokenFactoryStub(WBNB);
        StoxesBnbStocksVaultFactory factory =
            new StoxesBnbStocksVaultFactory(address(tokenFactory), address(this), V3_FACTORY);
        (address pool, uint24 fee) = factory.deepestPool(WBNB, USDT);
        assertTrue(pool != address(0));
        assertGt(IUniswapV3PoolMinimal(pool).liquidity(), 0);
        assertTrue(fee == 100 || fee == 500 || fee == 2500 || fee == 10_000);
        _proveObservation(pool, fee);
    }

    function _proveObservation(address pool, uint24 fee) private view {
        (uint160 current,, uint16 index, uint16 cardinality,,,) =
            IUniswapV3PoolMinimal(pool).slot0();
        assertGt(current, 0);
        assertGt(cardinality, 0);
        (uint32 oldest,,, bool initialized) =
            IUniswapV3PoolMinimal(pool).observations((uint256(index) + 1) % cardinality);
        if (!initialized) (oldest,,, initialized) = IUniswapV3PoolMinimal(pool).observations(0);
        assertTrue(initialized);
        uint32 age = uint32(block.timestamp) - oldest;
        uint32 window = age < 1800 ? age : 1800;
        if (window < 120) return;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory cumulatives,) = IUniswapV3PoolMinimal(pool).observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        int24 twap = int24(delta / int56(uint56(window)));
        if (delta < 0 && delta % int56(uint56(window)) != 0) --twap;
        int24 adverseTicks = int24(uint24(fee / 100 + 300) + 9);
        uint160 lowerLimit = TickMath.getSqrtRatioAtTick(twap - adverseTicks);
        uint160 upperLimit = TickMath.getSqrtRatioAtTick(twap + adverseTicks);
        assertLt(lowerLimit, upperLimit);
    }
}