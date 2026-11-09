// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface ILiveBurnToken {
    function pendingTax() external view returns (uint256);
    function protocolPending() external view returns (uint256);
    function mainPool() external view returns (address);
    function taxProcessor() external view returns (address);
    function vault() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ILiveBurnProcessor {
    function process(address) external returns (uint256);
    function warmObservation(address) external;
    function observationOf(address) external view returns (uint256, uint32, bool);
    function minThreshold() external view returns (uint256);
    function TWAP_WINDOW() external view returns (uint32);
}

interface ILiveBurnPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface ILiveBurnVault {
    function totalBnbBurned() external view returns (uint256);
}

interface ILiveBurnRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata, address, uint256
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
}

/// Exercises unchanged, already-deployed contracts for the actual test token.
/// No etch, storage writes, owner overrides, synthetic token balances, or new pools.
/// Only the trade scenarios give a new local trader synthetic native gas/trade funds.
/// The loopback upstream bridge rejects every broadcast/signing RPC method.
contract StoxesBnbLiveBurnRecoveryForkTest is Test {
    address constant TOKEN = address(bytes20(hex"18978a42f0efb5d6c02d613137335113bee19999"));
    address constant PROCESSOR = address(bytes20(hex"febd1f41fcd25212b43d3d8710e2ea0824e57962"));
    address constant PAIR = address(bytes20(hex"786616ba05d6ee95983dab420b30b4c0598d9c31"));
    address constant VAULT = address(bytes20(hex"becafea6eb879fd8c0b5383e3ed2e8c4789f5271"));
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    address constant DEAD = address(0xdead);
    address constant TRADER = address(0xB0B);
    bytes4 constant FLOOR_NOT_MET = bytes4(keccak256("FloorNotMet()"));
    ILiveBurnToken constant token = ILiveBurnToken(TOKEN);
    ILiveBurnProcessor constant processor = ILiveBurnProcessor(PROCESSOR);
    ILiveBurnVault constant vault = ILiveBurnVault(VAULT);
    bytes32 private originalCodeHashes;

    function setUp() public {
        if (!vm.envOr("RUN_BNB_LIVE_BURN_RECOVERY_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_BURN_RECOVERY_FORK_BLOCK"));
        assertEq(block.chainid, 56);
        assertEq(token.taxProcessor(), PROCESSOR);
        assertEq(token.mainPool(), PAIR);
        assertEq(token.vault(), VAULT);
        assertEq(processor.TWAP_WINDOW(), 1800);
        assertEq(ILiveBurnPair(PAIR).token0(), TOKEN);
        originalCodeHashes = _codeHashes();
        console2.log("Fork block", block.number);
        console2.log("Fork timestamp", block.timestamp);
        console2.log("Pending tax before (token wei)", token.pendingTax());
    }

    function testLiveFailureIsPriceFloorNotTaxThreshold() public {
        (uint112 reserveToken,,) = ILiveBurnPair(PAIR).getReserves();
        uint256 threshold = uint256(reserveToken) * 10 / 10_000;
        if (threshold < processor.minThreshold()) threshold = processor.minThreshold();
        assertGe(token.pendingTax(), threshold, "tax threshold already met");
        (, uint32 observedAt, bool initialized) = processor.observationOf(_sellKey());
        assertTrue(initialized);
        assertGe(block.timestamp - observedAt, 1800, "time window already met");
        uint256 pending = token.pendingTax();
        uint256 beforeBurn = vault.totalBnbBurned();
        vm.expectRevert(FLOOR_NOT_MET);
        processor.process(TOKEN);
        (, uint32 afterObservedAt,) = processor.observationOf(_sellKey());
        assertEq(afterObservedAt, observedAt, "failed process cannot refresh observation");
        assertEq(token.pendingTax(), pending);
        assertEq(vault.totalBnbBurned(), beforeBurn);
    }

    function testAnotherThirtyMinutesAloneStillFails() public {
        vm.warp(block.timestamp + 1800);
        vm.expectRevert(FLOOR_NOT_MET);
        processor.process(TOKEN);
    }

    function testRefreshRequiresFullWindowThenBurnsWithoutExtraTrades() public {
        uint256 pending = token.pendingTax();
        uint256 beforeBurn = vault.totalBnbBurned();
        uint256 refreshedAt = block.timestamp;
        processor.warmObservation(TOKEN);
        (, uint32 observedAt,) = processor.observationOf(_sellKey());
        assertEq(observedAt, refreshedAt);
        assertEq(token.pendingTax(), pending, "refresh does not move pending tax");
        assertEq(vault.totalBnbBurned(), beforeBurn, "refresh is not a burn");
        assertEq(processor.process(TOKEN), 0, "no early processing");
        vm.warp(refreshedAt + 1799);
        assertEq(processor.process(TOKEN), 0, "full 1800 seconds required");
        assertEq(vault.totalBnbBurned(), beforeBurn);
        vm.warp(refreshedAt + 1800);
        _processAndVerifyBurn();
    }

    function testRemainingTaxBurnsNextWindowWithoutAnotherRefresh() public {
        processor.warmObservation(TOKEN);
        vm.warp(block.timestamp + 1800);
        uint256 initialBurn = vault.totalBnbBurned();
        _processAndVerifyBurn();
        assertGt(token.pendingTax(), 0, "first processing is impact-clipped");
        vm.warp(block.timestamp + 1800);
        _processAndVerifyBurn();
        assertEq(token.pendingTax(), 0, "two batches clear existing tax on stable pool");
        console2.log("Total additional native BNB burned (wei)", vault.totalBnbBurned() - initialBurn);
    }

    function testSmallRoundTripAddsTaxButDoesNotResolveFloor() public {
        uint256 pending = token.pendingTax();
        _buy(0.01 ether);
        _sellAll();
        assertGt(token.pendingTax(), pending, "round trip accumulates more tax");
        vm.expectRevert(FLOOR_NOT_MET);
        processor.process(TOKEN);
    }

    function testPriceRaisingBuyCanPassWithoutRefresh() public {
        // A counterfactual, not a live trading recommendation.
        _buy(0.05 ether);
        _processAndVerifyBurn();
    }

    function testAdversePriceMoveAfterRefreshStillFailsProtection() public {
        _buy(0.01 ether);
        processor.warmObservation(TOKEN);
        vm.warp(block.timestamp + 1800);
        _sellAll();
        vm.expectRevert(FLOOR_NOT_MET);
        processor.process(TOKEN);
    }

    function _processAndVerifyBurn() private {
        uint256 pendingBefore = token.pendingTax();
        uint256 burnedBefore = vault.totalBnbBurned();
        uint256 deadBefore = DEAD.balance;
        vm.recordLogs();
        uint256 quoteOut = processor.process(TOKEN);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 burnDelta = vault.totalBnbBurned() - burnedBefore;
        assertGt(quoteOut, 0, "processor must actually convert tax");
        assertGt(burnDelta, 0, "vault must actually burn native BNB");
        assertLt(token.pendingTax(), pendingBefore);
        assertEq(DEAD.balance - deadBefore, burnDelta, "native balance agrees with burn counter");
        assertEq(VAULT.balance, 0, "no native BNB retained by vault");
        assertEq(ILiveBurnToken(WBNB).balanceOf(VAULT), 0, "no WBNB retained by vault");
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == VAULT && entries[i].topics.length == 1
                && entries[i].topics[0] == keccak256("BnbBurned(uint256,uint256)")) {
                (uint256 spent, uint256 burned) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(spent, burnDelta);
                assertEq(burned, burnDelta);
                found = true;
            }
        }
        assertTrue(found, "existing vault must emit the actual burn event");
        assertEq(_codeHashes(), originalCodeHashes, "deployed runtimes remain unchanged");
        console2.log("Tax converted (token wei)", pendingBefore - token.pendingTax());
        console2.log("Processor output (BNB wei)", quoteOut);
        console2.log("Native BNB burned (wei)", burnDelta);
        console2.log("Pending tax remaining (token wei)", token.pendingTax());
    }

    function _buy(uint256 amount) private {
        // Native funding override ONLY for counterfactual trade tests.
        vm.deal(TRADER, amount + 0.01 ether);
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = TOKEN;
        vm.prank(TRADER, TRADER);
        ILiveBurnRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            1, path, TRADER, block.timestamp + 300
        );
        assertGt(token.balanceOf(TRADER), 0);
    }

    function _sellAll() private {
        address[] memory path = new address[](2);
        path[0] = TOKEN;
        path[1] = WBNB;
        vm.startPrank(TRADER, TRADER);
        token.approve(ROUTER, type(uint256).max);
        ILiveBurnRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            token.balanceOf(TRADER), 1, path, TRADER, block.timestamp + 300
        );
        vm.stopPrank();
    }

    function _sellKey() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(TOKEN, true)))));
    }

    function _codeHashes() private view returns (bytes32) {
        return keccak256(abi.encode(TOKEN.codehash, PROCESSOR.codehash, PAIR.codehash, VAULT.codehash));
    }
}
