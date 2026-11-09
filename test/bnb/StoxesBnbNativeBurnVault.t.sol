// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbNativeBurnVault as Vault} from "../../src/bnb/vaults/StoxesBnbNativeBurnVault.sol";
import {StoxesBnbNativeBurnVaultFactory as Factory} from "../../src/bnb/vaults/StoxesBnbNativeBurnVaultFactory.sol";
import {BnbCreateParams, BnbLaunchKind} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {MockV3Pool} from "../mocks/MocksV3.sol";
import {StocksV3Factory} from "./StoxesBnbStocksVault.t.sol";
import {TickMath} from "../../src/vendor/TickMath.sol";

contract BurnLauncherStub {
    address public immutable WBNB;
    constructor(address wrapped) { WBNB = wrapped; }
    function create(Factory f, address token, address quote) external returns (Vault) {
        return Vault(payable(f.newVault(token, quote, msg.sender, "")));
    }
}

contract BurnReentrantStock is MockERC20 {
    address public target;
    constructor() MockERC20("Hook", "H", 18) {}
    function setTarget(address v) external { target = v; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (target != address(0)) {
            (bool ok,) = target.call(abi.encodeWithSignature("ping()"));
            require(!ok, "reentrant ping");
            (ok,) = target.call(abi.encodeWithSignature("convertAndBurn()"));
            require(!ok, "reentrant conversion");
        }
        return super.transfer(to, amount);
    }
}

contract StoxesBnbNativeBurnVaultTest is Test {
    MockERC20 token;
    BurnReentrantStock stock;
    MockWETH wrapped;
    MockERC20 bridge;
    StocksV3Factory v3;
    MockV3Pool direct;
    MockV3Pool first;
    MockV3Pool second;
    BurnLauncherStub launcher;
    Factory factory;
    Vault nativeVault;
    Vault stockVault;
    address constant DEAD = address(0xdead);

    function testRouteSetupUsesBoundedOracleCapacityWithoutWeakeningWindow() public {
        assertEq(factory.ORACLE_CARDINALITY(), 200);
        assertEq(stockVault.TWAP_WINDOW(), 1800);
        vm.expectCall(address(direct), abi.encodeWithSignature("increaseObservationCardinalityNext(uint16)", uint16(200)));
        factory.setQuoteRoute(address(stock), address(direct), address(0), 1 ether);
    }

    function setUp() public {
        vm.warp(10000);
        token = new MockERC20("Token", "T", 18);
        stock = new BurnReentrantStock();
        wrapped = new MockWETH();
        bridge = new MockERC20("Bridge", "B", 18);
        v3 = new StocksV3Factory();
        direct = _pool(address(stock), address(wrapped));
        first = _pool(address(stock), address(bridge));
        second = _pool(address(bridge), address(wrapped));
        launcher = new BurnLauncherStub(address(wrapped));
        factory = new Factory(address(launcher), address(this), address(v3), address(bridge));
        factory.setQuoteRoute(address(stock), address(direct), address(0), 1 ether);
        nativeVault = launcher.create(factory, address(token), address(wrapped));
        stockVault = launcher.create(factory, address(token), address(stock));
        wrapped.mint(address(direct), 100 ether);
        wrapped.mint(address(second), 100 ether);
        bridge.mint(address(first), 100 ether);
        vm.deal(address(wrapped), 1000 ether);
        vm.warp(block.timestamp + 1800);
    }

    function _pool(address a, address b) private returns (MockV3Pool p) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        p = new MockV3Pool(t0, t1, 500, TickMath.getSqrtRatioAtTick(0), 0);
        p.setPancakeCallback(true);
        p.setLiquidity(1e18);
        p.setWokbOutPerTokenWad(1e18);
        v3.setPool(a, b, 500, address(p));
    }

    function testNativeBurnsOnPingWithoutAnotherTransaction() public {
        uint256 before = DEAD.balance;
        wrapped.mint(address(nativeVault), 2 ether);
        nativeVault.ping();
        assertEq(DEAD.balance - before, 2 ether);
        assertEq(nativeVault.totalBnbBurned(), 2 ether);
        assertEq(nativeVault.accountedQuote(), 0);
        assertEq(wrapped.balanceOf(address(nativeVault)), 0);
        assertEq(wrapped.balanceOf(DEAD), 0);
        nativeVault.ping();
        assertEq(nativeVault.totalBnbBurned(), 2 ether);
    }
    function testFuzzNativeAccounting(uint96 raw) public {
        uint256 amount = bound(raw, 1, 100 ether);
        uint256 before = DEAD.balance;
        wrapped.mint(address(nativeVault), amount);
        nativeVault.ping();
        assertEq(nativeVault.totalBnbBurned(), amount);
        assertEq(DEAD.balance - before, amount);
        assertEq(address(nativeVault).balance, 0);
    }
    function testStockFundingDoesNotSwapOrBlockTrade() public {
        direct.setFailSwap(true);
        stock.mint(address(stockVault), 4 ether);
        stockVault.ping();
        assertEq(stockVault.accountedQuote(), 4 ether);
        assertEq(stockVault.totalBnbBurned(), 0);
    }
    function testStockClipBurnsImmediatelyAfterConversion() public {
        stock.mint(address(stockVault), 4 ether);
        uint256 before = DEAD.balance;
        (uint256 spent, uint256 burned) = stockVault.convertAndBurn();
        assertEq(spent, 1 ether);
        assertEq(burned, 1 ether);
        assertEq(DEAD.balance - before, burned);
        assertEq(stockVault.accountedQuote(), 3 ether);
        assertEq(address(stockVault).balance, 0);
        assertEq(wrapped.balanceOf(address(stockVault)), 0);
    }
    function testTwoHopConversionPreservesUnrelatedBalances() public {
        factory.setQuoteRoute(address(stock), address(first), address(second), 2 ether);
        Vault two = launcher.create(factory, address(token), address(stock));
        stock.mint(address(two), 3 ether);
        bridge.mint(address(two), 17 ether);
        wrapped.mint(address(two), 9 ether);
        uint256 before = DEAD.balance;
        two.convertAndBurn();
        assertEq(DEAD.balance - before, 2 ether);
        assertEq(bridge.balanceOf(address(two)), 17 ether);
        assertEq(wrapped.balanceOf(address(two)), 9 ether);
        assertEq(two.accountedQuote(), 1 ether);
    }
    function testRouteChangesDoNotAlterExistingVault() public {
        factory.setQuoteRoute(address(stock), address(first), address(second), 2 ether);
        assertEq(stockVault.pool0(), address(direct));
        assertEq(stockVault.pool1(), address(0));
        factory.setQuoteRoute(address(stock), address(0), address(0), 0);
        assertFalse(factory.supportsQuote(address(stock)));
        stock.mint(address(stockVault), 1 ether);
        stockVault.convertAndBurn();
        assertEq(stockVault.totalBnbBurned(), 1 ether);
    }
    function testConversionFailureRetainsFundsAndRetryWorks() public {
        stock.mint(address(stockVault), 3 ether);
        stockVault.ping();
        direct.setTwapUsable(false);
        vm.expectRevert(Vault.OracleNotReady.selector);
        stockVault.convertAndBurn();
        assertEq(stockVault.accountedQuote(), 3 ether);
        assertEq(stock.balanceOf(address(stockVault)), 3 ether);
        direct.setTwapUsable(true);
        stockVault.convertAndBurn();
        assertEq(stockVault.accountedQuote(), 2 ether);
        assertEq(stockVault.totalBnbBurned(), 1 ether);
    }
    function testPartialFillRevertsAtomically() public {
        stock.mint(address(stockVault), 1 ether);
        stockVault.ping();
        direct.setPartialFillBps(5000);
        vm.expectRevert(Vault.IncompleteFill.selector);
        stockVault.convertAndBurn();
        assertEq(stock.balanceOf(address(stockVault)), 1 ether);
        assertEq(stockVault.accountedQuote(), 1 ether);
        assertEq(stockVault.totalBnbBurned(), 0);
    }
    function testUnauthenticatedCallbackCannotSpend() public {
        stock.mint(address(stockVault), 1 ether);
        vm.expectRevert(Vault.InvalidRoute.selector);
        stockVault.pancakeV3SwapCallback(1, -1, "");
        assertEq(stock.balanceOf(address(stockVault)), 1 ether);
    }
    function testTransferReentrancyIsBlocked() public {
        stock.mint(address(stockVault), 1 ether);
        stock.setTarget(address(stockVault));
        stockVault.convertAndBurn();
        assertEq(stockVault.totalBnbBurned(), 1 ether);
    }
    function testInvalidRoutesRejected() public {
        vm.expectRevert();
        factory.setQuoteRoute(address(stock), address(first), address(0), 1 ether);
        vm.expectRevert();
        factory.setQuoteRoute(address(stock), address(direct), address(0), 0);
        vm.prank(address(99));
        vm.expectRevert();
        factory.setQuoteRoute(address(stock), address(direct), address(0), 1 ether);
    }
    function testNoVaultCreationOutsideUnchangedTokenFactory() public {
        vm.expectRevert();
        factory.newVault(address(token), address(wrapped), address(this), "");
    }
    function testTaxOnlyPositiveVaultAllocationAndEmptyData() public {
        BnbCreateParams memory p;
        p.kind = BnbLaunchKind.Tax;
        p.allocation.vaultBps = 5000;
        factory.onBeforeLaunch(p, address(this));
        p.kind = BnbLaunchKind.Simple;
        vm.expectRevert(); factory.onBeforeLaunch(p, address(this));
        p.kind = BnbLaunchKind.Tax; p.allocation.vaultBps = 0;
        vm.expectRevert(); factory.onBeforeLaunch(p, address(this));
        p.allocation.vaultBps = 10000; p.vaultData = hex"00";
        vm.expectRevert(); factory.onBeforeLaunch(p, address(this));
    }
    function testForcedNativeDonationNotCreditedAsBurn() public {
        vm.deal(address(nativeVault), 7 ether);
        nativeVault.ping();
        assertEq(nativeVault.totalBnbBurned(), 0);
        assertEq(address(nativeVault).balance, 7 ether);
    }
    function testPriceOutsideLimitRetainsStock() public {
        stock.mint(address(stockVault), 1 ether);
        stockVault.ping();
        int24 tick = address(stock) < address(wrapped) ? int24(-500) : int24(500);
        direct.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(tick));
        vm.expectRevert(Vault.ImpactTooHigh.selector);
        stockVault.convertAndBurn();
        assertEq(stockVault.accountedQuote(), 1 ether);
    }
}
