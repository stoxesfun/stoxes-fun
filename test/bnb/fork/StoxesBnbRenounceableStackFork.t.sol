// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbRenounceableTaxToken as Token} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {BnbCreateParams, BnbLaunchKind, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";

interface StackQuote {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
interface StackRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
}

/// Executes against the completed local deployment rehearsal, never broadcasts.
contract RenounceableStackForkTest is Test {
    address constant OWNER = 0x9Cf1e0bff5022cbE849d04185E2117CcA354c20B;
    address constant QUOTE = address(bytes20(hex"4902c5ebc598265ed2212b559b042de8a5eeec3f"));
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    StoxesBnbFactory factory;
    StoxesBnbPortal portal;

    function setUp() public {
        if (!vm.envOr("RUN_BNB_STACK_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18547");
        factory = StoxesBnbFactory(payable(vm.envAddress("BNB_STACK_FACTORY")));
        portal = StoxesBnbPortal(payable(factory.portal()));
        assertFalse(factory.launchesOpen());
        assertTrue(factory.isTestLaunchAdmin(OWNER));
    }

    function testRehearsedStackFloorLaunchGraduateAndFullSell() public {
        BnbCreateParams memory p;
        p.version = 1;
        p.kind = BnbLaunchKind.Tax;
        p.name = "Local rehearsal";
        p.symbol = "LOCAL";
        p.quoteToken = QUOTE;
        p.buyTaxBps = 500;
        p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(10000, 0, 0, 0);
        p.vaultFactory = vm.envAddress("BNB_STACK_FLOOR_FACTORY");
        p.vaultData = abi.encode(uint16(0));
        deal(QUOTE, OWNER, 10 ether);
        vm.startPrank(OWNER, OWNER);
        (address token, address vault,,) = factory.createTestToken(p, 1 ether);
        Token t = Token(token);
        assertEq(t.owner(), address(portal));
        StackQuote(QUOTE).approve(address(portal), 10 ether);
        portal.buyWithQuote(token, 0.1 ether, 1);
        uint256 bought = t.balanceOf(OWNER);
        assertGt(bought, 0);
        t.approve(address(portal), bought / 2);
        portal.sell(token, bought / 2, 1);
        portal.buyWithQuote(token, 2 ether, 1);
        assertEq(uint256(t.phase()), 2, "graduation finalized");
        assertEq(t.owner(), address(0));
        assertGt(t.mainPool().code.length, 0);
        uint256 fullBalance = t.balanceOf(OWNER);
        // Prove the exact rehearsed implementation permits large non-exempt
        // custody transfers in the graduation block, not only direct pool sells.
        assertGt(fullBalance, t.MAX_SUPPLY() / 100);
        address intermediary = makeAddr("rehearsal-intermediary");
        t.approve(intermediary, fullBalance);
        vm.stopPrank();
        vm.startPrank(intermediary, intermediary);
        t.transferFrom(OWNER, intermediary, fullBalance);
        t.approve(ROUTER, fullBalance);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = QUOTE;
        StackRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            fullBalance, 1, path, OWNER, block.timestamp + 300);
        assertEq(t.balanceOf(OWNER), 0);
        assertEq(t.balanceOf(intermediary), 0);
        assertEq(block.timestamp, t.graduatedAt());
        assertGt(StackQuote(QUOTE).balanceOf(vault), 0, "floor funded");
        vm.stopPrank();
    }
}