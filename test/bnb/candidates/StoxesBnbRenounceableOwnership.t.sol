// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20CloneBase} from "../../../src/base/ERC20CloneBase.sol";
import {StoxesBnbRenounceableTaxToken as Candidate} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {BnbTaxAllocation, IStoxesBnbTaxToken} from "../../../src/bnb/IStoxesBnb.sol";
import {TokenLaneCloneDeployer} from "../mocks/TokenLaneMocks.sol";

contract RenounceableOwnershipTest is Test {
    Candidate token;
    Candidate implementation;
    address portal = address(0x1001);
    address processor = address(0x1002);
    address vault = address(0x1003);
    address pair = address(0x1004);
    address holder = address(0x1005);
    address operator = address(0x1006);
    address outsider = address(0x1007);
    Candidate.InitParams params;

    function setUp() public {
        implementation = new Candidate();
        token = Candidate(new TokenLaneCloneDeployer().clone(address(implementation), bytes32("candidate")));
        params = Candidate.InitParams({
            name: "Candidate", symbol: "CAND", metaURI: "", buyTaxBps: 500, sellTaxBps: 500,
            allocation: BnbTaxAllocation(2500, 2500, 2500, 2500),
            commissionReceiver: address(0), vault: vault, balanceHook: address(0),
            creator: address(this), quoteToken: address(0x2001), portal: portal, taxProcessor: processor
        });
        token.initialize(params);
        token.transfer(portal, token.totalSupply());
        vm.prank(portal);
        token.transfer(holder, 1000 ether);
    }

    function _start() internal {
        vm.startPrank(portal);
        token.setMigrationOperator(operator);
        token.startMigration();
        vm.stopPrank();
    }

    function _graduate() internal {
        _start();
        vm.prank(portal);
        token.finalizeMigration(pair);
    }

    function testTruthfulOwnerBeforeGraduationAndLockedImplementation() public {
        assertEq(token.owner(), portal);
        assertEq(token.getOwner(), portal);
        assertEq(token.totalSupply(), 1e9 ether);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        implementation.initialize(params);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        token.initialize(params);
    }

    function testNoEarlyRenounceOrTransferInEitherPendingPhase() public {
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(portal);
            vm.expectRevert(Candidate.GraduationNotFinalized.selector);
            token.renounceOwnership();
            vm.expectRevert(Candidate.MigrationOwnerFixed.selector);
            token.transferOwnership(outsider);
            vm.expectRevert(Candidate.MigrationOwnerFixed.selector);
            token.transferOwnership(address(0));
            vm.stopPrank();
            assertEq(token.owner(), portal);
            if (i == 0) _start();
        }
    }

    function testOutsiderCannotControlMigration() public {
        vm.startPrank(outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.startMigration();
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.setMigrationOperator(outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.finalizeMigration(pair);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.renounceOwnership();
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.transferOwnership(outsider);
        vm.stopPrank();
    }

    function testRejectedFinalizationPreservesOwnerAndDeferredRecovery() public {
        vm.prank(portal);
        vm.expectRevert(Candidate.InvalidParams.selector);
        token.finalizeMigration(pair);
        _start();
        vm.prank(portal);
        vm.expectRevert(Candidate.InvalidParams.selector);
        token.finalizeMigration(address(0));
        assertEq(token.owner(), portal);
        assertEq(token.mainPool(), address(0));
        assertEq(uint256(token.phase()), uint256(IStoxesBnbTaxToken.Phase.Migrating));
        vm.warp(block.timestamp + 30 days);
        vm.prank(portal);
        token.finalizeMigration(pair);
        assertEq(token.owner(), address(0));
        assertEq(token.mainPool(), pair);
    }

    function testGraduationEmitsRealRevocationAndCannotRecoverOwnership() public {
        _start();
        vm.recordLogs();
        vm.prank(portal);
        token.finalizeMigration(pair);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(token));
        assertEq(last.topics[0], keccak256("OwnershipTransferred(address,address)"));
        assertEq(last.topics[1], bytes32(uint256(uint160(portal))));
        assertEq(last.topics[2], bytes32(0));
        assertEq(token.owner(), address(0));
        assertEq(token.getOwner(), address(0));
        vm.startPrank(portal);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.startMigration();
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.setMigrationOperator(outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.finalizeMigration(outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.transferOwnership(portal);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.renounceOwnership();
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        token.initialize(params);
        vm.stopPrank();
        assertEq(token.mainPool(), pair);
    }

    function testOperatorIsOneTimeAndTransfersRemainFrozenDuringMigration() public {
        _start();
        vm.prank(portal);
        vm.expectRevert(Candidate.InvalidParams.selector);
        token.setMigrationOperator(outsider);
        vm.prank(holder);
        vm.expectRevert(Candidate.TransferBlocked.selector);
        token.transfer(outsider, 1 ether);
        vm.prank(operator);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        token.finalizeMigration(pair);
    }

    function testVaultNeedsItsOwnAllowanceInEveryPhase() public {
        for (uint256 i; i < 3; ++i) {
            vm.prank(holder);
            token.approve(outsider, 100 ether);
            vm.prank(outsider);
            vm.expectRevert(Candidate.NotVault.selector);
            token.vaultBurn(holder, 100 ether);
            vm.prank(vault);
            vm.expectRevert(abi.encodeWithSelector(
                ERC20CloneBase.ERC20InsufficientAllowance.selector, vault, 0, 100 ether
            ));
            token.vaultBurn(holder, 100 ether);
            vm.prank(holder);
            token.approve(vault, 100 ether);
            vm.prank(vault);
            token.vaultBurn(holder, 100 ether);
            assertEq(token.allowance(holder, vault), 0);
            assertEq(token.balanceOf(holder), (900 - 100 * i) * 1 ether);
            assertEq(token.burned(), (i + 1) * 100 ether);
            assertEq(token.totalSupply(), 1e9 ether, "preserve dead-address burn economics");
            if (i == 0) _start();
            if (i == 1) {
                vm.prank(portal);
                token.finalizeMigration(pair);
            }
        }
    }

    function testTaxesFullExitAndProtocolAccountingSurviveRenouncement() public {
        _graduate();
        vm.prank(holder);
        token.transfer(pair, 1000 ether); // Full holder exit, 5% sell tax.
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(pair), 950 ether);
        assertEq(token.pendingTax(), 50 ether);
        assertEq(token.protocolPending(), 3 ether);
        vm.prank(outsider);
        vm.expectRevert(Candidate.NotProcessor.selector);
        token.harvestTax(type(uint256).max);
        vm.prank(processor);
        assertEq(token.harvestTax(25 ether), 25 ether);
        assertEq(token.protocolPending(), 1.5 ether);
        vm.prank(processor);
        assertEq(token.harvestTax(type(uint256).max), 25 ether);
        assertEq(token.protocolPending(), 0);
        assertEq(token.pendingTax(), 0);
        assertEq(token.balanceOf(processor), 50 ether);
        assertEq(token.owner(), address(0));
    }

    function testFuzzApprovedBurnCannotExceedApproval(uint96 seed) public {
        uint256 amount = bound(uint256(seed), 1, 1000 ether);
        vm.prank(holder);
        token.approve(vault, amount - 1);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(
            ERC20CloneBase.ERC20InsufficientAllowance.selector, vault, amount - 1, amount
        ));
        token.vaultBurn(holder, amount);
        assertEq(token.balanceOf(holder), 1000 ether);
        assertEq(token.allowance(holder, vault), amount - 1);
    }
}