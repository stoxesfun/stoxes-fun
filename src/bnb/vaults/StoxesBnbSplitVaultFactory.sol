// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams} from "../IStoxesBnb.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbSplitVault} from "./StoxesBnbSplitVault.sol";

contract StoxesBnbSplitVaultFactory is StoxesBnbVaultFactoryBase {
    constructor(address tokenFactory_, address owner_) StoxesBnbVaultFactoryBase(tokenFactory_, owner_) {}

    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Any launch kind; 1-10 unique nonzero recipients whose bps sum to 10000.";
    }

    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external pure override {
        if (creator == address(0)) revert InvalidVaultConfiguration();
        (address[] memory recipients_, uint16[] memory bps_) =
            abi.decode(params.vaultData, (address[], uint16[]));
        uint256 n = recipients_.length;
        if (n == 0 || n > 10 || n != bps_.length) revert InvalidVaultConfiguration();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (recipients_[i] == address(0) || bps_[i] == 0) revert InvalidVaultConfiguration();
            for (uint256 j; j < i; ++j) {
                if (recipients_[j] == recipients_[i]) revert InvalidVaultConfiguration();
            }
            total += bps_[i];
        }
        if (total != 10_000) revert InvalidVaultConfiguration();
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        onlyTokenFactory
        returns (address vault)
    {
        (address[] memory recipients_, uint16[] memory bps_) = abi.decode(vaultData, (address[], uint16[]));
        vault = address(
            new StoxesBnbSplitVault(token, quoteToken, creator, wrappedNative, recipients_, bps_)
        );
    }
}
