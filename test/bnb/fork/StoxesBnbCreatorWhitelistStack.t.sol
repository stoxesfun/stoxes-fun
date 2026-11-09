// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbRenounceableTaxToken as Token} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {BnbCreateParams, BnbLaunchKind, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";
import {StackQuote, StackRouter} from "./StoxesBnbRenounceableStackFork.t.sol";

/// Tests the exact rehearsed deployment; live RPC bridge cannot broadcast.
contract BnbCreatorWhitelistStackTest is Test {
    address constant QUOTE = address(bytes20(hex"4902c5ebc598265ed2212b559b042de8a5eeec3f"));
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    address creator;
    StoxesBnbFactory factory;
    StoxesBnbPortal portal;

    function setUp() public {
        if (!vm.envOr("RUN_BNB_CREATOR_WHITELIST_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18547");
        factory = StoxesBnbFactory(payable(vm.envAddress("BNB_STACK_FACTORY")));
        portal = StoxesBnbPortal(payable(factory.portal()));
        creator = vm.envAddress("BNB_WHITELIST_CREATOR");
        assertTrue(factory.creatorWhitelist(creator));
        assertFalse(factory.launchesOpen());
        assertTrue(creator != factory.owner());
    }

    function _params() internal view returns (BnbCreateParams memory p) {
        p.version = 1; p.kind = BnbLaunchKind.Tax;
        p.name = "Normal creator"; p.symbol = "NORMAL"; p.quoteToken = QUOTE;
        p.buyTaxBps = 500; p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(10000, 0, 0, 0);
        p.vaultFactory = vm.envAddress("BNB_STACK_FLOOR_FACTORY");
        p.vaultData = abi.encode(uint16(0));
    }

    function testNormalWhitelistedLaunchTradeGraduateAndDexSell() public {
        BnbCreateParams memory p = _params();
        (,,, uint128 target,,) = portal.quoteParams(QUOTE);
        assertGt(target, 0);
        deal(QUOTE, creator, uint256(target) * 10);
        vm.startPrank(creator, creator);
        (address token, address vault,,) = factory.createToken(p);
        assertEq(factory.testCurveQuote(token), 0, "must be ordinary public-compatible token");
        assertFalse(factory.launchesOpen());
        Token t = Token(token);
        StackQuote(QUOTE).approve(address(portal), type(uint256).max);
        portal.buyWithQuote(token, target / 10, 1);
        uint256 bought = t.balanceOf(creator);
        assertGt(bought, 0);
        t.approve(address(portal), bought / 2);
        portal.sell(token, bought / 2, 1);
        portal.buyWithQuote(token, uint256(target) * 2, 1);
        assertEq(uint256(t.phase()), 2, "finalized graduation");
        assertEq(t.owner(), address(0));
        uint256 all = t.balanceOf(creator);
        t.approve(ROUTER, all);
        address[] memory path = new address[](2);
        path[0] = token; path[1] = QUOTE;
        StackRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            all, 1, path, creator, block.timestamp + 300);
        assertEq(t.balanceOf(creator), 0);
        assertGt(StackQuote(QUOTE).balanceOf(vault), 0, "floor funded normally");
        vm.stopPrank();
    }

    function testNormalSimpleLaunchRevocationAndPublicOpening() public {
        BnbCreateParams memory p;
        p.version = 1; p.kind = BnbLaunchKind.Simple;
        p.name = "Normal simple"; p.symbol = "SIMPLE"; p.quoteToken = QUOTE;
        vm.prank(creator);
        (address token,,,) = factory.createToken(p);
        assertEq(factory.testCurveQuote(token), 0);
        vm.prank(factory.owner());
        factory.setCreatorWhitelisted(creator, false);
        p.salt = bytes32(uint256(2));
        vm.prank(creator);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);
        address publicCreator = makeAddr("unapproved-public");
        vm.prank(publicCreator);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);
        vm.prank(factory.owner());
        factory.setLaunchesOpen(true);
        vm.prank(publicCreator);
        factory.createToken(p); // Exactly the same function and params.
    }
}
