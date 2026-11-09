// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbIntegrationTest} from "./StoxesBnbIntegration.t.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {MockNonfungiblePositionManager, MockSwapRouter02, MockV3Pool} from "../mocks/MocksV3.sol";
import {TokenLanePortal} from "./mocks/TokenLaneMocks.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {BnbCreateParams, BnbFeeMode, BnbLaunchKind} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbFactory} from "../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbSimpleToken} from "../../src/bnb/StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {StoxesBnbV3Locker} from "../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbFloorReserveVaultFactory} from "../../src/bnb/vaults/StoxesBnbFloorReserveVaultFactory.sol";
import {StoxesBnbAdminFloorReserveVaultFactory} from
    "../../src/bnb/vaults/StoxesBnbAdminFloorReserveVaultFactory.sol";
import {StoxesBnbStocksVaultFactory} from "../../src/bnb/vaults/StoxesBnbStocksVaultFactory.sol";
import {StoxesBnbRoutedStocksVaultFactory} from "../../src/bnb/vaults/StoxesBnbRoutedStocksVaultFactory.sol";

interface IBncQuoteVault {
    function vaultQuoteToken() external view returns (address);
}

/// Local mocks only. This verifies denomination and the existing allowlist
/// boundary, not mainnet identity, liquidity, signatures or activation status.
contract StoxesBncCurveVerificationTest is StoxesBnbIntegrationTest {
    MockERC20 bncb;

    function _bncMode() internal {
        bncb = new MockERC20("CEA Industries bStock (local mock)", "BNCB", 18);
        portal.setQuoteParams(address(bncb), R, 0, K, GRAD, true);
        factory.setQuoteAllowed(address(bncb), true);
        factory.setQuoteAllowed(address(0), false);
        factory.setQuoteAllowed(address(stock), false);
        factory.setLaunchesOpen(true);
        portal.setCreatorDispatchThreshold(type(uint256).max);
    }

    function testBncFactoryBlocksNativeAndOtherQuoteSimpleAndTaxIncludingOwner() public {
        _bncMode();
        address[2] memory callers = [address(this), address(0xBAD)];
        address[2] memory forbidden = [address(0), address(stock)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 q; q < forbidden.length; ++q) {
                BnbCreateParams memory simple = _simple(forbidden[q], address(0), "");
                vm.prank(callers[c]);
                vm.expectRevert(StoxesBnbFactory.QuoteNotAllowed.selector);
                factory.createToken(simple);
                BnbCreateParams memory taxed = _tax(forbidden[q], address(buybackFactory), "");
                vm.prank(callers[c]);
                vm.expectRevert(StoxesBnbFactory.QuoteNotAllowed.selector);
                factory.createToken(taxed);
            }
        }
        // The owner bypasses launchesOpen, but never the quote allowlist.
        factory.setLaunchesOpen(false);
        vm.expectRevert(StoxesBnbFactory.QuoteNotAllowed.selector);
        factory.createToken(_simple(address(0), address(0), ""));
        factory.createToken(_simple(address(bncb), address(0), ""));
        factory.createToken(_tax(address(bncb), address(buybackFactory), ""));
    }

    function _buyBnc(address token, address buyer, uint256 offered) internal {
        bncb.mint(buyer, offered);
        vm.startPrank(buyer, buyer);
        bncb.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(token, offered, 0);
        vm.stopPrank();
    }

    function _assertTaxCurve(address vaultFactory, bytes memory data) internal {
        BnbCreateParams memory p = _tax(address(bncb), vaultFactory, data);
        (address token, address vault,,) = factory.createToken(p);
        uint256 treasuryBefore = bncb.balanceOf(treasury);
        uint256 nativeBefore = treasury.balance;
        _buyBnc(token, address(uint160(uint256(keccak256(abi.encode(vaultFactory))))), 0.01 ether);
        uint256 accrued = portal.creatorBucket(token);
        assertGt(accrued, 0);
        assertEq(bncb.balanceOf(address(this)), 0, "bucket is not a completed creator payout");
        assertGt(bncb.balanceOf(treasury), treasuryBefore);
        assertGt(bncb.balanceOf(vault), 0);
        assertEq(IBncQuoteVault(vault).vaultQuoteToken(), address(bncb));
        uint256 dispatched = portal.dispatchCreator(token);
        assertEq(dispatched, accrued);
        assertEq(bncb.balanceOf(address(this)), accrued);
        assertEq(portal.creatorBucket(token), 0);
        assertEq(treasury.balance, nativeBefore);
        assertEq(weth.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(vault), 0);
        bncb.transfer(address(0xF00D), accrued); // independent next fixture
    }

    function testBncTaxCurvePaysQuoteCreatorPlatformAndEveryVaultSelection() public {
        _bncMode();
        _assertTaxCurve(address(buybackFactory), "");
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xA1);
        recipients[1] = address(0xA2);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 4000;
        shares[1] = 6000;
        _assertTaxCurve(address(splitFactory), abi.encode(recipients, shares));
        _assertTaxCurve(address(giftFactory), abi.encode(keccak256("bnc-mock")));
        StoxesBnbFloorReserveVaultFactory floor =
            new StoxesBnbFloorReserveVaultFactory(address(factory), address(this), address(portal));
        factory.setVaultFactoryAllowed(address(floor), true);
        _assertTaxCurve(address(floor), abi.encode(uint16(0)));
        StoxesBnbAdminFloorReserveVaultFactory adminFloor =
            new StoxesBnbAdminFloorReserveVaultFactory(address(factory), address(this), address(portal));
        factory.setVaultFactoryAllowed(address(adminFloor), true);
        _assertTaxCurve(address(adminFloor), abi.encode(uint16(0)));
        StoxesBnbStocksVaultFactory stocks =
            new StoxesBnbStocksVaultFactory(address(factory), address(this), address(nfpm));
        stocks.setDividendStockAllowed(address(bncb), true);
        factory.setVaultFactoryAllowed(address(stocks), true);
        _assertTaxCurve(address(stocks), abi.encode(address(bncb), uint256(0)));
        StoxesBnbRoutedStocksVaultFactory routedStocks = new StoxesBnbRoutedStocksVaultFactory(
            address(factory), address(this), address(nfpm), address(stock)
        );
        routedStocks.setDividendStockAllowed(address(bncb), true);
        factory.setVaultFactoryAllowed(address(routedStocks), true);
        _assertTaxCurve(address(routedStocks), abi.encode(address(bncb), uint256(0)));
    }

    function testBncSimpleCurvePaysPlatformAndPreservesExistingCreatorEconomics() public {
        _bncMode();
        (address token,,,) = factory.createToken(_simple(address(bncb), address(0), ""));
        address buyer = address(0xB0B);
        uint256 nativeBefore = treasury.balance;
        _buyBnc(token, buyer, 0.01 ether);
        assertGt(bncb.balanceOf(treasury), 0);
        // Simple curves' 1% goes to platform; creator LP earnings begin after
        // graduation. BNC mode must not invent or change percentage splits.
        assertEq(portal.creatorBucket(token), 0);
        uint256 platformBefore = bncb.balanceOf(treasury);
        uint256 proceedsBefore = bncb.balanceOf(buyer);
        vm.startPrank(buyer, buyer);
        StoxesBnbSimpleToken(token).approve(address(portal), type(uint256).max);
        portal.sell(token, StoxesBnbSimpleToken(token).balanceOf(buyer) / 2, 0);
        vm.stopPrank();
        assertGt(bncb.balanceOf(buyer), proceedsBefore);
        assertGt(bncb.balanceOf(treasury), platformBefore);
        assertEq(treasury.balance, nativeBefore);
        assertEq(weth.balanceOf(treasury), 0);
    }

    function _graduateBnc(address token) internal {
        for (uint256 i; i < 24; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) break;
            _buyBnc(token, address(uint160(0x5000 + i)), 1 ether);
        }
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized);
    }

    function _assertTaxProcessing(address vaultFactory, bytes memory data) internal {
        (address token, address vault,,) = factory.createToken(_tax(address(bncb), vaultFactory, data));
        _graduateBnc(token);
        StoxesBnbTaxToken taxed = StoxesBnbTaxToken(token);
        assertEq(taxed.quoteToken(), address(bncb));
        assertEq(uint256(taxed.phase()), 2);
        // Past the fixed anti-farmer hour; accrue an ordinary transfer tax
        // against the real graduated pair, not a fake caller-supplied token.
        vm.warp(block.timestamp + 1 hours);
        address holder = address(0x5000);
        address pair = taxed.mainPool();
        uint256 sellAmount = taxed.balanceOf(holder) / 4;
        vm.prank(holder);
        taxed.transfer(pair, sellAmount);
        assertGt(taxed.pendingTax(), 0);
        processor.setThresholds(1, type(uint256).max);
        uint256 creatorBefore = bncb.balanceOf(address(this));
        uint256 treasuryBefore = bncb.balanceOf(treasury);
        uint256 vaultBefore = bncb.balanceOf(vault);
        uint256 nativeBefore = treasury.balance;
        assertGt(processor.process(token), 0);
        uint256 pending = processor.creatorPending(token);
        assertGt(pending, 0);
        assertEq(bncb.balanceOf(address(this)), creatorBefore, "unpaid bucket must not appear as payout");
        assertGt(bncb.balanceOf(treasury), treasuryBefore);
        assertGt(bncb.balanceOf(vault), vaultBefore);
        processor.dispatch(token);
        assertEq(bncb.balanceOf(address(this)) - creatorBefore, pending);
        assertEq(processor.creatorPending(token), 0);
        assertEq(treasury.balance, nativeBefore);
        assertEq(weth.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(vault), 0);
    }

    function testBncTaxGraduationAndProcessingRetainQuoteAndPendingIsNotPaid() public {
        _bncMode();
        _assertTaxProcessing(address(buybackFactory), "");
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xA1);
        recipients[1] = address(0xA2);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 4000;
        shares[1] = 6000;
        _assertTaxProcessing(address(splitFactory), abi.encode(recipients, shares));
        _assertTaxProcessing(address(giftFactory), abi.encode(keccak256("bnc-mock")));
        StoxesBnbFloorReserveVaultFactory floor =
            new StoxesBnbFloorReserveVaultFactory(address(factory), address(this), address(portal));
        factory.setVaultFactoryAllowed(address(floor), true);
        _assertTaxProcessing(address(floor), abi.encode(uint16(0)));
        StoxesBnbAdminFloorReserveVaultFactory adminFloor =
            new StoxesBnbAdminFloorReserveVaultFactory(address(factory), address(this), address(portal));
        factory.setVaultFactoryAllowed(address(adminFloor), true);
        _assertTaxProcessing(address(adminFloor), abi.encode(uint16(0)));
        StoxesBnbStocksVaultFactory stocks =
            new StoxesBnbStocksVaultFactory(address(factory), address(this), address(nfpm));
        stocks.setDividendStockAllowed(address(bncb), true);
        factory.setVaultFactoryAllowed(address(stocks), true);
        _assertTaxProcessing(address(stocks), abi.encode(address(bncb), uint256(0)));
        StoxesBnbRoutedStocksVaultFactory routedStocks = new StoxesBnbRoutedStocksVaultFactory(
            address(factory), address(this), address(nfpm), address(stock)
        );
        routedStocks.setDividendStockAllowed(address(bncb), true);
        factory.setVaultFactoryAllowed(address(routedStocks), true);
        _assertTaxProcessing(address(routedStocks), abi.encode(address(bncb), uint256(0)));
    }

    function testBncTaxCreatorOnlyWithoutVaultPaysBncNotGasAsset() public {
        _bncMode();
        BnbCreateParams memory p = _tax(address(bncb), address(0), "");
        p.allocation.vaultBps = 0;
        p.allocation.creatorBps = 10_000;
        p.allocation.burnBps = 0;
        p.allocation.liquidityBps = 0;
        (address token, address vault,,) = factory.createToken(p);
        assertEq(vault, address(0));
        _buyBnc(token, address(0xB0B), 0.01 ether);
        uint256 pending = portal.creatorBucket(token);
        portal.dispatchCreator(token);
        assertEq(bncb.balanceOf(address(this)), pending);
        assertGt(pending, 0);
        assertGt(bncb.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(address(this)), 0);
        assertEq(weth.balanceOf(treasury), 0);
    }

    function testBncAllowlistDoesNotBreakExistingTradingAndOffDoesNotRepairPairs() public {
        factory.setLaunchesOpen(true);
        (address nativeToken,,,) = factory.createToken(_simple(address(0), address(0), ""));
        BnbCreateParams memory other = _simple(address(stock), address(0), "");
        other.salt = keccak256("legacy-other");
        (address stockToken,,,) = factory.createToken(other);
        (address nativeTax,,,) = factory.createToken(_tax(address(0), address(buybackFactory), ""));
        _bncMode();
        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer, buyer);
        portal.buy{value: 0.01 ether}(nativeToken, 0);
        vm.prank(buyer, buyer);
        portal.buy{value: 0.01 ether}(nativeTax, 0);
        uint256 nativeCreatorBefore = address(this).balance;
        uint256 nativePending = portal.creatorBucket(nativeTax);
        portal.dispatchCreator(nativeTax);
        assertEq(address(this).balance - nativeCreatorBefore, nativePending);
        stock.mint(buyer, 100_000);
        vm.startPrank(buyer, buyer);
        stock.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(stockToken, 50_000, 0);
        StoxesBnbSimpleToken(stockToken).approve(address(portal), type(uint256).max);
        portal.sell(stockToken, StoxesBnbSimpleToken(stockToken).balanceOf(buyer) / 2, 0);
        StoxesBnbSimpleToken(nativeToken).approve(address(portal), type(uint256).max);
        portal.sell(nativeToken, StoxesBnbSimpleToken(nativeToken).balanceOf(buyer) / 2, 0);
        vm.stopPrank();
        BnbCreateParams memory bnc = _simple(address(bncb), address(0), "");
        bnc.salt = keccak256("bnc-unique");
        (address bncToken,,,) = factory.createToken(bnc);
        factory.setQuoteAllowed(address(0), true);
        factory.setQuoteAllowed(address(stock), true);
        factory.setQuoteAllowed(address(bncb), false);
        _buyBnc(bncToken, buyer, 0.01 ether);
        vm.startPrank(buyer, buyer);
        StoxesBnbSimpleToken(bncToken).approve(address(portal), type(uint256).max);
        portal.sell(bncToken, StoxesBnbSimpleToken(bncToken).balanceOf(buyer) / 2, 0);
        vm.stopPrank();
        assertEq(lens.getTokenState(bncToken).quoteToken, address(bncb));
        assertEq(lens.getTokenState(stockToken).quoteToken, address(stock));
        assertEq(lens.getTokenState(nativeToken).quoteToken, address(weth));
    }
}

contract StoxesBncLpVerificationTest is Test {
    MockERC20 token;
    MockERC20 bncb;
    MockWETH weth;
    MockNonfungiblePositionManager manager;
    StoxesBnbV3Locker locker;
    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA5);

    function setUp() public {
        token = new MockERC20("Community token", "MEME", 18);
        bncb = new MockERC20("CEA Industries bStock (local mock)", "BNCB", 18);
        weth = new MockWETH();
        manager = new MockNonfungiblePositionManager();
        MockSwapRouter02 router = new MockSwapRouter02();
        TokenLanePortal portal = new TokenLanePortal(address(weth));
        locker = new StoxesBnbV3Locker(
            address(portal),
            address(weth),
            address(manager),
            address(manager),
            address(router),
            treasury,
            address(this)
        );
        (address t0, address t1) =
            address(token) < address(bncb) ? (address(token), address(bncb)) : (address(bncb), address(token));
        address pool = manager.createAndInitializePoolIfNecessary(t0, t1, 10_000, uint160(1 << 96));
        MockV3Pool(pool).setPancakeCallback(true);
        MockV3Pool(pool).setLiquidity(1_000_000 ether);
        MockV3Pool(pool).setWokbOutPerTokenWad(1e18);
        token.mint(pool, 1_000_000 ether);
        bncb.mint(pool, 1_000_000 ether);
        token.mint(address(manager), 1_000_000 ether);
        bncb.mint(address(manager), 1_000_000 ether);
        (uint256 id,,,) = manager.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 10_000, -200, 200, 0, 0, 0, 0, address(locker), block.timestamp
            )
        );
        portal.registerLocker(locker, address(token), id, BnbFeeMode.Creator, 4000, creator, address(bncb));
        manager.setCollectable(id, 100 ether, 100 ether);
        vm.warp(block.timestamp + 1800);
        locker.setDispatchThreshold(type(uint256).max);
    }

    function testBncSimpleLpBothFeeSidesSettleInBncNotNativeAndAccrualIsNotPayout() public {
        locker.collect(address(token));
        StoxesBnbV3Locker.FeeRecord memory pending = locker.feeInfo(address(token));
        assertEq(pending.quote, address(bncb));
        assertEq(pending.creatorPending, 80 ether);
        assertEq(pending.treasuryPending, 120 ether);
        assertEq(bncb.balanceOf(creator), 0);
        assertEq(bncb.balanceOf(treasury), 0);
        vm.prank(address(0xCA11));
        locker.dispatch(address(token));
        assertEq(bncb.balanceOf(creator), 80 ether);
        assertEq(bncb.balanceOf(treasury), 120 ether);
        assertEq(weth.balanceOf(creator), 0);
        assertEq(weth.balanceOf(treasury), 0);
        assertEq(creator.balance, 0);
        assertEq(treasury.balance, 0);
        assertEq(locker.feeInfo(address(token)).totalDispatched, 200 ether);
        vm.expectRevert(StoxesBnbV3Locker.NothingPending.selector);
        locker.dispatch(address(token));
        assertEq(bncb.balanceOf(creator), 80 ether, "completed fees cannot pay twice");
    }
}
