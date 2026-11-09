// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbRoutedStocksVault as Vault} from "../../src/bnb/vaults/StoxesBnbRoutedStocksVault.sol";
import {StoxesBnbRoutedStocksVaultFactory as Factory} from "../../src/bnb/vaults/StoxesBnbRoutedStocksVaultFactory.sol";
import {BnbCreateParams, BnbLaunchKind} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {MockV3Pool} from "../mocks/MocksV3.sol";
import {StocksHookToken, SelectiveStock, StocksV3Factory} from "./StoxesBnbStocksVault.t.sol";
import {TickMath} from "../../src/vendor/TickMath.sol";

contract RoutedTokenFactoryStub {
    address public immutable WBNB;
    constructor(address wrapped) { WBNB = wrapped; }
    function portal() external view returns (address) { return address(this); }
    function v2Factory() external view returns (address) { return address(this); }
    function taxProcessor() external pure returns (address) { return address(7); }
    function graduator() external pure returns (address) { return address(8); }
    function locker() external pure returns (address) { return address(9); }
    function getPair(address, address) external pure returns (address) { return address(10); }
    function create(Factory f, address token, address quote, address stock, uint256 minimum) external returns (Vault) {
        return Vault(payable(f.newVault(token, quote, msg.sender, abi.encode(stock, minimum))));
    }
}

contract RoutedReentrantToken is MockERC20 {
    address public target;
    uint256 public attempts;
    constructor() MockERC20("Reentrant", "RE", 18) {}
    function setTarget(address v) external { target = v; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (target != address(0)) {
            ++attempts;
            (bool convertOk,) = target.call(abi.encodeWithSignature("convert()"));
            (bool pingOk,) = target.call(abi.encodeWithSignature("ping()"));
            (bool callbackOk,) = target.call(abi.encodeWithSignature("pancakeV3SwapCallback(int256,int256,bytes)", int256(1), int256(-1), bytes("")));
            require(!convertOk && !pingOk && !callbackOk, "reentrancy accepted");
        }
        return super.transfer(to, amount);
    }
}

contract RoutedCallbackAttackPool {
    address immutable template;
    uint256 public mode;
    constructor(address p) { template = p; }
    function setMode(uint256 m) external { mode = m; }
    fallback() external {
        (bool ok, bytes memory result) = template.staticcall(msg.data);
        require(ok);
        assembly { return(add(result, 32), mload(result)) }
    }
    function swap(address, bool zeroForOne, int256 amount, uint160, bytes calldata) external returns (int256, int256) {
        Vault target = Vault(payable(msg.sender));
        if (mode == 0) target.pancakeV3SwapCallback(amount, amount, "");
        else if (mode == 1) target.pancakeV3SwapCallback(zeroForOne ? -amount : amount, zeroForOne ? amount : -amount, "");
        else if (mode == 2) target.pancakeV3SwapCallback(zeroForOne ? amount + 1 : int256(-1), zeroForOne ? int256(-1) : amount + 1, "");
        else {
            target.pancakeV3SwapCallback(zeroForOne ? amount : int256(-1), zeroForOne ? int256(-1) : amount, "");
            target.pancakeV3SwapCallback(zeroForOne ? int256(1) : int256(-1), zeroForOne ? int256(-1) : int256(1), "");
        }
        return (0, 0);
    }
}

contract StoxesBnbRoutedStocksVaultTest is Test {
    StocksHookToken token;
    SelectiveStock stock;
    MockWETH wrapped;
    MockERC20 usdt;
    StocksV3Factory v3;
    MockV3Pool first;
    MockV3Pool second;
    MockV3Pool direct;
    RoutedTokenFactoryStub launcher;
    Factory factory;
    Vault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(10_000);
        token = new StocksHookToken();
        stock = new SelectiveStock(18);
        wrapped = new MockWETH();
        usdt = new MockERC20("USDT", "USDT", 18);
        v3 = new StocksV3Factory();
        first = _pool(address(wrapped), address(usdt), 500);
        second = _pool(address(usdt), address(stock), 2500);
        direct = _pool(address(wrapped), address(stock), 100);
        launcher = new RoutedTokenFactoryStub(address(wrapped));
        factory = new Factory(address(launcher), address(this), address(v3), address(usdt));
        factory.setDividendStockAllowed(address(stock), true);
        factory.setDividendRoute(address(stock), address(first), address(second), 1 ether);
        vault = launcher.create(factory, address(token), address(0), address(stock), 100 ether);
        token.setHook(address(vault));
        token.mint(alice, 300 ether); token.mint(bob, 200 ether);
        token.notify(address(0), alice); token.notify(address(0), bob);
        wrapped.mint(address(vault), 4 ether);
        usdt.mint(address(first), 100 ether);
        stock.mint(address(second), 100 ether);
        stock.mint(address(direct), 100 ether);
        vm.warp(block.timestamp + 1800);
    }
    function _pool(address a, address b, uint24 fee) private returns (MockV3Pool p) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        p = new MockV3Pool(t0, t1, fee, TickMath.getSqrtRatioAtTick(0), 0);
        p.setPancakeCallback(true); p.setLiquidity(1e18); p.setWokbOutPerTokenWad(1e18);
        v3.setPool(a, b, fee, address(p));
    }
    function _params(address quote) private view returns (BnbCreateParams memory p) {
        p.kind = BnbLaunchKind.Tax; p.quoteToken = quote;
        p.vaultData = abi.encode(address(stock), 100 ether);
    }
    function testTwoHopClipDividendsAndIntermediateDonationUntouched() public {
        usdt.mint(address(vault), 77 ether);
        (uint256 spent, uint256 received) = vault.convert();
        assertEq(spent, 1 ether); assertEq(received, 1 ether);
        assertEq(vault.accountedQuote(), 3 ether);
        assertEq(usdt.balanceOf(address(vault)), 77 ether);
        assertLe(vault.withdrawableOf(alice) + vault.withdrawableOf(bob), received);
        uint256 due = vault.withdrawableOf(alice);
        vm.prank(alice); vault.claim();
        assertEq(stock.balanceOf(alice), due);
    }
    function testDirectRouteAndImmutableSnapshots() public {
        factory.setDividendRoute(address(stock), address(direct), address(0), 2 ether);
        Vault fresh = launcher.create(factory, address(token), address(wrapped), address(stock), 0);
        wrapped.mint(address(fresh), 5 ether);
        (uint256 spent, uint256 received) = fresh.convert();
        assertEq(spent, 2 ether); assertEq(received, 2 ether);
        assertEq(fresh.unaccountedStock(), 2 ether);
        assertEq(vault.pool0(), address(first)); assertEq(vault.pool1(), address(second));
        assertEq(vault.maxAmountIn(), 1 ether);
        factory.setDividendRoute(address(stock), address(0), address(0), 0);
        vault.convert();
        vm.expectRevert(); launcher.create(factory, address(token), address(0), address(stock), 0);
    }
    function testSameAssetNoRouteNoSwapAndCarry() public {
        factory.setDividendRoute(address(stock), address(0), address(0), 0);
        Vault same = launcher.create(factory, address(token), address(stock), address(stock), 0);
        assertEq(same.pool0(), address(0));
        stock.mint(address(same), 1 ether); same.convert();
        assertEq(same.unaccountedStock(), 1 ether);
        token.setHook(address(same)); token.notify(address(0), alice); same.convert();
        uint256 due = same.withdrawableOf(alice); assertGt(due, 0);
        vm.prank(alice); same.claim(); same.ping();
        assertEq(same.withdrawableOf(alice), 0); assertEq(stock.balanceOf(alice), due);
    }
    function testStockPairedCannotSelectAnotherStockBothEntrypoints() public {
        BnbCreateParams memory p = _params(address(usdt));
        vm.expectRevert(); factory.onBeforeLaunch(p, alice);
        vm.expectRevert(); launcher.create(factory, address(token), address(usdt), address(stock), 0);
        p.quoteToken = address(stock); factory.onBeforeLaunch(p, alice);
        p.quoteToken = address(0); factory.onBeforeLaunch(p, alice);
        p.quoteToken = address(wrapped); factory.onBeforeLaunch(p, alice);
    }
    function testSameAssetConstructorCannotAcceptRoute() public {
        Vault.RouteConfig memory r = Vault.RouteConfig(address(v3), address(usdt), address(first), address(second), 1 ether);
        vm.expectRevert();
        new Vault(address(token), address(stock), alice, address(wrapped), address(stock), 0, r, new address[](0));
    }
    function testRejectInvalidRouteAndUnauthorizedConfiguration() public {
        vm.prank(alice); vm.expectRevert();
        factory.setDividendRoute(address(stock), address(direct), address(0), 1);
        vm.prank(alice); vm.expectRevert();
        factory.setDividendStockAllowed(address(stock), false);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(second), address(first), 1);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(first), address(0), 1);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(direct), address(0), 0);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(direct), address(0), uint256(type(int256).max) + 1);
        MockV3Pool fake = new MockV3Pool(direct.token0(), direct.token1(), 100, TickMath.getSqrtRatioAtTick(0), 0);
        fake.setLiquidity(1);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(fake), address(0), 1);
        direct.setLiquidity(0);
        vm.expectRevert(); factory.setDividendRoute(address(stock), address(direct), address(0), 1);
    }
    function testBothEntrypointsRejectDisabledStockAndExcessiveMinimum() public {
        factory.setDividendStockAllowed(address(stock), false);
        BnbCreateParams memory p = _params(address(stock));
        vm.expectRevert(); factory.onBeforeLaunch(p, alice);
        vm.expectRevert(); launcher.create(factory, address(token), address(stock), address(stock), 0);
        factory.setDividendStockAllowed(address(stock), true);
        vm.expectRevert(); launcher.create(factory, address(token), address(stock), address(stock), 10_000_001 ether);
        p.vaultData = abi.encode(address(stock), 10_000_001 ether);
        vm.expectRevert(); factory.onBeforeLaunch(p, alice);
        vm.expectRevert(); factory.newVault(address(token), address(stock), alice, abi.encode(address(stock), 0));
    }
    function testFirstPartialFillAtomicRollback() public {
        first.setPartialFillBps(5000);
        vm.expectRevert(Vault.IncompleteFill.selector); vault.convert(); _assertRollback();
    }
    function testSecondPartialFillAtomicRollback() public {
        second.setPartialFillBps(5000);
        vm.expectRevert(Vault.IncompleteFill.selector); vault.convert(); _assertRollback();
    }
    function _assertRollback() private view {
        assertEq(wrapped.balanceOf(address(vault)), 4 ether);
        assertEq(usdt.balanceOf(address(vault)), 0);
        assertEq(stock.balanceOf(address(vault)), 0);
        assertEq(vault.accountedQuote(), 0);
        assertEq(vault.magnifiedDividendPerShare(), 0);
    }
    function testCanonicalFactoryRecheckedEveryHop() public {
        v3.setPool(address(usdt), address(stock), 2500, address(0));
        vm.expectRevert(Vault.InvalidMarket.selector); vault.convert(); _assertRollback();
    }
    function testSecondHopOracleFailureRollsBackFirst() public {
        second.setTwapUsable(false);
        vm.expectRevert(Vault.OracleNotReady.selector); vault.convert(); _assertRollback();
    }
    function testFirstHopOracleFailure() public {
        first.setTwapUsable(false);
        vm.expectRevert(Vault.OracleNotReady.selector); vault.convert();
    }
    function testAdverseSpotVsTwapBothDirections() public {
        first.setTwapTick(address(wrapped) < address(usdt) ? int24(1000) : int24(-1000));
        vm.expectRevert(Vault.ImpactTooHigh.selector); vault.convert();
        first.setTwapTick(0);
        second.setTwapTick(address(usdt) < address(stock) ? int24(1000) : int24(-1000));
        vm.expectRevert(Vault.ImpactTooHigh.selector); vault.convert(); _assertRollback();
    }
    function testSpoofedCallbackRejectedBothDeltaOrientations() public {
        vm.expectRevert(Vault.InvalidMarket.selector); vault.pancakeV3SwapCallback(1, -1, "");
        vm.prank(address(first)); vm.expectRevert(Vault.InvalidMarket.selector);
        vault.pancakeV3SwapCallback(-1, 1, "");
    }
    function testMinimumExclusionsAndRewardDebtSurviveTransfers() public {
        vault.convert();
        uint256 due = vault.withdrawableOf(alice);
        token.move(alice, bob, 250 ether);
        assertEq(vault.sharesOf(alice), 0); assertEq(vault.withdrawableOf(alice), due);
        token.mint(address(10), 1000 ether); token.notify(address(0), address(10));
        assertEq(vault.sharesOf(address(10)), 0);
        token.move(bob, address(first), 100 ether);
        token.setMainPool(address(first)); vault.syncExclusions();
        assertEq(vault.sharesOf(address(first)), 0); assertTrue(vault.excluded(address(first)));
        stock.setFail(alice, true);
        vm.prank(alice); assertEq(vault.claim(), 0);
        assertEq(vault.withdrawableOf(alice), due);
        stock.setFail(alice, false);
        vm.prank(alice); assertEq(vault.claim(), due);
    }
    function testKeeperAliasesAndProcess() public {
        assertEq(vault.routeVersion(), 2); assertEq(factory.routeVersion(), 2);
        assertEq(vault.stock(), address(stock)); assertEq(vault.quoteToken(), address(wrapped));
        assertEq(vault.swapPool(), address(first)); assertEq(vault.swapFee(), 500);
        vault.growOracle(); vault.convert();
        (, uint256 claims) = vault.process(1_000_000);
        assertEq(claims, 2);
    }
    function testFuzzFundingConservation(uint96 a, uint96 b, uint96 funding) public {
        a = uint96(bound(a, 1, 1_000_000 ether)); b = uint96(bound(b, 1, 1_000_000 ether));
        funding = uint96(bound(funding, 1, 1_000_000 ether));
        StocksHookToken t = new StocksHookToken();
        Vault same = launcher.create(factory, address(t), address(stock), address(stock), 0);
        t.setHook(address(same)); t.mint(alice, a); t.mint(bob, b);
        t.notify(address(0), alice); t.notify(address(0), bob);
        stock.mint(address(same), funding); same.convert();
        assertLe(same.withdrawableOf(alice) + same.withdrawableOf(bob), funding);
        t.move(alice, bob, a);
        vm.prank(alice); same.claim(); vm.prank(bob); same.claim();
        assertLe(stock.balanceOf(alice) + stock.balanceOf(bob), funding);
    }
    function testOneWeiHolderThenFullSupplyTransferDoesNotOverflowHook() public {
        StocksHookToken t = new StocksHookToken();
        Vault same = launcher.create(factory, address(t), address(stock), address(stock), 0);
        t.setHook(address(same));
        t.mint(alice, 1); t.notify(address(0), alice);
        stock.mint(address(same), 1 ether); same.convert();
        assertEq(same.withdrawableOf(alice), 1 ether);
        t.mint(bob, 1e9 ether - 1); t.notify(address(0), bob);
        assertEq(same.withdrawableOf(bob), 0);
        t.move(bob, alice, 1e9 ether - 1);
        assertEq(same.withdrawableOf(alice), 1 ether);
        stock.mint(address(same), 2 ether); same.convert();
        vm.prank(alice); same.claim();
        assertLe(stock.balanceOf(alice), 3 ether);
        assertGe(stock.balanceOf(alice), 3 ether - 1);
        t.move(alice, bob, 1e9 ether);
        assertEq(same.withdrawableOf(bob), 0);
    }
    function testTickCumulativeSignedWrap() public {
        uint32[] memory ago = new uint32[](2); ago[0] = 1800;
        int56[] memory sums = new int56[](2);
        sums[0] = type(int56).max - 899;
        sums[1] = type(int56).min + 900; // modular difference +1800 => tick +1
        vm.mockCall(address(first), abi.encodeWithSelector(first.observe.selector, ago), abi.encode(sums, new uint160[](2)));
        vault.convert();
        assertGt(vault.withdrawableOf(alice), 0);
    }
    function testSameStockPayoutBlocksReentrantConvertPingAndCallback() public {
        RoutedReentrantToken reward = new RoutedReentrantToken();
        factory.setDividendStockAllowed(address(reward), true);
        Vault same = launcher.create(factory, address(token), address(reward), address(reward), 0);
        token.setHook(address(same)); token.notify(address(0), alice);
        reward.mint(address(same), 1 ether); same.convert();
        reward.setTarget(address(same));
        vm.prank(alice); same.claim();
        assertEq(reward.attempts(), 1);
        assertEq(same.withdrawableOf(alice), 0);
        assertLe(reward.balanceOf(alice), 1 ether);
    }
    function testSwapOutputBlocksReentrantConvertPingAndCallback() public {
        RoutedReentrantToken reward = new RoutedReentrantToken();
        MockV3Pool p = _pool(address(wrapped), address(reward), 500);
        factory.setDividendStockAllowed(address(reward), true);
        factory.setDividendRoute(address(reward), address(p), address(0), 1 ether);
        Vault v = launcher.create(factory, address(token), address(wrapped), address(reward), 0);
        wrapped.mint(address(v), 1 ether); reward.mint(address(p), 10 ether);
        reward.setTarget(address(v));
        vm.warp(block.timestamp + 1800);
        v.convert();
        assertEq(reward.attempts(), 1);
        assertEq(v.unaccountedStock(), 1 ether);
    }
    function testActiveCallbackRejectsWrongTokenTwoDebtsAndOverpayment() public {
        RoutedCallbackAttackPool hostile = new RoutedCallbackAttackPool(address(direct));
        v3.setPool(address(wrapped), address(stock), 100, address(hostile));
        // Mock canonical factory permits hostile pool to exercise callback guards.
        Vault.RouteConfig memory r = Vault.RouteConfig(address(v3), address(usdt), address(hostile), address(0), 1 ether);
        Vault v = new Vault(address(token), address(wrapped), alice, address(wrapped), address(stock), 0, r, new address[](0));
        wrapped.mint(address(v), 1 ether);
        for (uint256 i; i < 4; ++i) {
            hostile.setMode(i);
            vm.expectRevert(Vault.InvalidMarket.selector); v.convert();
            assertEq(wrapped.balanceOf(address(v)), 1 ether);
            assertEq(v.accountedQuote(), 0);
        }
    }
    function testAccumulatorOverflowRevertsFundingNotFutureHooks() public {
        StocksHookToken t = new StocksHookToken();
        Vault same = launcher.create(factory, address(t), address(stock), address(stock), 0);
        t.setHook(address(same)); t.mint(alice, 1); t.notify(address(0), alice);
        stock.mint(address(same), 2 ** 128);
        vm.expectRevert(); same.convert();
        assertEq(same.magnifiedDividendPerShare(), 0);
        t.mint(bob, 1 ether); t.notify(address(0), bob);
        same.convert();
        assertLe(same.withdrawableOf(alice) + same.withdrawableOf(bob), 2 ** 128);
    }
    function testConvertedZeroShareCarryCreditsWithoutAnyFreshQuote() public {
        StocksHookToken t = new StocksHookToken();
        Vault v = launcher.create(factory, address(t), address(wrapped), address(stock), 0);
        wrapped.mint(address(v), 1 ether); v.convert();
        assertEq(v.unaccountedStock(), 1 ether); assertEq(v.accountedQuote(), 0);
        t.setHook(address(v)); t.mint(alice, 1 ether); t.notify(address(0), alice);
        (uint256 spent, uint256 received) = v.convert();
        assertEq(spent, 0); assertEq(received, 0);
        assertEq(v.unaccountedStock(), 0);
        assertGt(v.withdrawableOf(alice), 0);
    }
}