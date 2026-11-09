// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StoxesBnbNativeBurnVault as Vault} from "../../../src/bnb/vaults/StoxesBnbNativeBurnVault.sol";
import {StoxesBnbNativeBurnVaultFactory as Factory} from "../../../src/bnb/vaults/StoxesBnbNativeBurnVaultFactory.sol";

/// All funds, approvals and writes exist ONLY in this read-only mainnet fork.
contract StoxesBnbNativeBurnRoutesForkTest is Test {
    string private plan;
    address private tokenFactory;
    Factory private extension;

    function setUp() public {
        if (!vm.envOr("RUN_BNB_NATIVE_BURN_FORK", false)) { vm.skip(true); return; }
        plan = vm.readFile("docs/bnb-native-burn-plan.json");
        uint256 forkBlock = vm.parseUint(vm.parseJsonString(plan, ".block"));
        vm.createSelectFork("http://127.0.0.1:18546", forkBlock);
        tokenFactory = vm.parseJsonAddress(plan, ".tokenFactory");
        extension = new Factory(tokenFactory, address(this),
            vm.parseJsonAddress(plan, ".constructorArgs[2]"),
            vm.parseJsonAddress(plan, ".constructorArgs[3]"));
        console2.log("Pinned block", forkBlock);
    }

    function testEveryConfiguredStockConvertsAtItsImmutableCapAndRetries() public {
        uint256 count = vm.parseJsonUint(plan, ".routeCount");
        for (uint256 i; i < count; i++) _check(i);
    }

    function _check(uint256 i) private {
        string memory prefix = string.concat(".routes[", vm.toString(i), "]");
        address stock = vm.parseJsonAddress(plan, string.concat(prefix, ".stock"));
        uint256 cap = vm.parseUint(vm.parseJsonString(plan, string.concat(prefix, ".maxAmountIn")));
        extension.setQuoteRoute(stock,
            vm.parseJsonAddress(plan, string.concat(prefix, ".pool0")),
            vm.parseJsonAddress(plan, string.concat(prefix, ".pool1")), cap);
        vm.prank(tokenFactory);
        Vault vault = Vault(payable(extension.newVault(address(uint160(0x1000 + i)), stock, address(this), "")));
        // Synthetic balance only; all pool, stock and wrapper runtimes are mainnet.
        deal(stock, address(vault), cap * 2);
        vault.ping();
        uint256 sinkBefore = address(0xdead).balance;
        (uint256 spent, uint256 burned) = vault.convertAndBurn();
        assertEq(spent, cap);
        assertGt(burned, 0);
        assertEq(address(0xdead).balance - sinkBefore, burned);
        assertEq(vault.accountedQuote(), cap);
        (uint256 spentAgain, uint256 burnedAgain) = vault.convertAndBurn();
        assertEq(spentAgain, cap);
        assertGt(burnedAgain, 0);
        assertEq(vault.accountedQuote(), 0);
        assertEq(vault.totalBnbBurned(), burned + burnedAgain);
        assertEq(address(vault).balance, 0);
        console2.log(vm.parseJsonString(plan, string.concat(prefix, ".symbol")), burned);
    }
}
