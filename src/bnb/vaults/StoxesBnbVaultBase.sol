// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardLite, SafeERC20Lite} from "../../base/Common.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {BnbQuotePayout} from "../libraries/BnbQuotePayout.sol";

interface IERC20BnbVault {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Common, ownerless custody and balance-delta accounting for launch vaults.
abstract contract StoxesBnbVaultBase is ReentrancyGuardLite {
    using SafeERC20Lite for address;

    address public immutable token;
    address public immutable vaultQuoteToken;
    address public immutable creator;
    address public immutable wrappedNative;
    uint256 public accountedQuote;

    event QuoteAccounted(uint256 amount, uint256 accountedQuote);

    error InvalidParams();
    error NativeNotAccepted();
    error InsufficientAccountedQuote();

    constructor(address token_, address quoteToken_, address creator_, address wrappedNative_) {
        if (
            token_ == address(0) || quoteToken_ == address(0) || creator_ == address(0)
                || wrappedNative_ == address(0)
        ) {
            revert InvalidParams();
        }
        token = token_;
        vaultQuoteToken = quoteToken_;
        creator = creator_;
        wrappedNative = wrappedNative_;
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert NativeNotAccepted();
    }

    function ping() public virtual {
        uint256 balance = IERC20BnbVault(vaultQuoteToken).balanceOf(address(this));
        if (balance <= accountedQuote) return;
        uint256 delta = balance - accountedQuote;
        accountedQuote = balance;
        _afterQuoteAccounted(delta);
        emit QuoteAccounted(delta, balance);
    }

    function description() external view virtual returns (string memory);
    function vaultUISchema() external view virtual returns (string memory);

    function _afterQuoteAccounted(uint256) internal virtual {}

    function _consume(uint256 amount) internal {
        if (amount > accountedQuote) revert InsufficientAccountedQuote();
        accountedQuote -= amount;
    }

    function _approve(address asset, address spender, uint256 amount) internal {
        _callApprove(asset, spender, 0);
        _callApprove(asset, spender, amount);
    }

    function _callApprove(address asset, address spender, uint256 amount) private {
        (bool ok, bytes memory data) =
            asset.call(abi.encodeWithSelector(IERC20BnbVault.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeERC20Lite.TransferFailed();
    }

    function _unwrap(uint256 amount) internal {
        IWETH(vaultQuoteToken).withdraw(amount);
    }

    function _payoutQuote(address to, uint256 amount) internal {
        BnbQuotePayout.payoutQuote(vaultQuoteToken, wrappedNative, to, amount);
    }
}
