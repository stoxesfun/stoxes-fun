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
import {StoxesBnbFloorReserveVault} from "../../src/bnb/vaults/StoxesBnbFloorReserveVault.sol";
import {StoxesBnbFloorReserveVaultFactory} from "../../src/bnb/vaults/StoxesBnbFloorReserveVaultFactory.sol";
import {
    BnbCreateParams,
    BnbFeeMode,
    BnbLaunchKind,
    BnbTaxAllocation,
    IStoxesBnbTaxToken
} from "../../src/bnb/IStoxesBnb.sol";
import {Clones} from "../../src/vendor/Clones.sol";
import {MockERC20, MockWETH, MockSwapPairMintable, MockSwapV2Factory} from "../mocks/Mocks.sol";
import {MockSwapRouter02} from "../mocks/MocksV3.sol";
import {RealisticBnbV3PositionManager} from "./mocks/RealisticV3Mocks.sol";

contract FloorReentrantReceiver {
    StoxesBnbFloorReserveVault public vault;
    StoxesBnbTaxToken public token;
    bool public reentryBlocked;
    bool private attacking;

    function configure(address vault_, address token_) external {
        vault = StoxesBnbFloorReserveVault(payable(vault_));
        token = StoxesBnbTaxToken(token_);
    }

    function approveAndRedeem(uint256 amount) external {
        token.approve(address(vault), amount);
        attacking = true;
        vault.redeem(amount, 0);
        attacking = false;
    }

    receive() external payable {
        if (attacking) {
            try vault.redeem(1, 0) {
                revert("reentry succeeded");
            } catch {
                reentryBlocked = true;
            }
        }
    }
}

contract StoxesBnbFloorReserveTest is Test {
    uint256 private constant R = 1 ether;
    uint256 private constant K = 1_000_000_000 ether;
    uint256 private constant GRAD = 4 ether;

    MockWETH weth;
    MockERC20 stock;
    MockSwapV2Factory v2;
    RealisticBnbV3PositionManager nfpm;
    StoxesBnbGraduator graduator;
    StoxesBnbPortal portal;
    StoxesBnbTaxProcessor processor;
    StoxesBnbFactory factory;
    StoxesBnbFloorReserveVaultFactory floorFactory;
    address treasury = address(0x7001);
    uint256 saltNonce;

    receive() external payable {}

    function _taxTokenImplementation() internal virtual returns (address) {
        return address(new StoxesBnbTaxToken());
    }

    function setUp() public {
        weth = new MockWETH();
        stock = new MockERC20("bStock", "BST", 6);
        v2 = new MockSwapV2Factory(25);
        nfpm = new RealisticBnbV3PositionManager();
        processor = new StoxesBnbTaxProcessor(address(weth), treasury, 0, address(this));
        graduator = new StoxesBnbGraduator(address(weth), address(nfpm), treasury, address(this));
        portal = new StoxesBnbPortal(address(weth), treasury, address(graduator), address(this));
        StoxesBnbV3Locker locker = new StoxesBnbV3Locker(
            address(portal),
            address(weth),
            address(nfpm),
            address(nfpm),
            address(new MockSwapRouter02()),
            treasury,
            address(this)
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
        floorFactory = new StoxesBnbFloorReserveVaultFactory(address(factory), address(this), address(portal));
        graduator.setPortal(address(portal));
        processor.setPortal(address(portal));
        portal.setLocker(address(locker));
        portal.setFactory(address(factory));
        portal.setQuoteParams(address(0), R, 0, K, GRAD, true);
        portal.setQuoteParams(address(stock), R, 0, K, 4_000_000, true);
        factory.setQuoteAllowed(address(stock), true);
        factory.setVaultFactoryAllowed(address(floorFactory), true);
    }

    function testOnBeforeLaunchRejections() public {
        BnbCreateParams memory p = _params(address(0));
        p.kind = BnbLaunchKind.Simple;
        vm.expectRevert();
        floorFactory.onBeforeLaunch(p, address(this));
        p.kind = BnbLaunchKind.Tax;
        p.allocation = BnbTaxAllocation(1999, 0, 0, 8001);
        vm.expectRevert();
        floorFactory.onBeforeLaunch(p, address(this));
        p.allocation = BnbTaxAllocation(2000, 0, 0, 8000);
        p.vaultData = abi.encode(uint16(1));
        vm.expectRevert();
        floorFactory.onBeforeLaunch(p, address(this));
    }

    function testFloorNeverFallsFromARedemptionAndNoSellTax() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(0));
        address holder = address(0xA11CE);
        _nativeBuy(address(token), holder, 0.2 ether);
        uint256 reserveBefore = vault.reserve();
        uint256 pendingBefore = token.pendingTax();
        uint256 amount = token.balanceOf(holder) / 3;
        uint256 quoted = vault.quoteRedeem(amount);
        uint256 floorBefore = vault.floorPrice();
        vm.startPrank(holder);
        token.approve(address(vault), type(uint256).max);
        vault.redeem(amount, quoted);
        vm.stopPrank();
        assertEq(reserveBefore - vault.reserve(), quoted);
        assertEq(token.pendingTax(), pendingBefore);
        assertGe(vault.floorPrice(), floorBefore);

        uint256 remainder = token.balanceOf(holder);
        uint256 holderBefore = holder.balance;
        vm.prank(holder);
        uint256 finalOut = vault.redeem(remainder, 0);
        assertEq(vault.reserve(), 0);
        assertEq(vault.circulatingSupply(), 0);
        assertEq(holder.balance - holderBefore, finalOut);
    }

    function testSixDecimalStockPayoutAndSlippage() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(stock));
        address holder = address(0xB0B);
        stock.mint(holder, 500_000);
        vm.startPrank(holder, holder);
        stock.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(address(token), 500_000, 0);
        token.approve(address(vault), type(uint256).max);
        uint256 amount = token.balanceOf(holder) / 2;
        uint256 quote = vault.quoteRedeem(amount);
        vm.expectRevert(StoxesBnbFloorReserveVault.SlippageExceeded.selector);
        vault.redeem(amount, quote + 1);
        uint256 before = stock.balanceOf(holder);
        vault.redeem(amount, quote);
        vm.stopPrank();
        assertEq(stock.balanceOf(holder) - before, quote);
        assertEq(vault.reserve(), stock.balanceOf(address(vault)));
    }

    function testReserveTracksCurveBuySellAndDonation() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(0));
        address holder = address(0xCAFE);
        _nativeBuy(address(token), holder, 0.1 ether);
        uint256 afterBuy = vault.reserve();
        assertGt(afterBuy, 0);
        vm.startPrank(holder);
        token.approve(address(portal), type(uint256).max);
        portal.sell(address(token), token.balanceOf(holder) / 4, 0);
        vm.stopPrank();
        assertGt(vault.reserve(), afterBuy);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 17}();
        weth.transfer(address(vault), 17);
        vault.ping();
        assertEq(vault.reserve(), weth.balanceOf(address(vault)));
    }

    function testPostGraduationProcessorRoutesQuoteIntoReserve() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(0));
        address holder = address(0x5151);
        _nativeBuy(address(token), holder, 0.1 ether);
        _fillNative(address(token));
        _sellOnMarket(token, holder, 5_000_000 ether);
        uint256 before = vault.reserve();
        vm.warp(block.timestamp + 1801);
        processor.process(address(token));
        assertGt(vault.reserve(), before);
        assertEq(vault.reserve(), weth.balanceOf(address(vault)));
    }

    function _sellOnMarket(StoxesBnbTaxToken token, address holder, uint256 sellAmount) private {
        MockSwapPairMintable market = MockSwapPairMintable(token.mainPool());
        (uint112 reserve0, uint112 reserve1,) = market.getReserves();
        bool tokenIs0 = market.token0() == address(token);
        uint256 reserveToken = tokenIs0 ? reserve0 : reserve1;
        uint256 reserveQuote = tokenIs0 ? reserve1 : reserve0;
        uint256 received = sellAmount * (10_000 - token.sellTaxBps()) / 10_000;
        uint256 withFee = received * (10_000 - 25);
        uint256 quoteOut = withFee * reserveQuote / (reserveToken * 10_000 + withFee);
        vm.prank(holder);
        token.transfer(address(market), sellAmount);
        market.swap(tokenIs0 ? 0 : quoteOut, tokenIs0 ? quoteOut : 0, holder, "");
    }

    function testCirculatingSupplyBondingAndFinalized() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(0));
        address holder = address(0xD00D);
        _nativeBuy(address(token), holder, 0.1 ether);
        assertEq(vault.circulatingSupply(), token.totalSupply() - token.balanceOf(address(portal)));
        _fillNative(address(token));
        assertEq(uint256(token.phase()), uint256(IStoxesBnbTaxToken.Phase.TaxEnforced));
        uint256 expected =
            token.totalSupply() - token.balanceOf(address(0xdead)) - token.balanceOf(address(token));
        assertEq(vault.circulatingSupply(), expected);
    }

    function testRedeemWorksDuringDeferredMigration() public {
        BnbCreateParams memory p = _params(address(0));
        bytes32 effectiveSalt = keccak256(abi.encode(address(this), p.salt));
        address predicted = Clones.predictDeterministicAddress(
            factory.taxTokenImplementation(), effectiveSalt, address(factory)
        );
        address pair = v2.createPair(predicted, address(weth));
        (address tokenAddress, address vaultAddress,,) = factory.createToken(p);
        StoxesBnbTaxToken token = StoxesBnbTaxToken(tokenAddress);
        StoxesBnbFloorReserveVault vault = StoxesBnbFloorReserveVault(payable(vaultAddress));

        address holder = address(0xABCD);
        _nativeBuy(tokenAddress, holder, 0.1 ether);
        vm.deal(address(this), 1 ether);
        // Synthetic unsupported pair state for the redemption/custody test.
        // Public buyFor can no longer be used to seed the canonical pool.
        vm.prank(address(portal));
        token.transfer(pair, 1 ether);
        weth.deposit{value: 0.5 ether}();
        weth.transfer(pair, 0.5 ether);
        MockSwapPairMintable(pair).sync();
        _fillNative(tokenAddress);
        assertEq(uint256(token.phase()), uint256(IStoxesBnbTaxToken.Phase.Migrating));
        assertEq(
            vault.circulatingSupply(),
            token.totalSupply() - token.balanceOf(address(0xdead)) - token.balanceOf(tokenAddress)
                - token.balanceOf(address(graduator))
        );
        vm.startPrank(holder);
        token.approve(address(vault), type(uint256).max);
        vault.redeem(token.balanceOf(holder) / 2, 0);
        vm.stopPrank();
    }

    function testNativeReceiverReentryIsBlocked() public {
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(0));
        FloorReentrantReceiver receiver = new FloorReentrantReceiver();
        receiver.configure(address(vault), address(token));
        vm.deal(address(this), 1 ether);
        portal.buyFor{value: 0.1 ether}(address(token), address(receiver), address(this), 0.1 ether, 0);
        receiver.approveAndRedeem(token.balanceOf(address(receiver)) / 2);
        assertTrue(receiver.reentryBlocked());
    }

    function testFuzzRedemptionRoundingNeverOverpays(uint8 piecesSeed) public {
        uint256 pieces = bound(uint256(piecesSeed), 2, 30);
        (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault) = _launch(address(stock));
        address holder = address(0xF00D);
        stock.mint(holder, 1_000_000);
        vm.startPrank(holder, holder);
        stock.approve(address(portal), type(uint256).max);
        portal.buyWithQuote(address(token), 1_000_000, 0);
        token.approve(address(vault), type(uint256).max);
        uint256 initialReserve = vault.reserve();
        uint256 initialBalance = token.balanceOf(holder);
        uint256 chunk = initialBalance / pieces;
        uint256 paid;
        for (uint256 i; i + 1 < pieces; ++i) {
            paid += vault.redeem(chunk, 0);
        }
        paid += vault.redeem(token.balanceOf(holder), 0);
        vm.stopPrank();
        assertLe(paid, initialReserve);
        assertEq(vault.reserve(), initialReserve - paid);
    }

    function _launch(address quote)
        private
        returns (StoxesBnbTaxToken token, StoxesBnbFloorReserveVault vault)
    {
        (address tokenAddress, address vaultAddress,,) = factory.createToken(_params(quote));
        token = StoxesBnbTaxToken(tokenAddress);
        vault = StoxesBnbFloorReserveVault(payable(vaultAddress));
    }

    function _params(address quote) private returns (BnbCreateParams memory p) {
        p.version = 1;
        p.kind = BnbLaunchKind.Tax;
        p.name = "Floor";
        p.symbol = "FLR";
        p.quoteToken = quote;
        p.buyTaxBps = 500;
        p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(10_000, 0, 0, 0);
        p.feeMode = BnbFeeMode.Creator;
        p.vaultFactory = address(floorFactory);
        p.vaultData = abi.encode(uint16(0));
        p.salt = keccak256(abi.encode(++saltNonce, quote));
    }

    function _nativeBuy(address token, address buyer, uint256 amount) private {
        vm.deal(buyer, amount);
        vm.prank(buyer, buyer);
        portal.buy{value: amount}(token, 0);
    }

    function _fillNative(address token) private {
        for (uint256 i; i < 24; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) return;
            address buyer = address(uint160(0x9000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer, buyer);
            portal.buy{value: 1 ether}(token, 0);
        }
        (,, bool done,,,) = portal.tokenState(token);
        assertTrue(done);
    }
}
