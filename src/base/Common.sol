// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title stoxes.fun common bases (minimal Initializable / Ownable / ReentrancyGuard)
/// @notice Deliberately tiny clone-safe bases for the stoxes.fun launchpad contracts.
///         Adapted from the OpenZeppelin patterns used by flap.sh's verified contracts
///         (MIT), trimmed to exactly what the stoxes.fun system needs.
abstract contract InitializableLite {
    uint8 private _initialized;

    error AlreadyInitialized();

    modifier initializer() {
        if (_initialized != 0) revert AlreadyInitialized();
        _initialized = 1;
        _;
    }

    /// @dev Implementation contracts call this in their constructor so that the
    ///      bare implementation (not a clone) can never be initialized/hijacked.
    function _disableInitializers() internal {
        _initialized = type(uint8).max;
    }
}

abstract contract OwnableLite {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function _initOwner(address initialOwner) internal {
        if (initialOwner == address(0)) revert ZeroAddress();
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

abstract contract ReentrancyGuardLite {
    uint256 private _entered;

    error Reentrancy();

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }
}

/// @notice Minimal safe ERC20 transfer helpers (handles non-standard tokens that
///         return no data). The Robinhood Chain stock tokens are standard ERC-20s,
///         but we fail closed on any falsy return anyway.
library SafeERC20Lite {
    error TransferFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
