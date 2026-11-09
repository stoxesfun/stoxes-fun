// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams} from "../IStoxesBnb.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbBuybackBurnVault} from "./StoxesBnbBuybackBurnVault.sol";

contract StoxesBnbBuybackBurnVaultFactory is StoxesBnbVaultFactoryBase {
    address public immutable portal;
    address public immutable swapRouter;

    constructor(
        address tokenFactory_,
        address owner_,
        address portal_,
        address swapRouter_,
        address wrappedNative_
    ) StoxesBnbVaultFactoryBase(tokenFactory_, owner_) {
        if (
            portal_ == address(0) || swapRouter_ == address(0)
                || wrappedNative_ != wrappedNative
        ) {
            revert InvalidVaultConfiguration();
        }
        portal = portal_;
        swapRouter = swapRouter_;
    }

    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Any launch kind; vaultData must be empty.";
    }

    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external pure override {
        if (creator == address(0) || params.vaultData.length != 0) revert InvalidVaultConfiguration();
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        onlyTokenFactory
        returns (address vault)
    {
        if (vaultData.length != 0) revert InvalidVaultConfiguration();
        vault = address(
            new StoxesBnbBuybackBurnVault(token, quoteToken, creator, portal, swapRouter, wrappedNative)
        );
    }
}
