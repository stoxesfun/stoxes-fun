// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbFloorReserveTest} from "./StoxesBnbFloorReserve.t.sol";
import {StoxesBnbAdminFloorReserveVault} from "../../src/bnb/vaults/StoxesBnbAdminFloorReserveVault.sol";
import {StoxesBnbAdminFloorReserveVaultFactory} from "../../src/bnb/vaults/StoxesBnbAdminFloorReserveVaultFactory.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {BnbCreateParams, BnbLaunchKind, BnbFeeMode, BnbTaxAllocation} from "../../src/bnb/IStoxesBnb.sol";

/// Reuse the authentic full launch fixture without modifying legacy source/tests.
contract StoxesBnbAdminFloorIntegrationTest is StoxesBnbFloorReserveTest {
    function _adminLaunch(address quote) internal returns(StoxesBnbTaxToken t, StoxesBnbAdminFloorReserveVault v) {
        StoxesBnbAdminFloorReserveVaultFactory af =
            new StoxesBnbAdminFloorReserveVaultFactory(address(factory), address(this), address(portal));
        factory.setVaultFactoryAllowed(address(af), true);
        BnbCreateParams memory p;
        p.version = 1;
        p.kind = BnbLaunchKind.Tax;
        p.name = "Admin Floor";
        p.symbol = "AF";
        p.quoteToken = quote;
        p.buyTaxBps = 500;
        p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(10_000, 0, 0, 0);
        p.feeMode = BnbFeeMode.Creator;
        p.vaultFactory = address(af);
        p.vaultData = abi.encode(uint16(0));
        (address tokenAddress, address vaultAddress,,) = factory.createToken(p);
        t = StoxesBnbTaxToken(tokenAddress);
        v = StoxesBnbAdminFloorReserveVault(payable(vaultAddress));
    }

    function testRealMainFactoryNativeWithdrawalAndRotation() public {
        (StoxesBnbTaxToken t, StoxesBnbAdminFloorReserveVault v) = _adminLaunch(address(0));
        address holder = address(0xAAA);
        vm.deal(holder, 1 ether);
        vm.prank(holder, holder);
        portal.buy{value: 0.2 ether}(address(t), 0);
        assertGt(v.reserve(), 0);
        uint256 before = v.reserve();
        uint256 balance = t.balanceOf(holder);
        factory.setLaunchesOpen(false);
        v.withdrawReserve(address(0xBBB), before / 2);
        assertEq(t.balanceOf(holder), balance);
        factory.transferOwnership(address(0xCCC));
        vm.expectRevert(); v.withdrawReserve(address(0xBBB), 1);
        vm.prank(address(0xCCC));
        v.withdrawReserve(address(0xBBB), 1);
        uint256 remaining = v.reserve();
        vm.startPrank(holder);
        t.approve(address(v), balance);
        assertEq(v.redeem(balance, remaining), remaining);
        vm.stopPrank();
        assertEq(v.reserve(), 0);
    }

    function testRealMainFactorySixDecimalStockWithdrawalAndRedemption() public {
        (StoxesBnbTaxToken t, StoxesBnbAdminFloorReserveVault v) = _adminLaunch(address(stock));
        address holder = address(0xAAA);
        stock.mint(holder, 500_000);
        vm.startPrank(holder, holder);
        stock.approve(address(portal), 500_000);
        portal.buyWithQuote(address(t), 500_000, 0);
        t.approve(address(v), type(uint256).max);
        vm.stopPrank();
        uint256 before = v.reserve();
        v.withdrawReserve(address(0xBBB), before / 3);
        assertEq(stock.balanceOf(address(0xBBB)), before / 3);
        uint256 remaining = v.reserve();
        uint256 holderBalance = t.balanceOf(holder);
        vm.prank(holder);
        assertEq(v.redeem(holderBalance, remaining), remaining);
        assertEq(v.reserve(), 0);
    }
}