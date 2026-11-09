// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbMigrationForkTest, MigrationERC20, MigrationPool, MigrationNfpm} from "./StoxesBnbMigrationFork.t.sol";
import {StoxesBnbFreshRecoveryForkTest} from "./StoxesBnbFreshRecoveryFork.t.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbGraduator} from "../../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbV3Locker} from "../../../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbAdminFloorReserveVaultFactory} from "../../../src/bnb/vaults/StoxesBnbAdminFloorReserveVaultFactory.sol";
import {BnbCreateParams, BnbLaunchKind, BnbFeeMode, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";
import {console2} from "forge-std/Test.sol";

/// Opt-in fresh candidate stack on real Pancake contracts. No broadcasts, keys,
/// etch, or storage edits to the application/DEX. Only test wallet funding and
/// explicit native-quote admission are simulated.
contract StoxesBnbAdminTestCurveForkTest is StoxesBnbFreshRecoveryForkTest {
    function setUp() public override {
        if (!vm.envOr("RUN_BNB_ADMIN_CURVE_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_FORK_BLOCK"));
        assertEq(block.chainid, 56);
        StoxesBnbFactory live = StoxesBnbFactory(payable(address(bytes20(hex"62d721d2a69d5796310cec75d7b60246d756eff7"))));
        StoxesBnbPortal previous = StoxesBnbPortal(payable(live.portal()));
        StoxesBnbV3Locker previousLocker = StoxesBnbV3Locker(payable(previous.locker()));
        owner = live.owner();
        address treasury = previous.treasury();
        StoxesBnbGraduator g = new StoxesBnbGraduator(WBNB, NFPM, treasury, owner);
        portal = new StoxesBnbPortal(WBNB, treasury, address(g), owner);
        processor = new StoxesBnbTaxProcessor(
            WBNB, treasury, StoxesBnbTaxProcessor(payable(live.taxProcessor())).minThreshold(), owner
        );
        locker = new StoxesBnbV3Locker(
            address(portal), WBNB, NFPM, previousLocker.v3Factory(), previousLocker.swapRouter(), treasury, owner
        );
        factory = new StoxesBnbFactory(
            live.simpleTokenImplementation(), live.taxTokenImplementation(),
            address(portal), WBNB, V2FACTORY, address(processor), owner
        );
        FLOOR = address(new StoxesBnbAdminFloorReserveVaultFactory(address(factory), owner, address(portal)));
        FACTORY = address(factory); PORTAL = address(portal); GRADUATOR = address(g);
        PROCESSOR = address(processor); LOCKER = address(locker);
        vm.startPrank(owner);
        g.setPortal(PORTAL); processor.setPortal(PORTAL); portal.setFactory(FACTORY); portal.setLocker(LOCKER);
        factory.setVaultFactoryAllowed(FLOOR, true);
        factory.setQuoteAllowed(BNCB, true);
        // Fork-only native admission, not an override of live BNCB-only policy.
        factory.setQuoteAllowed(address(0), true);
        _copyAdminCurve(previous, BNCB); _copyAdminCurve(previous, WBNB);
        portal.setCreatorDispatchThreshold(previous.creatorDispatchThreshold());
        vm.stopPrank();
        assertFalse(factory.launchesOpen());
        console2.log("Admin curve candidate: fresh local stack at pinned BSC block", block.number);
    }

    function _copyAdminCurve(StoxesBnbPortal previous, address quote) private {
        (uint128 r, uint128 h, uint256 k, uint128 grad,, bool allowed) = previous.quoteParams(quote);
        portal.setQuoteParams(quote, r, h, k, grad, allowed);
    }

    function testAdminCurveNativeTaxPointTwoLifecycle() public { _testCurve(address(0), true, false, 0.2 ether); }
    function testAdminCurveNativeSimplePointTwoLifecycle() public { _testCurve(address(0), false, false, 0.2 ether); }
    function testAdminCurveBncbTaxOneLifecycle() public { _testCurve(BNCB, true, false, 1 ether); }
    function testAdminCurveBncbSimpleOneLifecycle() public { _testCurve(BNCB, false, false, 1 ether); }
    function testAdminCurveBncbSimpleHolderOneLifecycle() public { _testCurve(BNCB, false, true, 1 ether); }

    function _testCurve(address quote, bool tax, bool holders, uint256 amount) private {
        target = amount;
        BnbCreateParams memory p;
        p.version = 1; p.kind = tax ? BnbLaunchKind.Tax : BnbLaunchKind.Simple;
        p.name = "Admin curve fork test"; p.symbol = "TEST";
        p.quoteToken = quote; p.salt = keccak256(abi.encode(quote, tax, holders));
        p.creatorBuyQuoteAmount = target / 1000; p.creatorBuyMinTokensOut = 1;
        if (tax) {
            p.buyTaxBps = 500; p.sellTaxBps = 500;
            p.allocation = BnbTaxAllocation(4000, 2000, 2000, 2000);
            p.vaultFactory = FLOOR; p.vaultData = abi.encode(uint16(0));
        } else {
            p.feeMode = holders ? BnbFeeMode.Holders : BnbFeeMode.Creator;
            p.creatorFeeShareBps = 5000;
        }
        _fund(quote, owner, target * 2);
        if (quote != address(0)) { vm.prank(owner); MigrationERC20(quote).approve(FACTORY, type(uint256).max); }
        vm.prank(owner, owner);
        (address token, address vault,,) = factory.createTestToken{
            value: quote == address(0) ? p.creatorBuyQuoteAmount : 0
        }(p, target);
        (,,, uint128 stored,) = portal.tokenCurve(token);
        assertEq(stored, target);
        assertEq(factory.testCurveQuote(token), target);
        _curveRoundTrip(token, quote, tax, vault);
        _fill(token, quote);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized, "small-curve migration must actually finalize");
        address pool = _pool(token);
        if (tax) {
            (uint112 r0, uint112 r1,) = MigrationPool(pool).getReserves();
            assertGt(r0, 0); assertGt(r1, 0);
            assertGt(MigrationERC20(pool).balanceOf(DEAD), 0);
        } else {
            uint256 tokenId = locker.feeInfo(token).tokenId;
            assertGt(tokenId, 0);
            assertEq(MigrationNfpm(NFPM).ownerOf(tokenId), LOCKER);
            assertGt(MigrationPool(pool).liquidity(), 0);
        }
        _dexRoundTrip(token, quote, tax, pool);
        _fees(token, quote, tax, vault);
        assertFalse(factory.launchesOpen(), "test never opens public launches");
    }
}