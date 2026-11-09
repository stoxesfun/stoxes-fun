// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams, BnbLaunchKind} from "../IStoxesBnb.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbFloorReserveVault} from "./StoxesBnbFloorReserveVault.sol";

contract StoxesBnbFloorReserveVaultFactory is StoxesBnbVaultFactoryBase {
    uint16 public constant MIN_VAULT_BPS = 2_000;
    uint16 public constant SURPLUS_TO_HOLDERS_BPS = 0;

    address public immutable portal;

    constructor(address tokenFactory_, address owner_, address portal_)
        StoxesBnbVaultFactoryBase(tokenFactory_, owner_)
    {
        if (portal_ == address(0) || portal_.code.length == 0) {
            revert InvalidVaultConfiguration();
        }
        portal = portal_;
    }

    function tokenCreationPolicies() external pure override returns (string memory) {
        return
            "Tax launches only; vault allocation must be at least 2000 bps; surplusToHoldersBps must be zero.";
    }

    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external pure override {
        if (
            creator == address(0) || params.kind != BnbLaunchKind.Tax
                || params.allocation.vaultBps < MIN_VAULT_BPS || params.vaultData.length != 32
                || abi.decode(params.vaultData, (uint16)) != SURPLUS_TO_HOLDERS_BPS
        ) revert InvalidVaultConfiguration();
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        onlyTokenFactory
        returns (address vault)
    {
        if (vaultData.length != 32 || abi.decode(vaultData, (uint16)) != SURPLUS_TO_HOLDERS_BPS) {
            revert InvalidVaultConfiguration();
        }
        vault = address(new StoxesBnbFloorReserveVault(token, quoteToken, creator, portal));
    }
}
