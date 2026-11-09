// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbMigrationForkTest, MigrationERC20, MigrationPool, MigrationNfpm} from "./StoxesBnbMigrationFork.t.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbGraduator} from "../../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbV3Locker} from "../../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbAdminFloorReserveVaultFactory} from "../../../src/bnb/vaults/StoxesBnbAdminFloorReserveVaultFactory.sol";
import {console2} from "forge-std/Test.sol";

contract ForkRejectNative {
    receive() external payable { revert("no native"); }
}

/// Fresh candidate application stack, locally deployed to the pinned fork.
/// No bytecode replacement or storage edits to application/Pancake contracts.
/// Existing immutable token implementations are reused intentionally: no token
/// implementation change is needed, but each NEW clone binds to the NEW portal.
contract StoxesBnbFreshRecoveryForkTest is StoxesBnbMigrationForkTest {
    function setUp() public virtual override {
        super.setUp();
        if (!vm.envOr("RUN_BNB_MIGRATION_FORK", false)) return;
        StoxesBnbPortal previous = portal;
        StoxesBnbFactory previousFactory = factory;
        address treasury = previous.treasury();
        StoxesBnbGraduator g = new StoxesBnbGraduator(WBNB, NFPM, treasury, owner);
        portal = new StoxesBnbPortal(WBNB, treasury, address(g), owner);
        processor = new StoxesBnbTaxProcessor(WBNB, treasury, processor.minThreshold(), owner);
        locker = new StoxesBnbV3Locker(
            address(portal), WBNB, NFPM, locker.v3Factory(), locker.swapRouter(), treasury, owner
        );
        factory = new StoxesBnbFactory(
            previousFactory.simpleTokenImplementation(), previousFactory.taxTokenImplementation(),
            address(portal), WBNB, V2FACTORY, address(processor), owner
        );
        FLOOR = address(new StoxesBnbAdminFloorReserveVaultFactory(address(factory), owner, address(portal)));
        FACTORY = address(factory); PORTAL = address(portal); GRADUATOR = address(g);
        PROCESSOR = address(processor); LOCKER = address(locker);
        vm.startPrank(owner);
        g.setPortal(PORTAL);
        processor.setPortal(PORTAL);
        portal.setFactory(FACTORY);
        portal.setLocker(LOCKER);
        factory.setVaultFactoryAllowed(FLOOR, true);
        factory.setQuoteAllowed(BNCB, previousFactory.quoteAllowed(BNCB));
        factory.setQuoteAllowed(address(0), previousFactory.quoteAllowed(address(0)));
        _copyCurve(previous, BNCB);
        _copyCurve(previous, WBNB);
        portal.setCreatorDispatchThreshold(previous.creatorDispatchThreshold());
        vm.stopPrank();
        assertEq(portal.graduator(), GRADUATOR);
        assertEq(factory.portal(), PORTAL);
        assertEq(g.portal(), PORTAL);
        assertFalse(factory.launchesOpen(), "fresh stack remains admission closed");
        console2.log("FRESH CANDIDATE STACK: local deployment only, no etch, no live writes");
        console2.log("Candidate factory", FACTORY);
        console2.log("Candidate portal", PORTAL);
        console2.log("Candidate graduator", GRADUATOR);
    }

    function _copyCurve(StoxesBnbPortal previous, address asset) private {
        (uint128 r, uint128 h, uint256 k, uint128 graduation,, bool allowed) = previous.quoteParams(asset);
        portal.setQuoteParams(asset, r, h, k, graduation, allowed);
        (uint128 newR, uint128 newH, uint256 newK, uint128 newGraduation,, bool newAllowed) = portal.quoteParams(asset);
        assertEq(r, newR); assertEq(h, newH); assertEq(k, newK);
        assertEq(graduation, newGraduation); assertEq(allowed, newAllowed);
    }

    function testBNCB_Tax_ContaminatedPairRecovery() public override {
        _freshDonation(1 ether, true);
    }

    function testBNCB_FreshStackUnsyncedHugeDonation() public {
        _freshDonation(type(uint112).max, false);
    }

    function testForwardingBNCB_V2() public { _forwarding(BNCB, true); }
    function testForwardingBNCB_V3() public { _forwarding(BNCB, false); }
    function testForwardingNative_V2() public { _forwarding(address(0), true); }
    function testForwardingNative_V3() public { _forwarding(address(0), false); }

    function _forwarding(address quote, bool tax) private {
        (address token,) = _create(quote, tax, quote == address(0));
        address pool = tax ? _pool(token) : StoxesBnbGraduator(payable(GRADUATOR)).simplePool(token, _asset(quote));
        assertGt(pool.code.length, 0, "pool address reserved before any buyFor");
        assertEq(MigrationERC20(token).balanceOf(pool), 0);
        address buyer = address(0xFA100);
        address holder = address(0xFA101);
        address refund = address(0xFA102);
        _fund(quote, buyer, target * 4);
        if (quote != address(0)) { vm.prank(buyer); MigrationERC20(quote).approve(PORTAL, type(uint256).max); }
        uint256 beforeBuyer = _balance(quote, buyer);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        _forwardBuy(token, quote, buyer, pool, refund, target, 0);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        _forwardBuy(token, quote, buyer, holder, pool, target, 0);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        _forwardBuy(token, quote, buyer, address(0), refund, target, 0);
        vm.expectRevert(StoxesBnbPortal.SlippageExceeded.selector);
        _forwardBuy(token, quote, buyer, holder, refund, target, type(uint256).max);
        assertEq(_balance(quote, buyer), beforeBuyer, "rejected buys must not spend");
        uint256 beforeRefund = _balance(quote, refund);
        (uint256 bought, uint256 spent) = _forwardBuy(token, quote, buyer, holder, refund, target / 10, 1);
        assertGt(bought, 0); assertLe(bought, portal.CURVE_SALE_SUPPLY());
        assertEq(spent, target / 10);
        assertEq(MigrationERC20(token).balanceOf(holder), bought);
        assertEq(MigrationERC20(token).balanceOf(buyer), 0);
        assertEq(_balance(quote, buyer), beforeBuyer - spent);
        assertEq(_balance(quote, refund), beforeRefund);
        _forwardSells(token, quote, holder, pool, bought);
        assertEq(MigrationERC20(token).balanceOf(pool), 0, "forwarding never seeded the pool");
        beforeBuyer = _balance(quote, buyer);
        beforeRefund = _balance(quote, refund);
        (, spent) = _forwardBuy(token, quote, buyer, holder, refund, target * 2, 1);
        assertLt(spent, target * 2);
        assertEq(_balance(quote, buyer), beforeBuyer - target * 2);
        assertEq(_balance(quote, refund), beforeRefund + target * 2 - spent);
        assertEq(MigrationERC20(token).phase(), 2);
        vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
        _forwardBuy(token, quote, buyer, holder, refund, 1, 0);
        vm.prank(holder); vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
        portal.sellFor(token, refund, 1, 0);
        _dexRoundTrip(token, quote, tax, _pool(token));
        console2.log("PASS buyFor/sellFor: pool/refund guards, separate recipients, exact refunds, allowance, slippage, phases");
    }

    function _forwardBuy(
        address token, address quote, address buyer, address recipient, address refund, uint256 offered, uint256 minOut
    ) private returns (uint256, uint256) {
        vm.prank(buyer, buyer);
        return portal.buyFor{value: quote == address(0) ? offered : 0}(token, recipient, refund, offered, minOut);
    }

    function _forwardSells(address token, address quote, address holder, address pool, uint256 bought) private {
        address recipient = address(0xFA103);
        vm.prank(holder); vm.expectRevert();
        portal.sellFor(token, recipient, bought / 4, 0); // No approval yet.
        vm.prank(holder); MigrationERC20(token).approve(PORTAL, type(uint256).max);
        // Approval does not let another caller debit this holder's tokens.
        vm.prank(address(0xbad)); vm.expectRevert();
        portal.sellFor(token, recipient, bought / 4, 0);
        vm.prank(holder); vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        portal.sellFor(token, pool, bought / 4, 0);
        vm.prank(holder); vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        portal.sellFor(token, address(0), bought / 4, 0);
        vm.prank(holder); vm.expectRevert(StoxesBnbPortal.SlippageExceeded.selector);
        portal.sellFor(token, recipient, bought / 4, type(uint256).max);
        assertEq(MigrationERC20(token).balanceOf(holder), bought);
        uint256 beforeRecipient = _balance(quote, recipient);
        uint256 beforeHolder = _balance(quote, holder);
        vm.prank(holder);
        uint256 out = portal.sellFor(token, recipient, bought / 4, 1);
        assertGt(out, 0);
        assertEq(_balance(quote, recipient), beforeRecipient + out);
        assertEq(_balance(quote, holder), beforeHolder, "not accidentally paid to seller");
        assertEq(MigrationERC20(token).balanceOf(holder), bought - bought / 4);
        if (quote == address(0)) {
            ForkRejectNative rejector = new ForkRejectNative();
            vm.prank(holder);
            uint256 wrapped = portal.sellFor(token, address(rejector), bought / 4, 1);
            assertGt(wrapped, 0);
            assertEq(MigrationERC20(WBNB).balanceOf(address(rejector)), wrapped);
            assertEq(address(rejector).balance, 0);
        }
    }

    function testV3ForwardingBlockedWhileMigrationPending() public {
        (address token,) = _create(BNCB, false, false);
        (address t0, address t1) = token < BNCB ? (token, BNCB) : (BNCB, token);
        MigrationNfpm(NFPM).createAndInitializePoolIfNecessary(t0, t1, 10_000, uint160(1 << 96));
        _fill(token, BNCB);
        assertEq(MigrationERC20(token).phase(), 1);
        vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
        portal.buyFor(token, owner, owner, 1, 0);
        vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
        portal.sellFor(token, owner, 1, 0);
        portal.finalizeGraduation(token);
        assertEq(MigrationERC20(token).phase(), 2);
        _dexRoundTrip(token, BNCB, false, _pool(token));
    }

    function _freshDonation(uint256 donation, bool synced) private {
        (address token, address vault) = _create(BNCB, true, false);
        address pool = _pool(token);
        _fund(BNCB, address(this), donation);
        MigrationERC20(BNCB).transfer(pool, donation);
        if (synced) MigrationPool(pool).sync();
        assertEq(MigrationERC20(pool).totalSupply(), 0);
        _fill(token, BNCB);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized);
        assertEq(MigrationERC20(token).phase(), 2);
        assertEq(MigrationERC20(token).balanceOf(pool), 200_000_000 ether);
        assertEq(MigrationERC20(token).balanceOf(GRADUATOR), 0);
        assertEq(MigrationERC20(BNCB).balanceOf(GRADUATOR), 0);
        assertEq(MigrationERC20(pool).balanceOf(DEAD), MigrationERC20(pool).totalSupply() - 1000);
        _dexRoundTrip(token, BNCB, true, pool);
        _fees(token, BNCB, true, vault);
        console2.log("PASS fresh candidate stack donation recovery and post-migration lifecycle");
    }
}