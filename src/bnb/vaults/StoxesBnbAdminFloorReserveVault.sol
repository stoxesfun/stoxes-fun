// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "../../vendor/FixedPointMathLib.sol";
import {IStoxesBnbTaxToken} from "../IStoxesBnb.sol";
import {StoxesBnbVaultBase, IERC20BnbVault} from "./StoxesBnbVaultBase.sol";

interface IAdminFloorFactory {
    function owner() external view returns (address);
    function portal() external view returns (address);
    function WBNB() external view returns (address);
}

interface IAdminFloorPortal {
    function WBNB() external view returns (address);
    function graduator() external view returns (address);
}

interface IAdminFloorToken is IERC20BnbVault {
    function totalSupply() external view returns (uint256);
}

/// @notice Administratively withdrawable reserve. The current main factory owner
/// can remove ALL backing without burning tokens. Existing legacy vaults are unchanged.
contract StoxesBnbAdminFloorReserveVault is StoxesBnbVaultBase {
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public immutable portal;
    address public immutable graduator;
    address public immutable tokenFactory;

    event Redeemed(address indexed holder, uint256 amountBurned, uint256 quoteOut, uint256 newReserve, uint256 newCirculating);
    event ReserveWithdrawn(address indexed admin, address indexed recipient, uint256 amount, uint256 newReserve);
    error InvalidRedemption();
    error SlippageExceeded();
    error NotReserveAdmin();
    error InvalidWithdrawal();
    error NativeTransferFailed();

    constructor(address token_, address quoteToken_, address creator_, address portal_, address tokenFactory_)
        StoxesBnbVaultBase(token_, quoteToken_, creator_, IAdminFloorPortal(portal_).WBNB())
    {
        if (
            tokenFactory_.code.length == 0 || portal_.code.length == 0
                || IAdminFloorFactory(tokenFactory_).portal() != portal_
                || IAdminFloorFactory(tokenFactory_).WBNB() != wrappedNative
        ) revert InvalidParams();
        address custodian = IAdminFloorPortal(portal_).graduator();
        if (custodian == address(0)) revert InvalidParams();
        portal = portal_;
        graduator = custodian;
        tokenFactory = tokenFactory_;
    }

    function adminWithdrawalVersion() external pure returns (uint16) { return 1; }

    function reserveAdmin() public view returns (address) {
        return IAdminFloorFactory(tokenFactory).owner();
    }

    // Guard synchronization too: a payout callback must not re-account funds that
    // have been consumed but have not yet left a callback-capable quote token.
    function ping() public override nonReentrant { super.ping(); }

    function withdrawReserve(address recipient, uint256 amount) external nonReentrant {
        address admin = reserveAdmin();
        if (admin == address(0) || msg.sender != admin) revert NotReserveAdmin();
        if (recipient == address(0) || recipient == address(this) || amount == 0) revert InvalidWithdrawal();
        super.ping();
        _consume(amount);
        if (vaultQuoteToken == wrappedNative) {
            _unwrap(amount);
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            _payoutQuote(recipient, amount);
        }
        emit ReserveWithdrawn(admin, recipient, amount, accountedQuote);
    }

    function reserve() external view returns (uint256) { return accountedQuote; }

    function circulatingSupply() public view returns (uint256 circulating) {
        IAdminFloorToken launchToken = IAdminFloorToken(token);
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
        super.ping();
        uint256 circulatingBefore = circulatingSupply();
        if (amount == 0 || amount > circulatingBefore) revert InvalidRedemption();
        quoteOut = FixedPointMathLib.fullMulDiv(accountedQuote, amount, circulatingBefore);
        if (quoteOut < minOut) revert SlippageExceeded();
        IStoxesBnbTaxToken(token).vaultBurn(msg.sender, amount);
        _consume(quoteOut);
        if (quoteOut != 0) _payoutQuote(msg.sender, quoteOut);
        emit Redeemed(msg.sender, amount, quoteOut, accountedQuote, circulatingSupply());
    }

    function description() external pure override returns (string memory) {
        return "Admin-managed floor reserve: current main factory owner can withdraw all backing without burning tokens.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return '{"type":"tuple","fields":[{"name":"surplusToHoldersBps","type":"uint16","const":0}],"description":"Reserved for a future on-chain surplus rule; must be zero"}';
    }
}