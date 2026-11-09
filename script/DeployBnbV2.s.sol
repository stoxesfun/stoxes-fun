// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {StoxesBnbGraduator} from "../src/bnb/StoxesBnbGraduator.sol";
import {StoxesBnbPortal} from "../src/bnb/StoxesBnbPortal.sol";
import {StoxesBnbV3Locker} from "../src/bnb/StoxesBnbV3Locker.sol";
import {StoxesBnbTaxProcessor} from "../src/bnb/StoxesBnbTaxProcessor.sol";
import {StoxesBnbFactory} from "../src/bnb/StoxesBnbFactory.sol";
import {StoxesBnbSimpleToken} from "../src/bnb/StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "../src/bnb/StoxesBnbTaxToken.sol";
import {StoxesBnbLens} from "../src/bnb/StoxesBnbLens.sol";
import {StoxesBnbBuybackBurnVaultFactory} from "../src/bnb/vaults/StoxesBnbBuybackBurnVaultFactory.sol";
import {StoxesBnbSplitVaultFactory} from "../src/bnb/vaults/StoxesBnbSplitVaultFactory.sol";
import {StoxesBnbGiftVaultFactory} from "../src/bnb/vaults/StoxesBnbGiftVaultFactory.sol";
import {StoxesBnbFloorReserveVaultFactory} from "../src/bnb/vaults/StoxesBnbFloorReserveVaultFactory.sol";
import {StoxesBnbStocksVaultFactory} from "../src/bnb/vaults/StoxesBnbStocksVaultFactory.sol";

/// @notice BNB Chain v2 deployment. Running without BROADCAST=1 performs the
/// same deployment and wiring as a simulation, but never opens a broadcast.
contract DeployBnbV2 is Script {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant V3_NFPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant SWAP_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    struct Deployed {
        address portalMath;
        StoxesBnbGraduator graduator;
        StoxesBnbPortal portal;
        StoxesBnbV3Locker locker;
        StoxesBnbTaxProcessor taxProcessor;
        address simpleImplementation;
        address taxImplementation;
        StoxesBnbFactory factory;
        StoxesBnbBuybackBurnVaultFactory buybackVaultFactory;
        StoxesBnbSplitVaultFactory splitVaultFactory;
        StoxesBnbGiftVaultFactory giftVaultFactory;
        StoxesBnbFloorReserveVaultFactory floorReserveVaultFactory;
        StoxesBnbStocksVaultFactory stocksVaultFactory;
        StoxesBnbLens lens;
    }

    function run() external {
        require(block.chainid == 56, "wrong chain: expected BNB Chain 56");
        _verifyInfrastructure();

        uint256 privateKey = vm.envUint("BNB_DEPLOYER_PRIVATE_KEY");
        address admin = vm.addr(privateKey);
        address treasury = vm.envAddress("BNB_TREASURY");
        address keeper = vm.envAddress("BNB_KEEPER");
        address proofSigner = vm.envAddress("BNB_GIFT_PROOF_SIGNER");
        require(
            treasury != address(0) && keeper != address(0) && proofSigner != address(0), "zero env address"
        );

        bool broadcast = vm.envOr("BROADCAST", uint256(0)) == 1;
        if (broadcast) vm.startBroadcast(privateKey);
        else vm.startPrank(admin);

        Deployed memory d = _deploy(admin, treasury, proofSigner);
        _wire(d);

        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
        _log(d, admin, treasury, keeper, proofSigner, broadcast);
    }

    function _deploy(address admin, address treasury, address proofSigner)
        internal
        returns (Deployed memory d)
    {
        d.graduator = new StoxesBnbGraduator(WBNB, V3_NFPM, treasury, admin);
        d.portal = new StoxesBnbPortal(WBNB, treasury, address(d.graduator), admin);
        d.portalMath = _findLinkedLibrary(address(d.portal), address(d.graduator));
        _assertNoUnlinkedPlaceholder(address(d.portal));
        d.locker = new StoxesBnbV3Locker(
            address(d.portal), WBNB, V3_NFPM, V3_FACTORY, SWAP_ROUTER, treasury, admin
        );
        d.taxProcessor = new StoxesBnbTaxProcessor(WBNB, treasury, 0, admin);
        d.simpleImplementation = address(new StoxesBnbSimpleToken());
        d.taxImplementation = address(new StoxesBnbTaxToken());
        d.factory = new StoxesBnbFactory(
            d.simpleImplementation,
            d.taxImplementation,
            address(d.portal),
            WBNB,
            V2_FACTORY,
            address(d.taxProcessor),
            admin
        );
        d.buybackVaultFactory = new StoxesBnbBuybackBurnVaultFactory(
            address(d.factory), admin, address(d.portal), SWAP_ROUTER, WBNB
        );
        d.splitVaultFactory = new StoxesBnbSplitVaultFactory(address(d.factory), admin);
        d.giftVaultFactory = new StoxesBnbGiftVaultFactory(address(d.factory), admin, proofSigner);
        d.floorReserveVaultFactory =
            new StoxesBnbFloorReserveVaultFactory(address(d.factory), admin, address(d.portal));
        d.stocksVaultFactory =
            new StoxesBnbStocksVaultFactory(address(d.factory), admin, V3_FACTORY);
        d.lens = new StoxesBnbLens(address(d.portal));
    }

    function _findLinkedLibrary(address first, address second) internal view returns (address linked) {
        bytes memory code = first.code;
        for (uint256 i; i < code.length;) {
            uint8 op = uint8(code[i]);
            if (op == 0x73 && i + 21 <= code.length) {
                address candidate = _push20At(code, i);
                if (candidate.code.length != 0 && _containsPush20(second.code, candidate)) {
                    return candidate;
                }
            }
            i += op >= 0x60 && op <= 0x7f ? uint256(op - 0x5f) + 1 : 1;
        }
        revert("linked PortalMath not found");
    }

    function _containsPush20(bytes memory code, address candidate) internal pure returns (bool) {
        for (uint256 i; i < code.length;) {
            uint8 op = uint8(code[i]);
            if (op == 0x73 && i + 21 <= code.length && _push20At(code, i) == candidate) return true;
            i += op >= 0x60 && op <= 0x7f ? uint256(op - 0x5f) + 1 : 1;
        }
        return false;
    }

    function _push20At(bytes memory code, uint256 opcodeIndex) internal pure returns (address value) {
        assembly {
            value := shr(96, mload(add(add(code, 0x21), opcodeIndex)))
        }
    }

    function _assertNoUnlinkedPlaceholder(address target) internal view {
        bytes memory code = target.code;
        for (uint256 i; i + 2 < code.length; ++i) {
            require(
                !(code[i] == 0x5f && code[i + 1] == 0x5f && code[i + 2] == 0x24),
                "unlinked library placeholder"
            );
        }
    }

    function _wire(Deployed memory d) internal {
        d.graduator.setPortal(address(d.portal));
        d.taxProcessor.setPortal(address(d.portal));
        d.portal.setLocker(address(d.locker));
        d.portal.setFactory(address(d.factory));
        d.portal.setQuoteParams(
            WBNB,
            vm.envUint("BNB_CURVE_R"),
            vm.envUint("BNB_CURVE_H"),
            vm.envUint("BNB_CURVE_K"),
            vm.envUint("BNB_GRADUATION_QUOTE"),
            true
        );
        d.factory.setVaultFactoryAllowed(address(d.buybackVaultFactory), true);
        d.factory.setVaultFactoryAllowed(address(d.splitVaultFactory), true);
        d.factory.setVaultFactoryAllowed(address(d.giftVaultFactory), true);
        d.factory.setVaultFactoryAllowed(address(d.floorReserveVaultFactory), true);
        d.factory.setVaultFactoryAllowed(address(d.stocksVaultFactory), true);
        _registerDividendStocks(d.stocksVaultFactory);
        _seedCreatorWhitelist(d.factory);
        // launchesOpen intentionally remains false.
    }

    /// @dev Public addresses only. Same configuration is used in simulation and broadcast.
    function _seedCreatorWhitelist(StoxesBnbFactory factory) internal {
        address[] memory empty = new address[](0);
        address[] memory accounts = vm.envOr("BNB_CREATOR_WHITELIST", ",", empty);
        for (uint256 i; i < accounts.length; ++i) {
            factory.setCreatorWhitelisted(accounts[i], true);
            require(factory.creatorWhitelist(accounts[i]), "whitelist seed failed");
        }
        require(!factory.launchesOpen(), "must remain closed");
    }

    function _registerDividendStocks(StoxesBnbStocksVaultFactory stocksFactory) internal {
        bytes memory list = bytes(vm.envOr("BNB_DIVIDEND_STOCKS", string("")));
        uint256 start;
        for (uint256 i; i <= list.length; ++i) {
            if (i != list.length && list[i] != bytes1(",")) continue;
            if (i == start) {
                start = i + 1;
                continue;
            }
            bytes memory item = new bytes(i - start);
            for (uint256 j; j < item.length; ++j) item[j] = list[start + j];
            address stock = vm.parseAddress(string(item));
            require(stock.code.length != 0, "dividend stock has no code");
            (bool ok, bytes memory data) = stock.staticcall(abi.encodeWithSignature("decimals()"));
            require(ok && data.length == 32 && abi.decode(data, (uint256)) <= 255, "bad dividend stock");
            stocksFactory.setDividendStockAllowed(stock, true);
            start = i + 1;
        }
    }

    function _verifyInfrastructure() internal view {
        require(WBNB.code.length != 0, "WBNB has no code");
        require(V2_FACTORY.code.length != 0, "V2 factory has no code");
        require(V3_FACTORY.code.length != 0, "V3 factory has no code");
        require(V3_NFPM.code.length != 0, "V3 NFPM has no code");
        require(SWAP_ROUTER.code.length != 0, "swap router has no code");

        (bool symbolOk, bytes memory symbolData) = WBNB.staticcall(abi.encodeWithSignature("symbol()"));
        require(
            symbolOk && keccak256(bytes(abi.decode(symbolData, (string)))) == keccak256("WBNB"), "bad WBNB"
        );
        (bool feeToOk,) = V2_FACTORY.staticcall(abi.encodeWithSignature("feeTo()"));
        require(feeToOk, "V2 feeTo probe failed");
        (bool poolOk,) = V3_FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,uint24)", WBNB, address(1), 10_000)
        );
        require(poolOk, "V3 getPool probe failed");
    }

    function _log(
        Deployed memory d,
        address admin,
        address treasury,
        address keeper,
        address proofSigner,
        bool broadcast
    ) internal pure {
        console.log("broadcast:", broadcast);
        console.log("admin:", admin);
        console.log("treasury:", treasury);
        console.log("keeper:", keeper);
        console.log("gift proof signer:", proofSigner);
        console.log("StoxesBnbPortalMath:", d.portalMath);
        console.log("StoxesBnbGraduator:", address(d.graduator));
        console.log("StoxesBnbPortal:", address(d.portal));
        console.log("StoxesBnbV3Locker:", address(d.locker));
        console.log("StoxesBnbTaxProcessor:", address(d.taxProcessor));
        console.log("StoxesBnbSimpleToken implementation:", d.simpleImplementation);
        console.log("StoxesBnbTaxToken implementation:", d.taxImplementation);
        console.log("StoxesBnbFactory:", address(d.factory));
        console.log("BuybackBurnVaultFactory:", address(d.buybackVaultFactory));
        console.log("SplitVaultFactory:", address(d.splitVaultFactory));
        console.log("GiftVaultFactory:", address(d.giftVaultFactory));
        console.log("FloorReserveVaultFactory:", address(d.floorReserveVaultFactory));
        console.log("StocksVaultFactory:", address(d.stocksVaultFactory));
        console.log("StoxesBnbLens:", address(d.lens));
    }
}
