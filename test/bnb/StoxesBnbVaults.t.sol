// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {BnbLaunchKind} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbSplitVault} from "../../src/bnb/vaults/StoxesBnbSplitVault.sol";
import {StoxesBnbGiftVault} from "../../src/bnb/vaults/StoxesBnbGiftVault.sol";
import {StoxesBnbGiftVaultFactory} from "../../src/bnb/vaults/StoxesBnbGiftVaultFactory.sol";
import {StoxesBnbBuybackBurnVault} from "../../src/bnb/vaults/StoxesBnbBuybackBurnVault.sol";
import {VaultLanePortal, VaultLaneToken} from "./mocks/VaultLaneMocks.sol";
import {MockV3Pool} from "../mocks/MocksV3.sol";

contract RejectsNative {}

contract SplitGasExhaustingReceiver {
    receive() external payable {
        while (gasleft() != 0) {}
    }
}

contract StoxesBnbVaultsTest is Test {
    MockERC20 quote;
    MockWETH weth;
    VaultLaneToken token;
    VaultLanePortal portal;
    address creator = address(0xC0FFEE);
    uint256 signerKey = 0xA11CE;
    address signer;

    function setUp() public {
        quote = new MockERC20("Quote", "Q", 18);
        weth = new MockWETH();
        token = new VaultLaneToken();
        portal = new VaultLanePortal();
        signer = vm.addr(signerKey);
    }

    function testSplitDistributionAndDustCarry() public {
        address[] memory recipients = new address[](3);
        recipients[0] = address(1);
        recipients[1] = address(2);
        recipients[2] = address(3);
        uint16[] memory bps = new uint16[](3);
        bps[0] = 3333;
        bps[1] = 3333;
        bps[2] = 3334;
        StoxesBnbSplitVault vault =
            new StoxesBnbSplitVault(address(token), address(quote), creator, address(weth), recipients, bps);
        quote.mint(address(vault), 2);
        assertEq(vault.distribute(), 0);
        assertEq(vault.accountedQuote(), 2);
        quote.mint(address(vault), 9_998);
        assertEq(vault.distribute(), 10_000);
        assertEq(quote.balanceOf(recipients[0]), 3333);
        assertEq(quote.balanceOf(recipients[2]), 3334);
    }

    function testSplitRejectsBadBps() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(1);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 9999;
        vm.expectRevert();
        new StoxesBnbSplitVault(address(token), address(quote), creator, address(weth), recipients, bps);
    }

    function testGiftProofClaimAndReplay() public {
        (StoxesBnbGiftVault vault,) = _gift();
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _proof(vault, address(0xB0B), deadline, 7, signerKey);
        vault.manageByProof(address(0xB0B), deadline, 7, sig);
        vm.expectRevert(StoxesBnbGiftVault.NonceAlreadyUsed.selector);
        vault.manageByProof(address(0xB0B), deadline, 7, sig);
        quote.mint(address(vault), 9 ether);
        assertEq(vault.claim(), 9 ether);
        assertEq(quote.balanceOf(address(0xB0B)), 9 ether);
    }

    function testGiftRejectsForgeryAndExpiry() public {
        (StoxesBnbGiftVault vault,) = _gift();
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _proof(vault, address(0xB0B), deadline, 1, 0xBEEF);
        vm.expectRevert(StoxesBnbGiftVault.InvalidProof.selector);
        vault.manageByProof(address(0xB0B), deadline, 1, sig);
        vm.warp(deadline + 1);
        sig = _proof(vault, address(0xB0B), deadline, 2, signerKey);
        vm.expectRevert(StoxesBnbGiftVault.ProofExpired.selector);
        vault.manageByProof(address(0xB0B), deadline, 2, sig);
    }

    function testGiftFallbackTiming() public {
        (StoxesBnbGiftVault vault,) = _gift();
        quote.mint(address(vault), 5 ether);
        vault.ping();
        vm.expectRevert(StoxesBnbGiftVault.FallbackUnavailable.selector);
        vault.fallbackToCreator();
        vm.warp(block.timestamp + 7 days);
        vault.fallbackToCreator();
        assertEq(quote.balanceOf(creator), 5 ether);
    }

    function testGiftReadsRotatedFactorySigner() public {
        (StoxesBnbGiftVault vault, StoxesBnbGiftVaultFactory factory) = _gift();
        address next = vm.addr(0xBEEF);
        factory.setProofSigner(next);
        bytes memory oldSig = _proof(vault, next, block.timestamp + 1, 1, signerKey);
        vm.expectRevert(StoxesBnbGiftVault.InvalidProof.selector);
        vault.manageByProof(next, block.timestamp + 1, 1, oldSig);
    }

    function testReceiveOnlyAcceptsWrappedNativeWithdrawals() public {
        StoxesBnbSplitVault vault = _oneRecipient(address(weth));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testReceiveRejectsNonWrappedQuote() public {
        StoxesBnbSplitVault vault = _oneRecipient(address(quote));
        vm.deal(address(this), 1);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    function testNativeSplitPayoutAndWrappedFallback() public {
        address[] memory recipients = new address[](2);
        SplitGasExhaustingReceiver rejecting = new SplitGasExhaustingReceiver();
        recipients[0] = address(0xA11CE);
        recipients[1] = address(rejecting);
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5000;
        bps[1] = 5000;
        StoxesBnbSplitVault vault = new StoxesBnbSplitVault(
            address(token), address(weth), creator, address(weth), recipients, bps
        );
        vm.deal(address(this), 2 ether);
        weth.deposit{value: 2 ether}();
        weth.transfer(address(vault), 2 ether);

        vault.distribute();

        assertEq(recipients[0].balance, 1 ether);
        assertEq(weth.balanceOf(address(rejecting)), 1 ether);
    }

    function testBuybackPreGraduationWethBurns() public {
        portal.configure(address(token), address(weth), address(0), BnbLaunchKind.Simple, false);
        StoxesBnbBuybackBurnVault vault = new StoxesBnbBuybackBurnVault(
            address(token), address(weth), creator, address(portal), address(99), address(weth)
        );
        vm.deal(address(this), 2 ether);
        weth.deposit{value: 2 ether}();
        weth.transfer(address(vault), 2 ether);
        (uint256 spent, uint256 burned) = vault.execute();
        assertEq(spent, 2 ether);
        assertEq(burned, 4 ether);
        assertEq(token.balanceOf(vault.BURN_ADDRESS()), 4 ether);
    }

    function testRegressionBuybackRejectsDeferredGraduation() public {
        portal.configure(address(token), address(weth), address(0x1234), BnbLaunchKind.Simple, true);
        portal.setPending(true);
        StoxesBnbBuybackBurnVault vault = new StoxesBnbBuybackBurnVault(
            address(token), address(weth), creator, address(portal), address(99), address(weth)
        );
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(vault), 1 ether);
        vm.expectRevert(StoxesBnbBuybackBurnVault.GraduationNotFinalized.selector);
        vault.execute();
    }

    function testRegressionBuybackReportsOracleNotReadyWithoutLosingQuote() public {
        (address token0, address token1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        MockV3Pool pool = new MockV3Pool(token0, token1, 10_000, uint160(1 << 96), 0);
        pool.setPancakeCallback(true);
        pool.setLiquidity(1_000 ether);
        pool.setTwapUsable(false);
        portal.configure(address(token), address(quote), address(pool), BnbLaunchKind.Simple, true);
        StoxesBnbBuybackBurnVault vault = new StoxesBnbBuybackBurnVault(
            address(token), address(quote), creator, address(portal), address(99), address(weth)
        );
        quote.mint(address(vault), 10 ether);
        vm.expectRevert(StoxesBnbBuybackBurnVault.OracleNotReady.selector);
        vault.execute();
        assertEq(quote.balanceOf(address(vault)), 10 ether);
        assertEq(vault.accountedQuote(), 0);
    }

    function testRegressionBuybackLiquidityCliffCarriesThenRetries() public {
        (address token0, address token1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        MockV3Pool pool = new MockV3Pool(token0, token1, 10_000, uint160(1 << 96), 0);
        pool.setPancakeCallback(true);
        pool.setLiquidity(1_000 ether);
        pool.setWokbOutPerTokenWad(1 ether);
        pool.setLiquidityCliff(-409, 4000);
        token.mint(address(pool), 100 ether);
        portal.configure(address(token), address(quote), address(pool), BnbLaunchKind.Simple, true);
        StoxesBnbBuybackBurnVault vault = new StoxesBnbBuybackBurnVault(
            address(token), address(quote), creator, address(portal), address(99), address(weth)
        );
        quote.mint(address(vault), 10 ether);
        vm.warp(block.timestamp + 120);
        vault.execute();
        assertEq(vault.accountedQuote(), 6 ether);
        assertEq(token.balanceOf(address(0xdead)), 4 ether);

        pool.setSqrtPriceX96(uint160(1 << 96));
        pool.setTick(0);
        pool.setLiquidity(1_000 ether);
        pool.setPartialFillBps(0);
        vault.execute();
        assertEq(vault.accountedQuote(), 0);
        assertEq(token.balanceOf(address(0xdead)), 10 ether);
    }

    function _gift() private returns (StoxesBnbGiftVault vault, StoxesBnbGiftVaultFactory factory) {
        factory = new StoxesBnbGiftVaultFactory(address(this), address(this), signer);
        vault = new StoxesBnbGiftVault(
            address(token), address(quote), creator, address(weth), address(factory), keccak256("alice")
        );
    }

    function _proof(StoxesBnbGiftVault vault, address recipient, uint256 deadline, uint256 nonce, uint256 key)
        private
        view
        returns (bytes memory sig)
    {
        bytes32 payload = keccak256(
            abi.encode(block.chainid, address(vault), vault.handleHash(), recipient, deadline, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _oneRecipient(address quote_) private returns (StoxesBnbSplitVault vault) {
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vault = new StoxesBnbSplitVault(
            address(token), quote_, creator, address(weth), recipients, bps
        );
    }

    function WBNB() external view returns (address) {
        return address(weth);
    }
}
