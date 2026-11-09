// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20, MockSwapPairMintable} from "../mocks/Mocks.sol";
import {StoxesBnbGraduator} from "../../src/bnb/StoxesBnbGraduator.sol";

contract RejectedDonationQuote is MockERC20 {
    address public blocked;
    constructor() MockERC20("Quote", "Q", 18) {}
    function setBlocked(address to) external { blocked = to; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "recipient blocked");
        return super.transfer(to, amount);
    }
}

/// Fast adversarial/accounting tests. The real pair acceptance tests live in
/// fork/StoxesBnbV2RecoveryFork.t.sol; these mocks are not deployment evidence.
contract StoxesBnbV2ContaminationTest is Test {
    uint256 constant T = 200_000_000 ether;
    uint256 constant Q = 2000 ether;
    address constant TREASURY = address(0x777);
    address constant DEAD = address(0xdead);
    StoxesBnbGraduator g;
    MockERC20 token;
    RejectedDonationQuote quote;
    MockSwapPairMintable pair;

    function setUp() public {
        token = new MockERC20("Token", "T", 18);
        quote = new RejectedDonationQuote();
        g = new StoxesBnbGraduator(address(1), address(2), TREASURY, address(this));
        g.setPortal(address(this));
        pair = new MockSwapPairMintable(address(token), address(quote), 25);
        token.mint(address(this), T);
        quote.mint(address(this), Q);
        token.approve(address(g), T);
        quote.approve(address(g), Q);
    }

    function _begin() internal returns (bool) {
        return g.beginTax(address(token), address(quote), address(pair), T, Q);
    }

    function _assertPending(uint256 quoteBudget) internal view {
        (address q, address p,, uint128 t, uint128 amount,,,, bool simple) = g.pending(address(token));
        assertEq(q, address(quote)); assertEq(p, address(pair)); assertEq(t, T);
        assertEq(amount, quoteBudget); assertFalse(simple);
        assertEq(token.balanceOf(address(g)), T);
        assertEq(quote.balanceOf(address(g)), quoteBudget);
    }

    function _assertRecovered(uint256 donation, uint256 quoteBudget) internal view {
        uint256 denominator = 10_000 + (T / 2) * 9975;
        uint256 left = donation > 1 ? (donation * 10_000 + denominator - 1) / denominator : donation;
        assertEq(token.balanceOf(address(pair)), T);
        assertEq(quote.balanceOf(address(pair)), quoteBudget + left);
        assertEq(quote.balanceOf(TREASURY), donation - left, "treasury gets only donated quote");
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.balanceOf(address(g)), 0);
        assertEq(quote.balanceOf(address(g)), 0);
        assertEq(pair.lpRecipient(), DEAD);
        assertGt(pair.totalSupply(), 0);
        (address q, address p,,,,,,,) = g.pending(address(token));
        assertEq(q, address(0)); assertEq(p, address(0));
    }

    function testFuzzDonationConservation(uint112 donation, bool synced, bool reverse) public {
        if (reverse) pair = new MockSwapPairMintable(address(quote), address(token), 25);
        quote.mint(address(pair), donation);
        if (synced) pair.sync();
        assertTrue(_begin());
        _assertRecovered(donation, Q);
    }

    function testCleanAndDust() public {
        quote.mint(address(pair), 1);
        pair.sync();
        assertTrue(_begin());
        _assertRecovered(1, Q);
    }

    function testSixDecimalQuoteDonation() public {
        // The recovery operates on raw units, not assumed 18-decimal prices.
        MockERC20 six = new MockERC20("Six decimals", "SIX", 6);
        pair = new MockSwapPairMintable(address(six), address(token), 25);
        six.mint(address(this), 4_000_000);
        six.approve(address(g), 4_000_000);
        six.mint(address(pair), 100_000_000_000_000);
        pair.sync();
        assertTrue(g.beginTax(address(token), address(six), address(pair), T, 4_000_000));
        assertEq(six.balanceOf(address(pair)), 4_000_001);
        assertEq(six.balanceOf(TREASURY), 100_000_000_000_000 - 1);
        assertEq(token.balanceOf(address(pair)), T);
    }

    function testRejectsTokenOnlyAndTwoSidedBalancesEvenWhenUnsynced() public {
        token.mint(address(pair), 1);
        quote.mint(address(pair), 1 ether);
        assertFalse(_begin());
        _assertPending(Q);
        vm.expectRevert(StoxesBnbGraduator.PriceOutOfBand.selector);
        g.finalize(address(token));
        _assertPending(Q);
        assertEq(quote.balanceOf(TREASURY), 0);
        assertEq(pair.totalSupply(), 0);
    }

    function testRejectsExistingLpEvenAtExactMigrationPrice() public {
        token.mint(address(pair), T);
        quote.mint(address(pair), Q);
        pair.mint(address(0xbad));
        uint256 supply = pair.totalSupply();
        assertFalse(_begin());
        vm.expectRevert(StoxesBnbGraduator.PriceOutOfBand.selector);
        g.finalize(address(token));
        _assertPending(Q);
        assertEq(pair.totalSupply(), supply);
        assertEq(pair.lpRecipient(), address(0xbad));
    }

    function testWrongQuoteIdentityDefersWithoutTransfers() public {
        pair = new MockSwapPairMintable(address(token), address(new MockERC20("Wrong", "W", 18)), 25);
        assertFalse(_begin());
        _assertPending(Q);
        assertEq(token.balanceOf(address(pair)), 0);
    }

    function testReserveOverflowAndFinalPriceBoundFailClosed() public {
        quote.mint(address(pair), uint256(type(uint112).max) + 1);
        assertFalse(_begin());
        vm.expectRevert(StoxesBnbGraduator.PriceOutOfBand.selector);
        g.finalize(address(token));
        _assertPending(Q);
    }

    function testExcessiveRoundingCannotSetArbitraryFinalPrice() public {
        quote.mint(address(pair), type(uint112).max);
        assertFalse(g.beginTax(address(token), address(quote), address(pair), T, 1));
        _assertPending(1);
        vm.expectRevert(StoxesBnbGraduator.PriceOutOfBand.selector);
        g.finalize(address(token));
        _assertPending(1);
    }

    function testDeferredRetryUsesNewDonationsAndCannotReplay() public {
        // Synthetic unsupported token balance forces pending. Removing it is
        // test-only ERC20 behavior, not a claimed rescue for deployed tax tokens.
        token.mint(address(pair), 1);
        assertFalse(_begin());
        vm.prank(address(pair)); token.transfer(address(this), 1);
        quote.mint(address(pair), 1 ether);
        pair.sync();
        quote.mint(address(pair), 2 ether);
        (,,,,, bool complete) = g.finalize(address(token));
        assertTrue(complete);
        _assertRecovered(3 ether, Q);
        vm.expectRevert(StoxesBnbGraduator.NoPending.selector);
        g.finalize(address(token));
    }

    function testRejectedDonationTransferRollsBackAllFundsAndCanRetry() public {
        token.mint(address(pair), 1);
        assertFalse(_begin());
        vm.prank(address(pair)); token.transfer(address(this), 1);
        quote.mint(address(pair), 1 ether);
        pair.sync();
        quote.setBlocked(TREASURY);
        vm.expectRevert();
        g.finalize(address(token));
        _assertPending(Q);
        assertEq(token.balanceOf(address(pair)), 0);
        assertEq(quote.balanceOf(address(pair)), 1 ether);
        assertEq(pair.totalSupply(), 0);
        quote.setBlocked(address(0));
        (,,,,, bool complete) = g.finalize(address(token));
        assertTrue(complete);
        _assertRecovered(1 ether, Q);
    }

    function testRecoveryCannotSpendAnotherTokensCustody() public {
        token.mint(address(pair), 1);
        assertFalse(_begin());
        _assertPending(Q);
        MockERC20 other = new MockERC20("Other", "O", 18);
        MockSwapPairMintable otherPair = new MockSwapPairMintable(address(other), address(quote), 25);
        other.mint(address(this), T);
        other.approve(address(g), T);
        quote.mint(address(this), Q);
        quote.approve(address(g), Q);
        quote.mint(address(otherPair), 1 ether);
        assertTrue(g.beginTax(address(other), address(quote), address(otherPair), T, Q));
        _assertPending(Q);
        assertEq(other.balanceOf(address(otherPair)), T);
        assertEq(quote.balanceOf(address(otherPair)), Q + 1);
    }

    function testOnlyPortalCanBeginOrFinalize() public {
        vm.startPrank(address(0xbad));
        vm.expectRevert(StoxesBnbGraduator.NotPortal.selector);
        g.beginTax(address(token), address(quote), address(pair), T, Q);
        vm.expectRevert(StoxesBnbGraduator.NotPortal.selector);
        g.finalize(address(token));
        vm.stopPrank();
    }
}