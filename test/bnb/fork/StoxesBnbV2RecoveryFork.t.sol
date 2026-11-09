// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbMigrationForkTest, MigrationERC20, MigrationPool} from "./StoxesBnbMigrationFork.t.sol";
import {StoxesBnbGraduator} from "../../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {console2} from "forge-std/Test.sol";

/// CANDIDATE ONLY: overlays the new graduator runtime in a private fork.
/// All other application code/state, token implementations and Pancake contracts
/// are the deployed versions. This is NOT an upgrade available on mainnet.
/// The original deployed-code acceptance suite remains independently red.
contract StoxesBnbV2RecoveryForkTest is StoxesBnbMigrationForkTest {
    bytes private deployedRuntime;
    bytes private candidateRuntime;

    function setUp() public override {
        super.setUp();
        if (!vm.envOr("RUN_BNB_MIGRATION_FORK", false)) return;
        deployedRuntime = GRADUATOR.code;
        StoxesBnbGraduator old = StoxesBnbGraduator(payable(GRADUATOR));
        StoxesBnbGraduator candidate = new StoxesBnbGraduator(WBNB, NFPM, old.treasury(), old.admin());
        candidateRuntime = address(candidate).code;
        vm.etch(GRADUATOR, candidateRuntime);
        console2.log("CANDIDATE ONLY: graduator runtime overlay, not a live upgrade");
        console2.logBytes32(GRADUATOR.codehash);
        console2.log("Canonical Pancake V2 factory runtime hash");
        console2.logBytes32(V2FACTORY.codehash);
        console2.log("Canonical Pancake V2 router runtime hash");
        console2.logBytes32(V2ROUTER.codehash);
    }

    function testBNCB_Tax_ContaminatedPairRecovery() public override {
        _donationLifecycle(BNCB, 1 ether, true, false);
    }

    function testBNCB_UnsyncedDonation() public { _donationLifecycle(BNCB, 1 ether, false, false); }
    function testBNCB_DustDonation() public { _donationLifecycle(BNCB, 1, true, false); }
    function testBNCB_HugeDonation() public { _donationLifecycle(BNCB, type(uint112).max, true, false); }
    function testNative_SyncedDonation_ForkOnlyAdmission() public {
        _donationLifecycle(address(0), 1 ether, true, false);
    }

    function testBNCB_DeferredRecovery_CandidateOverlayOnly() public {
        // Establish the exact stuck state with UNMODIFIED deployed bytecode.
        // After proving it reverts, the candidate overlay exercises finalize.
        _donationLifecycle(BNCB, 1 ether, true, true);
    }

    function _donationLifecycle(address quote, uint256 donation, bool synced, bool deferred) internal {
        (address token, address vault) = _create(quote, true, quote == address(0));
        address asset = _asset(quote);
        address pool = _pool(token);
        assertTrue(MigrationPool(pool).token0() == token || MigrationPool(pool).token1() == token);
        assertTrue(MigrationPool(pool).token0() == asset || MigrationPool(pool).token1() == asset);
        _fund(asset, address(this), donation);
        MigrationERC20(asset).transfer(pool, donation);
        if (synced) MigrationPool(pool).sync();
        assertEq(MigrationERC20(pool).totalSupply(), 0);
        vm.prank(owner); vm.expectRevert();
        MigrationERC20(token).transfer(pool, 1);
        if (deferred) vm.etch(GRADUATOR, deployedRuntime);
        _fill(token, quote);
        if (deferred) {
            assertEq(MigrationERC20(token).phase(), 1);
            assertEq(MigrationERC20(pool).totalSupply(), 0);
            vm.prank(owner); vm.expectRevert();
            MigrationERC20(token).transfer(pool, 1);
            vm.prank(owner); MigrationERC20(token).approve(PORTAL, type(uint256).max);
            vm.prank(owner); vm.expectRevert();
            portal.sell(token, 1 ether, 0);
            vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
            portal.buyFor(token, owner, owner, 1, 0);
            vm.expectRevert(StoxesBnbPortal.NotBonding.selector);
            portal.sellFor(token, owner, 1, 0);
            uint256 tokensBefore = MigrationERC20(token).balanceOf(GRADUATOR);
            uint256 quoteBefore = MigrationERC20(asset).balanceOf(GRADUATOR);
            vm.expectRevert(StoxesBnbGraduator.PriceOutOfBand.selector);
            portal.finalizeGraduation(token);
            assertEq(MigrationERC20(token).balanceOf(GRADUATOR), tokensBefore);
            assertEq(MigrationERC20(asset).balanceOf(GRADUATOR), quoteBefore);
            // A second adversarial donation between begin and finalize, this
            // time unsynced. Recovery must use balances, not stale reserves.
            _fund(asset, address(this), donation);
            MigrationERC20(asset).transfer(pool, donation);
            donation *= 2;
            vm.etch(GRADUATOR, candidateRuntime);
            uint256 treasuryBefore = MigrationERC20(asset).balanceOf(portal.treasury());
            uint256 gasBefore = gasleft();
            portal.finalizeGraduation(token);
            console2.log("Candidate finalize call gas", gasBefore - gasleft());
            assertEq(MigrationERC20(token).balanceOf(pool), tokensBefore);
            assertEq(MigrationERC20(asset).balanceOf(pool), quoteBefore + 1);
            assertEq(MigrationERC20(asset).balanceOf(portal.treasury()), treasuryBefore + donation - 1);
            assertEq(MigrationERC20(asset).balanceOf(GRADUATOR), 0);
            assertEq(MigrationERC20(token).balanceOf(GRADUATOR), 0);
        }
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized, "donation migration must finalize");
        assertEq(MigrationERC20(token).phase(), 2);
        assertEq(MigrationERC20(token).balanceOf(pool), 200_000_000 ether, "all migration tokens in pool");
        assertEq(MigrationERC20(pool).balanceOf(DEAD), MigrationERC20(pool).totalSupply() - 1000);
        assertEq(MigrationERC20(pool).balanceOf(owner), 0);
        assertEq(MigrationERC20(pool).balanceOf(address(this)), 0);
        assertEq(MigrationERC20(pool).balanceOf(GRADUATOR), 0);
        (address pendingQuote, address pendingPool,,,,,,,) = StoxesBnbGraduator(payable(GRADUATOR)).pending(token);
        assertEq(pendingPool, address(0));
        assertEq(pendingQuote, address(0));
        vm.expectRevert();
        portal.finalizeGraduation(token);
        _dexRoundTrip(token, quote, true, pool);
        _fees(token, quote, true, vault);
        console2.log("PASS candidate donation recovery, LP burn, actual DEX buy/sell and tax payouts");
    }
}