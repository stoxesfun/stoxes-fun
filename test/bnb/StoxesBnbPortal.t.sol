// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbPortal} from "../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbGraduator} from "../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbPortalMath} from "../../src/bnb/libraries/StoxesBnbPortalMath.sol";
import {
    BnbLaunchKind,
    IStoxesBnbPortal,
    IStoxesBnbTaxToken
} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20, MockWETH, MockSwapPairMintable} from "../mocks/Mocks.sol";
import {
    MockNonfungiblePositionManager,
    MockV3Pool
} from "../mocks/MocksV3.sol";
import {
    PortalLaneLocker,
    PortalLaneSimpleToken,
    PortalLaneTaxToken,
    PortalLaneTaxProcessor,
    PortalLaneVault,
    PortalLanePair
} from "./mocks/PortalLaneMocks.sol";

contract PortalGasExhaustingReceiver {
    receive() external payable {
        while (gasleft() != 0) {}
    }
}

contract StoxesBnbPortalTest is Test {
    uint256 internal constant R = 1 ether;
    uint256 internal constant K = 1_000_000_000 ether;
    uint256 internal constant GRAD = 4 ether;

    MockWETH internal weth;
    MockNonfungiblePositionManager internal nfpm;
    PortalLaneLocker internal locker;
    StoxesBnbGraduator internal graduator;
    StoxesBnbPortal internal portal;
    address internal treasury = address(0x7100);
    address internal creator = address(0xC0DE);

    function setUp() public {
        weth = new MockWETH();
        nfpm = new MockNonfungiblePositionManager();
        locker = new PortalLaneLocker();
        graduator = new StoxesBnbGraduator(address(weth), address(nfpm), treasury, address(this));
        portal = new StoxesBnbPortal(address(weth), treasury, address(graduator), address(this));
        graduator.setPortal(address(portal));
        portal.setLocker(address(locker));
        portal.setFactory(address(this));
        portal.setQuoteParams(address(0), R, 0, K, GRAD, true);
    }

    function _registerSimple() internal returns (PortalLaneSimpleToken token) {
        token = new PortalLaneSimpleToken(address(portal), address(weth), creator);
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), address(weth), BnbLaunchKind.Simple, creator, address(0), address(0)
            )
        );
    }

    function _registerTax(address quote, address pair)
        internal
        returns (PortalLaneTaxToken token, PortalLaneVault vault)
    {
        vault = new PortalLaneVault(quote);
        token = new PortalLaneTaxToken(
            address(portal), quote, creator, address(vault), address(0xB0), address(0xC0)
        );
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), quote, BnbLaunchKind.Tax, creator, address(vault), pair
            )
        );
    }

    function testBuySellAndTreasuryFee() public {
        PortalLaneSimpleToken token = _registerSimple();
        address user = address(0xA1);
        vm.deal(user, 1 ether);
        vm.prank(user, user);
        (uint256 out, uint256 spent) = portal.buy{value: 0.02 ether}(address(token), 0);
        assertGt(out, 0);
        assertEq(treasury.balance, spent / 100);
        vm.prank(user);
        token.approve(address(portal), out);
        uint256 beforeNative = user.balance;
        vm.prank(user);
        uint256 received = portal.sell(address(token), out / 2, 0);
        assertEq(user.balance, beforeNative + received);
        assertGt(treasury.balance, spent / 100);
    }

    function testSellForPaysRecipientNativeAndPullsFromCaller() public {
        PortalLaneSimpleToken token = _registerSimple();
        address user = address(0xA3);
        address recipient = address(0xB3);
        vm.deal(user, 1 ether);
        vm.prank(user, user);
        (uint256 out,) = portal.buy{value: 0.02 ether}(address(token), 0);
        vm.prank(user);
        token.approve(address(portal), out);
        uint256 userNative = user.balance;
        uint256 userTokens = token.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        portal.sellFor(address(token), address(0), out, 0);
        vm.prank(user);
        uint256 received = portal.sellFor(address(token), recipient, out, 0);
        assertGt(received, 0);
        assertEq(recipient.balance, received);
        assertEq(user.balance, userNative);
        assertEq(token.balanceOf(user), userTokens - out);
        assertEq(token.balanceOf(recipient), 0);
    }

    function testBuyForExceedsFormerWalletCap() public {
        PortalLaneSimpleToken token = _registerSimple();
        address user = address(0xA2);
        vm.deal(user, 2 ether);
        uint256 beforeNative = user.balance;
        vm.prank(user, user);
        (uint256 out, uint256 spent) =
            portal.buyFor{value: 1 ether}(address(token), user, user, 1 ether, 0);
        assertGt(out, 40_000_000 ether);
        assertEq(spent, 1 ether);
        assertEq(user.balance, beforeNative - spent);
    }

    function testSameOriginRepeatedLargeBuysFullSellAndRebuy() public {
        PortalLaneSimpleToken token = _registerSimple();
        address user = address(0xA4);
        vm.deal(user, 10 ether);
        vm.startPrank(user, user);
        (uint256 first,) = portal.buy{value: 1 ether}(address(token), 0);
        (uint256 second,) = portal.buy{value: 1 ether}(address(token), 0);
        assertGt(first, 40_000_000 ether);
        assertGt(second, 40_000_000 ether);
        token.approve(address(portal), type(uint256).max);
        assertGt(portal.sell(address(token), first + second, 0), 0);
        assertEq(token.balanceOf(user), 0);
        (uint256 rebought,) = portal.buy{value: 1 ether}(address(token), 0);
        assertGt(rebought, 40_000_000 ether);
        vm.stopPrank();
        assertEq(portal.MAX_ORIGIN_TOKENS(), type(uint256).max);
    }

    function testSixDecimalQuoteBuyAndSell() public {
        MockERC20 quote = new MockERC20("Stock", "STK", 6);
        portal.setQuoteParams(address(quote), R, 0, K, 4_000_000, true);
        PortalLaneSimpleToken token =
            new PortalLaneSimpleToken(address(portal), address(quote), creator);
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), address(quote), BnbLaunchKind.Simple, creator, address(0), address(0)
            )
        );
        quote.mint(address(this), 1_000_000);
        quote.approve(address(portal), type(uint256).max);
        (uint256 out,) = portal.buyWithQuote(address(token), 200_000, 0);
        assertGt(out, 40_000_000 ether);
        token.approve(address(portal), out);
        uint256 before = quote.balanceOf(address(this));
        portal.sell(address(token), out, 0);
        assertGt(quote.balanceOf(address(this)), before);
        (uint256 rebought,) = portal.buyWithQuote(address(token), 200_000, 0);
        assertGt(rebought, 40_000_000 ether);
    }

    function testTaxQuoteLargeBuyFullSellRebuyWithoutWalletCap() public {
        MockERC20 quote = new MockERC20("Stock", "STK", 18);
        portal.setQuoteParams(address(quote), R, 0, K, GRAD, true);
        MockSwapPairMintable pair = new MockSwapPairMintable(address(quote), address(0x1234), 25);
        (PortalLaneTaxToken token,) = _registerTax(address(quote), address(pair));
        quote.mint(address(this), 5 ether);
        quote.approve(address(portal), type(uint256).max);
        (uint256 out,) = portal.buyWithQuote(address(token), 1 ether, 0);
        assertGt(out, 40_000_000 ether);
        token.approve(address(portal), out);
        assertGt(portal.sell(address(token), out, 0), 0);
        assertEq(token.balanceOf(address(this)), 0);
        (uint256 rebought,) = portal.buyWithQuote(address(token), 1 ether, 0);
        assertGt(rebought, 40_000_000 ether);
    }

    function testEveryPreGradTaxStreamAndDispatch() public {
        MockERC20 quote = new MockERC20("Stock", "STK", 18);
        portal.setQuoteParams(address(quote), R, 0, K, GRAD, true);
        MockSwapPairMintable pair =
            new MockSwapPairMintable(address(quote), address(0x1234), 25);
        (PortalLaneTaxToken token, PortalLaneVault vault) =
            _registerTax(address(quote), address(pair));
        portal.setCreatorDispatchThreshold(type(uint256).max);
        quote.mint(address(this), 1 ether);
        quote.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(address(token), 0.05 ether, 0);
        assertGt(quote.balanceOf(treasury), 0);
        assertGt(quote.balanceOf(address(0xC0)), 0);
        assertGt(vault.accountedQuote(), 0);
        assertEq(vault.pings(), 1);
        assertGt(portal.creatorBucket(address(token)), 0);
        (uint128 burn, uint128 liquidity) = portal.taxEscrow(address(token));
        assertGt(burn, 0);
        assertGt(liquidity, 0);
        uint256 creatorBefore = quote.balanceOf(creator);
        portal.dispatchCreator(address(token));
        assertGt(quote.balanceOf(creator), creatorBefore);
    }

    function testGasExhaustingCommissionAndCreatorFallBackToWbnb() public {
        PortalGasExhaustingReceiver hostile = new PortalGasExhaustingReceiver();
        PortalLaneVault vault = new PortalLaneVault(address(weth));
        PortalLaneTaxToken token = new PortalLaneTaxToken(
            address(portal),
            address(weth),
            address(hostile),
            address(vault),
            address(0xB0),
            address(hostile)
        );
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token),
                address(weth),
                BnbLaunchKind.Tax,
                address(hostile),
                address(vault),
                address(0x1234)
            )
        );
        portal.setCreatorDispatchThreshold(0);
        vm.deal(address(this), 0.05 ether);

        portal.buy{value: 0.05 ether}(address(token), 0);

        assertGt(weth.balanceOf(address(hostile)), 0);
        assertEq(address(hostile).balance, 0);
        assertEq(portal.creatorBucket(address(token)), 0);
    }

    function testRegressionRealV3AmountsGraduateAndLock() public {
        PortalLaneSimpleToken token = _registerSimple();
        _fillNative(address(token));
        (,, bool graduated,,,) = portal.tokenState(address(token));
        assertTrue(graduated);
        assertEq(token.phase(), 2);
        assertEq(locker.registeredToken(), address(token));
        assertGt(locker.registeredId(), 0);
    }

    function testRegressionBurnEscrowIsAccountedAtProcessor() public {
        PortalLanePair pair = new PortalLanePair(address(weth));
        PortalLaneVault vault = new PortalLaneVault(address(weth));
        PortalLaneTaxProcessor taxProcessor = new PortalLaneTaxProcessor();
        PortalLaneTaxToken token = new PortalLaneTaxToken(
            address(portal), address(weth), creator, address(vault), address(taxProcessor), address(0xC0)
        );
        pair.setToken(address(token));
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), address(weth), BnbLaunchKind.Tax, creator, address(vault), address(pair)
            )
        );
        _fillNative(address(token));
        assertEq(pair.lpRecipient(), address(0xdead));
        assertEq(uint256(token.phase()), uint256(IStoxesBnbTaxToken.Phase.TaxEnforced));
        assertGt(weth.balanceOf(address(taxProcessor)), 0);
        assertGt(taxProcessor.burnQuotePending(address(token)), 0);
    }

    function testHostileSimplePoolDefersThenFinalizes() public {
        PortalLaneSimpleToken token = _registerSimple();
        nfpm.setNextTick(800_000);
        (address token0, address token1) =
            address(token) < address(weth) ? (address(token), address(weth)) : (address(weth), address(token));
        address pool = nfpm.createAndInitializePoolIfNecessary(token0, token1, 10_000, uint160(1 << 96));
        _fillNative(address(token));
        assertEq(token.phase(), 1);
        (,,, bool finalized,,) = portal.tokenState(address(token));
        assertFalse(finalized);
        uint160 expected = StoxesBnbPortalMath.sqrtPriceFromCurve(
            portal.curvePrice(address(token)), 18, address(token) < address(weth)
        );
        MockV3Pool(pool).setSqrtPriceX96(expected);
        (,,,,,, int24 expectedLow, int24 expectedHigh,) = graduator.pending(address(token));
        MockV3Pool(pool).setTick(expectedLow + (expectedHigh - expectedLow) / 2);
        portal.finalizeGraduation(address(token));
        assertEq(token.phase(), 2);
        (,, int24 mintedLow, int24 mintedHigh, uint256 amount0, uint256 amount1) =
            nfpm.positions(locker.registeredId());
        assertEq(mintedLow, expectedLow);
        assertEq(mintedHigh, expectedHigh);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        (,,, finalized,,) = portal.tokenState(address(token));
        assertTrue(finalized);
    }

    function testAccessControl() public {
        vm.expectRevert(StoxesBnbPortal.LockerAlreadySet.selector);
        portal.setLocker(address(locker));
        vm.expectRevert(StoxesBnbPortal.FactoryAlreadySet.selector);
        portal.setFactory(address(this));
        vm.expectRevert();
        portal.setFactory(address(0xF));
        PortalLaneSimpleToken token =
            new PortalLaneSimpleToken(address(portal), address(weth), creator);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), address(weth), BnbLaunchKind.Simple, creator, address(0), address(0)
            )
        );
        vm.prank(address(0xBAD));
        vm.expectRevert();
        graduator.beginTax(address(token), address(weth), address(1), 1, 1);
    }

    function testRegressionCurveParamsAreSnapshottedPerToken() public {
        PortalLaneSimpleToken token = _registerSimple();
        uint256 beforePrice = portal.curvePrice(address(token));
        portal.setQuoteParams(address(0), 2 ether, 1 ether, K * 2, GRAD * 2, true);
        assertEq(portal.curvePrice(address(token)), beforePrice);
    }

    function _fillNative(address token) internal {
        address user = address(0x1000);
        vm.deal(user, 20 ether);
        for (uint256 i; i < 20; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) break;
            uint256 before = user.balance;
            vm.prank(user, user);
            (, uint256 spent) = portal.buy{value: 1 ether}(token, 0);
            assertEq(user.balance, before - spent);
        }
    }
}