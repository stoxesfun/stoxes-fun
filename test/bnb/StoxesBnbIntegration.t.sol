// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbGraduator} from "../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbPortal} from "../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbV3Locker} from "../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbFactory} from "../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbSimpleToken} from "../../src/bnb/StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {StoxesBnbLens} from "../../src/bnb/StoxesBnbLens.sol";
import {StoxesBnbBuybackBurnVault} from "../../src/bnb/vaults/StoxesBnbBuybackBurnVault.sol";
import {StoxesBnbBuybackBurnVaultFactory} from "../../src/bnb/vaults/StoxesBnbBuybackBurnVaultFactory.sol";
import {StoxesBnbSplitVaultFactory} from "../../src/bnb/vaults/StoxesBnbSplitVaultFactory.sol";
import {StoxesBnbGiftVault} from "../../src/bnb/vaults/StoxesBnbGiftVault.sol";
import {StoxesBnbGiftVaultFactory} from "../../src/bnb/vaults/StoxesBnbGiftVaultFactory.sol";
import {BnbCreateParams, BnbFeeMode, BnbLaunchKind, BnbTaxAllocation} from "../../src/bnb/IStoxesBnb.sol";
import {Clones} from "../../src/vendor/Clones.sol";
import {MockERC20, MockWETH, MockSwapV2Factory} from "../mocks/Mocks.sol";
import {MockSwapRouter02, MockV3Pool} from "../mocks/MocksV3.sol";
import {RealisticBnbV3PositionManager} from "./mocks/RealisticV3Mocks.sol";

contract StoxesBnbIntegrationTest is Test {
    uint256 constant R = 1 ether;
    uint256 constant K = 1_000_000_000 ether;
    uint256 constant GRAD = 4 ether;

    MockWETH weth;
    MockSwapV2Factory v2;
    RealisticBnbV3PositionManager nfpm;
    MockSwapRouter02 router;
    StoxesBnbGraduator graduator;
    StoxesBnbPortal portal;
    StoxesBnbV3Locker locker;
    StoxesBnbTaxProcessor processor;
    StoxesBnbFactory factory;
    StoxesBnbBuybackBurnVaultFactory buybackFactory;
    StoxesBnbSplitVaultFactory splitFactory;
    StoxesBnbGiftVaultFactory giftFactory;
    StoxesBnbLens lens;
    MockERC20 stock;
    address treasury = address(0x7001);
    uint256 signerKey = 0xA11CE;

    receive() external payable {}

    function _taxTokenImplementation() internal virtual returns (address) {
        return address(new StoxesBnbTaxToken());
    }

    function setUp() public virtual {
        weth = new MockWETH();
        v2 = new MockSwapV2Factory(25);
        nfpm = new RealisticBnbV3PositionManager();
        router = new MockSwapRouter02();
        processor = new StoxesBnbTaxProcessor(address(weth), treasury, 0, address(this));
        graduator = new StoxesBnbGraduator(address(weth), address(nfpm), treasury, address(this));
        portal = new StoxesBnbPortal(address(weth), treasury, address(graduator), address(this));
        locker = new StoxesBnbV3Locker(
            address(portal), address(weth), address(nfpm), address(nfpm), address(router), treasury, address(this)
        );
        factory = new StoxesBnbFactory(
            address(new StoxesBnbSimpleToken()),
            _taxTokenImplementation(),
            address(portal),
            address(weth),
            address(v2),
            address(processor),
            address(this)
        );
        buybackFactory = new StoxesBnbBuybackBurnVaultFactory(
            address(factory), address(this), address(portal), address(router), address(weth)
        );
        splitFactory = new StoxesBnbSplitVaultFactory(address(factory), address(this));
        giftFactory = new StoxesBnbGiftVaultFactory(address(factory), address(this), vm.addr(signerKey));
        lens = new StoxesBnbLens(address(portal));
        graduator.setPortal(address(portal));
        processor.setPortal(address(portal));
        portal.setLocker(address(locker));
        portal.setFactory(address(factory));
        portal.setQuoteParams(address(0), R, 0, K, GRAD, true);
        factory.setVaultFactoryAllowed(address(buybackFactory), true);
        factory.setVaultFactoryAllowed(address(splitFactory), true);
        factory.setVaultFactoryAllowed(address(giftFactory), true);
        stock = new MockERC20("bStock", "BST", 6);
        portal.setQuoteParams(address(stock), R, 0, K, 4_000_000, true);
        factory.setQuoteAllowed(address(stock), true);
    }

    function testRealSimpleAtomicBuyGraduatesAndLensTracksPhases() public {
        BnbCreateParams memory p = _simple(address(0), address(buybackFactory), "");
        p.creatorBuyQuoteAmount = 0.1 ether;
        vm.deal(address(this), 10 ether);
        (address token, address vault,,) = factory.createToken{value: 0.1 ether}(p);
        StoxesBnbLens.TokenState memory beforeState = lens.getTokenState(token);
        assertEq(uint256(beforeState.kind), uint256(BnbLaunchKind.Simple));
        assertEq(beforeState.phase, 0);
        assertEq(beforeState.vault, vault);

        weth.deposit{value: 0.01 ether}();
        weth.transfer(vault, 0.01 ether);
        vm.prank(address(0xBEEF), address(0xBEEF));
        StoxesBnbBuybackBurnVault(payable(vault)).execute();
        assertGt(StoxesBnbSimpleToken(token).balanceOf(address(0xdead)), 0);

        _fillNative(token, 1);
        StoxesBnbLens.TokenState memory afterState = lens.getTokenState(token);
        assertTrue(afterState.graduated);
        assertEq(afterState.phase, 2);
        assertTrue(afterState.market != address(0));
        assertGt(locker.feeInfo(token).tokenId, 0);
    }

    function testRegressionTaxGraduationWarmsCanonicalTwap() public {
        address[] memory recipients = new address[](2);
        recipients[0] = address(0xA1);
        recipients[1] = address(0xA2);
        uint16[] memory shares = new uint16[](2);
        shares[0] = 4000;
        shares[1] = 6000;
        BnbCreateParams memory p = _tax(address(0), address(splitFactory), abi.encode(recipients, shares));
        vm.deal(address(this), 10 ether);
        (address token, address vault,,) = factory.createToken(p);
        address buyer = address(0xB1);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer, buyer);
        portal.buy{value: 0.1 ether}(token, 0);
        assertGt(treasury.balance, 0);
        assertGt(portal.creatorBucket(token), 0);
        assertGt(StoxesBnbGiftVaultLike(vault).accountedQuote(), 0);
        (uint128 burn, uint128 liquidity) = portal.taxEscrow(token);
        assertGt(burn, 0);
        assertGt(liquidity, 0);

        _fillNative(token, 2);
        assertEq(uint256(StoxesBnbTaxToken(token).phase()), 2);
        assertEq(MockLpRecipient(StoxesBnbTaxToken(token).mainPool()).lpRecipient(), address(0xdead));
        address observationKey = address(
            uint160(uint256(keccak256(abi.encodePacked(token, true))))
        );
        (,, bool warmed) = processor.observationOf(observationKey);
        assertTrue(warmed);
    }

    function testRealSixDecimalGiftProofClaimAndLaunchGate() public {
        factory.setLaunchesOpen(false);
        BnbCreateParams memory p =
            _tax(address(stock), address(giftFactory), abi.encode(keccak256("lowercase")));
        address outsider = address(0xBAD);
        vm.prank(outsider);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);

        (address token, address vault,,) = factory.createToken(p);
        stock.mint(address(this), 100_000);
        stock.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(token, 50_000, 0);
        address recipient = address(0xCAFE);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = 7;
        bytes32 payload =
            keccak256(abi.encode(block.chainid, vault, keccak256("lowercase"), recipient, deadline, nonce));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload)));
        StoxesBnbGiftVault(payable(vault)).manageByProof(
            recipient, deadline, nonce, abi.encodePacked(r, s, v)
        );
        uint256 before = stock.balanceOf(recipient);
        StoxesBnbGiftVault(payable(vault)).claim();
        assertGt(stock.balanceOf(recipient), before);
        assertEq(lens.getTokenState(token).quoteToken, address(stock));
    }

    function testTaxBuyForCannotSeedCanonicalPairButStillPaysNormalRecipient() public {
        (address token,,,) = factory.createToken(
            _tax(address(stock), address(giftFactory), abi.encode(keccak256("gift")))
        );
        (,,,, address pair,,,,,) = portal.stateDetails(token);
        address buyer = address(0xBAD);
        stock.mint(buyer, 1_000_000);
        vm.startPrank(buyer, buyer);
        stock.approve(address(portal), type(uint256).max);
        vm.expectRevert(StoxesBnbPortal.InvalidParams.selector);
        portal.buyFor(token, pair, buyer, 50_000, 1);
        assertEq(stock.balanceOf(buyer), 1_000_000, "rejected before pulling quote");
        assertEq(StoxesBnbTaxToken(token).balanceOf(pair), 0);
        (uint256 bought,) = portal.buyFor(token, buyer, buyer, 50_000, 1);
        assertGt(bought, 0);
        assertEq(StoxesBnbTaxToken(token).balanceOf(buyer), bought);
        vm.stopPrank();
    }

    function testRegressionRealisticV3GraduatesWithSixDecimalQuote() public {
        BnbCreateParams memory p = _simple(address(stock), address(0), "");
        (address token,,,) = factory.createToken(p);
        for (uint256 i; i < 24; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) break;
            address buyer = address(uint160(0x5000 + i));
            stock.mint(buyer, 10_000_000);
            vm.startPrank(buyer, buyer);
            stock.approve(address(portal), type(uint256).max);
            portal.buyWithQuote(token, 10_000_000, 0);
            vm.stopPrank();
        }
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized);
        assertEq(StoxesBnbSimpleToken(token).phase(), 2);
        StoxesBnbV3Locker.FeeRecord memory feeRecord = locker.feeInfo(token);
        assertGt(feeRecord.tokenId, 0);
        assertGe(
            MockV3Pool(feeRecord.pool).observationCardinalityNext(), 200
        );
    }

    function testRegressionDeferredSimpleMigrationFreezesHolderAndPoolTransfers() public {
        (address token,,,) = factory.createToken(_simple(address(0), address(0), ""));
        address holder = address(0xA11CE);
        vm.deal(holder, 1 ether);
        vm.prank(holder, holder);
        portal.buy{value: 0.01 ether}(token, 0);

        (address token0, address token1) =
            token < address(weth) ? (token, address(weth)) : (address(weth), token);
        address pool =
            nfpm.createAndInitializePoolIfNecessary(token0, token1, 10_000, uint160(1 << 96));
        _fillNative(token, 0);
        assertEq(StoxesBnbSimpleToken(token).phase(), 1);

        vm.prank(holder);
        vm.expectRevert(StoxesBnbSimpleToken.TransferBlocked.selector);
        StoxesBnbSimpleToken(token).transfer(address(0xB0B), 1 ether);
        vm.prank(holder);
        vm.expectRevert(StoxesBnbSimpleToken.TransferBlocked.selector);
        StoxesBnbSimpleToken(token).transfer(pool, 1 ether);

        // The attacker can initialize the predictable pool but cannot add
        // useful liquidity. The Graduator's one-wei limit swap reprices this
        // empty pool without relying on a test-only slot0 mutation.
        portal.finalizeGraduation(token);
        assertEq(StoxesBnbSimpleToken(token).phase(), 2);
        vm.prank(holder);
        StoxesBnbSimpleToken(token).transfer(address(0xB0B), 1 ether);
    }

    function testHostileLiquidSimplePoolUsesBoundedCorrectiveSwap() public {
        (address token,,,) = factory.createToken(_simple(address(0), address(0), ""));
        (address token0, address token1) =
            token < address(weth) ? (token, address(weth)) : (address(weth), token);
        address pool =
            nfpm.createAndInitializePoolIfNecessary(token0, token1, 10_000, uint160(1 << 96));
        // This is attacker-provided liquidity at an out-of-band initialized
        // price. The mock moves to the swap limit rather than mutating slot0.
        MockV3Pool(pool).setLiquidity(1);
        MockV3Pool(pool).setPartialFillBps(10_000);
        _fillNative(token, 0);
        assertEq(StoxesBnbSimpleToken(token).phase(), 1);
        portal.finalizeGraduation(token);
        assertEq(StoxesBnbSimpleToken(token).phase(), 2);
    }

    function testFactoryRejectsPredictedTokenWithLiveCanonicalPool() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        bytes32 salt = keccak256(abi.encode(address(this), p.salt));
        address predicted = Clones.predictDeterministicAddress(
            factory.simpleTokenImplementation(), salt, address(factory)
        );
        (address token0, address token1) =
            predicted < address(weth) ? (predicted, address(weth)) : (address(weth), predicted);
        address pool =
            nfpm.createAndInitializePoolIfNecessary(token0, token1, 10_000, uint160(1 << 96));
        MockV3Pool(pool).setLiquidity(1);
        vm.expectRevert(StoxesBnbFactory.PoolPreexists.selector);
        factory.createToken(p);
    }

    function testFactoryRejectsPredictedPoolHoldingEitherAssetWithoutActiveLiquidity() public {
        BnbCreateParams memory p = _simple(address(0), address(0), "");
        p.salt = keccak256("funded-empty-pool");
        bytes32 salt = keccak256(abi.encode(address(this), p.salt));
        address predicted = Clones.predictDeterministicAddress(
            factory.simpleTokenImplementation(), salt, address(factory)
        );
        (address token0, address token1) =
            predicted < address(weth) ? (predicted, address(weth)) : (address(weth), predicted);
        address pool =
            nfpm.createAndInitializePoolIfNecessary(token0, token1, 10_000, uint160(1 << 96));
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1}();
        weth.transfer(pool, 1);
        assertEq(MockV3Pool(pool).liquidity(), 0);
        vm.expectRevert(StoxesBnbFactory.PoolPreexists.selector);
        factory.createToken(p);
    }

    function _fillNative(address token, uint256 first) internal {
        for (uint256 i = first; i < 24; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) return;
            address buyer = address(uint160(0x1000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer, buyer);
            portal.buy{value: 1 ether}(token, 0);
        }
        (,, bool done,,,) = portal.tokenState(token);
        assertTrue(done);
    }

    function _simple(address quote, address vf, bytes memory data)
        internal
        pure
        returns (BnbCreateParams memory p)
    {
        p.version = 1;
        p.kind = BnbLaunchKind.Simple;
        p.name = "Simple";
        p.symbol = "SIM";
        p.quoteToken = quote;
        p.feeMode = BnbFeeMode.Creator;
        p.creatorFeeShareBps = 2500;
        p.vaultFactory = vf;
        p.vaultData = data;
        p.salt = keccak256("simple");
    }

    function _tax(address quote, address vf, bytes memory data)
        internal
        pure
        returns (BnbCreateParams memory p)
    {
        p.version = 1;
        p.kind = BnbLaunchKind.Tax;
        p.name = "Tax";
        p.symbol = "TAX";
        p.quoteToken = quote;
        p.buyTaxBps = 500;
        p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(2500, 2500, 2500, 2500);
        p.feeMode = BnbFeeMode.Creator;
        p.vaultFactory = vf;
        p.vaultData = data;
        p.salt = keccak256(abi.encode(quote, vf));
    }
}

interface StoxesBnbGiftVaultLike {
    function accountedQuote() external view returns (uint256);
}

interface MockLpRecipient {
    function lpRecipient() external view returns (address);
}
