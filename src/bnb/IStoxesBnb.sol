// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title stoxes.fun BNB v2 launchpad — shared interfaces
/// @notice Fresh BNB Chain (chain id 56) stack. Every launch runs through the
///         Portal bonding curve first, quoted in either native BNB (auto-wrapped
///         to WBNB inside the Portal) or an owner-registered bStock. Graduation
///         target depends on the token kind:
///           - Simple (non-tax)  -> V3 1% pool, permanent locker
///           - Tax               -> V2 pair, LP locked forever
///         A launch may attach ONE vault (Buyback&Burn / Split / Gift / ...).
///         The vault interface is the extension point: listing a new vault
///         factory on the token factory is the only change a new vault needs.
///
///         All rates are on-chain readable constants; ownership of tokens is
///         renounced from birth (owner() == getOwner() == address(0)).

/// @notice How a launch graduates off the curve.
enum BnbLaunchKind {
    Unknown, // not registered
    Simple, // graduates to a V3 1% position held by the locker
    Tax // graduates to a V2 pair, LP burned to 0xdead
}

/// @notice Post-graduation V3 LP-fee routing chosen at launch (Simple kind).
enum BnbFeeMode {
    Creator, // creator share paid to the creator wallet
    Holders // creator share is used to buy back + burn the token
}

/// @notice Tax allocation buckets (bps of collected tax; MUST sum to 10_000).
struct BnbTaxAllocation {
    uint16 vaultBps; // forwarded to the attached vault (in the quote asset)
    uint16 creatorBps; // creator bucket (auto-dispatched at threshold)
    // Pre-grad: burn + liquidity quote is escrowed in the Portal. At graduation
    // the liquidity escrow is added to the V2 LP and the burn escrow is handed
    // to the TaxProcessor, which buys + burns on the live pair.
    // Post-grad: token-side tax is liquidated by the TaxProcessor; burn share
    // is burned as tokens, liquidity share is paired and added to the V2 pair.
    uint16 burnBps;
    uint16 liquidityBps;
}

/// @notice Receives settled token balances after a Tax token balance change.
interface IStoxesBnbBalanceHook {
    function onBalanceChange(address from, uint256 fromBalanceAfter, address to, uint256 toBalanceAfter) external;
}

/// @notice Versioned launch parameters passed to `StoxesBnbFactory.createToken`.
/// @dev    `version` MUST equal `StoxesBnbFactory.PARAMS_VERSION`. New fields
///         are appended in a new version; indexers switch on `version`.
struct BnbCreateParams {
    uint16 version; // == 1
    BnbLaunchKind kind;
    string name;
    string symbol;
    string metaURI;
    address quoteToken; // address(0) = native BNB (Portal wraps to WBNB); else an allowlisted bStock
    // --- Tax kind only (must be zero for Simple) ---
    uint16 buyTaxBps; // 0..1000, step 50 (0.5%)
    uint16 sellTaxBps; // 0..1000, step 50 (0.5%)
    BnbTaxAllocation allocation; // sums to 10_000 when any tax > 0; all zero otherwise
    address commissionReceiver; // address(0) = disabled
    // --- Simple kind only ---
    BnbFeeMode feeMode;
    uint16 creatorFeeShareBps; // creator's share of V3 LP fees, 0..MAX_CREATOR_FEE_SHARE_BPS
    // --- Optional vault ---
    address vaultFactory; // address(0) = no vault; else an allowlisted IStoxesBnbVaultFactory
    bytes vaultData; // ABI-encoded, vault-factory specific
    // --- Atomic creator first buy (quote units; for BNB sent as msg.value) ---
    uint256 creatorBuyQuoteAmount;
    uint256 creatorBuyMinTokensOut;
    // --- CREATE2 vanity ---
    bytes32 salt; // caller-bound: factory hashes (msg.sender, salt)
}

/// @notice Vault factories create one vault per launch. Listed by the token
///         factory owner; never user-supplied addresses.
interface IStoxesBnbVaultFactory {
    /// @notice Bumped whenever `vaultData` encoding or vault semantics change.
    function factorySpecVersion() external view returns (uint16);
    /// @notice Whether the launched Tax token must notify its vault of balance changes.
    function wantsBalanceHook() external view returns (bool);
    /// @notice Human/indexer readable policies this vault imposes on token
    ///         creation (e.g. "tax kind only", "min vaultBps 2000"). Enforced
    ///         inside `onBeforeLaunch`, described here.
    function tokenCreationPolicies() external view returns (string memory);
    /// @notice Called by the token factory BEFORE the token is deployed. MUST
    ///         revert if the params are incompatible with this vault.
    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external view;
    /// @notice Deploys the vault for `token`. Only the token factory may call.
    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault);
}

/// @notice Every vault. Receives the token's quote asset (WBNB or bStock) via
///         plain ERC-20 transfer; accounts by balance delta on `ping()`.
interface IStoxesBnbVault {
    event QuoteAccounted(uint256 amount, uint256 accountedQuote);

    function token() external view returns (address);
    function vaultQuoteToken() external view returns (address);
    function creator() external view returns (address);
    /// @notice Quote received and recognised so far (balance-delta accounting).
    function accountedQuote() external view returns (uint256);
    /// @notice Recognise newly arrived quote (balance - accounted). Permissionless.
    function ping() external;
    /// @notice Short human description of what the vault does with funds.
    function description() external view returns (string memory);
    /// @notice JSON schema (string) describing `vaultData` for UIs.
    function vaultUISchema() external view returns (string memory);
}

/// @notice Portal lifecycle hooks used by the factory and tokens.
interface IStoxesBnbPortal {
    struct Registration {
        address token;
        address quoteToken; // WBNB for native launches
        BnbLaunchKind kind;
        address creator;
        address vault; // address(0) = none
        address pair; // pre-created V2 pair (Tax) or address(0)
    }

    function registerToken(Registration calldata reg) external;
    /// @notice Buy on behalf of `recipient`, paying `quoteAmount` in the launch's
    ///         quote token (pulled via transferFrom, or msg.value for BNB).
    ///         Partial fill against the per-origin quota / graduation room; the
    ///         unspent remainder is refunded to `refundTo`.
    function buyFor(address token, address recipient, address refundTo, uint256 quoteAmount, uint256 minTokensOut)
        external
        payable
        returns (uint256 tokensOut, uint256 quoteSpent);
    /// @notice Sell `amount` tokens pulled from msg.sender; quote proceeds are
    ///         paid to `recipient` (native BNB for BNB launches, WBNB if the
    ///         recipient rejects BNB, else the bStock).
    function sellFor(address token, address recipient, uint256 amount, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut);
    function tokenState(address token)
        external
        view
        returns (
            BnbLaunchKind kind,
            address quoteToken,
            bool graduated,
            bool finalized,
            uint256 sold,
            uint256 quoteReserve
        );
    /// @notice Current marginal bonding-curve price, in quote units per 1e18 tokens.
    function curvePrice(address token) external view returns (uint256);
}

/// @notice Tax token surface the Portal / TaxProcessor / lens rely on.
interface IStoxesBnbTaxToken {
    enum Phase {
        BondingCurve,
        Migrating,
        TaxEnforced
    }

    event VaultBurn(address indexed from, uint256 amount);

    function phase() external view returns (Phase);
    function buyTaxBps() external view returns (uint16);
    function sellTaxBps() external view returns (uint16);
    function allocation() external view returns (BnbTaxAllocation memory);
    function commissionReceiver() external view returns (address);
    function commissionBps() external view returns (uint16);
    function vault() external view returns (address);
    function balanceHook() external view returns (address);
    function creator() external view returns (address);
    function quoteToken() external view returns (address);
    function portal() external view returns (address);
    function taxProcessor() external view returns (address);
    function mainPool() external view returns (address);
    function setMigrationOperator(address operator) external;
    function startMigration() external;
    function finalizeMigration(address pair) external;
    function vaultBurn(address from, uint256 amount) external;
    /// @notice Pull accrued token-side tax to the processor (post-grad).
    function harvestTax(uint256 maxAmount) external returns (uint256 amount);
    function pendingTax() external view returns (uint256);
}

/// @notice Simple token surface.
interface IStoxesBnbSimpleToken {
    function phase() external view returns (uint8);
    function portal() external view returns (address);
    function creator() external view returns (address);
    function quoteToken() external view returns (address);
    function vault() external view returns (address);
    function mainPool() external view returns (address);
    function feeMode() external view returns (BnbFeeMode);
    function creatorFeeShareBps() external view returns (uint16);
    function setMigrationOperator(address operator) external;
    function startMigration() external;
    function finalizeMigration() external;
}
