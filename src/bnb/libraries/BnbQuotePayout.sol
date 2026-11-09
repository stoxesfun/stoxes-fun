// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

library BnbQuotePayout {
    using SafeERC20Lite for address;

    uint256 internal constant NATIVE_GAS_STIPEND = 50_000;

    function payoutQuote(address quote, address wrappedNative, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quote != wrappedNative) {
            quote.safeTransfer(to, amount);
            return;
        }

        IWETH(wrappedNative).withdraw(amount);
        (bool ok,) = to.call{value: amount, gas: NATIVE_GAS_STIPEND}("");
        if (!ok) {
            IWETH(wrappedNative).deposit{value: amount}();
            wrappedNative.safeTransfer(to, amount);
        }
    }
}