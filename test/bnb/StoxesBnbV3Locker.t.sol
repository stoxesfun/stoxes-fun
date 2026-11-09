// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {
    MockNonfungiblePositionManager,
    MockSwapRouter02,
    MockV3Pool
} from "../mocks/MocksV3.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {BnbFeeMode} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbV3Locker} from "../../src/bnb/StoxesBnbV3Locker.sol";
import {TokenLanePortal} from "./mocks/TokenLaneMocks.sol";

contract StoxesBnbV3LockerTest is Test {
    MockERC20 token;
    MockERC20 quote;
    MockNonfungiblePositionManager manager;
    MockSwapRouter02 router;
    TokenLanePortal portal;
    StoxesBnbV3Locker locker;
    address pool;
    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA5);

    function setUp() public {
        token = new MockERC20("Token", "T", 18);
        quote = new MockERC20("Quote", "Q", 18);
        manager = new MockNonfungiblePositionManager();
        router = new MockSwapRouter02();
        portal = new TokenLanePortal(address(quote));
        locker = new StoxesBnbV3Locker(
            address(portal), address(0xBEEF), address(manager), address(manager), address(router), treasury, address(this)
        );
        (address t0, address t1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        pool = manager.createAndInitializePoolIfNecessary(t0, t1, 10_000, uint160(1 << 96));
        MockV3Pool(pool).setPancakeCallback(true);
        MockV3Pool(pool).setLiquidity(1_000_000 ether);
        router.setPool(address(token), pool);
        router.setPool(address(quote), pool);
        router.setRate(address(token), 1e18);
        router.setRate(address(quote), 1e18);
        token.mint(pool, 1_000_000 ether);
        quote.mint(pool, 1_000_000 ether);
        token.mint(address(manager), 1_000_000 ether);
        quote.mint(address(manager), 1_000_000 ether);
        MockV3Pool(pool).setWokbOutPerTokenWad(1e18);
        vm.warp(block.timestamp + 1800);
        locker.setDispatchThreshold(1);
    }

    function _mintAndRegister(BnbFeeMode mode, uint16 share) internal returns (uint256 id) {
        (address t0, address t1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        (id,,,) = manager.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: 10_000,
                tickLower: -200,
                tickUpper: 200,
                amount0Desired: 0,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
        portal.registerLocker(locker, address(token), id, mode, share, creator, address(quote));
    }

    function _fees(uint256 id, uint256 tokenAmount, uint256 quoteAmount) internal {
        if (address(token) < address(quote)) manager.setCollectable(id, tokenAmount, quoteAmount);
        else manager.setCollectable(id, quoteAmount, tokenAmount);
    }

    function testRegisterAccessShareCapAndFeeInfo() public {
        vm.expectRevert(StoxesBnbV3Locker.NotPortal.selector);
        locker.register(address(token), 1, BnbFeeMode.Creator, 1000, creator, address(quote));

        (address t0, address t1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        (uint256 id,,,) = manager.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 10_000, -200, 200, 0, 0, 0, 0, address(locker), block.timestamp
            )
        );
        vm.expectRevert(StoxesBnbV3Locker.InvalidParams.selector);
        portal.registerLocker(locker, address(token), id, BnbFeeMode.Creator, 5001, creator, address(quote));
        portal.registerLocker(locker, address(token), id, BnbFeeMode.Creator, 4000, creator, address(quote));
        StoxesBnbV3Locker.FeeRecord memory info = locker.feeInfo(address(token));
        assertEq(info.tokenId, id);
        assertEq(info.pool, pool);
        assertEq(info.creatorShareBps, 4000);
    }

    function testCreatorModeCollectRoutesBothFeeSides() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Creator, 4000);
        _fees(id, 100 ether, 100 ether);
        locker.collect(address(token));
        assertEq(quote.balanceOf(creator), 80 ether);
        assertEq(quote.balanceOf(treasury), 120 ether);
        StoxesBnbV3Locker.FeeRecord memory info = locker.feeInfo(address(token));
        assertEq(info.totalCollected, 200 ether);
        assertEq(info.totalDispatched, 200 ether);
    }

    function testHoldersModeBuybackBurnAndFloor() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Holders, 5000);
        _fees(id, 0, 100 ether);
        MockV3Pool(pool).setWokbOutPerTokenWad(0.9 ether);
        vm.expectRevert();
        locker.collect(address(token));

        MockV3Pool(pool).setWokbOutPerTokenWad(1 ether);
        locker.collect(address(token));
        assertEq(token.balanceOf(address(0xdead)), 50 ether);
        assertEq(quote.balanceOf(treasury), 50 ether);
        assertEq(quote.balanceOf(creator), 0);
    }

    function testDispatchThresholdAndPermissionlessDispatch() public {
        locker.setDispatchThreshold(type(uint256).max);
        uint256 id = _mintAndRegister(BnbFeeMode.Creator, 2500);
        _fees(id, 0, 100 ether);
        locker.collect(address(token));
        assertEq(quote.balanceOf(creator), 0);
        StoxesBnbV3Locker.FeeRecord memory info = locker.feeInfo(address(token));
        assertEq(info.creatorPending, 25 ether);
        vm.prank(address(0xCA11));
        locker.dispatch(address(token));
        assertEq(quote.balanceOf(creator), 25 ether);
        assertEq(quote.balanceOf(treasury), 75 ether);
    }

    function testNoWithdrawalSurface() public {
        _mintAndRegister(BnbFeeMode.Creator, 0);
        (bool ok,) = address(locker).call(
            abi.encodeWithSignature("withdraw(uint256,address)", uint256(1), address(this))
        );
        assertFalse(ok);
        assertEq(manager.ownerOf(1), address(locker));
    }

    function testRegressionUnwarmedOracleCarriesCollectedFees() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Holders, 4000);
        assertGe(MockV3Pool(pool).observationCardinalityNext(), 200);
        MockV3Pool(pool).setTwapUsable(false);
        _fees(id, 100 ether, 100 ether);
        locker.collect(address(token));
        StoxesBnbV3Locker.FeeRecord memory pending = locker.feeInfo(address(token));
        assertEq(pending.tokenPending, 100 ether);
        assertEq(pending.creatorPending, 0);
        assertEq(pending.treasuryPending, 0);
        assertEq(pending.holdersPending, 40 ether);
        assertEq(quote.balanceOf(creator), 0);
        assertEq(quote.balanceOf(treasury), 60 ether);
        MockV3Pool(pool).setTwapUsable(true);
        locker.collect(address(token));
        StoxesBnbV3Locker.FeeRecord memory afterRetry = locker.feeInfo(address(token));
        assertEq(afterRetry.tokenPending, 0);
        assertEq(afterRetry.holdersPending, 0);
        assertEq(token.balanceOf(address(0xdead)), 80 ether);
        assertEq(afterRetry.totalDispatched, 200 ether);
    }

    function testRegressionLiquidityCliffCarriesThenRetryConsumesRemainder() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Holders, 5000);
        MockV3Pool(pool).setLiquidityCliff(-409, 4000);
        _fees(id, 0, 100 ether);
        locker.collect(address(token));
        StoxesBnbV3Locker.FeeRecord memory info = locker.feeInfo(address(token));
        assertEq(token.balanceOf(address(0xdead)), 20 ether);
        assertEq(info.holdersPending, 30 ether);
        assertEq(MockV3Pool(pool).liquidity(), 0);

        MockV3Pool(pool).setSqrtPriceX96(uint160(1 << 96));
        MockV3Pool(pool).setTick(0);
        MockV3Pool(pool).setLiquidity(1_000_000 ether);
        MockV3Pool(pool).setPartialFillBps(0);
        locker.dispatch(address(token));
        info = locker.feeInfo(address(token));
        assertEq(info.holdersPending, 0);
        assertEq(token.balanceOf(address(0xdead)), 50 ether);
    }

    function testRegressionAdaptiveWindowUsesOldestRetainedObservation() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Creator, 4000);
        MockV3Pool(pool).setObservationState(2, 3, uint32(block.timestamp - 119), true);
        _fees(id, 100 ether, 0);
        locker.collect(address(token));
        assertEq(locker.feeInfo(address(token)).tokenPending, 100 ether);
        assertEq(quote.balanceOf(creator), 0);

        MockV3Pool(pool).setObservationState(2, 3, uint32(block.timestamp - 120), true);
        locker.collect(address(token));
        assertEq(quote.balanceOf(creator), 40 ether);
        assertEq(locker.feeInfo(address(token)).tokenPending, 0);
    }

    function testPermissionlessOracleGrowthIsBounded() public {
        _mintAndRegister(BnbFeeMode.Creator, 0);
        locker.growOracle(address(token), 500);
        assertEq(MockV3Pool(pool).observationCardinalityNext(), 700);
        vm.expectRevert(StoxesBnbV3Locker.InvalidParams.selector);
        locker.growOracle(address(token), 501);
    }

    function testRegressionUniswapCallbackSelectorIsUnsupported() public {
        uint256 id = _mintAndRegister(BnbFeeMode.Creator, 0);
        MockV3Pool(pool).setPancakeCallback(false);
        _fees(id, 1 ether, 0);
        vm.expectRevert();
        locker.collect(address(token));
    }
}