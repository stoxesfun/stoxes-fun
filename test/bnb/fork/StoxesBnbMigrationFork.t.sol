// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbGraduator} from "../../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbV3Locker} from "../../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../../../src/bnb/StoxesBnbTaxProcessor.sol";
import {BnbCreateParams, BnbLaunchKind, BnbFeeMode, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";

interface MigrationERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
    function phase() external view returns (uint8);
    function pendingTax() external view returns (uint256);
}
interface MigrationV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256, uint256, address[] calldata, address, uint256) external;
}
interface MigrationPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
    function liquidity() external view returns (uint128);
    function sync() external;
    function getReserves() external view returns (uint112, uint112, uint32);
}
interface MigrationNfpm {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function ownerOf(uint256) external view returns (address);
    function safeTransferFrom(address, address, uint256) external;
}

/// Opt-in only. Read-only local RPC bridge; no private keys, broadcast or live writes.
/// RUN_BNB_MIGRATION_FORK=true BNB_FORK_BLOCK=<block> forge test
///   --match-contract StoxesBnbMigrationForkTest -vv --threads 1
/// All tested application/DEX bytecode is inherited from the pinned chain.
contract StoxesBnbMigrationForkTest is Test {
    // Defaults are always the pinned deployment. A separately named fresh-stack
    // candidate fixture can rebind these ONLY after verifying that deployment.
    address internal FACTORY = 0xCd630D5987fff7D7060845F90c53c680F52d484f;
    address internal PORTAL = 0x83961f06d22DeB4FE62744E215bF0f2F613c0fA3;
    address internal GRADUATOR = 0x6De565BB12663d31692f64FcFb8f2319789b7D42;
    address internal LOCKER = 0x956bAbe25a2e92fC8FCAaF9fEf50C628c1DDd007;
    address internal PROCESSOR = 0x6Aff48AB2D1BE82CF553EDa7e9D988e32c0251c0;
    address internal FLOOR = 0xBc82915D50638090840ab288a8228fE29e591C1E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BNCB = 0x4902C5ebc598265Ed2212b559B042De8a5Eeec3f;
    address constant V2FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant DEAD = address(0xdead);
    StoxesBnbFactory factory = StoxesBnbFactory(payable(FACTORY));
    StoxesBnbPortal portal = StoxesBnbPortal(payable(PORTAL));
    StoxesBnbV3Locker locker = StoxesBnbV3Locker(payable(LOCKER));
    StoxesBnbTaxProcessor processor = StoxesBnbTaxProcessor(payable(PROCESSOR));
    address owner;
    address activePool;
    address payer;
    uint256 target;
    uint256 serial;
    receive() external payable {}

    function setUp() public virtual {
        if (!vm.envOr("RUN_BNB_MIGRATION_FORK", false)) { vm.skip(true); return; }
        uint256 pinned = vm.envUint("BNB_FORK_BLOCK");
        vm.createSelectFork("http://127.0.0.1:18546", pinned);
        assertEq(block.chainid, 56);
        assertEq(FACTORY.codehash, 0xe4cddd26ae2be489bd062ddb519111b601e465f7bda0a65d79e296502fd7bccd);
        assertEq(PORTAL.codehash, 0xf3476931a5ea76551b6fb694b32c784c15da42ed03204d19db23ebc5328dfa61);
        assertEq(GRADUATOR.codehash, 0xcee29c5102243c6ba25a6e4dcdf0fcd6fc14a89df41033886353808306ab01a7);
        assertEq(factory.portal(), PORTAL);
        assertEq(factory.WBNB(), WBNB);
        assertEq(factory.v2Factory(), V2FACTORY);
        assertEq(factory.taxProcessor(), PROCESSOR);
        assertEq(portal.graduator(), GRADUATOR);
        assertEq(portal.locker(), LOCKER);
        assertEq(StoxesBnbGraduator(payable(GRADUATOR)).positionManager(), NFPM);
        assertGt(WBNB.code.length, 0);
        assertGt(BNCB.code.length, 0);
        owner = factory.owner();
        console2.log("Pinned BSC block", block.number);
        console2.log("Factory runtime hash"); console2.logBytes32(FACTORY.codehash);
        console2.log("Portal runtime hash"); console2.logBytes32(PORTAL.codehash);
        console2.log("Graduator runtime hash"); console2.logBytes32(GRADUATOR.codehash);
    }

    function testBNCB_Tax_FullLifecycle() public { _lifecycle(BNCB, true, false); }
    function testBNCB_Simple_FullLifecycle() public { _lifecycle(BNCB, false, false); }
    function testNative_Tax_FullLifecycle_ForkOnlyAdmission() public { _lifecycle(address(0), true, true); }
    function testNative_Simple_FullLifecycle_ForkOnlyAdmission() public { _lifecycle(address(0), false, true); }

    function _create(address quote, bool tax, bool allowNative) internal returns (address token, address vault) {
        if (allowNative && !factory.quoteAllowed(quote)) {
            // Explicit scenario variant only: BNC mode can disable new native launches.
            // No curve, DEX, token or migration settings are modified.
            vm.prank(owner); factory.setQuoteAllowed(quote, true);
            console2.log("FORK ONLY: native quote admission enabled");
        }
        assertTrue(factory.quoteAllowed(quote), "live quote admission blocked");
        (,,, uint128 graduation,, bool allowed) = portal.quoteParams(_asset(quote));
        assertTrue(allowed);
        target = graduation;
        assertGt(target, 0);
        console2.log("Actual graduation quote units", target);
        BnbCreateParams memory p;
        p.version = 1; p.kind = tax ? BnbLaunchKind.Tax : BnbLaunchKind.Simple;
        p.name = "Fork migration test"; p.symbol = "FORK";
        p.quoteToken = quote; p.salt = keccak256(abi.encode(quote, tax, ++serial));
        if (tax) {
            p.buyTaxBps = 500; p.sellTaxBps = 500;
            p.allocation = BnbTaxAllocation(4000, 2000, 2000, 2000);
            p.vaultFactory = FLOOR; p.vaultData = abi.encode(uint16(0));
        } else {
            p.feeMode = BnbFeeMode.Creator; p.creatorFeeShareBps = 5000;
        }
        _configureLaunch(p);
        p.creatorBuyQuoteAmount = target / 1000;
        p.creatorBuyMinTokensOut = 1;
        _fund(quote, owner, target * 2);
        if (quote != address(0)) { vm.prank(owner); MigrationERC20(quote).approve(FACTORY, type(uint256).max); }
        vm.prank(owner, owner);
        (token, vault,,) = factory.createToken{value: quote == address(0) ? p.creatorBuyQuoteAmount : 0}(p);
        assertGt(token.code.length, 0);
        assertEq(MigrationERC20(token).phase(), 0);
        assertGt(MigrationERC20(token).balanceOf(owner), 0, "atomic creator purchase");
        console2.log("Created token", token);
    }

    function _configureLaunch(BnbCreateParams memory) internal virtual {}

    function _curveRoundTrip(address token, address quote, bool tax, address vault) internal {
        address trader = address(0xA1100);
        uint256 beforeFee = _balance(quote, portal.treasury());
        _fund(quote, trader, target);
        (uint256 received, uint256 spent) = _buy(token, quote, trader, target / 1000);
        assertGt(received, 0); assertGt(spent, 0);
        assertLe(received, portal.CURVE_SALE_SUPPLY());
        assertGe(_balance(quote, portal.treasury()) - beforeFee, spent / 100, "curve fee settled");
        if (tax) {
            assertGt(MigrationERC20(_asset(quote)).balanceOf(vault), 0, "floor funded");
            (uint128 burn, uint128 liq) = portal.taxEscrow(token);
            assertGt(burn, 0); assertGt(liq, 0);
        }
        vm.prank(trader); MigrationERC20(token).approve(PORTAL, received);
        uint256 before = _balance(quote, trader);
        vm.prank(trader, trader);
        uint256 out = portal.sell(token, received / 2, 1);
        assertGt(out, 0);
        assertEq(_balance(quote, trader), before + out, "curve sell actually paid");
        console2.log("PASS atomic creation, curve buy/sell, fee and tax accounting");
    }

    function _fill(address token, address quote) internal {
        for (uint256 i; i < 40; ++i) {
            (,, bool graduated,,,) = portal.tokenState(token);
            if (graduated) break;
            address trader = address(uint160(0xB0000 + i));
            _fund(quote, trader, target * 2);
            uint256 before = _balance(quote, trader);
            (uint256 out, uint256 spent) = _buy(token, quote, trader, target * 2);
            assertGt(out, 0); assertLe(out, portal.CURVE_SALE_SUPPLY());
            assertLt(spent, target * 2, "overshoot clamped");
            assertEq(_balance(quote, trader), before - spent, "refund conserved");
        }
        (,, bool done,, uint256 sold,) = portal.tokenState(token);
        assertTrue(done, "final buy did not graduate");
        assertLe(sold, 800_000_000 ether);
        console2.log("PASS final buy, curve capacity, overshoot refunds");
    }

    function _lifecycle(address quote, bool tax, bool allowNative) internal {
        (address token, address vault) = _create(quote, tax, allowNative);
        _curveRoundTrip(token, quote, tax, vault);
        _fill(token, quote);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized, "normal migration unexpectedly deferred");
        assertEq(MigrationERC20(token).phase(), 2);
        address pool = _pool(token);
        assertGt(pool.code.length, 0);
        if (tax) {
            (uint112 r0, uint112 r1,) = MigrationPool(pool).getReserves();
            assertGt(r0, 0); assertGt(r1, 0);
            assertGt(MigrationERC20(pool).balanceOf(DEAD), 0, "V2 LP burned");
            assertEq(MigrationERC20(pool).balanceOf(owner), 0, "creator has no LP");
            assertEq(MigrationERC20(pool).balanceOf(GRADUATOR), 0, "graduator has no LP");
        } else {
            StoxesBnbV3Locker.FeeRecord memory f = locker.feeInfo(token);
            assertGt(f.tokenId, 0);
            assertEq(MigrationNfpm(NFPM).ownerOf(f.tokenId), LOCKER);
            assertGt(MigrationPool(pool).liquidity(), 0);
            vm.prank(owner); vm.expectRevert();
            MigrationNfpm(NFPM).safeTransferFrom(LOCKER, owner, f.tokenId);
        }
        console2.log("PASS liquidity placement and LP custody");
        _dexRoundTrip(token, quote, tax, pool);
        _fees(token, quote, tax, vault);
    }

    function _dexRoundTrip(address token, address quote, bool tax, address pool) internal {
        address trader = address(0xD0000);
        address asset = _asset(quote);
        // Simulated WBNB is deposited, not unbacked wrapped-token storage edits.
        _fund(asset, trader, target);
        uint256 before = MigrationERC20(token).balanceOf(trader);
        // Tax processing has a real minimum pending-token threshold. Generate
        // enough organic pool volume to cross it; never lower deployed thresholds.
        _swap(pool, trader, asset, token, tax ? target / 20 : target / 100, tax);
        uint256 bought = MigrationERC20(token).balanceOf(trader) - before;
        assertGt(bought, 0, "DEX buy delivered tokens");
        uint256 beforeQuote = MigrationERC20(asset).balanceOf(trader);
        _swap(pool, trader, token, asset, bought / 2, tax);
        assertGt(MigrationERC20(asset).balanceOf(trader), beforeQuote, "DEX sell paid quote");
        if (tax) assertGt(MigrationERC20(token).pendingTax(), 0, "DEX tax accrued");
        console2.log("PASS real Pancake pool buy AND sell");
    }

    function _fees(address token, address quote, bool tax, address vault) internal {
        vm.warp(block.timestamp + 1801); vm.roll(block.number + 1);
        if (tax) {
            uint256 beforeVault = MigrationERC20(_asset(quote)).balanceOf(vault);
            uint256 beforeTreasury = _balance(quote, processor.treasury());
            uint256 pendingBefore = MigrationERC20(token).pendingTax();
            uint256 out = processor.process(token);
            assertGt(out, 0, "tax conversion actually executed");
            assertLt(MigrationERC20(token).pendingTax(), pendingBefore);
            assertGt(MigrationERC20(_asset(quote)).balanceOf(vault), beforeVault);
            assertGt(_balance(quote, processor.treasury()), beforeTreasury);
            uint256 beforeDead = MigrationERC20(token).balanceOf(DEAD);
            vm.warp(block.timestamp + 1801);
            uint256 burned = processor.buyAndBurn(token);
            assertGt(burned, 0);
            assertGt(MigrationERC20(token).balanceOf(DEAD), beforeDead);
        } else {
            locker.collect(token);
            StoxesBnbV3Locker.FeeRecord memory f = locker.feeInfo(token);
            assertGt(f.totalCollected, 0, "real V3 fees collected");
            if (f.creatorPending + f.treasuryPending + f.holdersPending > 0) locker.dispatch(token);
            assertGt(locker.feeInfo(token).totalDispatched, 0, "real V3 fees dispatched");
        }
        console2.log("PASS post-graduation fee settlement");
    }

    function testBNCB_Simple_DeferredRecovery() public {
        (address token,) = _create(BNCB, false, false);
        (address t0, address t1) = token < BNCB ? (token, BNCB) : (BNCB, token);
        // Real Pancake pool initialized at a deliberately hostile price, no mock/storage override.
        MigrationNfpm(NFPM).createAndInitializePoolIfNecessary(t0, t1, 10_000, uint160(1 << 96));
        _fill(token, BNCB);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertFalse(finalized);
        assertEq(MigrationERC20(token).phase(), 1);
        vm.prank(owner); vm.expectRevert();
        MigrationERC20(token).transfer(address(0xBAD), 1);
        portal.finalizeGraduation(token);
        assertEq(MigrationERC20(token).phase(), 2, "deferred V3 must recover");
        assertEq(MigrationNfpm(NFPM).ownerOf(locker.feeInfo(token).tokenId), LOCKER);
        _dexRoundTrip(token, BNCB, false, _pool(token));
        console2.log("PASS real hostile-price V3 recovery");
    }

    function testBNCB_Tax_ContaminatedPairRecovery() public virtual {
        (address token,) = _create(BNCB, true, false);
        address pool = _pool(token);
        _fund(BNCB, address(this), 1 ether);
        MigrationERC20(BNCB).transfer(pool, 1 ether);
        MigrationPool(pool).sync();
        _fill(token, BNCB);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertFalse(finalized);
        assertEq(MigrationERC20(token).phase(), 1);
        assertGt(MigrationERC20(token).balanceOf(GRADUATOR), 0);
        assertGt(MigrationERC20(BNCB).balanceOf(GRADUATOR), 0);
        assertEq(MigrationERC20(pool).totalSupply(), 0);
        vm.prank(owner); MigrationERC20(token).approve(PORTAL, type(uint256).max);
        vm.prank(owner); vm.expectRevert();
        portal.sell(token, 1 ether, 0);
        console2.log("V2 deferred: phase=1, migration assets retained, no LP minted, curve sell blocked");
        // Intentionally demand actual recovery, not an "expected revert" that masks a stuck token.
        portal.finalizeGraduation(token);
        assertEq(MigrationERC20(token).phase(), 2, "contaminated V2 must recover");
        _dexRoundTrip(token, BNCB, true, pool);
    }

    function _pool(address token) internal view returns (address pool) {
        (,,,, pool,,,,,) = portal.stateDetails(token);
    }
    function _asset(address quote) internal pure returns (address) { return quote == address(0) ? WBNB : quote; }
    function _balance(address quote, address who) internal view returns (uint256) {
        return quote == address(0) ? who.balance : MigrationERC20(quote).balanceOf(who);
    }
    function _fund(address quote, address who, uint256 amount) internal {
        if (quote == address(0)) vm.deal(who, amount);
        else if (quote == WBNB) {
            vm.deal(who, amount);
            vm.prank(who);
            (bool ok,) = WBNB.call{value: amount}(abi.encodeWithSignature("deposit()"));
            require(ok, "WBNB deposit");
        } else deal(quote, who, amount, true);
    }
    function _buy(address token, address quote, address who, uint256 amount) internal returns (uint256, uint256) {
        if (quote == address(0)) { vm.prank(who, who); return portal.buy{value: amount}(token, 1); }
        vm.prank(who); MigrationERC20(quote).approve(PORTAL, type(uint256).max);
        vm.prank(who, who); return portal.buyWithQuote(token, amount, 1);
    }
    function _swap(address pool, address who, address input, address output, uint256 amount, bool tax) internal {
        if (tax) {
            address[] memory path = new address[](2); path[0] = input; path[1] = output;
            vm.prank(who); MigrationERC20(input).approve(V2ROUTER, amount);
            vm.prank(who, who);
            MigrationV2(V2ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 1, path, who, block.timestamp);
        } else {
            vm.prank(who); MigrationERC20(input).approve(address(this), amount);
            activePool = pool; payer = who;
            bool zeroForOne = input == MigrationPool(pool).token0();
            MigrationPool(pool).swap(who, zeroForOne, int256(amount),
                zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341), "");
            activePool = address(0); payer = address(0);
        }
    }
    function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == activePool && payer != address(0), "unexpected callback");
        if (a0 > 0) MigrationERC20(MigrationPool(msg.sender).token0()).transferFrom(payer, msg.sender, uint256(a0));
        if (a1 > 0) MigrationERC20(MigrationPool(msg.sender).token1()).transferFrom(payer, msg.sender, uint256(a1));
    }
}