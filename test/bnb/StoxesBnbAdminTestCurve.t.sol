// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbIntegrationTest} from "./StoxesBnbIntegration.t.sol";
import {StoxesBnbFactory} from "../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbSimpleToken} from "../../src/bnb/StoxesBnbSimpleToken.sol";
import {BnbCreateParams, IStoxesBnbPortal} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// Fresh local contracts; no live transactions or secrets.
contract StoxesBnbAdminTestCurveTest is StoxesBnbIntegrationTest {
    address delegate = address(0xAD01);
    address stranger = address(0xBAD);

    function testSingleCreatorBuyCanGraduateAndRefundOvershoot() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        p.creatorBuyQuoteAmount = 1 ether;
        vm.deal(address(this), 2 ether);
        uint256 before = address(this).balance;
        (address token,, uint256 bought, uint256 spent) =
            factory.createTestToken{value: 1 ether}(p, 0.2 ether);
        assertEq(bought, portal.CURVE_SALE_SUPPLY());
        assertLt(spent, 1 ether);
        assertEq(address(this).balance, before - spent);
        (,, bool graduated, bool finalized,,) = portal.tokenState(token);
        assertTrue(graduated);
        assertTrue(finalized);
    }

    function testAdminNativePointTwoScalesFullCurveAndGraduates() public {
        (address token,,,) = factory.createTestToken(_simple(address(0), address(0), ""), 0.2 ether);
        _assertCurve(token, 0.2 ether, R / 20, K / 20);
        _fillNative(token, 0);
        (,, bool graduated, bool finalized,,) = portal.tokenState(token);
        assertTrue(graduated);
        assertTrue(finalized);
        assertGt(locker.feeInfo(token).tokenId, 0);
    }

    function testAdminTaxPointTwoGraduatesWithVault() public {
        BnbCreateParams memory p = _tax(address(0), address(giftFactory), abi.encode(bytes32("test")));
        (address token, address vault,,) = factory.createTestToken(p, 0.2 ether);
        _assertCurve(token, 0.2 ether, R / 20, K / 20);
        _fillNative(token, 0);
        (,, bool graduated, bool finalized,,) = portal.tokenState(token);
        assertTrue(graduated);
        assertTrue(finalized);
        assertGt(weth.balanceOf(vault), 0);
    }

    function testAdminStockOneUnitUsesQuoteDecimalsAndAtomicPurchase() public {
        // Six-decimal fixture also catches accidental hardcoded 18-decimal parsing.
        BnbCreateParams memory p = _simple(address(stock), address(0), "");
        p.creatorBuyQuoteAmount = 100_000;
        stock.mint(address(this), 100_000);
        stock.approve(address(factory), 100_000);
        (address token,, uint256 bought, uint256 spent) = factory.createTestToken(p, 1_000_000);
        _assertCurve(token, 1_000_000, R / 4, K / 4);
        assertGt(bought, 0);
        assertGt(bought, 40_000_000 ether);
        assertLe(bought, portal.CURVE_SALE_SUPPLY());
        assertEq(stock.balanceOf(address(this)), 100_000 - spent);
        assertEq(stock.balanceOf(address(factory)), 0);
        StoxesBnbSimpleToken(token).approve(address(portal), bought);
        uint256 before = stock.balanceOf(address(this));
        portal.sell(token, bought, 0);
        assertGt(stock.balanceOf(address(this)), before);
    }

    function testAdminBncbOneUnitEighteenDecimals() public {
        MockERC20 bncb = new MockERC20("Test BNCB", "BNCB", 18);
        portal.setQuoteParams(address(bncb), 500 ether, 0, K * 500, 2000 ether, true);
        factory.setQuoteAllowed(address(bncb), true);
        (address token,,,) = factory.createTestToken(_simple(address(bncb), address(0), ""), 1 ether);
        _assertCurve(token, 1 ether, 0.25 ether, K / 4);
    }

    function testTestCurveDoesNotChangeDefaultsOrExistingAndSubsequentPublicTokens() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        (address beforeToken,,,) = factory.createToken(p);
        p.salt = bytes32(uint256(2));
        (address testToken,,,) = factory.createTestToken(p, 0.2 ether);
        p.salt = bytes32(uint256(3));
        factory.setLaunchesOpen(true);
        vm.prank(stranger);
        (address afterToken,,,) = factory.createToken(p);
        _assertCurve(beforeToken, GRAD, R, K);
        _assertCurve(testToken, 0.2 ether, R / 20, K / 20);
        _assertCurve(afterToken, GRAD, R, K);
        (uint128 r,, uint256 k, uint128 target,,) = portal.quoteParams(address(weth));
        assertEq(r, R); assertEq(k, K); assertEq(target, GRAD);
        assertEq(factory.testCurveQuote(beforeToken), 0);
        assertEq(factory.testCurveQuote(testToken), 0.2 ether);
        assertEq(factory.testCurveQuote(afterToken), 0);
    }

    function testPublicCannotCreateTestEvenWhenPublicLaunchesOpen() public {
        factory.setLaunchesOpen(true);
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        vm.prank(stranger);
        vm.expectRevert(StoxesBnbFactory.NotTestLaunchAdmin.selector);
        factory.createTestToken(p, 0.2 ether);
        vm.prank(stranger);
        vm.expectRevert();
        factory.setTestLaunchAdmin(stranger, true);
    }

    function testDelegateRevocationAndClosedPublicGate() public {
        assertFalse(factory.launchesOpen());
        factory.setTestLaunchAdmin(delegate, true);
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        vm.prank(delegate);
        (address token,,,) = factory.createTestToken(p, 0.2 ether);
        assertEq(StoxesBnbSimpleToken(token).creator(), delegate);
        assertFalse(factory.launchesOpen());
        p.salt = bytes32(uint256(2));
        vm.prank(delegate);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);
        factory.setTestLaunchAdmin(delegate, false);
        vm.prank(delegate);
        vm.expectRevert(StoxesBnbFactory.NotTestLaunchAdmin.selector);
        factory.createTestToken(p, 1 ether);
    }

    function testDirectPortalOverrideAndExistingTokenMutationRejected() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        (address token,,,) = factory.createTestToken(p, 0.2 ether);
        IStoxesBnbPortal.Registration memory reg = IStoxesBnbPortal.Registration(
            token, address(weth), p.kind, address(this), address(0), address(0)
        );
        vm.expectRevert(StoxesBnbPortal.NotFactory.selector);
        portal.registerTestToken(reg, 1 ether); // Even portal owner cannot mutate it.
        vm.prank(address(factory));
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        portal.registerTestToken(reg, 1 ether);
        _assertCurve(token, 0.2 ether, R / 20, K / 20);
    }

    function testTestLaunchStillRequiresBothQuotePermissions() public {
        BnbCreateParams memory p = _simple(address(stock), address(0), "");
        factory.setQuoteAllowed(address(stock), false);
        vm.expectRevert(StoxesBnbFactory.QuoteNotAllowed.selector);
        factory.createTestToken(p, 1_000_000);
        factory.setQuoteAllowed(address(stock), true);
        portal.setQuoteParams(address(stock), R, 0, K, 4_000_000, false);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        factory.createTestToken(p, 1_000_000);
    }

    function testInvalidTargetBoundsAndPrecisionCollapseRejected() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createTestToken(p, 0);
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createTestToken(p, uint256(type(uint128).max) + 1);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        factory.createTestToken(p, 1); // r would round to zero.
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.setTestLaunchAdmin(address(0), true);
    }

    function testFuzzTestCurveScalesWithoutChangingDefaults(uint96 input) public {
        uint256 target = bound(input, 1e12, 1000 ether);
        (address token,,,) = factory.createTestToken(_simple(address(0), address(0), ""), target);
        _assertCurve(token, target, R * target / GRAD, K * target / GRAD);
        (uint128 r,, uint256 k, uint128 defaultTarget,,) = portal.quoteParams(address(weth));
        assertEq(r, R); assertEq(k, K); assertEq(defaultTarget, GRAD);
    }

    function _assertCurve(address token, uint256 target, uint256 rExpected, uint256 kExpected) private view {
        (uint128 r, uint128 h, uint256 k, uint128 graduationQuote,) = portal.tokenCurve(token);
        assertEq(r, rExpected); assertEq(h, 0); assertEq(k, kExpected);
        assertEq(graduationQuote, target);
    }
}