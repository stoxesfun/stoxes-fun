// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20, MockWETH} from "../mocks/Mocks.sol";
import {Clones} from "../../src/vendor/Clones.sol";
import {
    BnbCreateParams,
    BnbLaunchKind,
    BnbFeeMode,
    BnbTaxAllocation
} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbFactory} from "../../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbSimpleToken} from "../../src/bnb/StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {
    TokenLanePortal,
    TokenLaneVaultFactory,
    TokenLaneV2Factory
} from "./mocks/TokenLaneMocks.sol";

contract FeeQuote is MockERC20 {
    constructor() MockERC20("Fee Quote", "FQ", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        balanceOf[to] -= amount / 100;
        totalSupply -= amount / 100;
        return true;
    }
}

contract StoxesBnbFactoryTest is Test {
    StoxesBnbFactory factory;
    StoxesBnbSimpleToken simpleImpl;
    StoxesBnbTaxToken taxImpl;
    TokenLanePortal portal;
    TokenLaneVaultFactory vaultFactory;
    TokenLaneV2Factory v2;
    MockWETH weth;
    MockERC20 stock;
    address user = address(0xB0B);

    event TokenCreated(
        address indexed token,
        address indexed creator,
        BnbLaunchKind kind,
        address quoteToken,
        address vault,
        address vaultFactory,
        uint16 paramsVersion,
        bytes params
    );

    function setUp() public {
        weth = new MockWETH();
        stock = new MockERC20("Stock", "STK", 18);
        portal = new TokenLanePortal(address(weth));
        v2 = new TokenLaneV2Factory();
        vaultFactory = new TokenLaneVaultFactory();
        simpleImpl = new StoxesBnbSimpleToken();
        taxImpl = new StoxesBnbTaxToken();
        factory = new StoxesBnbFactory(
            address(simpleImpl),
            address(taxImpl),
            address(portal),
            address(weth),
            address(v2),
            address(0xBEEF),
            address(this)
        );
        factory.setQuoteAllowed(address(stock), true);
        factory.setVaultFactoryAllowed(address(vaultFactory), true);
        stock.mint(user, 100 ether);
        vm.deal(user, 100 ether);
    }

    function _simple() internal pure returns (BnbCreateParams memory p) {
        p.version = 1;
        p.kind = BnbLaunchKind.Simple;
        p.name = "Simple";
        p.symbol = "SIM";
        p.feeMode = BnbFeeMode.Creator;
        p.creatorFeeShareBps = 3000;
        p.salt = bytes32(uint256(7));
    }

    function _tax() internal pure returns (BnbCreateParams memory p) {
        p.version = 1;
        p.kind = BnbLaunchKind.Tax;
        p.name = "Tax";
        p.symbol = "TAX";
        p.buyTaxBps = 500;
        p.sellTaxBps = 500;
        p.allocation = BnbTaxAllocation(2500, 2500, 2500, 2500);
        p.feeMode = BnbFeeMode.Creator;
        p.salt = bytes32(uint256(8));
    }

    function testOwnerBypassesClosedAndPublicGateWorks() public {
        BnbCreateParams memory p = _simple();
        factory.createToken(p);
        p.salt = bytes32(uint256(9));
        vm.prank(user);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);
        factory.setLaunchesOpen(true);
        vm.prank(user);
        factory.createToken(p);
    }

    function testWhitelistNormalLaunchAndRevocation() public {
        BnbCreateParams memory p = _simple();
        factory.setCreatorWhitelisted(user, true);
        vm.prank(user);
        (address token,,,) = factory.createToken(p);
        assertEq(factory.testCurveQuote(token), 0, "normal not test launch");
        assertFalse(factory.launchesOpen());
        factory.setCreatorWhitelisted(user, false);
        p.salt = bytes32(uint256(77));
        vm.prank(user);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(p);
        factory.setLaunchesOpen(true);
        vm.prank(user);
        factory.createToken(p);
    }

    function testWhitelistCannotGrantItselfOrBypassValidation() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setCreatorWhitelisted(user, true);
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.setCreatorWhitelisted(address(0), true);
        factory.setCreatorWhitelisted(user, true);
        BnbCreateParams memory p = _simple();
        p.version = 2;
        vm.prank(user);
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
    }

    function testTestDelegateIsNotNormalWhitelistedCreator() public {
        factory.setTestLaunchAdmin(user, true);
        vm.prank(user);
        vm.expectRevert(StoxesBnbFactory.LaunchesClosed.selector);
        factory.createToken(_simple());
    }

    function testValidationVersionKindTaxStepsAndAllocation() public {
        BnbCreateParams memory p = _simple();
        p.version = 2;
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
        p = _simple();
        p.kind = BnbLaunchKind.Unknown;
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
        p = _tax();
        p.buyTaxBps = 525;
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
        p = _tax();
        p.allocation.liquidityBps = 2499;
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
        p = _simple();
        p.buyTaxBps = 50;
        vm.expectRevert(StoxesBnbFactory.InvalidParams.selector);
        factory.createToken(p);
    }

    function testQuoteAndVaultAllowlists() public {
        BnbCreateParams memory p = _simple();
        p.quoteToken = address(0x1234);
        vm.expectRevert(StoxesBnbFactory.QuoteNotAllowed.selector);
        factory.createToken(p);
        p = _simple();
        p.vaultFactory = address(0x5678);
        vm.expectRevert(StoxesBnbFactory.VaultFactoryNotAllowed.selector);
        factory.createToken(p);
    }

    function testCallerBoundPredictionAndRenouncedOwnership() public {
        factory.setLaunchesOpen(true);
        BnbCreateParams memory p = _simple();
        bytes32 bound = keccak256(abi.encode(user, p.salt));
        address predicted =
            Clones.predictDeterministicAddress(address(simpleImpl), bound, address(factory));
        vm.prank(user);
        (address token,,,) = factory.createToken(p);
        assertEq(token, predicted);
        assertEq(StoxesBnbSimpleToken(token).owner(), address(0));
        assertEq(StoxesBnbSimpleToken(token).getOwner(), address(0));
        assertTrue(
            predicted
                != Clones.predictDeterministicAddress(
                    address(simpleImpl), keccak256(abi.encode(address(this), p.salt)), address(factory)
                )
        );
    }

    function testTokenCreatedEventAndVaultHooks() public {
        BnbCreateParams memory p = _simple();
        p.vaultFactory = address(vaultFactory);
        p.vaultData = hex"1234";
        address predicted = Clones.predictDeterministicAddress(
            address(simpleImpl), keccak256(abi.encode(address(this), p.salt)), address(factory)
        );
        vm.recordLogs();
        (address token, address vault,,) = factory.createToken(p);
        assertEq(token, predicted);
        assertEq(vault, vaultFactory.lastVault());
        assertEq(vaultFactory.beforeCount(), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("TokenCreated(address,address,uint8,address,address,address,uint16,bytes)");
        bool found;
        for (uint256 i; i < logs.length; i++) if (logs[i].topics[0] == sig) found = true;
        assertTrue(found);
    }

    function testAtomicNativeBuyAndRefund() public {
        factory.setLaunchesOpen(true);
        portal.setBuy(6000, 2);
        BnbCreateParams memory p = _simple();
        p.creatorBuyQuoteAmount = 10 ether;
        uint256 beforeBal = user.balance;
        vm.prank(user);
        (address token,, uint256 out, uint256 spent) = factory.createToken{value: 10 ether}(p);
        assertEq(spent, 6 ether);
        assertEq(out, 12 ether);
        assertEq(StoxesBnbSimpleToken(token).balanceOf(user), out);
        assertEq(user.balance, beforeBal - spent);
    }

    function testAtomicStockBuyAndRefund() public {
        factory.setLaunchesOpen(true);
        portal.setBuy(5000, 3);
        BnbCreateParams memory p = _simple();
        p.quoteToken = address(stock);
        p.creatorBuyQuoteAmount = 10 ether;
        stock.mint(address(factory), 7 ether);
        vm.startPrank(user);
        stock.approve(address(factory), type(uint256).max);
        (address token,, uint256 out, uint256 spent) = factory.createToken(p);
        vm.stopPrank();
        assertEq(spent, 5 ether);
        assertEq(out, 15 ether);
        assertEq(stock.balanceOf(user), 95 ether);
        assertEq(stock.balanceOf(address(factory)), 7 ether);
        assertEq(StoxesBnbSimpleToken(token).balanceOf(user), out);
    }

    function testRegressionFeeQuotePullRevertsOnShortfall() public {
        FeeQuote feeQuote = new FeeQuote();
        factory.setQuoteAllowed(address(feeQuote), true);
        factory.setLaunchesOpen(true);
        feeQuote.mint(user, 10 ether);
        BnbCreateParams memory p = _simple();
        p.quoteToken = address(feeQuote);
        p.creatorBuyQuoteAmount = 10 ether;
        vm.startPrank(user);
        feeQuote.approve(address(factory), type(uint256).max);
        vm.expectRevert(StoxesBnbFactory.QuoteTransferShortfall.selector);
        factory.createToken(p);
        vm.stopPrank();
    }
}