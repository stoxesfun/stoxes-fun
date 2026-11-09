// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbFreshRecoveryForkTest} from "./StoxesBnbFreshRecoveryFork.t.sol";
import {MigrationERC20, MigrationPool, MigrationNfpm} from "./StoxesBnbMigrationFork.t.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbGraduator} from "../../../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbTaxProcessor} from "../../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbV3Locker} from "../../../src/bnb/StoxesBnbV3Locker.sol";
import {BnbCreateParams, BnbFeeMode, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbSplitVault} from "../../../src/bnb/vaults/StoxesBnbSplitVault.sol";
import {StoxesBnbStocksVault} from "../../../src/bnb/vaults/StoxesBnbStocksVault.sol";
import {StoxesBnbBuybackBurnVault} from "../../../src/bnb/vaults/StoxesBnbBuybackBurnVault.sol";
import {StoxesBnbGiftVault} from "../../../src/bnb/vaults/StoxesBnbGiftVault.sol";
import {StoxesBnbGiftVaultFactory} from "../../../src/bnb/vaults/StoxesBnbGiftVaultFactory.sol";
import {console2} from "forge-std/Test.sol";

/// Tests unchanged PUBLISHED bytecode, not the inherited fresh-stack deployment.
/// Fork-only funding/owner impersonation; native admission and synthetic Gift
/// signer changes are explicitly limited to their isolated test scenarios.
contract StoxesBnbPublishedLifecycleForkTest is StoxesBnbFreshRecoveryForkTest {
    address constant STOCKS = address(bytes20(hex"c55d5855c8fbf4929c77455f1d2239180835cd1c"));
    address constant SPLIT = address(bytes20(hex"c6cefaef59cc8e9dfdae083e75da9e55da2c1f4e"));
    address constant GIFT = address(bytes20(hex"3edae5198b469509e64aa2890ff619aeb0f41636"));
    address constant BUYBACK = address(bytes20(hex"151ef41180bb3c1b6f7d60f6600934744ea02660"));
    uint8 internal variant; // 0=original fixtures, 1=split, 2=gift, 3=buyback, 4=stocks, 5=holders

    function setUp() public override {
        if (!vm.envOr("RUN_BNB_PUBLISHED_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_FORK_BLOCK"));
        assertEq(block.chainid, 56);
        FACTORY = address(bytes20(hex"62d721d2a69d5796310cec75d7b60246d756eff7"));
        PORTAL = address(bytes20(hex"19364b67ab6139b526cfe8346e94562ab741cb58"));
        GRADUATOR = address(bytes20(hex"98ee75a9a5ed5f98379c6e0c24f5b48d2d0963bd"));
        LOCKER = address(bytes20(hex"3a5f6662e02c8e71442c301b6a5769a033f3cbba"));
        PROCESSOR = address(bytes20(hex"9d971da26d133075c3a8f9d363cc1e877c182043"));
        FLOOR = address(bytes20(hex"24883952a15cac6553cb32259f2dc027d291b899"));
        factory = StoxesBnbFactory(payable(FACTORY));
        portal = StoxesBnbPortal(payable(PORTAL));
        locker = StoxesBnbV3Locker(payable(LOCKER));
        processor = StoxesBnbTaxProcessor(payable(PROCESSOR));
        owner = factory.owner();
        assertEq(factory.portal(), PORTAL);
        assertEq(factory.taxProcessor(), PROCESSOR);
        assertEq(factory.WBNB(), WBNB);
        assertEq(factory.v2Factory(), V2FACTORY);
        assertEq(portal.graduator(), GRADUATOR);
        assertEq(portal.locker(), LOCKER);
        assertEq(StoxesBnbGraduator(payable(GRADUATOR)).positionManager(), NFPM);
        console2.log("PUBLISHED UNMODIFIED CONTRACTS at BSC block", block.number);
        console2.logBytes32(FACTORY.codehash);
        console2.logBytes32(PORTAL.codehash);
        console2.logBytes32(GRADUATOR.codehash);
    }

    function _configureLaunch(BnbCreateParams memory p) internal override {
        if (variant == 1) {
            p.vaultFactory = SPLIT;
            address[] memory recipients = new address[](2);
            uint16[] memory bps = new uint16[](2);
            recipients[0] = address(0xCAFE1); recipients[1] = address(0xCAFE2);
            bps[0] = 6000; bps[1] = 4000;
            p.vaultData = abi.encode(recipients, bps);
        } else if (variant == 2) {
            p.vaultFactory = GIFT; p.vaultData = abi.encode(keccak256("fork-only-recipient"));
        } else if (variant == 3) {
            p.vaultFactory = BUYBACK; p.vaultData = "";
        } else if (variant == 4) {
            p.vaultFactory = STOCKS; p.vaultData = abi.encode(BNCB, uint256(0));
        } else if (variant == 5) {
            p.feeMode = BnbFeeMode.Holders;
        } else if (variant == 6) {
            p.buyTaxBps = 0; p.sellTaxBps = 0;
            p.allocation = BnbTaxAllocation(0, 0, 0, 0);
            p.vaultFactory = address(0); p.vaultData = "";
        }
    }

    function testTaxSplit_AllStages() public { _vaultLifecycle(1, true); }
    function testTaxGift_AllStages() public { _vaultLifecycle(2, true); }
    function testTaxBuyback_AllStages() public { _vaultLifecycle(3, true); }
    function testTaxStocks_AllStages() public { _vaultLifecycle(4, true); }
    // Non-tax launches intentionally have no vault options. Their supported
    // fee destinations are tested below: creator payments or holder buyback.
    function testSimpleCreatorAndTreasury_ActualPayments() public {
        (address token,) = _create(BNCB, false, false);
        _curveRoundTrip(token, BNCB, false, address(0));
        _fill(token, BNCB);
        assertEq(MigrationERC20(token).phase(), 2);
        _dexRoundTrip(token, BNCB, false, _pool(token));
        uint256 creatorBefore = MigrationERC20(BNCB).balanceOf(owner);
        uint256 treasuryBefore = MigrationERC20(BNCB).balanceOf(portal.treasury());
        _fees(token, BNCB, false, address(0));
        assertGt(MigrationERC20(BNCB).balanceOf(owner), creatorBefore, "non-tax creator paid");
        assertGt(MigrationERC20(BNCB).balanceOf(portal.treasury()), treasuryBefore, "non-tax treasury paid");
    }
    function testZeroTaxV2_ProtocolCurveFeeAndMigration() public {
        variant = 6;
        (address token,) = _create(BNCB, true, false);
        _curveRoundTrip(token, BNCB, false, address(0));
        _fill(token, BNCB);
        assertEq(MigrationERC20(token).phase(), 2);
        address pool = _pool(token);
        assertGt(MigrationERC20(pool).balanceOf(DEAD), 0);
        address trader = address(0xD0000);
        _fund(BNCB, trader, target);
        _swap(pool, trader, BNCB, token, target / 100, true);
        uint256 bought = MigrationERC20(token).balanceOf(trader);
        assertGt(bought, 0);
        uint256 before = MigrationERC20(BNCB).balanceOf(trader);
        _swap(pool, trader, token, BNCB, bought / 2, true);
        assertGt(MigrationERC20(BNCB).balanceOf(trader), before);
        assertEq(MigrationERC20(token).pendingTax(), 0, "zero tax must stay zero");
    }
    function testNativeStocks_ConversionAndHolderClaimsBothStages() public {
        variant = 4;
        (address token, address vault) = _create(address(0), true, true);
        _curveRoundTrip(token, address(0), true, vault);
        (uint256 spent, uint256 received) = StoxesBnbStocksVault(payable(vault)).convert();
        assertGt(spent, 0); assertGt(received, 0);
        _vaultPayout(token, vault);
        _fill(token, address(0));
        assertEq(MigrationERC20(token).phase(), 2);
        _dexRoundTrip(token, address(0), true, _pool(token));
        _fees(token, address(0), true, vault);
        (spent, received) = StoxesBnbStocksVault(payable(vault)).convert();
        assertGt(spent, 0); assertGt(received, 0);
        _vaultPayout(token, vault);
    }
    function testSimpleHolderFees_ActualBurn() public {
        variant = 5;
        (address token,) = _create(BNCB, false, false);
        _curveRoundTrip(token, BNCB, false, address(0));
        _fill(token, BNCB);
        assertEq(MigrationERC20(token).phase(), 2);
        _dexRoundTrip(token, BNCB, false, _pool(token));
        uint256 deadBefore = MigrationERC20(token).balanceOf(DEAD);
        _fees(token, BNCB, false, address(0));
        assertGt(MigrationERC20(token).balanceOf(DEAD), deadBefore, "holder fee buyback must burn");
    }

    function _vaultLifecycle(uint8 selected, bool tax) private {
        variant = selected;
        (address token, address vault) = _create(BNCB, tax, false);
        uint256 creatorBefore = MigrationERC20(BNCB).balanceOf(owner);
        _curveRoundTrip(token, BNCB, tax, vault);
        if (tax && portal.creatorBucket(token) > 0) portal.dispatchCreator(token);
        if (tax) assertGt(MigrationERC20(BNCB).balanceOf(owner), creatorBefore, "curve creator payment");
        if (tax) _vaultPayout(token, vault);
        _fill(token, BNCB);
        (,,, bool finalized,,) = portal.tokenState(token);
        assertTrue(finalized, "vault migration must finalize");
        assertEq(MigrationERC20(token).phase(), 2);
        address pool = _pool(token);
        if (tax) {
            assertGt(MigrationERC20(pool).balanceOf(DEAD), 0, "LP burned");
        } else {
            assertGt(MigrationPool(pool).liquidity(), 0);
            assertEq(MigrationNfpm(NFPM).ownerOf(locker.feeInfo(token).tokenId), LOCKER);
        }
        _dexRoundTrip(token, BNCB, tax, pool);
        uint256 postCreatorBefore = MigrationERC20(BNCB).balanceOf(owner);
        uint256 treasuryBefore = MigrationERC20(BNCB).balanceOf(portal.treasury());
        _fees(token, BNCB, tax, vault);
        if (tax && processor.creatorPending(token) > 0) processor.dispatch(token);
        if (tax) assertGt(MigrationERC20(BNCB).balanceOf(owner), postCreatorBefore, "post-migration creator paid");
        assertGt(MigrationERC20(BNCB).balanceOf(portal.treasury()), treasuryBefore, "post-migration treasury paid");
        _vaultPayout(token, vault);
    }

    function _vaultPayout(address token, address vault) private {
        if (variant == 1) {
            uint256 a = MigrationERC20(BNCB).balanceOf(address(0xCAFE1));
            uint256 b = MigrationERC20(BNCB).balanceOf(address(0xCAFE2));
            uint256 paid = StoxesBnbSplitVault(payable(vault)).distribute();
            assertGt(paid, 0);
            assertGt(MigrationERC20(BNCB).balanceOf(address(0xCAFE1)), a);
            assertGt(MigrationERC20(BNCB).balanceOf(address(0xCAFE2)), b);
        } else if (variant == 2) {
            // No access to real Gift signer: alter only fork proof signer to a
            // synthetic test key. Core monetary contracts remain unchanged.
            vm.prank(owner); StoxesBnbGiftVaultFactory(GIFT).setProofSigner(vm.addr(12345));
            StoxesBnbGiftVault gift = StoxesBnbGiftVault(payable(vault));
            uint256 nonce = ++serial;
            uint256 deadline = block.timestamp + 60;
            bytes32 payload = keccak256(abi.encode(block.chainid, vault, gift.handleHash(), address(0xCAFE1), deadline, nonce));
            bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(12345, digest);
            gift.manageByProof(address(0xCAFE1), deadline, nonce, abi.encodePacked(r, s, v));
            uint256 before = MigrationERC20(BNCB).balanceOf(address(0xCAFE1));
            gift.claim();
            assertGt(MigrationERC20(BNCB).balanceOf(address(0xCAFE1)), before, "gift recipient paid");
        } else if (variant == 3) {
            uint256 before = MigrationERC20(token).balanceOf(DEAD);
            (, uint256 burned) = StoxesBnbBuybackBurnVault(payable(vault)).execute();
            if (burned == 0) {
                // The first V2 execution seeds its TWAP observation without
                // spending. Demand a successful later execution, not just a
                // passing "no progress" response.
                assertEq(MigrationERC20(token).balanceOf(DEAD), before);
                vm.warp(block.timestamp + 1801);
                (, burned) = StoxesBnbBuybackBurnVault(payable(vault)).execute();
            }
            assertGt(burned, 0, "vault buyback executed");
            assertGt(MigrationERC20(token).balanceOf(DEAD), before, "vault tokens burned");
        } else if (variant == 4) {
            uint256 before = MigrationERC20(BNCB).balanceOf(address(0xA1100));
            vm.prank(address(0xA1100));
            uint256 paid = StoxesBnbStocksVault(payable(vault)).claim();
            assertGt(paid, 0, "holder dividend claim");
            assertEq(MigrationERC20(BNCB).balanceOf(address(0xA1100)), before + paid);
        }
        console2.log("PASS vault beneficiary balance delta, variant", variant);
    }
}