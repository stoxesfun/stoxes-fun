// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20CloneBase} from "../base/ERC20CloneBase.sol";
import {InitializableLite} from "../base/Common.sol";
import {IStoxesBnbSimpleToken} from "./IStoxesBnb.sol";
import {BnbFeeMode} from "./IStoxesBnb.sol";

contract StoxesBnbSimpleToken is ERC20CloneBase, InitializableLite, IStoxesBnbSimpleToken {
    uint256 public constant MAX_SUPPLY = 1e9 ether;

    uint8 private _phase;
    address public override portal;
    address public override creator;
    address public override quoteToken;
    address public override vault;
    address public override mainPool;
    address public migrationOperator;
    BnbFeeMode public override feeMode;
    uint16 public override creatorFeeShareBps;
    string public metaURI;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PhaseChanged(uint8 indexed phase);

    error NotPortal();
    error TransferBlocked();
    error InvalidParams();

    struct InitParams {
        string name;
        string symbol;
        string metaURI;
        address portal;
        address creator;
        address quoteToken;
        address vault;
        BnbFeeMode feeMode;
        uint16 creatorFeeShareBps;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (
            p.portal == address(0) || p.creator == address(0) || p.quoteToken == address(0)
                || bytes(p.name).length == 0 || bytes(p.symbol).length == 0
        ) {
            revert InvalidParams();
        }
        _initERC20(p.name, p.symbol);
        metaURI = p.metaURI;
        portal = p.portal;
        creator = p.creator;
        quoteToken = p.quoteToken;
        vault = p.vault;
        feeMode = p.feeMode;
        creatorFeeShareBps = p.creatorFeeShareBps;
        _mint(msg.sender, MAX_SUPPLY);
        emit OwnershipTransferred(msg.sender, address(0));
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    function getOwner() external pure returns (address) {
        return address(0);
    }

    function phase() external view override returns (uint8) {
        return _phase;
    }

    function startMigration() external override {
        if (msg.sender != portal) revert NotPortal();
        if (_phase == 0) {
            _phase = 1;
            emit PhaseChanged(1);
        }
    }

    function setMigrationOperator(address operator) external override {
        if (msg.sender != portal) revert NotPortal();
        if (_phase != 0 || operator == address(0) || migrationOperator != address(0)) {
            revert InvalidParams();
        }
        migrationOperator = operator;
    }

    function finalizeMigration() external override {
        if (msg.sender != portal) revert NotPortal();
        if (_phase == 1) {
            _phase = 2;
            emit PhaseChanged(2);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (_phase == 0 && from != portal && to != portal) revert TransferBlocked();
        if (
            _phase == 1 && from != portal && from != migrationOperator
                && to != address(0xdead)
        ) revert TransferBlocked();
        super._transfer(from, to, amount);
    }
}