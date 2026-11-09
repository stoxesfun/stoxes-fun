// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "../../mocks/Mocks.sol";
import {BnbLaunchKind} from "../../../src/bnb/IStoxesBnb.sol";

contract VaultLaneToken is MockERC20 {
    address public mainPool;

    constructor() MockERC20("Launch", "LCH", 18) {}

    function setMainPool(address pool) external {
        mainPool = pool;
    }
}

contract VaultLanePortal {
    BnbLaunchKind public kind;
    address public quote;
    address public token;
    address public pool;
    bool public graduated;
    bool public pending;

    function configure(address token_, address quote_, address pool_, BnbLaunchKind kind_, bool graduated_)
        external
    {
        token = token_;
        quote = quote_;
        pool = pool_;
        kind = kind_;
        graduated = graduated_;
    }

    function setPending(bool value) external {
        pending = value;
    }

    function tokenState(address) external view returns (BnbLaunchKind, address, bool, bool, uint256, uint256) {
        return (kind, quote, graduated, graduated && !pending, 1, 1);
    }

    function curvePrice(address) external pure returns (uint256) {
        return 1 ether;
    }

    function stateDetails(address)
        external
        view
        returns (BnbLaunchKind, address, address, address, address, uint128, uint128, bool, bool, bool)
    {
        return (
            kind,
            quote,
            address(11),
            address(12),
            pool,
            1,
            1,
            graduated,
            pending,
            graduated && !pending
        );
    }

    function buyFor(address, address recipient, address, uint256 quoteAmount, uint256)
        external
        payable
        returns (uint256 tokensOut, uint256 quoteSpent)
    {
        if (msg.value == 0) {
            MockERC20(quote).transferFrom(msg.sender, address(this), quoteAmount);
        } else {
            require(msg.value == quoteAmount, "value");
        }
        tokensOut = quoteAmount * 2;
        quoteSpent = quoteAmount;
        VaultLaneToken(token).mint(recipient, tokensOut);
    }
}
