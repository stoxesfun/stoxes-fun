// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "../../mocks/Mocks.sol";
import {
    BnbFeeMode,
    BnbTaxAllocation,
    IStoxesBnbSimpleToken,
    IStoxesBnbTaxToken,
    IStoxesBnbVault
} from "../../../src/bnb/IStoxesBnb.sol";

contract PortalLaneVault is IStoxesBnbVault {
    address public token;
    address public vaultQuoteToken;
    address public creator;
    uint256 public accountedQuote;
    uint256 public pings;

    constructor(address quote) {
        vaultQuoteToken = quote;
    }

    function ping() external {
        accountedQuote = MockERC20(vaultQuoteToken).balanceOf(address(this));
        ++pings;
    }

    function description() external pure returns (string memory) {
        return "test";
    }

    function vaultUISchema() external pure returns (string memory) {
        return "{}";
    }
}

contract PortalLaneTaxProcessor {
    mapping(address => uint256) public burnQuotePending;

    function notifyBurnQuote(address token, uint256 amount) external {
        burnQuotePending[token] += amount;
    }

    function warmObservation(address) external {}
}

contract PortalLaneSimpleToken is MockERC20, IStoxesBnbSimpleToken {
    uint8 public override phase;
    address public override portal;
    address public override creator;
    address public override quoteToken;
    address public override vault;
    address public override mainPool;
    BnbFeeMode public override feeMode;
    uint16 public override creatorFeeShareBps;

    constructor(address portal_, address quote_, address creator_)
        MockERC20("Simple", "SMP", 18)
    {
        portal = portal_;
        quoteToken = quote_;
        creator = creator_;
        feeMode = BnbFeeMode.Creator;
        creatorFeeShareBps = 2_000;
        totalSupply = 1_000_000_000 ether;
        balanceOf[portal_] = totalSupply;
    }

    function startMigration() external {
        require(msg.sender == portal);
        phase = 1;
    }

    function setMigrationOperator(address) external {
        require(msg.sender == portal);
    }

    function finalizeMigration() external {
        require(msg.sender == portal);
        phase = 2;
    }
}

contract PortalLaneTaxToken is MockERC20, IStoxesBnbTaxToken {
    Phase public override phase;
    uint16 public override buyTaxBps;
    uint16 public override sellTaxBps;
    BnbTaxAllocation private _allocation;
    address public override commissionReceiver;
    uint16 public override commissionBps;
    address public override vault;
    address public override balanceHook;
    address public override creator;
    address public override quoteToken;
    address public override portal;
    address public override taxProcessor;
    address public override mainPool;

    constructor(
        address portal_,
        address quote_,
        address creator_,
        address vault_,
        address processor_,
        address commission_
    ) MockERC20("Tax", "TAX", 18) {
        portal = portal_;
        quoteToken = quote_;
        creator = creator_;
        vault = vault_;
        taxProcessor = processor_;
        commissionReceiver = commission_;
        commissionBps = 600;
        buyTaxBps = 500;
        sellTaxBps = 500;
        _allocation = BnbTaxAllocation(2_500, 2_500, 2_500, 2_500);
        totalSupply = 1_000_000_000 ether;
        balanceOf[portal_] = totalSupply;
    }

    function allocation() external view returns (BnbTaxAllocation memory) {
        return _allocation;
    }

    function startMigration() external {
        require(msg.sender == portal);
        phase = Phase.Migrating;
    }

    function setMigrationOperator(address) external {
        require(msg.sender == portal);
    }

    function finalizeMigration(address pair) external {
        require(msg.sender == portal);
        mainPool = pair;
        phase = Phase.TaxEnforced;
    }

    function harvestTax(uint256) external pure returns (uint256) {
        return 0;
    }

    function pendingTax() external pure returns (uint256) {
        return 0;
    }

    function vaultBurn(address from, uint256 amount) external {
        require(msg.sender == vault);
        require(allowance[from][vault] >= amount);
        allowance[from][vault] -= amount;
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit VaultBurn(from, amount);
    }
}

contract PortalLaneLocker {
    address public registeredToken;
    uint256 public registeredId;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function register(
        address token,
        uint256 tokenId,
        BnbFeeMode,
        uint16,
        address,
        address
    ) external {
        registeredToken = token;
        registeredId = tokenId;
    }
}

contract PortalLanePair {
    address public token0;
    address public token1;
    address public lpRecipient;
    uint256 public totalSupply;

    constructor(address quote) {
        token0 = quote;
    }

    function setToken(address token) external {
        require(token1 == address(0));
        token1 = token;
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (0, 0, 0);
    }

    function mint(address to) external returns (uint256) {
        require(MockERC20(token0).balanceOf(address(this)) > 0);
        require(MockERC20(token1).balanceOf(address(this)) > 0);
        lpRecipient = to;
        totalSupply += 1;
        return 1;
    }
}