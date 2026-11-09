// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface ScannerToken {
    function owner() external view returns (address);
    function getOwner() external view returns (address);
    function phase() external view returns (uint8);
    function mainPool() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ScannerRouter {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
}

/// Read-only mainnet fork. Never broadcast. The round-trip tests fund only a
/// local test wallet; the existing-holder exit uses unchanged deployed balances.
contract StoxesBnbGraduatedScannerForkTest is Test {
    address constant TOKEN = address(bytes20(hex"5075baa3d5bd5529a0dfbf16c7e04b617a449999"));
    address constant QUOTE = address(bytes20(hex"4902c5ebc598265ed2212b559b042de8a5eeec3f"));
    address constant POOL = address(bytes20(hex"61caef5732b52297f806611207dc4c55e9014ea2"));
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    address constant HOLDER = address(bytes20(hex"a606f5ebe7cebb5496cc73026f3c94dc289dbb3a"));

    function setUp() public {
        if (!vm.envOr("RUN_BNB_SCANNER_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_FORK_BLOCK"));
        assertEq(block.chainid, 56);
    }

    function testDeployedOwnershipAndFinalizedPool() public view {
        assertEq(ScannerToken(TOKEN).owner(), address(0));
        assertEq(ScannerToken(TOKEN).getOwner(), address(0));
        assertEq(ScannerToken(TOKEN).phase(), 2);
        assertEq(ScannerToken(TOKEN).mainPool(), POOL);
    }

    function _swap(address who, address input, address output, uint256 amount) private returns (uint256 received) {
        address[] memory path = new address[](2);
        path[0] = input; path[1] = output;
        uint256 beforeBalance = ScannerToken(output).balanceOf(who);
        vm.startPrank(who, who);
        ScannerToken(input).approve(ROUTER, amount);
        ScannerRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 1, path, who, block.timestamp + 300
        );
        vm.stopPrank();
        received = ScannerToken(output).balanceOf(who) - beforeBalance;
        assertGt(received, 0, "swap must deliver real output");
    }

    function testHistoricalExistingHolderCanSellEntireBalance() public {
        // Both original holders already exited on mainnet by the current
        // snapshot. Reproduce the first holder's full exit just before its
        // observed sell at block 125448269; do not invent a holder balance.
        vm.rollFork(125448268);
        uint256 amount = ScannerToken(TOKEN).balanceOf(HOLDER);
        assertGt(amount, 0);
        uint256 received = _swap(HOLDER, TOKEN, QUOTE, amount);
        assertEq(ScannerToken(TOKEN).balanceOf(HOLDER), 0);
        console2.log("Existing holder sold TEST raw", amount);
        console2.log("Existing holder received BNCB raw", received);
    }

    function testFreshWalletSmallRoundTrip() public { _roundTrip(0.1 ether); }
    function testFreshWalletLargerRoundTrip() public { _roundTrip(3 ether); }

    function _roundTrip(uint256 amount) private {
        address buyer = makeAddr("scanner-fresh-buyer");
        deal(QUOTE, buyer, amount);
        address[] memory path = new address[](2);
        path[0] = QUOTE; path[1] = TOKEN;
        uint256 gross = ScannerRouter(ROUTER).getAmountsOut(amount, path)[1];
        uint256 bought = _swap(buyer, QUOTE, TOKEN, amount);
        assertEq(bought, gross - gross * 500 / 10_000, "buy tax must be 5 percent");
        path[0] = TOKEN; path[1] = QUOTE;
        uint256 expected = ScannerRouter(ROUTER).getAmountsOut(bought - bought * 500 / 10_000, path)[1];
        uint256 received = _swap(buyer, TOKEN, QUOTE, bought);
        assertEq(received, expected, "sell tax must be 5 percent");
        assertEq(ScannerToken(TOKEN).balanceOf(buyer), 0);
        console2.log("Fresh wallet spent BNCB raw", amount);
        console2.log("Fresh wallet recovered BNCB raw", received);
    }
}