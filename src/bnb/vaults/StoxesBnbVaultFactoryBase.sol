// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite} from "../../base/Common.sol";
import {BnbCreateParams, IStoxesBnbVaultFactory} from "../IStoxesBnb.sol";

abstract contract StoxesBnbVaultFactoryBase is OwnableLite, IStoxesBnbVaultFactory {
    address public immutable tokenFactory;
    address public immutable wrappedNative;
    uint16 public constant FACTORY_SPEC_VERSION = 1;

    error NotTokenFactory();
    error InvalidVaultConfiguration();

    modifier onlyTokenFactory() {
        if (msg.sender != tokenFactory) revert NotTokenFactory();
        _;
    }

    constructor(address tokenFactory_, address owner_) {
        if (tokenFactory_ == address(0)) revert InvalidVaultConfiguration();
        tokenFactory = tokenFactory_;
        (bool ok, bytes memory data) = tokenFactory_.staticcall(abi.encodeWithSignature("WBNB()"));
        if (!ok || data.length < 32) revert InvalidVaultConfiguration();
        wrappedNative = abi.decode(data, (address));
        if (wrappedNative == address(0)) revert InvalidVaultConfiguration();
        _initOwner(owner_);
    }

    function factorySpecVersion() external pure returns (uint16) {
        return FACTORY_SPEC_VERSION;
    }

    function wantsBalanceHook() external pure virtual returns (bool) {
        return false;
    }

    function tokenCreationPolicies() external pure virtual returns (string memory);
    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external view virtual;
}
