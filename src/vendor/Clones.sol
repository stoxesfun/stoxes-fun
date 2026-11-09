// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (proxy/Clones.sol) — minimal EIP-1167 subset.
// flap.sh's verified Portal uses the same OpenZeppelin ClonesUpgradeable library to
// deploy per-token clones of one audited implementation; stoxes.fun keeps that
// exact clone-factory pattern.
pragma solidity ^0.8.26;

library Clones {
    error CloneCreationFailed();

    /// @dev Deploys an EIP-1167 minimal proxy pointing at `implementation`.
    function clone(address implementation) internal returns (address instance) {
        // OpenZeppelin Clones.sol (v4.x) verbatim minimal-proxy creation code.
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneCreationFailed();
    }

    /// @dev Deploys an EIP-1167 minimal proxy via CREATE2 — the address is a
    ///      pure function of (deployer, implementation, salt), so vanity salts
    ///      can be mined off-chain against the constant clone init-code hash.
    function cloneDeterministic(address implementation, bytes32 salt)
        internal
        returns (address instance)
    {
        // OpenZeppelin Clones.sol (v4.x) verbatim, with create2.
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneCreationFailed();
    }

    /// @dev The address `cloneDeterministic` would deploy to for `deployer`.
    function predictDeterministicAddress(address implementation, bytes32 salt, address deployer)
        internal
        pure
        returns (address predicted)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    /// @dev The constant EIP-1167 init-code hash for `implementation` — the
    ///      off-chain salt miner's ground truth.
    function initCodeHash(address implementation) internal pure returns (bytes32 hash) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            hash := keccak256(ptr, 0x37)
        }
    }
}
