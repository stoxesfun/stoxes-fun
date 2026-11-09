// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams, BnbLaunchKind} from "../IStoxesBnb.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal} from "../../interfaces/IUniswapV3.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbNativeBurnVault} from "./StoxesBnbNativeBurnVault.sol";

/// @notice Additive extension: approve with the EXISTING token factory's allowlist.
/// Changing a route affects future launches only; existing vaults are immutable.
contract StoxesBnbNativeBurnVaultFactory is StoxesBnbVaultFactoryBase {
    // Same minimum as the existing Stocks extension. Growing thousands of slots
    // synchronously can exceed BSC's per-transaction gas limit. This never lowers
    // an existing pool's capacity; conversions still require the FULL 1800s TWAP.
    uint16 public constant ORACLE_CARDINALITY = 200;
    address public immutable v3Factory;
    address public immutable bridge;
    struct QuoteRoute { address pool0; address pool1; uint256 maxAmountIn; }
    mapping(address => QuoteRoute) public quoteRoute;
    event QuoteRouteSet(address indexed quote, address pool0, address pool1, uint256 maxAmountIn);
    event BurnVaultCreated(address indexed token, address indexed vault, address quote);

    constructor(address tokenFactory_, address owner_, address v3Factory_, address bridge_)
        StoxesBnbVaultFactoryBase(tokenFactory_, owner_)
    {
        if (v3Factory_.code.length == 0 || bridge_.code.length == 0 || bridge_ == wrappedNative) revert InvalidVaultConfiguration();
        v3Factory = v3Factory_;
        bridge = bridge_;
    }

    function setQuoteRoute(address quote, address pool0, address pool1, uint256 maxAmountIn) external onlyOwner {
        if (quote.code.length == 0 || quote == wrappedNative) revert InvalidVaultConfiguration();
        if (pool0 == address(0) && pool1 == address(0) && maxAmountIn == 0) {
            delete quoteRoute[quote];
        } else {
            if (maxAmountIn == 0 || maxAmountIn > uint256(type(int256).max)) revert InvalidVaultConfiguration();
            _validatePool(pool0, quote, pool1 == address(0) ? wrappedNative : bridge);
            if (pool1 != address(0)) _validatePool(pool1, bridge, wrappedNative);
            IUniswapV3PoolMinimal(pool0).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
            if (pool1 != address(0)) IUniswapV3PoolMinimal(pool1).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
            quoteRoute[quote] = QuoteRoute(pool0, pool1, maxAmountIn);
        }
        emit QuoteRouteSet(quote, pool0, pool1, maxAmountIn);
    }

    function supportsQuote(address quote) public view returns (bool) {
        if (quote == address(0) || quote == wrappedNative) return true;
        QuoteRoute memory r = quoteRoute[quote];
        if (r.maxAmountIn == 0) return false;
        _validatePool(r.pool0, quote, r.pool1 == address(0) ? wrappedNative : bridge);
        if (r.pool1 != address(0)) _validatePool(r.pool1, bridge, wrappedNative);
        return true;
    }
    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Tax only; positive vault allocation; empty vaultData; BNB or an authorized immutable bStock-to-WBNB route.";
    }
    function onBeforeLaunch(BnbCreateParams calldata p, address creator) external view override {
        if (creator == address(0) || p.kind != BnbLaunchKind.Tax || p.allocation.vaultBps == 0 ||
            p.vaultData.length != 0 || !supportsQuote(p.quoteToken)) revert InvalidVaultConfiguration();
    }
    function newVault(address token, address quote, address creator, bytes calldata data)
        external onlyTokenFactory returns (address vault)
    {
        if (data.length != 0 || !supportsQuote(quote)) revert InvalidVaultConfiguration();
        if (quote == address(0)) quote = wrappedNative;
        QuoteRoute memory r = quoteRoute[quote];
        vault = address(new StoxesBnbNativeBurnVault(token, quote, creator, wrappedNative,
            StoxesBnbNativeBurnVault.Route(v3Factory, bridge, r.pool0, r.pool1, r.maxAmountIn)));
        emit BurnVaultCreated(token, vault, quote);
    }
    function _validatePool(address pool, address input, address output) private view {
        if (pool.code.length == 0 || input == output) revert InvalidVaultConfiguration();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        uint24 fee = p.fee();
        if (fee != 100 && fee != 500 && fee != 2500 && fee != 10_000) revert InvalidVaultConfiguration();
        (address a, address b) = input < output ? (input, output) : (output, input);
        if (p.token0() != a || p.token1() != b || p.liquidity() == 0 ||
            IUniswapV3FactoryMinimal(v3Factory).getPool(a, b, fee) != pool) revert InvalidVaultConfiguration();
    }
}
