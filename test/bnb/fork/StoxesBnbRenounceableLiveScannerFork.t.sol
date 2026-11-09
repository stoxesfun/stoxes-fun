// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface LiveScannerToken {
    function owner() external view returns (address);
    function phase() external view returns (uint8);
    function mainPool() external view returns (address);
    function graduatedAt() external view returns (uint64);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface LiveScannerRouter {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata, address, uint256
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
}

/// Evidence for the user's new token, at one immutable snapshot. No broadcast.
/// Only the local buyer's quote funding and, in one test, local time are changed.
contract StoxesBnbRenounceableLiveScannerForkTest is Test {
    address constant TOKEN = address(bytes20(hex"3c3c54babbeb6a5037de5f55c8a0549bb96d9999"));
    address constant QUOTE = address(bytes20(hex"4902c5ebc598265ed2212b559b042de8a5eeec3f"));
    address constant POOL = address(bytes20(hex"4ba4e3b4a3da35263be9171045ee85c36e4f3ca9"));
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    address constant DEAD = address(0xdead);
    address constant WBNB = address(bytes20(hex"bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"));

    function setUp() public {
        if (!vm.envOr("RUN_BNB_LIVE_SCANNER_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", 125462265);
        assertEq(block.chainid, 56);
    }

    function testFinalizedRenouncedAndAllLpBurned() public view {
        assertEq(LiveScannerToken(TOKEN).owner(), address(0));
        assertEq(LiveScannerToken(TOKEN).phase(), 2);
        assertEq(LiveScannerToken(TOKEN).mainPool(), POOL);
        assertEq(LiveScannerToken(POOL).balanceOf(address(0)), 1000);
        assertEq(
            LiveScannerToken(POOL).balanceOf(DEAD) + LiveScannerToken(POOL).balanceOf(address(0)),
            LiveScannerToken(POOL).totalSupply()
        );
    }

    function _path(address input, address output) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = input;
        path[1] = output;
    }

    function _swap(address buyer, address input, address output, uint256 amount)
        private returns (uint256 received)
    {
        uint256 beforeBalance = LiveScannerToken(output).balanceOf(buyer);
        vm.startPrank(buyer, buyer);
        LiveScannerToken(input).approve(ROUTER, amount);
        LiveScannerRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 1, _path(input, output), buyer, block.timestamp + 300
        );
        vm.stopPrank();
        received = LiveScannerToken(output).balanceOf(buyer) - beforeBalance;
        assertGt(received, 0);
    }

    function _roundTrip(uint256 amount) private {
        address buyer = makeAddr("live-scanner-fresh-buyer");
        deal(QUOTE, buyer, amount);
        uint256 bought = _swap(buyer, QUOTE, TOKEN, amount);
        uint256 recovered = _swap(buyer, TOKEN, QUOTE, bought);
        assertEq(LiveScannerToken(TOKEN).balanceOf(buyer), 0);
        console2.log("BNCB spent raw", amount);
        console2.log("TST bought raw", bought);
        console2.log("BNCB recovered raw", recovered);
    }

    function testSmallBuyAndFullSellDuringFirstHour() public { _roundTrip(0.1 ether); }

    function testLargerBuyRevertsDuringFirstHour() public {
        assertLt(block.timestamp, uint256(LiveScannerToken(TOKEN).graduatedAt()) + 1 hours);
        uint256 gross = LiveScannerRouter(ROUTER).getAmountsOut(0.5 ether, _path(QUOTE, TOKEN))[1];
        assertGt(gross * 9500 / 10000, 10_000_000 ether);
        address buyer = makeAddr("live-scanner-large-buyer");
        deal(QUOTE, buyer, 0.5 ether);
        vm.startPrank(buyer, buyer);
        LiveScannerToken(QUOTE).approve(ROUTER, 0.5 ether);
        vm.expectRevert(bytes("Pancake: TRANSFER_FAILED"));
        LiveScannerRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0.5 ether, 1, _path(QUOTE, TOKEN), buyer, block.timestamp + 300
        );
        vm.stopPrank();
        // Reveal the token error masked by Pancake's low-level transfer helper.
        vm.prank(POOL);
        vm.expectRevert(bytes4(keccak256("MaxWalletExceeded()")));
        LiveScannerToken(TOKEN).transfer(buyer, gross);
    }

    function testSameLargerBuyAndFullSellAfterFirstHour() public {
        vm.warp(uint256(LiveScannerToken(TOKEN).graduatedAt()) + 1 hours);
        _roundTrip(0.5 ether);
    }

    function testExistingHolderFullDexExitDuringFirstHour() public {
        address holder = address(bytes20(hex"a606f5ebe7cebb5496cc73026f3c94dc289dbb3a"));
        uint256 amount = LiveScannerToken(TOKEN).balanceOf(holder);
        assertGt(amount, 10_000_000 ether);
        uint256 received = _swap(holder, TOKEN, QUOTE, amount);
        assertEq(LiveScannerToken(TOKEN).balanceOf(holder), 0);
        console2.log("Existing holder sold TST raw", amount);
        console2.log("Existing holder received BNCB raw", received);
    }

    function testExistingHolderIntermediaryTransferFailsUntilWindowEnds() public {
        address holder = address(bytes20(hex"a606f5ebe7cebb5496cc73026f3c94dc289dbb3a"));
        address intermediary = makeAddr("non-exempt-intermediary");
        uint256 amount = LiveScannerToken(TOKEN).balanceOf(holder);
        assertGt(amount, 10_000_000 ether);
        vm.startPrank(holder, holder);
        vm.expectRevert(bytes4(keccak256("MaxWalletExceeded()")));
        LiveScannerToken(TOKEN).transfer(intermediary, amount);
        vm.warp(uint256(LiveScannerToken(TOKEN).graduatedAt()) + 1 hours);
        assertTrue(LiveScannerToken(TOKEN).transfer(intermediary, amount));
        vm.stopPrank();
        assertEq(LiveScannerToken(TOKEN).balanceOf(intermediary), amount);
    }

    function _nativePath(bool buying) private pure returns (address[] memory path) {
        path = new address[](3);
        path[0] = buying ? WBNB : TOKEN;
        path[1] = QUOTE;
        path[2] = buying ? TOKEN : WBNB;
    }

    function _nativeRoundTrip(uint256 amount) private {
        address buyer = makeAddr("native-route-buyer");
        deal(buyer, amount);
        vm.startPrank(buyer, buyer);
        LiveScannerRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            1, _nativePath(true), buyer, block.timestamp + 300
        );
        uint256 bought = LiveScannerToken(TOKEN).balanceOf(buyer);
        assertGt(bought, 0);
        LiveScannerToken(TOKEN).approve(ROUTER, bought);
        LiveScannerRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            bought, 1, _nativePath(false), buyer, block.timestamp + 300
        );
        vm.stopPrank();
        assertEq(LiveScannerToken(TOKEN).balanceOf(buyer), 0);
        assertGt(buyer.balance, 0);
        console2.log("BNB spent raw", amount);
        console2.log("BNB recovered raw", buyer.balance);
    }

    function testNativeSmallRoundTripDuringFirstHour() public { _nativeRoundTrip(0.0005 ether); }

    function testNativeLargerBuyFailsBeforeExpiryAndRoundTripsAfter() public {
        address buyer = makeAddr("native-route-buyer");
        deal(buyer, 0.01 ether);
        vm.prank(buyer, buyer);
        vm.expectRevert(bytes("Pancake: TRANSFER_FAILED"));
        LiveScannerRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            1, _nativePath(true), buyer, block.timestamp + 300
        );
        vm.warp(uint256(LiveScannerToken(TOKEN).graduatedAt()) + 1 hours);
        _nativeRoundTrip(0.01 ether);
    }
}