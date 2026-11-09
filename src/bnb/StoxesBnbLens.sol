// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BnbFeeMode,
    BnbLaunchKind,
    BnbTaxAllocation,
    IStoxesBnbPortal,
    IStoxesBnbSimpleToken,
    IStoxesBnbTaxToken,
    IStoxesBnbVault
} from "./IStoxesBnb.sol";

/// @notice Read-only aggregation for token pages and indexers.
contract StoxesBnbLens {
    struct TokenState {
        BnbLaunchKind kind;
        uint8 phase;
        address quoteToken;
        uint256 curveSold;
        uint256 curveQuoteReserve;
        uint256 curvePrice;
        bool graduated;
        bool finalized;
        address market;
        address vault;
        address creator;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        BnbTaxAllocation taxAllocation;
        address commissionReceiver;
        uint16 commissionBps;
        BnbFeeMode feeMode;
        uint16 creatorFeeShareBps;
        string vaultDescription;
    }

    address public immutable portal;

    constructor(address portal_) {
        require(portal_ != address(0), "portal");
        portal = portal_;
    }

    function getTokenState(address token) external view returns (TokenState memory s) {
        (s.kind, s.quoteToken, s.graduated, s.finalized, s.curveSold, s.curveQuoteReserve) =
            IStoxesBnbPortal(portal).tokenState(token);
        s.curvePrice = IStoxesBnbPortal(portal).curvePrice(token);
        (s.creator, s.vault, s.market) = _portalDetails(token);

        if (s.kind == BnbLaunchKind.Tax) {
            IStoxesBnbTaxToken t = IStoxesBnbTaxToken(token);
            try t.phase() returns (IStoxesBnbTaxToken.Phase value) {
                s.phase = uint8(value);
                s.buyTaxBps = t.buyTaxBps();
                s.sellTaxBps = t.sellTaxBps();
                s.taxAllocation = t.allocation();
                s.commissionReceiver = t.commissionReceiver();
                s.commissionBps = t.commissionBps();
            } catch {}
        } else if (s.kind == BnbLaunchKind.Simple) {
            IStoxesBnbSimpleToken t = IStoxesBnbSimpleToken(token);
            try t.phase() returns (uint8 value) {
                s.phase = value;
                s.feeMode = t.feeMode();
                s.creatorFeeShareBps = t.creatorFeeShareBps();
            } catch {}
        }

        if (s.vault != address(0)) {
            try IStoxesBnbVault(s.vault).description() returns (string memory text) {
                s.vaultDescription = text;
            } catch {}
        }
    }

    function _portalDetails(address token)
        private
        view
        returns (address creator, address vault, address market)
    {
        (bool ok, bytes memory data) =
            portal.staticcall(abi.encodeWithSignature("stateDetails(address)", token));
        if (!ok || data.length < 320) return (address(0), address(0), address(0));
        (,, creator, vault, market,,,,,) = abi.decode(
            data, (BnbLaunchKind, address, address, address, address, uint128, uint128, bool, bool, bool)
        );
    }
}
