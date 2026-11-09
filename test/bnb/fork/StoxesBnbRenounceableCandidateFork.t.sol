// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StoxesBnbRenounceableTaxToken as Candidate} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {BnbTaxAllocation} from "../../../src/bnb/IStoxesBnb.sol";
import {Clones} from "../../../src/vendor/Clones.sol";

interface CandidateForkERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface CandidateForkFactory {
    function createPair(address, address) external returns (address);
}

interface CandidateForkRouter {
    function factory() external view returns (address);
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external returns (uint256, uint256, uint256);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata, address, uint256
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
}

/// Opt-in LOCAL fork only. Deploys a fresh candidate and pair into the in-memory
/// fork, never onto BSC. Reads are routed through the broadcast-blocking bridge.
contract RenounceableCandidateForkTest is Test {
    address constant QUOTE = address(bytes20(hex"4902c5ebc598265ed2212b559b042de8a5eeec3f"));
    address constant ROUTER = address(bytes20(hex"10ed43c718714eb63d5aa57b78b54704e256024e"));
    Candidate token;
    address pair;

    function _tokenLiquidity() internal pure virtual returns (uint256) { return 100_000_000 ether; }
    function _quoteLiquidity() internal pure virtual returns (uint256) { return 1000 ether; }

    function setUp() public {
        if (!vm.envOr("RUN_BNB_CANDIDATE_FORK", false)) { vm.skip(true); return; }
        vm.createSelectFork("http://127.0.0.1:18546", vm.envUint("BNB_FORK_BLOCK"));
        assertEq(block.chainid, 56);
        token = Candidate(Clones.cloneDeterministic(address(new Candidate()), bytes32("candidate-fork")));
        token.initialize(Candidate.InitParams({
            name: "Local candidate", symbol: "LOCAL", metaURI: "", buyTaxBps: 500, sellTaxBps: 500,
            allocation: BnbTaxAllocation(2500, 2500, 2500, 2500), commissionReceiver: address(0),
            vault: address(0xBA17), balanceHook: address(0), creator: address(this),
            quoteToken: QUOTE, portal: address(this), taxProcessor: address(this)
        }));
        assertEq(token.owner(), address(this));
        pair = CandidateForkFactory(CandidateForkRouter(ROUTER).factory()).createPair(address(token), QUOTE);
        token.setMigrationOperator(ROUTER);
        token.startMigration();
        uint256 tokenAmount = _tokenLiquidity();
        uint256 quoteAmount = _quoteLiquidity();
        token.approve(ROUTER, tokenAmount);
        deal(QUOTE, address(this), quoteAmount);
        CandidateForkERC20(QUOTE).approve(ROUTER, quoteAmount);
        CandidateForkRouter(ROUTER).addLiquidity(
            address(token), QUOTE, tokenAmount, quoteAmount,
            tokenAmount, quoteAmount, address(0xdead), block.timestamp + 300
        );
        token.finalizeMigration(pair);
        assertEq(token.owner(), address(0));
        assertEq(token.getOwner(), address(0));
        assertEq(token.mainPool(), pair);
    }

    function _swap(address buyer, address input, address output, uint256 amount)
        internal returns (uint256 received)
    {
        address[] memory path = new address[](2);
        path[0] = input;
        path[1] = output;
        uint256 beforeBalance = CandidateForkERC20(output).balanceOf(buyer);
        vm.startPrank(buyer, buyer);
        CandidateForkERC20(input).approve(ROUTER, amount);
        CandidateForkRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 1, path, buyer, block.timestamp + 300
        );
        vm.stopPrank();
        received = CandidateForkERC20(output).balanceOf(buyer) - beforeBalance;
        assertGt(received, 0);
    }

    function testCandidateSmallBncbRoundTrip() public { _roundTrip(0.1 ether); }
    function testCandidateLargerBncbRoundTrip() public { _roundTrip(3 ether); }

    function _roundTrip(uint256 amount) private {
        address buyer = makeAddr("candidate-fork-buyer");
        deal(QUOTE, buyer, amount);
        address[] memory path = new address[](2);
        path[0] = QUOTE;
        path[1] = address(token);
        uint256 gross = CandidateForkRouter(ROUTER).getAmountsOut(amount, path)[1];
        uint256 bought = _swap(buyer, QUOTE, address(token), amount);
        assertEq(bought, gross - gross * 500 / 10_000);
        uint256 received = _swap(buyer, address(token), QUOTE, bought);
        assertEq(token.balanceOf(buyer), 0, "full holder exit");
        assertGt(received, amount * 80 / 100);
        assertLt(received, amount);
        uint256 pending = token.pendingTax();
        assertGt(pending, 0);
        uint256 beforeProcessor = token.balanceOf(address(this));
        assertEq(token.harvestTax(type(uint256).max), pending);
        assertEq(token.balanceOf(address(this)), beforeProcessor + pending);
        assertEq(token.pendingTax(), 0);
        assertEq(token.protocolPending(), 0);
        assertEq(token.owner(), address(0));
        console2.log("BNCB spent raw", amount);
        console2.log("BNCB recovered raw", received);
    }
}

/// Same small reserve scale as the reported live failure, but a freshly deployed
/// uncapped implementation. Never replace code/storage in the user's live clone.
contract RenounceableNoLimitsForkTest is RenounceableCandidateForkTest {
    address constant WBNB = address(bytes20(hex"bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"));

    function _tokenLiquidity() internal pure override returns (uint256) {
        return 581205373113503258179420310;
    }

    function _quoteLiquidity() internal pure override returns (uint256) {
        return 8626104138282324629;
    }

    function testLargeImmediateBuyRepeatBuyAndFullSell() public {
        address buyer = makeAddr("uncapped-repeat-buyer");
        deal(QUOTE, buyer, 1 ether);
        _swap(buyer, QUOTE, address(token), 0.5 ether);
        assertGt(token.balanceOf(buyer), token.MAX_SUPPLY() / 100);
        _swap(buyer, QUOTE, address(token), 0.5 ether);
        _swap(buyer, address(token), QUOTE, token.balanceOf(buyer));
        assertEq(token.balanceOf(buyer), 0);
        assertEq(block.timestamp, token.graduatedAt(), "no clock advance");
        assertEq(token.owner(), address(0));
    }

    function testLargeNativeBuyIntermediaryCustodyAndFullNativeSellImmediately() public {
        address buyer = makeAddr("uncapped-native-buyer");
        address intermediary = makeAddr("uncapped-aggregator-intermediary");
        deal(buyer, 0.01 ether);
        address[] memory path = new address[](3);
        path[0] = WBNB; path[1] = QUOTE; path[2] = address(token);
        vm.startPrank(buyer, buyer);
        CandidateForkRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            1, path, buyer, block.timestamp + 300
        );
        uint256 bought = token.balanceOf(buyer);
        assertGt(bought, token.MAX_SUPPLY() / 100, "must exceed the removed cap");
        token.approve(intermediary, bought);
        vm.stopPrank();
        vm.startPrank(intermediary, intermediary);
        token.transferFrom(buyer, intermediary, bought);
        assertEq(token.balanceOf(intermediary), bought);
        token.approve(ROUTER, bought);
        path[0] = address(token); path[2] = WBNB;
        CandidateForkRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            bought, 1, path, buyer, block.timestamp + 300
        );
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(intermediary), 0);
        assertGt(buyer.balance, 0.008 ether);
        assertLt(buyer.balance, 0.01 ether);
        assertEq(block.timestamp, token.graduatedAt(), "immediate native round trip");
        assertEq(token.owner(), address(0));
        assertEq(token.getOwner(), address(0));
        assertEq(
            CandidateForkERC20(pair).balanceOf(address(0xdead)) + CandidateForkERC20(pair).balanceOf(address(0)),
            CandidateForkERC20(pair).totalSupply(),
            "all LP stays burned"
        );
        console2.log("Native BNB recovered after immediate uncapped round trip", buyer.balance);
    }
}