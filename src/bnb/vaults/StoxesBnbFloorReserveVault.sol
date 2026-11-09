// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";
import {IStoxesBnbTaxToken} from "../IStoxesBnb.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";

interface IStoxesBnbFloorPortal {
    function WBNB() external view returns (address);
    function graduator() external view returns (address);
}

interface IERC20FloorReserve is IERC20BnbVault {
    function totalSupply() external view returns (uint256);
}

/// @title Ownerless floor reserve for Tax launches
/// @notice Quote inflows and permissionless donations establish a redemption floor.
///         Circulating supply is total supply less balances at the burn address, zero
///         address, token itself (pending tax), the Portal while the curve is open,
///         and the graduator while migration is in progress. Pool, pair, and locker
///         balances remain circulating after finalization because those tokens are
///         sellable.
/// @dev The reserve is monotonic except for redemption payouts. The per-token
///      floor price can nevertheless dip when previously excluded tokens enter
///      circulation, including zero-buy-tax launches and pending tax released
///      after graduation. Every redemption pays the live reserve/circulation ratio.
/// @dev Volume Boost is intentionally not shipped. A trust-minimised on-chain volume
///      measure sourced from token transfer counters is wash-inflatable by its
///      beneficiary, while an off-chain committed epoch puts a keeper in the money
///      path. This version therefore ships the pure reserve; vaultData retains a
///      bounded slot for a future on-chain surplus rule.
contract StoxesBnbFloorReserveVault is StoxesBnbVaultBase {
    using SafeERC20Lite for address;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable portal;
    address public immutable graduator;

    event Redeemed(
        address indexed holder,
        uint256 amountBurned,
        uint256 quoteOut,
        uint256 newReserve,
        uint256 newCirculating
    );

    error InvalidRedemption();
    error SlippageExceeded();
    error NativeTransferFailed();

    constructor(address token_, address quoteToken_, address creator_, address portal_)
        StoxesBnbVaultBase(token_, quoteToken_, creator_, IStoxesBnbFloorPortal(portal_).WBNB())
    {
        if (portal_ == address(0) || portal_.code.length == 0) revert InvalidParams();
        address wrapped = IStoxesBnbFloorPortal(portal_).WBNB();
        address migrationCustodian = IStoxesBnbFloorPortal(portal_).graduator();
        if (wrapped == address(0) || migrationCustodian == address(0)) revert InvalidParams();
        portal = portal_;
        graduator = migrationCustodian;
    }

    function reserve() external view returns (uint256) {
        return accountedQuote;
    }

    function circulatingSupply() public view returns (uint256 circulating) {
        IERC20FloorReserve launchToken = IERC20FloorReserve(token);
        circulating = launchToken.totalSupply();
        circulating -= launchToken.balanceOf(BURN_ADDRESS);
        circulating -= launchToken.balanceOf(address(0));
        circulating -= launchToken.balanceOf(token);

        IStoxesBnbTaxToken.Phase currentPhase = IStoxesBnbTaxToken(token).phase();
        if (currentPhase == IStoxesBnbTaxToken.Phase.BondingCurve) {
            circulating -= launchToken.balanceOf(portal);
        } else if (currentPhase == IStoxesBnbTaxToken.Phase.Migrating) {
            circulating -= launchToken.balanceOf(graduator);
        }
    }

    function floorPrice() external view returns (uint256) {
        uint256 circulating = circulatingSupply();
        return circulating == 0 ? 0 : FixedPointMathLib.fullMulDiv(accountedQuote, 1e18, circulating);
    }

    function quoteRedeem(uint256 amount) public view returns (uint256) {
        uint256 circulating = circulatingSupply();
        return circulating == 0 ? 0 : FixedPointMathLib.fullMulDiv(accountedQuote, amount, circulating);
    }

    function redeem(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 quoteOut) {
        ping();
        uint256 circulatingBefore = circulatingSupply();
        if (amount == 0 || amount > circulatingBefore) revert InvalidRedemption();
        quoteOut = FixedPointMathLib.fullMulDiv(accountedQuote, amount, circulatingBefore);
        if (quoteOut < minOut) revert SlippageExceeded();

        IStoxesBnbTaxToken(token).vaultBurn(msg.sender, amount);
        _consume(quoteOut);

        if (quoteOut != 0) {
            _payoutQuote(msg.sender, quoteOut);
        }

        emit Redeemed(msg.sender, amount, quoteOut, accountedQuote, circulatingSupply());
    }

    function description() external pure override returns (string memory) {
        return "Holds quote proceeds as an ownerless floor redeemable by burning launch tokens.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return
        '{"type":"tuple","fields":[{"name":"surplusToHoldersBps","type":"uint16","const":0}],"description":"Reserved for a future on-chain surplus rule; must be zero"}';
    }
}
