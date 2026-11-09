// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StoxesBnbRoutedStocksVault as Vault} from "../../../src/bnb/vaults/StoxesBnbRoutedStocksVault.sol";
import {StoxesBnbRoutedStocksVaultFactory as Factory} from "../../../src/bnb/vaults/StoxesBnbRoutedStocksVaultFactory.sol";
import {StocksHookToken} from "../StoxesBnbStocksVault.t.sol";
import {RoutedTokenFactoryStub} from "../StoxesBnbRoutedStocksVault.t.sol";
import {IERC20BnbVault} from "../../../src/bnb/vaults/StoxesBnbVaultBase.sol";

interface IForkWrapped {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

/// @notice Explicit opt-in public-RPC fork; no broadcast/signers/secrets.
/// RUN_ROUTED_STOCKS_FORK=true forge test --match-contract StoxesBnbRoutedStocksForkTest -vv
contract StoxesBnbRoutedStocksForkTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant V3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant LAUNCH_FACTORY = 0xCd630D5987fff7D7060845F90c53c680F52d484f;
    address constant LEGACY = 0x2511394B97d4A9783e57C0Cb85F4348374827c90;
    address constant ALICE = address(0xA11CE);

    function testAllAuditedRoutesRealSwapsAndClaims() public {
        if (!vm.envOr("RUN_ROUTED_STOCKS_FORK", false)) { vm.skip(true); return; }
        string memory json = vm.readFile("docs/bnb-stock-route-audit.json");
        uint256 count;
        uint256 directCount;
        uint256 twoHopCount;
        while (vm.keyExistsJson(json, string.concat(".candidates[", vm.toString(count), "].address"))) {
            string memory root = string.concat(".candidates[", vm.toString(count), "]");
            // Independent fresh forks avoid cross-route price contamination. Public nodes
            // are not archive nodes; log the actual execution block separately from audit.
            uint256 blockNumber = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".blockNumber")));
            _freshFork();
            address asset = vm.parseJsonAddress(json, string.concat(root, ".address"));
            address[] memory pools = vm.parseJsonAddressArray(json, string.concat(root, ".selectedRoute.pools"));
            require(vm.parseJsonBool(json, string.concat(root, ".identity.passed")), "identity");
            require(vm.parseJsonBool(json, string.concat(root, ".selectedRoute.eligible")), "ineligible");
            uint256 clip = vm.parseUint(vm.parseJsonString(json, string.concat(root, ".selectedRoute.maxAmountIn")));
            require(clip > 0 && pools.length > 0 && pools.length <= 2, "route");
            _prove(asset, pools[0], pools.length == 2 ? pools[1] : address(0), clip);
            if (pools.length == 2) ++twoHopCount; else ++directCount;
            console2.log("PASS stock", vm.parseJsonString(json, string.concat(root, ".symbol")));
            console2.log("audit block", blockNumber);
            console2.log("execution block", block.number);
            ++count;
        }
        // Keep the historical 12-stock report immutable. The registration-only
        // plan supplies fresh, explicitly approved routes for the three additions.
        assertEq(count, 12, "historical coverage changed");
        string memory additions = vm.readFile("docs/bnb-bstocks-additions-plan.json");
        string[3] memory expected = [string("NVDAB"), string("GOOGLB"), string("BABAB")];
        for (uint256 i; i < 3; ++i) {
            string memory root = string.concat(".freshAudit.candidates[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(additions, string.concat(root, ".symbol")), expected[i]);
            require(vm.parseJsonBool(additions, string.concat(root, ".identityPassed")), "addition identity");
            require(vm.parseJsonBool(additions, string.concat(root, ".selectedRoute.eligible")), "addition ineligible");
            address asset = vm.parseJsonAddress(additions, string.concat(root, ".address"));
            address[] memory pools = vm.parseJsonAddressArray(additions, string.concat(root, ".selectedRoute.pools"));
            uint256 clip = vm.parseUint(vm.parseJsonString(additions, string.concat(root, ".selectedRoute.maxAmountIn")));
            assertEq(pools.length, 2);
            assertEq(clip, 1 ether);
            _freshFork();
            _prove(asset, pools[0], pools[1], clip);
            ++count;
            ++twoHopCount;
        }
        assertFalse(vm.keyExistsJson(additions, ".freshAudit.candidates[3].address"), "unexpected addition");
        assertEq(count, 15, "audit incomplete: require all 15");
        assertGt(directCount, 0, "direct path not tested");
        assertGt(twoHopCount, 0, "two-hop path not tested");
    }

    function _freshFork() private {
        // Public RPC nodes can disagree on their latest block during rotation.
        // Retry explicit providers; never swallow a swap/oracle/claim failure.
        try vm.createSelectFork("https://bsc-dataseed.bnbchain.org") returns (uint256) { return; }
        catch {}
        try vm.createSelectFork("https://bsc-rpc.publicnode.com") returns (uint256) { return; }
        catch {}
        vm.createSelectFork("https://bsc-dataseed.bnbchain.org");
    }

    function _prove(address asset, address p0, address p1, uint256 clip) private {
        RoutedTokenFactoryStub launcher = new RoutedTokenFactoryStub(WBNB);
        Factory factory = new Factory(address(launcher), address(this), V3, USDT);
        factory.setDividendStockAllowed(asset, true);
        factory.setDividendRoute(asset, p0, p1, clip);
        StocksHookToken token = new StocksHookToken();
        Vault vault = launcher.create(factory, address(token), address(0), asset, 0);
        token.setHook(address(vault));
        token.mint(ALICE, 1 ether); token.notify(address(0), ALICE);
        vm.deal(address(this), clip * 2);
        IForkWrapped(WBNB).deposit{value: clip * 2}();
        IForkWrapped(WBNB).transfer(address(vault), clip * 2);
        uint256 gasBefore = gasleft();
        (uint256 spent, uint256 received) = vault.convert();
        console2.log("convert gas (execution only)", gasBefore - gasleft());
        assertEq(spent, clip); assertGt(received, 0);
        assertEq(vault.accountedQuote(), clip);
        assertEq(IERC20BnbVault(USDT).balanceOf(address(vault)), 0);
        uint256 claimable = vault.withdrawableOf(ALICE);
        assertLe(claimable, received); assertGt(claimable, 0);
        vm.prank(ALICE); vault.claim();
        assertEq(IERC20BnbVault(asset).balanceOf(ALICE), claimable);
        assertEq(vault.withdrawableOf(ALICE), 0);
        // Registry changes cannot mutate or disable already-created vault snapshots.
        factory.setDividendStockAllowed(asset, false);
        factory.setDividendRoute(asset, address(0), address(0), 0);
        assertEq(vault.pool0(), p0); assertEq(vault.maxAmountIn(), clip);
    }
}