// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "../../../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20CloneBase} from "../../base/ERC20CloneBase.sol";
import {BnbTaxAllocation, IStoxesBnbBalanceHook, IStoxesBnbTaxToken} from "../IStoxesBnb.sol";

/// @notice New-launch implementation; existing immutable clones cannot be upgraded.
/// @dev Ownership covers migration only. Fee harvesting and allowance-bound vault
/// burns remain explicit, fixed-address capabilities; no scanner outcome is promised.
/// The uncapped source revision requires a new implementation deployment.
contract StoxesBnbRenounceableTaxToken is ERC20CloneBase, OwnableUpgradeable, IStoxesBnbTaxToken {
    uint256 public constant MAX_SUPPLY = 1e9 ether;
    uint16 public constant PROTOCOL_BPS_OF_TAXED_VOLUME = 30;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Phase private _phase;
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
    address public migrationOperator;
    string public metaURI;
    uint64 public graduatedAt;
    uint256 public protocolPending;
    mapping(address => bool) public exempt;

    event PhaseChanged(Phase indexed phase);
    event TaxHarvested(uint256 amount, uint256 protocolAmount);
    error NotProcessor();
    error NotVault();
    error InvalidParams();
    error TransferBlocked();
    error MigrationOwnerFixed();
    error GraduationNotFinalized();

    // Keep the existing factory's initialization ABI, including field order.
    struct InitParams {
        string name;
        string symbol;
        string metaURI;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        BnbTaxAllocation allocation;
        address commissionReceiver;
        address vault;
        address balanceHook;
        address creator;
        address quoteToken;
        address portal;
        address taxProcessor;
    }

    constructor() { _disableInitializers(); }

    function initialize(InitParams calldata p) external initializer {
        if (p.portal == address(0) || p.taxProcessor == address(0) || p.creator == address(0)) {
            revert InvalidParams();
        }
        if (p.buyTaxBps > 1000 || p.sellTaxBps > 1000 || p.buyTaxBps % 50 != 0 || p.sellTaxBps % 50 != 0) {
            revert InvalidParams();
        }
        __Ownable_init();
        _transferOwnership(p.portal);
        _initERC20(p.name, p.symbol);
        metaURI = p.metaURI;
        buyTaxBps = p.buyTaxBps;
        sellTaxBps = p.sellTaxBps;
        _allocation = p.allocation;
        commissionReceiver = p.commissionReceiver;
        uint16 effectiveTax = p.buyTaxBps > p.sellTaxBps ? p.buyTaxBps : p.sellTaxBps;
        commissionBps = p.commissionReceiver == address(0) || effectiveTax == 0
            ? 0 : effectiveTax <= 100 ? 600 : uint16(60_000 / effectiveTax);
        vault = p.vault;
        balanceHook = p.balanceHook;
        creator = p.creator;
        quoteToken = p.quoteToken;
        portal = p.portal;
        taxProcessor = p.taxProcessor;
        exempt[p.portal] = true;
        exempt[p.taxProcessor] = true;
        exempt[p.vault] = true;
        exempt[DEAD] = true;
        _mint(msg.sender, MAX_SUPPLY);
    }

    function getOwner() external view returns (address) { return owner(); }
    function phase() external view override returns (Phase) { return _phase; }
    function allocation() external view override returns (BnbTaxAllocation memory) { return _allocation; }
    function pendingTax() external view override returns (uint256) { return balanceOf(address(this)); }
    function burned() external view returns (uint256) { return balanceOf(DEAD); }

    // Prevent accidentally moving ownership away from the fixed portal, or
    // stranding curve/deferred migration by renouncing before finalization.
    function transferOwnership(address) public view override onlyOwner { revert MigrationOwnerFixed(); }

    function renounceOwnership() public override onlyOwner {
        if (_phase != Phase.TaxEnforced) revert GraduationNotFinalized();
        super.renounceOwnership();
    }

    function startMigration() external override onlyOwner {
        if (_phase != Phase.BondingCurve) revert InvalidParams();
        _phase = Phase.Migrating;
        emit PhaseChanged(_phase);
    }

    function setMigrationOperator(address operator) external override onlyOwner {
        if (_phase != Phase.BondingCurve || operator == address(0) || migrationOperator != address(0)) {
            revert InvalidParams();
        }
        migrationOperator = operator;
    }

    function finalizeMigration(address pair) external override onlyOwner {
        if (_phase != Phase.Migrating || pair == address(0)) revert InvalidParams();
        mainPool = pair;
        exempt[pair] = true;
        graduatedAt = uint64(block.timestamp);
        _phase = Phase.TaxEnforced;
        emit PhaseChanged(_phase);
        // No external calls between finalization and irreversible revocation.
        renounceOwnership();
    }

    /// @dev Deliberately unchanged: only the fixed vault, and only its allowance.
    /// Not unrestricted confiscation. Required for curve-phase redemption too.
    function vaultBurn(address from, uint256 amount) external override {
        if (msg.sender != vault) revert NotVault();
        uint256 allowed = allowance(from, vault);
        if (allowed < amount) revert ERC20InsufficientAllowance(vault, allowed, amount);
        unchecked { _approve(from, vault, allowed - amount); }
        _rawTransfer(from, DEAD, amount);
        _afterTokenTransfer(from, DEAD, amount);
        emit VaultBurn(from, amount);
    }

    /// @dev Deliberately unchanged: only token-held fees, to the fixed processor.
    /// Preserve atomic protocolPending consumption expected by the processor.
    function harvestTax(uint256 maxAmount) external override returns (uint256 amount) {
        if (msg.sender != taxProcessor) revert NotProcessor();
        uint256 balance = balanceOf(address(this));
        amount = balance < maxAmount ? balance : maxAmount;
        if (amount != 0) {
            uint256 protocolAmount = balance == amount ? protocolPending : protocolPending * amount / balance;
            protocolPending -= protocolAmount;
            _rawTransfer(address(this), taxProcessor, amount);
            emit TaxHarvested(amount, protocolAmount);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        Phase p = _phase;
        if (p == Phase.BondingCurve) {
            if (from != portal && to != portal) revert TransferBlocked();
            _rawTransfer(from, to, amount);
            _afterTokenTransfer(from, to, amount);
            return;
        }
        if (p == Phase.Migrating) {
            if (from != portal && from != migrationOperator && to != DEAD) revert TransferBlocked();
            _rawTransfer(from, to, amount);
            _afterTokenTransfer(from, to, amount);
            return;
        }
        uint256 tax;
        uint256 protocolCut;
        uint16 rate;
        if (from == mainPool && !exempt[to]) rate = buyTaxBps;
        else if (to == mainPool && !exempt[from]) rate = sellTaxBps;
        if (rate != 0) {
            tax = amount * rate / 10_000;
            protocolCut = amount * PROTOCOL_BPS_OF_TAXED_VOLUME / 10_000;
            if (protocolCut > tax) protocolCut = tax;
            protocolPending += protocolCut;
        }
        if (tax != 0) _rawTransfer(from, address(this), tax);
        _rawTransfer(from, to, amount - tax);
        _afterTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256) internal override {
        address hook = balanceHook;
        if (hook != address(0)) {
            IStoxesBnbBalanceHook(hook).onBalanceChange(from, balanceOf(from), to, balanceOf(to));
        }
    }
}