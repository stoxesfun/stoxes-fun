// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {BnbLaunchKind, BnbTaxAllocation, IStoxesBnbPortal} from "../../src/bnb/IStoxesBnb.sol";
import {StoxesBnbTaxToken} from "../../src/bnb/StoxesBnbTaxToken.sol";
import {StoxesBnbTaxProcessor} from "../../src/bnb/StoxesBnbTaxProcessor.sol";
import {
    TokenLaneCloneDeployer,
    TokenLanePortal,
    TokenLanePair,
    TokenLaneVault
} from "./mocks/TokenLaneMocks.sol";

contract AttackerTaxToken {
    address public portal;
    address public quoteToken;
    address public taxProcessor;

    constructor(address portal_, address quote_, address processor_) {
        portal = portal_;
        quoteToken = quote_;
        taxProcessor = processor_;
    }
}

contract StoxesBnbTaxProcessorTest is Test {
    StoxesBnbTaxToken token;
    StoxesBnbTaxProcessor processor;
    TokenLanePortal portal;
    TokenLanePair pair;
    TokenLaneVault vault;
    MockERC20 quote;
    address treasury = address(0x7EA5);
    address commission = address(0xC011);
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);

    function _taxTokenImplementation() internal virtual returns (address) {
        return address(new StoxesBnbTaxToken());
    }

    function setUp() public {
        quote = new MockERC20("Quote", "Q", 18);
        portal = new TokenLanePortal(address(quote));
        processor = new StoxesBnbTaxProcessor(address(0xBEEF), treasury, 1 ether, address(this));
        processor.setPortal(address(portal));
        StoxesBnbTaxToken impl = StoxesBnbTaxToken(_taxTokenImplementation());
        token = StoxesBnbTaxToken(
            new TokenLaneCloneDeployer().clone(address(impl), bytes32("processor-token"))
        );
        vault = new TokenLaneVault(address(token), address(quote), creator);
        token.initialize(
            StoxesBnbTaxToken.InitParams({
                name: "Tax",
                symbol: "TAX",
                metaURI: "",
                buyTaxBps: 100,
                sellTaxBps: 100,
                allocation: BnbTaxAllocation(2500, 2500, 2500, 2500),
                commissionReceiver: commission,
                vault: address(vault),
                balanceHook: address(0),
                creator: creator,
                quoteToken: address(quote),
                portal: address(portal),
                taxProcessor: address(processor)
            })
        );
        token.transfer(address(portal), token.totalSupply());
        pair = new TokenLanePair(address(token), address(quote));
        portal.registerToken(
            IStoxesBnbPortal.Registration(
                address(token), address(quote), BnbLaunchKind.Tax, creator, address(vault), address(pair)
            )
        );
        portal.startTax(address(token));
        portal.finishTax(address(token), address(pair));
        portal.move(address(token), address(pair), 10_000 ether);
        quote.mint(address(pair), 10_000 ether);
        pair.seed(1000 ether, 1000 ether);
        processor.setThresholds(1 ether, 1);
    }

    function _accrue(uint256 gross) internal {
        pair.sendToken(address(token), buyer, gross);
    }

    function _warm() internal {
        assertEq(processor.process(address(token)), 0);
        vm.warp(block.timestamp + processor.TWAP_WINDOW());
    }

    function testThresholdGate() public {
        processor.setThresholds(100 ether, 1);
        _accrue(1000 ether);
        _warm();
        vm.expectRevert(StoxesBnbTaxProcessor.BelowThreshold.selector);
        processor.process(address(token));
    }

    function testRegressionTwapFloorRevertRollsBackHarvest() public {
        _accrue(1000 ether);
        _warm();
        uint256 pending = token.pendingTax();
        pair.setOutputBps(9000);
        vm.expectRevert(StoxesBnbTaxProcessor.FloorNotMet.selector);
        processor.process(address(token));
        assertEq(token.pendingTax(), pending);
    }

    function testEveryRoutingStreamAndLiquidityBurn() public {
        _accrue(1000 ether);
        _warm();
        uint256 deadBefore = token.balanceOf(address(0xdead));
        uint256 out = processor.process(address(token));
        assertGt(out, 0);
        assertGt(quote.balanceOf(treasury), 0);
        assertGt(quote.balanceOf(commission), 0);
        assertGt(quote.balanceOf(address(vault)), 0);
        assertGt(vault.pingCount(), 0);
        assertGt(quote.balanceOf(creator), 0);
        assertGt(token.balanceOf(address(0xdead)), deadBefore);
        assertEq(pair.lpRecipient(), address(0xdead));
        assertGt(pair.lpMinted(), 0);
        assertEq(processor.creatorPending(address(token)), 0);
    }

    function testPermissionlessCreatorDispatch() public {
        processor.setThresholds(1 ether, type(uint256).max);
        _accrue(1000 ether);
        _warm();
        processor.process(address(token));
        assertGt(processor.creatorPending(address(token)), 0);
        vm.prank(address(0xCA11));
        processor.dispatch(address(token));
        assertGt(quote.balanceOf(creator), 0);
    }

    function testRegressionPermissionlessBurnEscrowBuyAndBurn() public {
        uint256 burnQuote = 10 ether;
        quote.mint(address(processor), burnQuote);
        vm.prank(address(portal));
        processor.notifyBurnQuote(address(token), burnQuote);
        assertEq(processor.buyAndBurn(address(token)), 0);
        vm.warp(block.timestamp + processor.TWAP_WINDOW());
        vm.prank(address(0xCA11));
        uint256 burned = processor.buyAndBurn(address(token));
        assertGt(burned, 0);
        assertEq(token.balanceOf(address(0xdead)), burned);
        assertLt(processor.burnQuotePending(address(token)), burnQuote);
    }

    function testRegressionFakeTokenCannotAuthorizeBurnAccounting() public {
        AttackerTaxToken fake = new AttackerTaxToken(address(this), address(quote), address(processor));
        quote.mint(address(processor), 1 ether);
        vm.expectRevert(StoxesBnbTaxProcessor.NotPortal.selector);
        processor.notifyBurnQuote(address(fake), 1 ether);
        vm.expectRevert(StoxesBnbTaxProcessor.UnregisteredToken.selector);
        processor.process(address(fake));
    }

    function testRegressionBurnNotificationRequiresMeasuredQuoteDelta() public {
        vm.prank(address(portal));
        vm.expectRevert(StoxesBnbTaxProcessor.QuoteTransferShortfall.selector);
        processor.notifyBurnQuote(address(token), 1 ether);
    }

    function testRegressionV2FeeAwareCapExecutesAtStablePrice() public {
        _accrue(4_000 ether);
        _warm();
        uint256 beforePending = token.pendingTax();
        uint256 out = processor.process(address(token));
        assertGt(out, 0);
        assertGt(token.pendingTax(), 0);
        assertLt(token.pendingTax(), beforePending);
    }
}