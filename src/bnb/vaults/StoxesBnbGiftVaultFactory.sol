// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams} from "../IStoxesBnb.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbGiftVault} from "./StoxesBnbGiftVault.sol";

contract StoxesBnbGiftVaultFactory is StoxesBnbVaultFactoryBase {
    address public proofSigner;

    event ProofSignerChanged(address indexed oldSigner, address indexed newSigner);

    constructor(address tokenFactory_, address owner_, address proofSigner_)
        StoxesBnbVaultFactoryBase(tokenFactory_, owner_)
    {
        if (proofSigner_ == address(0)) revert InvalidVaultConfiguration();
        proofSigner = proofSigner_;
    }

    function setProofSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidVaultConfiguration();
        emit ProofSignerChanged(proofSigner, newSigner);
        proofSigner = newSigner;
    }

    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Any launch kind; vaultData is a nonzero keccak256 hash of a lowercase social handle.";
    }

    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external pure override {
        if (creator == address(0) || abi.decode(params.vaultData, (bytes32)) == bytes32(0)) {
            revert InvalidVaultConfiguration();
        }
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        onlyTokenFactory
        returns (address vault)
    {
        bytes32 handleHash = abi.decode(vaultData, (bytes32));
        vault = address(
            new StoxesBnbGiftVault(
                token, quoteToken, creator, wrappedNative, address(this), handleHash
            )
        );
    }
}
