// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StoxesBnbFactory} from "../../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbPortal} from "../../../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbTaxProcessor} from "../../../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbRenounceableTaxToken as Token} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {StoxesBnbNativeBurnVault as Vault} from "../../../src/bnb/vaults/StoxesBnbNativeBurnVault.sol";
import {StoxesBnbNativeBurnVaultFactory as Factory} from "../../../src/bnb/vaults/StoxesBnbNativeBurnVaultFactory.sol";
import {BnbCreateParams, BnbLaunchKind, BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";
import {StackQuote, StackRouter} from "./StoxesBnbRenounceableStackFork.t.sol";

/// Read-only upstream; configuration/funding below exist ONLY in the local fork.
contract StoxesBnbNativeBurnForkTest is Test {
    address constant LIVE = address(bytes20(hex"dfb1afc6dabcbc23e5a3fd09c8a0137112f58f96"));
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant V3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    address constant STOCK = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address constant STOCK_POOL = 0x66faaD27cf481f82d0089ec8156B3AA3636010C7;
    StoxesBnbFactory factory;
    StoxesBnbPortal portal;
    Factory extension;
    address creator = address(0xA11CE);

    function setUp() public {
        if (!vm.envOr("RUN_BNB_NATIVE_BURN_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_BURN_FORK_BLOCK"));
        factory = StoxesBnbFactory(payable(LIVE));
        portal = StoxesBnbPortal(payable(factory.portal()));
        extension = new Factory(LIVE, address(this), V3, USDT);
        console2.log("Fork block", block.number);
    }

    function testDeployedFactoryCurveAndGraduatedNativeBurns() public {
        bytes32 beforeFactory = LIVE.codehash;
        bytes32 beforePortal = address(portal).codehash;
        vm.startPrank(factory.owner());
        factory.setVaultFactoryAllowed(address(extension), true);
        factory.setQuoteAllowed(address(0), true);
        factory.setCreatorWhitelisted(creator, true);
        vm.stopPrank();
        uint128 target = _allowNativeCurve();
        assertGt(target, 0, "existing native curve required");
        vm.deal(creator, uint256(target) * 5 + 1 ether);
        vm.startPrank(creator, creator);
        (address token, address vault) = _launch();
        Vault sink = Vault(payable(vault));
        assertGt(sink.totalBnbBurned(), 0, "creator buy must burn immediately");
        assertEq(StackQuote(WBNB).balanceOf(vault), 0);
        uint256 firstBurn = sink.totalBnbBurned();
        Token(token).approve(address(portal), type(uint256).max);
        portal.sell(token, Token(token).balanceOf(creator) / 2, 1);
        assertGt(sink.totalBnbBurned(), firstBurn, "curve sell must burn immediately");
        portal.buy{value: uint256(target) * 2}(token, 1);
        assertEq(uint256(Token(token).phase()), 2, "graduated");
        uint256 beforeDex = sink.totalBnbBurned();
        _dexSell(token);
        assertEq(sink.totalBnbBurned(), beforeDex, "DEX tax still awaits existing processor");
        vm.stopPrank();
        StoxesBnbTaxProcessor processor = StoxesBnbTaxProcessor(payable(factory.taxProcessor()));
        processor.warmObservation(token);
        vm.warp(block.timestamp + 1801);
        processor.process(token);
        assertGt(sink.totalBnbBurned(), beforeDex, "processor delivery must burn atomically");
        assertEq(StackQuote(WBNB).balanceOf(vault), 0);
        assertEq(address(vault).balance, 0);
        assertEq(LIVE.codehash, beforeFactory);
        assertEq(address(portal).codehash, beforePortal);
    }
    function _allowNativeCurve() private returns (uint128 target) {
        (uint128 r, uint128 h, uint256 k, uint128 t,, bool allowed) = portal.quoteParams(WBNB);
        target = t;
        if (!allowed) {
            vm.prank(portal.owner());
            portal.setQuoteParams(WBNB, r, h, k, target, true);
        }
    }
    function _launch() private returns (address token, address vault) {
        BnbCreateParams memory p;
        p.version = 1; p.kind = BnbLaunchKind.Tax;
        p.name = "Native burn compatibility"; p.symbol = "NBURN";
        p.buyTaxBps = 500; p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(10000, 0, 0, 0);
        p.vaultFactory = address(extension);
        p.creatorBuyQuoteAmount = 0.1 ether;
        p.creatorBuyMinTokensOut = 1;
        (token, vault,,) = factory.createToken{value: p.creatorBuyQuoteAmount}(p);
    }
    function _dexSell(address token) private {
        Token(token).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token; path[1] = WBNB;
        StackRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            Token(token).balanceOf(creator) / 10, 1, path, creator, block.timestamp + 300);
    }

    function testRealStockPoolConvertsAndBurnsWithoutHoldingBnb() public {
        extension.setQuoteRoute(STOCK, STOCK_POOL, address(0), 0.01 ether);
        vm.prank(LIVE);
        Vault vault = Vault(payable(extension.newVault(address(0x1234), STOCK, creator, "")));
        // Synthetic stock funding fixture; pool, stock and WBNB code are real.
        deal(STOCK, address(vault), 0.02 ether);
        vault.ping();
        assertEq(vault.accountedQuote(), 0.02 ether);
        uint256 before = address(0xdead).balance;
        (uint256 spent, uint256 burned) = vault.convertAndBurn();
        assertEq(spent, 0.01 ether);
        assertGt(burned, 0);
        assertEq(address(0xdead).balance - before, burned);
        assertEq(StackQuote(WBNB).balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        assertEq(vault.accountedQuote(), 0.01 ether);
    }
}
