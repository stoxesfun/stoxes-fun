// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StoxesBnbRenounceableTaxToken} from "../../../src/bnb/candidates/StoxesBnbRenounceableTaxToken.sol";
import {StoxesBnbIntegrationTest} from "../StoxesBnbIntegration.t.sol";
import {StoxesBnbFloorReserveTest} from "../StoxesBnbFloorReserve.t.sol";
import {StoxesBnbTaxProcessorTest} from "../StoxesBnbTaxProcessor.t.sol";
import {StoxesBnbAdminFloorIntegrationTest} from "../StoxesBnbAdminFloorIntegration.t.sol";
import {StoxesBnbTaxTokenTest} from "../StoxesBnbTaxToken.t.sol";

// Replay unchanged economic/real-contract tests against the alternate
// implementation. Existing harnesses retain their original implementation.
contract RenounceableTokenTest is StoxesBnbTaxTokenTest {
    function _taxTokenImplementation() internal override returns (address) {
        return address(new StoxesBnbRenounceableTaxToken());
    }
}

contract RenounceableIntegrationTest is StoxesBnbIntegrationTest {
    function _taxTokenImplementation() internal override returns (address) {
        return address(new StoxesBnbRenounceableTaxToken());
    }
}

contract RenounceableFloorReserveTest is StoxesBnbFloorReserveTest {
    function _taxTokenImplementation() internal override returns (address) {
        return address(new StoxesBnbRenounceableTaxToken());
    }
}

contract RenounceableProcessorTest is StoxesBnbTaxProcessorTest {
    function _taxTokenImplementation() internal override returns (address) {
        return address(new StoxesBnbRenounceableTaxToken());
    }
}

contract RenounceableAdminFloorTest is StoxesBnbAdminFloorIntegrationTest {
    function _taxTokenImplementation() internal override returns (address) {
        return address(new StoxesBnbRenounceableTaxToken());
    }
}