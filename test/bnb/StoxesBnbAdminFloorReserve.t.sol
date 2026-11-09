// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StoxesBnbAdminFloorReserveVault} from "../../src/bnb/vaults/StoxesBnbAdminFloorReserveVault.sol";
import {StoxesBnbAdminFloorReserveVaultFactory} from "../../src/bnb/vaults/StoxesBnbAdminFloorReserveVaultFactory.sol";
import {StoxesBnbVaultFactoryBase} from "../../src/bnb/vaults/StoxesBnbVaultFactoryBase.sol";
import {IStoxesBnbTaxToken, BnbCreateParams, BnbLaunchKind, BnbTaxAllocation} from "../../src/bnb/IStoxesBnb.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";

contract AdminFloorPortalMock {
    address public WBNB;
    address public graduator = address(0x123);
    constructor(address w) { WBNB = w; }
}

contract AdminFloorMainMock {
    address public owner;
    address public portal;
    address public WBNB;
    bool public launchesOpen;
    constructor(address p, address w) { owner = msg.sender; portal = p; WBNB = w; }
    function setOwner(address o) external { require(msg.sender == owner); owner = o; }
    function create(StoxesBnbAdminFloorReserveVaultFactory f, address t, address q, address c) external returns(address) {
        return f.newVault(t, q, c, abi.encode(uint16(0)));
    }
}

contract AdminFloorTokenMock is MockERC20 {
    IStoxesBnbTaxToken.Phase public phase;
    constructor() MockERC20("Launch", "L", 18) {}
    function setPhase(IStoxesBnbTaxToken.Phase p) external { phase = p; }
    function vaultBurn(address holder, uint256 amount) external {
        balanceOf[holder] -= amount;
        balanceOf[address(0xdead)] += amount;
    }
}

contract AdminFloorCallbackStock is MockERC20 {
    StoxesBnbAdminFloorReserveVault public vault;
    bool public fail;
    bool public blocked;
    constructor(uint8 d) MockERC20("Stock", "S", d) {}
    function configure(StoxesBnbAdminFloorReserveVault v, bool f) external { vault = v; fail = f; }
    function transfer(address to, uint256 amount) public override returns(bool) {
        // Callback BEFORE balances change exercises the dangerous sync window.
        if (address(vault) != address(0) && msg.sender == address(vault)) {
            (bool a,) = address(vault).call(abi.encodeCall(vault.withdrawReserve, (to, 1)));
            (bool b,) = address(vault).call(abi.encodeCall(vault.redeem, (1, 0)));
            (bool c,) = address(vault).call(abi.encodeCall(vault.ping, ()));
            require(!a && !b && !c, "callback succeeded");
            blocked = true;
        }
        if (fail) return false;
        return super.transfer(to, amount);
    }
    function withdraw(address to, uint256 amount) external { vault.withdrawReserve(to, amount); }
}

contract AdminFloorNativeReceiver {
    StoxesBnbAdminFloorReserveVault public vault;
    bool public fail;
    bool public blocked;
    function configure(StoxesBnbAdminFloorReserveVault v, bool f) external { vault = v; fail = f; }
    function withdraw(uint256 amount) external { vault.withdrawReserve(address(this), amount); }
    receive() external payable {
        require(!fail, "reject native");
        (bool a,) = address(vault).call(abi.encodeCall(vault.withdrawReserve, (address(this), 1)));
        (bool b,) = address(vault).call(abi.encodeCall(vault.redeem, (1, 0)));
        (bool c,) = address(vault).call(abi.encodeCall(vault.ping, ()));
        require(!a && !b && !c, "callback succeeded");
        blocked = true;
    }
}

contract StoxesBnbAdminFloorReserveTest is Test {
    MockWETH weth;
    AdminFloorCallbackStock stock;
    AdminFloorTokenMock token;
    AdminFloorMainMock main;
    AdminFloorPortalMock portal;
    StoxesBnbAdminFloorReserveVaultFactory factory;
    StoxesBnbAdminFloorReserveVault vault;
    address creator = address(0xCAFE);
    address recipient = address(0xBEEF);

    receive() external payable {}

    function setUp() public {
        weth = new MockWETH();
        stock = new AdminFloorCallbackStock(6);
        token = new AdminFloorTokenMock();
        portal = new AdminFloorPortalMock(address(weth));
        main = new AdminFloorMainMock(address(portal), address(weth));
        factory = new StoxesBnbAdminFloorReserveVaultFactory(address(main), address(0xFACA), address(portal));
        vault = _vault(address(stock));
        token.mint(creator, 1_000 ether);
        stock.mint(address(vault), 1_000_000);
        vault.ping();
    }

    function _vault(address quote) internal returns(StoxesBnbAdminFloorReserveVault) {
        return StoxesBnbAdminFloorReserveVault(payable(main.create(factory, address(token), quote, creator)));
    }

    function testVersionAndFactoryProvenanceAndPortalValidation() public {
        assertEq(factory.adminWithdrawalVersion(), 1);
        assertEq(vault.adminWithdrawalVersion(), 1);
        assertEq(vault.tokenFactory(), address(main));
        vm.expectRevert(StoxesBnbVaultFactoryBase.NotTokenFactory.selector);
        factory.newVault(address(token), address(stock), creator, abi.encode(uint16(0)));
        AdminFloorPortalMock wrong = new AdminFloorPortalMock(address(weth));
        vm.expectRevert();
        new StoxesBnbAdminFloorReserveVaultFactory(address(main), address(this), address(wrong));
        vm.expectRevert();
        new StoxesBnbAdminFloorReserveVault(address(token), address(stock), creator, address(wrong), address(main));
        vm.prank(address(main));
        vm.expectRevert();
        factory.newVault(address(token), address(stock), creator, abi.encode(uint16(1)));
    }

    function testLaunchPolicyPreserved() public {
        BnbCreateParams memory p;
        p.kind = BnbLaunchKind.Tax;
        p.allocation = BnbTaxAllocation(2000, 0, 0, 8000);
        p.vaultData = abi.encode(uint16(0));
        factory.onBeforeLaunch(p, creator);
        p.kind = BnbLaunchKind.Simple;
        vm.expectRevert(); factory.onBeforeLaunch(p, creator);
        p.kind = BnbLaunchKind.Tax;
        p.allocation.vaultBps = 1999;
        vm.expectRevert(); factory.onBeforeLaunch(p, creator);
        p.allocation.vaultBps = 2000;
        p.vaultData = abi.encode(uint16(1));
        vm.expectRevert(); factory.onBeforeLaunch(p, creator);
        p.vaultData = "";
        vm.expectRevert(); factory.onBeforeLaunch(p, creator);
        p.vaultData = abi.encode(uint16(0));
        vm.expectRevert(); factory.onBeforeLaunch(p, address(0));
    }

    function testUnauthorizedCreatorKeeperArbitraryAndSubfactoryOwner() public {
        address[4] memory denied = [creator, address(0xB077), recipient, factory.owner()];
        for (uint256 i; i < denied.length; ++i) {
            vm.prank(denied[i]);
            vm.expectRevert(StoxesBnbAdminFloorReserveVault.NotReserveAdmin.selector);
            vault.withdrawReserve(recipient, 1);
        }
        assertEq(vault.reserve(), 1_000_000);
    }

    function testRotationAndZeroOwnerFailClosedWhileLaunchesClosed() public {
        assertFalse(main.launchesOpen());
        vault.withdrawReserve(recipient, 1);
        main.setOwner(creator);
        assertEq(vault.reserveAdmin(), creator);
        vm.expectRevert(StoxesBnbAdminFloorReserveVault.NotReserveAdmin.selector);
        vault.withdrawReserve(recipient, 1);
        vm.startPrank(creator);
        vault.withdrawReserve(recipient, 1);
        // Production OwnableLite has no renounce method. Model a zero owner to
        // prove fail-closed behavior should a future main factory support it.
        main.setOwner(address(0));
        vm.expectRevert(StoxesBnbAdminFloorReserveVault.NotReserveAdmin.selector);
        vault.withdrawReserve(recipient, 1);
        vm.stopPrank();
        vm.prank(address(0));
        vm.expectRevert(StoxesBnbAdminFloorReserveVault.NotReserveAdmin.selector);
        vault.withdrawReserve(recipient, 1);
    }

    function testInvalidInputsAndFullDrainNoBurn() public {
        vm.expectRevert(); vault.withdrawReserve(address(0), 1);
        vm.expectRevert(); vault.withdrawReserve(address(vault), 1);
        vm.expectRevert(); vault.withdrawReserve(recipient, 0);
        vm.expectRevert(); vault.withdrawReserve(recipient, 1_000_001);
        uint256 supply = token.totalSupply();
        uint256 circulation = vault.circulatingSupply();
        vault.withdrawReserve(recipient, 1_000_000);
        assertEq(vault.reserve(), 0);
        assertEq(stock.balanceOf(recipient), 1_000_000);
        assertEq(token.totalSupply(), supply);
        assertEq(vault.circulatingSupply(), circulation);
        assertEq(vault.floorPrice(), 0);
        vm.prank(creator);
        assertEq(vault.redeem(1 ether, 0), 0);
    }

    function testDonationsSyncWithdrawalThenHolderRedemption() public {
        stock.mint(address(vault), 200_000);
        vault.withdrawReserve(recipient, 400_000);
        assertEq(vault.reserve(), 800_000);
        assertEq(vault.floorPrice(), 800);
        vm.prank(creator);
        assertEq(vault.redeem(250 ether, 200_000), 200_000);
        assertEq(vault.reserve(), 600_000);
        assertEq(stock.balanceOf(creator), 200_000);
        vm.prank(creator);
        assertEq(vault.redeem(750 ether, 600_000), 600_000);
        assertEq(vault.reserve(), 0);
        assertEq(vault.circulatingSupply(), 0);
    }

    function testErc20CallbackAndFailureRollbackIncludingDonationSync() public {
        stock.configure(vault, false);
        main.setOwner(address(stock)); // Reentry caller really IS current admin.
        stock.withdraw(recipient, 250_000);
        assertTrue(stock.blocked());
        assertEq(vault.reserve(), stock.balanceOf(address(vault)));
        stock.configure(vault, true);
        stock.mint(address(vault), 123);
        vm.expectRevert(); stock.withdraw(recipient, 750_123);
        assertEq(vault.reserve(), 750_000);
        assertEq(stock.balanceOf(address(vault)), 750_123);
        assertEq(stock.balanceOf(recipient), 250_000);
    }

    function testNativeWbnbFundedFullDrainCallbacksAndFailureRollback() public {
        vault = _vault(address(weth));
        vm.deal(address(this), 2 ether);
        weth.deposit{value: 2 ether}();
        weth.transfer(address(vault), 1 ether);
        AdminFloorNativeReceiver receiver = new AdminFloorNativeReceiver();
        receiver.configure(vault, false);
        main.setOwner(address(receiver));
        receiver.withdraw(1 ether); // unsynced WBNB donation -> native BNB.
        assertTrue(receiver.blocked());
        assertEq(address(receiver).balance, 1 ether);
        assertEq(weth.balanceOf(address(receiver)), 0);
        assertEq(vault.reserve(), 0);
        weth.transfer(address(vault), 1 ether);
        receiver.configure(vault, true);
        vm.expectRevert(StoxesBnbAdminFloorReserveVault.NativeTransferFailed.selector);
        receiver.withdraw(1 ether);
        assertEq(vault.reserve(), 0); // sync was rolled back as well
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function testPhaseAwareCirculation() public {
        token.mint(address(portal), 100 ether);
        token.mint(portal.graduator(), 200 ether);
        token.mint(address(token), 30 ether);
        token.mint(address(0), 10 ether);
        token.mint(address(0xdead), 20 ether);
        token.setPhase(IStoxesBnbTaxToken.Phase.BondingCurve);
        assertEq(vault.circulatingSupply(), 1200 ether);
        token.setPhase(IStoxesBnbTaxToken.Phase.Migrating);
        assertEq(vault.circulatingSupply(), 1100 ether);
        token.setPhase(IStoxesBnbTaxToken.Phase.TaxEnforced);
        assertEq(vault.circulatingSupply(), 1300 ether);
        vault.withdrawReserve(recipient, 100);
        assertEq(vault.circulatingSupply(), 1300 ether);
    }

    function testFuzzCustomDecimals(uint8 decimalsSeed, uint96 amountSeed) public {
        uint8 decimals = uint8(bound(decimalsSeed, 0, 24));
        uint256 amount = bound(uint256(amountSeed), 2, type(uint96).max);
        AdminFloorCallbackStock custom = new AdminFloorCallbackStock(decimals);
        vault = _vault(address(custom));
        custom.mint(address(vault), amount);
        vault.withdrawReserve(recipient, amount / 2);
        assertEq(custom.balanceOf(recipient), amount / 2);
        assertEq(vault.reserve(), amount - amount / 2);
        vm.prank(creator);
        assertEq(vault.redeem(1000 ether, 0), amount - amount / 2);
        assertEq(vault.reserve(), 0);
    }
}