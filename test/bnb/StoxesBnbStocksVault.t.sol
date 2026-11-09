// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbStocksVault} from "../../src/bnb/vaults/StoxesBnbStocksVault.sol";
import {StoxesBnbStocksVaultFactory} from "../../src/bnb/vaults/StoxesBnbStocksVaultFactory.sol";
import {StoxesBnbGraduator} from "../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbPortal} from "../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbV3Locker} from "../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbFactory} from "../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbSimpleToken} from "../../src/bnb/StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {IStoxesBnbBalanceHook, BnbCreateParams, BnbFeeMode, BnbLaunchKind, BnbTaxAllocation} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20, MockWETH, MockSwapV2Factory} from "../mocks/Mocks.sol";
import {MockSwapRouter02, MockV3Pool} from "../mocks/MocksV3.sol";
import {RealisticBnbV3PositionManager} from "./mocks/RealisticV3Mocks.sol";
import {TickMath} from "../../src/vendor/TickMath.sol";

contract StocksHookToken is MockERC20 {
    address public hook;
    address public mainPool;
    constructor() MockERC20("Launch", "LCH", 18) {}
    function setHook(address h) external { hook = h; }
    function setMainPool(address pool_) external { mainPool = pool_; }
    function notify(address from, address to) external {
        IStoxesBnbBalanceHook(hook).onBalanceChange(from, balanceOf[from], to, balanceOf[to]);
    }
    function move(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        IStoxesBnbBalanceHook(hook).onBalanceChange(from, balanceOf[from], to, balanceOf[to]);
    }
    function burnAndNotify(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        IStoxesBnbBalanceHook(hook).onBalanceChange(from, balanceOf[from], address(0), 0);
    }
}

contract SelectiveStock is MockERC20 {
    mapping(address => bool) public failTo;
    constructor(uint8 d) MockERC20("Dividend Stock", "DST", d) {}
    function setFail(address account, bool fail) external { failTo[account] = fail; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTo[to]) return false;
        return super.transfer(to, amount);
    }
}

contract StocksV3Factory {
    mapping(bytes32 => address) public pools;
    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(a < b ? a : b, a < b ? b : a, fee))] = pool;
    }
    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a < b ? a : b, a < b ? b : a, fee))];
    }
}

contract StocksGasExhaustingReceiver {
    receive() external payable {
        while (gasleft() != 0) {}
    }
}

contract StoxesBnbStocksVaultTest is Test {
    struct FactoryEnv {
        MockWETH weth;
        MockSwapV2Factory v2Factory;
        RealisticBnbV3PositionManager nfpm;
        StoxesBnbPortal portal;
        StoxesBnbFactory factory;
    }

    StocksHookToken token;
    SelectiveStock stock;
    MockERC20 quote;
    StocksV3Factory v3;
    MockV3Pool pool;
    StoxesBnbStocksVault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address excludedAccount = address(0xE);

    function setUp() public {
        vm.warp(10_000);
        token = new StocksHookToken();
        stock = new SelectiveStock(18);
        quote = new MockERC20("Quote", "Q", 18);
        v3 = new StocksV3Factory();
        (address t0, address t1) =
            address(quote) < address(stock) ? (address(quote), address(stock)) : (address(stock), address(quote));
        pool = new MockV3Pool(t0, t1, 500, TickMath.getSqrtRatioAtTick(0), 0);
        pool.setPancakeCallback(true);
        pool.setLiquidity(1e18);
        pool.setWokbOutPerTokenWad(1e18);
        v3.setPool(address(quote), address(stock), 500, address(pool));
        address[] memory exclusions = new address[](1);
        exclusions[0] = excludedAccount;
        vault = new StoxesBnbStocksVault(
            address(token), address(quote), address(this), address(0xBEEF), address(stock), 100 ether,
            address(pool), 500, exclusions
        );
        token.setHook(address(vault));
        token.mint(alice, 300 ether);
        token.mint(bob, 200 ether);
        token.mint(excludedAccount, 500 ether);
        token.notify(address(0), alice);
        token.notify(address(0), bob);
        token.notify(address(0), excludedAccount);
        quote.mint(address(vault), 1_000 ether);
        stock.mint(address(pool), 2_000 ether);
        vm.warp(block.timestamp + 1800);
    }

    function testTrackerTransfersBurnsMinHoldingRingAndExclusions() public {
        assertEq(vault.totalShares(), 500 ether);
        assertEq(vault.holderCount(), 2);
        assertEq(vault.sharesOf(excludedAccount), 0);
        token.move(alice, bob, 250 ether);
        assertEq(vault.sharesOf(alice), 0);
        assertEq(vault.sharesOf(bob), 450 ether);
        assertEq(vault.holderCount(), 1);
        token.move(bob, alice, 100 ether);
        assertEq(vault.holderCount(), 2);
        token.burnAndNotify(alice, 100 ether);
        assertEq(vault.sharesOf(alice), 0);
        assertEq(vault.holderCount(), 1);
        // The same balance callback path covers pool-side transfers and vaultBurn burns.
        token.move(bob, address(pool), 100 ether);
        token.burnAndNotify(bob, 50 ether);
        assertEq(vault.sharesOf(bob), 200 ether);
    }

    function testClaimAndBoundedProcessSkipsFailedTransfer() public {
        vault.convert();
        uint256 aliceDue = vault.withdrawableOf(alice);
        uint256 bobDue = vault.withdrawableOf(bob);
        assertGt(aliceDue, 0);
        assertGt(bobDue, 0);
        vm.prank(alice);
        vault.claim();
        assertEq(stock.balanceOf(alice), aliceDue);
        stock.setFail(bob, true);
        (, uint256 claims) = vault.process(1_000_000);
        assertEq(claims, 0);
        assertEq(vault.withdrawableOf(bob), bobDue);
        stock.setFail(bob, false);
        vault.process(1_000_000);
        assertEq(stock.balanceOf(bob), bobDue);
    }

    function testProcessFallsBackToWbnbForGasExhaustingHolder() public {
        MockWETH wrapped = new MockWETH();
        StocksHookToken launch = new StocksHookToken();
        StocksGasExhaustingReceiver hostile = new StocksGasExhaustingReceiver();
        address[] memory none = new address[](0);
        StoxesBnbStocksVault directVault = new StoxesBnbStocksVault(
            address(launch),
            address(wrapped),
            address(this),
            address(wrapped),
            address(wrapped),
            1,
            address(0),
            0,
            none
        );
        launch.setHook(address(directVault));
        launch.mint(address(hostile), 1 ether);
        launch.notify(address(0), address(hostile));
        vm.deal(address(this), 1 ether);
        wrapped.deposit{value: 1 ether}();
        wrapped.transfer(address(directVault), 1 ether);
        directVault.ping();

        (, uint256 claims) = directVault.process(1_000_000);

        assertEq(claims, 1);
        assertEq(wrapped.balanceOf(address(hostile)), 1 ether);
        assertEq(address(hostile).balance, 0);
    }

    function testPriceLimitedPartialFillCarriesQuote() public {
        pool.setPartialFillBps(2500);
        (uint256 spent, uint256 received) = vault.convert();
        assertEq(spent, 250 ether);
        assertEq(received, 250 ether);
        assertEq(vault.accountedQuote(), 750 ether);
    }

    function testStockEqualsQuoteAndZeroShareCarryCreditedLater() public {
        StocksHookToken t = new StocksHookToken();
        SelectiveStock direct = new SelectiveStock(6);
        address[] memory none = new address[](0);
        StoxesBnbStocksVault directVault = new StoxesBnbStocksVault(
            address(t), address(direct), address(this), address(0xBEEF), address(direct), 1, address(0), 0, none
        );
        t.setHook(address(directVault));
        direct.mint(address(directVault), 1_000_000);
        directVault.convert();
        assertEq(directVault.unaccountedStock(), 1_000_000);
        t.mint(alice, 10 ether);
        t.notify(address(0), alice);
        directVault.convert();
        assertEq(directVault.unaccountedStock(), 0);
        assertLe(directVault.withdrawableOf(alice), 1_000_000);
        assertGe(directVault.withdrawableOf(alice), 999_999);
    }

    function testHookOnlyToken() public {
        vm.expectRevert(StoxesBnbStocksVault.OnlyToken.selector);
        vault.onBalanceChange(alice, 1, bob, 1);
    }

    function testDefensiveSyncExcludesFutureCanonicalV3Pool() public {
        token.move(alice, address(pool), 100 ether);
        assertEq(vault.sharesOf(address(pool)), 100 ether);
        token.setMainPool(address(pool));
        vault.syncExclusions();
        assertEq(vault.sharesOf(address(pool)), 0);
        token.move(bob, address(pool), 100 ether);
        assertEq(vault.sharesOf(address(pool)), 0);
    }

    function testFuzzMagnifiedClaimsNeverExceedFunding(uint96 a, uint96 b, uint96 funding) public {
        a = uint96(bound(a, 100 ether, 1_000_000 ether));
        b = uint96(bound(b, 100 ether, 1_000_000 ether));
        funding = uint96(bound(funding, 1, 1_000_000 ether));
        StocksHookToken t = new StocksHookToken();
        SelectiveStock s = new SelectiveStock(18);
        address[] memory none = new address[](0);
        StoxesBnbStocksVault v = new StoxesBnbStocksVault(
            address(t), address(s), address(this), address(0xBEEF), address(s), 1, address(0), 0, none
        );
        t.setHook(address(v));
        t.mint(alice, a); t.mint(bob, b);
        t.notify(address(0), alice); t.notify(address(0), bob);
        s.mint(address(v), funding);
        v.convert();
        assertLe(v.withdrawableOf(alice) + v.withdrawableOf(bob), funding);
    }

    function testRealFactoryWiringNativeAndStockQuotedNoSwap() public {
        FactoryEnv memory env = _factoryEnv();
        StoxesBnbStocksVaultFactory sf =
            new StoxesBnbStocksVaultFactory(address(env.factory), address(this), address(env.nfpm));
        env.factory.setVaultFactoryAllowed(address(sf), true);
        sf.setDividendStockAllowed(address(stock), true);
        address live = env.nfpm.createAndInitializePoolIfNecessary(
            address(env.weth) < address(stock) ? address(env.weth) : address(stock),
            address(env.weth) < address(stock) ? address(stock) : address(env.weth),
            500,
            TickMath.getSqrtRatioAtTick(0)
        );
        MockV3Pool(live).setLiquidity(1);
        _assertNativePairExcluded(env, sf);
        _assertDirectStockVault(env, sf);
    }

    function _factoryEnv() private returns (FactoryEnv memory env) {
        env.weth = new MockWETH();
        env.v2Factory = new MockSwapV2Factory(25);
        env.nfpm = new RealisticBnbV3PositionManager();
        StoxesBnbTaxProcessor processor =
            new StoxesBnbTaxProcessor(address(env.weth), address(7), 0, address(this));
        StoxesBnbGraduator graduator =
            new StoxesBnbGraduator(address(env.weth), address(env.nfpm), address(7), address(this));
        env.portal =
            new StoxesBnbPortal(address(env.weth), address(7), address(graduator), address(this));
        MockSwapRouter02 router = new MockSwapRouter02();
        StoxesBnbV3Locker locker = new StoxesBnbV3Locker(
            address(env.portal),
            address(env.weth),
            address(env.nfpm),
            address(env.nfpm),
            address(router),
            address(7),
            address(this)
        );
        env.factory = new StoxesBnbFactory(
            address(new StoxesBnbSimpleToken()),
            address(new StoxesBnbTaxToken()),
            address(env.portal),
            address(env.weth),
            address(env.v2Factory),
            address(processor),
            address(this)
        );
        graduator.setPortal(address(env.portal));
        processor.setPortal(address(env.portal));
        env.portal.setLocker(address(locker));
        env.portal.setFactory(address(env.factory));
        env.portal.setQuoteParams(address(0), 1 ether, 0, 1_000_000_000 ether, 4 ether, true);
    }

    function _assertNativePairExcluded(FactoryEnv memory env, StoxesBnbStocksVaultFactory sf) private {
        BnbCreateParams memory p = _params(address(0), address(sf), abi.encode(address(stock), 0));
        (address nativeToken, address nativeVault,,) = env.factory.createToken(p);
        assertEq(StoxesBnbTaxToken(nativeToken).balanceHook(), nativeVault);
        address pair = env.v2Factory.getPair(nativeToken, address(env.weth));
        assertEq(StoxesBnbStocksVault(payable(nativeVault)).sharesOf(pair), 0);
        for (uint256 i; i < 24; ++i) {
            (,, bool graduated,,,) = env.portal.tokenState(nativeToken);
            if (graduated) break;
            address buyer = address(uint160(0x6000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer, buyer);
            env.portal.buy{value: 1 ether}(nativeToken, 0);
        }
        assertEq(uint256(StoxesBnbTaxToken(nativeToken).phase()), 2);
        pair = StoxesBnbTaxToken(nativeToken).mainPool();
        assertEq(StoxesBnbStocksVault(payable(nativeVault)).sharesOf(pair), 0);
        vm.prank(pair);
        StoxesBnbTaxToken(nativeToken).transfer(address(0xBEEF), 1 ether);
        assertEq(StoxesBnbStocksVault(payable(nativeVault)).sharesOf(pair), 0);
        uint256 tradeBalance = StoxesBnbTaxToken(nativeToken).balanceOf(address(0xBEEF));
        vm.prank(address(0xBEEF));
        StoxesBnbTaxToken(nativeToken).transfer(pair, tradeBalance);
        assertEq(StoxesBnbStocksVault(payable(nativeVault)).sharesOf(pair), 0);
    }

    function _assertDirectStockVault(FactoryEnv memory env, StoxesBnbStocksVaultFactory sf) private {
        env.portal.setQuoteParams(address(stock), 1e6, 0, 1e15, 4e6, true);
        env.factory.setQuoteAllowed(address(stock), true);
        BnbCreateParams memory p =
            _params(address(stock), address(sf), abi.encode(address(stock), 0));
        p.salt = bytes32(uint256(1));
        (address stockToken, address directVault,,) = env.factory.createToken(p);
        assertEq(StoxesBnbTaxToken(stockToken).balanceHook(), directVault);
        assertEq(StoxesBnbStocksVault(payable(directVault)).swapPool(), address(0));
    }

    function testOnBeforeLaunchRejections() public {
        StoxesBnbStocksVaultFactory sf =
            new StoxesBnbStocksVaultFactory(address(this), address(this), address(v3));
        BnbCreateParams memory p = _params(address(quote), address(sf), abi.encode(address(stock), 0));
        vm.expectRevert(); sf.onBeforeLaunch(p, address(this));
        sf.setDividendStockAllowed(address(stock), true);
        p.vaultData = abi.encode(address(stock), 10_000_001 ether);
        vm.expectRevert(); sf.onBeforeLaunch(p, address(this));
        p.vaultData = abi.encode(address(stock), 0);
        p.kind = BnbLaunchKind.Simple;
        vm.expectRevert(); sf.onBeforeLaunch(p, address(this));
        p.kind = BnbLaunchKind.Tax;
        MockERC20 absent = new MockERC20("Absent", "ABS", 18);
        p.quoteToken = address(absent);
        vm.expectRevert(); sf.onBeforeLaunch(p, address(this));
    }

    function _params(address quoteToken, address vf, bytes memory data)
        private pure returns (BnbCreateParams memory p)
    {
        p.version = 1; p.kind = BnbLaunchKind.Tax; p.name = "Stock Launch"; p.symbol = "STL";
        p.quoteToken = quoteToken; p.buyTaxBps = 100; p.sellTaxBps = 100;
        p.allocation = BnbTaxAllocation(10_000, 0, 0, 0);
        p.feeMode = BnbFeeMode.Creator; p.vaultFactory = vf; p.vaultData = data;
    }

    function WBNB() external pure returns (address) {
        return address(0xBEEF);
    }
}