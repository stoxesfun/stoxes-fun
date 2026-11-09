// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {BnbTaxAllocation} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {
    TokenLaneCloneDeployer,
    TokenLanePortal,
    TokenLanePair
} from "./mocks/TokenLaneMocks.sol";

contract StoxesBnbTaxTokenTest is Test {
    StoxesBnbTaxToken token;
    TokenLanePortal portal;
    TokenLanePair pair;
    MockERC20 quote;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _taxTokenImplementation() internal virtual returns (address) {
        return address(new StoxesBnbTaxToken());
    }

    function setUp() public {
        quote = new MockERC20("Quote", "Q", 18);
        portal = new TokenLanePortal(address(quote));
        address implementation = _taxTokenImplementation();
        TokenLaneCloneDeployer deployer = new TokenLaneCloneDeployer();
        token = StoxesBnbTaxToken(deployer.clone(address(implementation), bytes32("tax")));
        token.initialize(
            StoxesBnbTaxToken.InitParams({
                name: "Tax",
                symbol: "TAX",
                metaURI: "ipfs://tax",
                buyTaxBps: 500,
                sellTaxBps: 1000,
                allocation: BnbTaxAllocation(2500, 2500, 2500, 2500),
                commissionReceiver: address(0xC0DE),
                vault: address(0xBA17),
                balanceHook: address(0),
                creator: address(this),
                quoteToken: address(quote),
                portal: address(portal),
                taxProcessor: address(this)
            })
        );
        token.transfer(address(portal), token.totalSupply());
        pair = new TokenLanePair(address(token), address(quote));
        portal.startTax(address(token));
        portal.finishTax(address(token), address(pair));
        portal.move(address(token), address(pair), 100_000_000 ether);
        quote.mint(address(pair), 100_000_000 ether);
        pair.seed(100_000_000 ether, 100_000_000 ether);
    }

    function testRenouncedAndConfiguration() public view {
        assertEq(token.owner(), address(0));
        assertEq(token.getOwner(), address(0));
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1000);
        assertEq(token.commissionBps(), 60);
    }

    function testBondingOnlyPortalMediatedTransfers() public {
        address implementation = _taxTokenImplementation();
        TokenLaneCloneDeployer deployer = new TokenLaneCloneDeployer();
        StoxesBnbTaxToken fresh =
            StoxesBnbTaxToken(deployer.clone(address(implementation), bytes32("fresh")));
        fresh.initialize(
            StoxesBnbTaxToken.InitParams({
                name: "Fresh",
                symbol: "FR",
                metaURI: "",
                buyTaxBps: 0,
                sellTaxBps: 0,
                allocation: BnbTaxAllocation(0, 0, 0, 0),
                commissionReceiver: address(0),
                vault: address(0xBA17),
                balanceHook: address(0),
                creator: address(this),
                quoteToken: address(quote),
                portal: address(portal),
                taxProcessor: address(this)
            })
        );
        vm.expectRevert(StoxesBnbTaxToken.TransferBlocked.selector);
        fresh.transfer(alice, 1 ether);
        fresh.transfer(address(portal), 2 ether);
        portal.move(address(fresh), alice, 1 ether);
        assertEq(fresh.balanceOf(alice), 1 ether);
        vm.prank(alice);
        fresh.approve(address(0xBA17), 0.4 ether);
        vm.prank(address(0xBA17));
        fresh.vaultBurn(alice, 0.4 ether);
        assertEq(fresh.balanceOf(address(0xdead)), 0.4 ether);
        assertEq(fresh.burned(), 0.4 ether);
    }

    function testVaultBurnUsesDeadWalletAfterGraduation() public {
        vm.prank(address(pair));
        token.transfer(alice, 10 ether);
        uint256 amount = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(0xBA17), amount);
        vm.prank(address(0xBA17));
        token.vaultBurn(alice, amount);
        assertEq(token.balanceOf(address(0xdead)), amount);
        assertEq(token.burned(), amount);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function testRegressionMigratingFreezesHolderTransfers() public {
        address implementation = _taxTokenImplementation();
        StoxesBnbTaxToken fresh = StoxesBnbTaxToken(
            new TokenLaneCloneDeployer().clone(address(implementation), bytes32("migrating"))
        );
        fresh.initialize(
            StoxesBnbTaxToken.InitParams({
                name: "Migrating",
                symbol: "MIG",
                metaURI: "",
                buyTaxBps: 0,
                sellTaxBps: 0,
                allocation: BnbTaxAllocation(0, 0, 0, 0),
                commissionReceiver: address(0),
                vault: address(0),
                balanceHook: address(0),
                creator: address(this),
                quoteToken: address(quote),
                portal: address(portal),
                taxProcessor: address(this)
            })
        );
        fresh.transfer(address(portal), fresh.totalSupply());
        portal.move(address(fresh), alice, 10 ether);
        vm.startPrank(address(portal));
        fresh.setMigrationOperator(address(0x600D));
        fresh.startMigration();
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(StoxesBnbTaxToken.TransferBlocked.selector);
        fresh.transfer(bob, 1 ether);
        vm.prank(alice);
        vm.expectRevert(StoxesBnbTaxToken.TransferBlocked.selector);
        fresh.transfer(address(pair), 1 ether);
    }

    function testBuySellTaxOnlyPoolAndProtocolAccounting() public {
        pair.sendToken(address(token), alice, 100 ether);
        assertEq(token.balanceOf(alice), 95 ether);
        assertEq(token.pendingTax(), 5 ether);
        assertEq(token.protocolPending(), 0.3 ether);

        vm.prank(alice);
        token.transfer(bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.pendingTax(), 5 ether);

        vm.prank(alice);
        token.transfer(address(pair), 20 ether);
        assertEq(token.pendingTax(), 7 ether);
        assertEq(token.protocolPending(), 0.36 ether);
    }

    function testLargeWalletAndFullTransferImmediatelyAfterGraduation() public {
        assertEq(block.timestamp, token.graduatedAt());
        portal.move(address(token), alice, 600_000_000 ether);
        vm.prank(alice);
        token.transfer(bob, 600_000_000 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 600_000_000 ether);
        assertEq(token.pendingTax(), 0, "ordinary transfers remain untaxed");
    }

    function testRepeatedLargeBuysAndFullIntermediarySellInSameBlock() public {
        assertEq(block.timestamp, token.graduatedAt());
        pair.sendToken(address(token), alice, 20_000_000 ether);
        pair.sendToken(address(token), alice, 30_000_000 ether);
        uint256 bought = 47_500_000 ether;
        assertEq(token.balanceOf(alice), bought);
        address router = address(0xA660);
        vm.prank(alice);
        token.approve(router, bought);
        vm.prank(router);
        token.transferFrom(alice, bob, bought);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), bought, "intermediary custody has no cap");
        vm.prank(bob);
        token.approve(router, bought);
        vm.prank(router);
        token.transferFrom(bob, address(pair), bought);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.pendingTax(), 7_250_000 ether, "buy and sell taxes unchanged");
        assertEq(token.protocolPending(), 292_500 ether, "protocol accounting unchanged");
        assertEq(block.timestamp, token.graduatedAt(), "no waiting period");
    }

    function testFuzzUncappedImmediateTransfers(uint256 seed) public {
        uint256 amount = bound(seed, token.MAX_SUPPLY() / 100 + 1, 900_000_000 ether);
        portal.move(address(token), alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(block.timestamp, token.graduatedAt());
    }

    function testBalanceAndAllowanceChecksRemainForLargeTransfers() public {
        portal.move(address(token), alice, 50_000_000 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 50_000_000 ether + 1);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 50_000_000 ether);
        vm.prank(alice);
        token.approve(bob, 50_000_000 ether - 1);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 50_000_000 ether);
        assertEq(token.balanceOf(alice), 50_000_000 ether);
    }

    function testHarvestAccessAndCap() public {
        pair.sendToken(address(token), alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(StoxesBnbTaxToken.NotProcessor.selector);
        token.harvestTax(1 ether);
        uint256 amount = token.harvestTax(2 ether);
        assertEq(amount, 2 ether);
        assertEq(token.balanceOf(address(this)), 2 ether);
        assertEq(token.pendingTax(), 3 ether);
        assertEq(token.protocolPending(), 0.18 ether);
    }
}