// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {StoxesBnbVaultBase} from "./StoxesBnbVaultBase.sol";

contract StoxesBnbSplitVault is StoxesBnbVaultBase {
    using SafeERC20Lite for address;

    address[] private _recipients;
    uint16[] private _bps;

    event Distributed(uint256 amount);

    constructor(
        address token_,
        address quoteToken_,
        address creator_,
        address wrappedNative_,
        address[] memory recipients_,
        uint16[] memory bps_
    ) StoxesBnbVaultBase(token_, quoteToken_, creator_, wrappedNative_) {
        uint256 n = recipients_.length;
        if (n == 0 || n > 10 || n != bps_.length) revert InvalidParams();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (recipients_[i] == address(0) || bps_[i] == 0) revert InvalidParams();
            for (uint256 j; j < i; ++j) {
                if (recipients_[j] == recipients_[i]) revert InvalidParams();
            }
            total += bps_[i];
        }
        if (total != 10_000) revert InvalidParams();
        _recipients = recipients_;
        _bps = bps_;
    }

    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    function bps() external view returns (uint16[] memory) {
        return _bps;
    }

    function distribute() external nonReentrant returns (uint256 paid) {
        ping();
        uint256 amount = accountedQuote;
        uint256 n = _recipients.length;
        for (uint256 i; i < n; ++i) {
            paid += amount * _bps[i] / 10_000;
        }
        _consume(paid);
        for (uint256 i; i < n; ++i) {
            uint256 share = amount * _bps[i] / 10_000;
            if (share != 0) _payoutQuote(_recipients[i], share);
        }
        emit Distributed(paid);
    }

    function description() external pure override returns (string memory) {
        return "Splits quote proceeds among fixed recipients.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return
        '{"type":"tuple","fields":[{"name":"recipients","type":"address[]","maxItems":10},{"name":"bps","type":"uint16[]","sum":10000}]}';
    }
}
