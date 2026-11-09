// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams, BnbLaunchKind} from "../IStoxesBnb.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal} from "../../interfaces/IUniswapV3.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbStocksVault} from "./StoxesBnbStocksVault.sol";

interface IStocksTokenFactory {
    function portal() external view returns (address);
    function taxProcessor() external view returns (address);
    function v2Factory() external view returns (address);
}

interface IStocksV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IStocksPortal {
    function graduator() external view returns (address);
    function locker() external view returns (address);
}

contract StoxesBnbStocksVaultFactory is StoxesBnbVaultFactoryBase {
    uint256 public constant MAX_MIN_HOLDING = 10_000_000 ether;
    uint16 public constant ORACLE_CARDINALITY = 200;
    uint24[4] private _feeTiers = [uint24(100), 500, 2500, 10_000];

    address public immutable v3Factory;
    mapping(address => bool) public dividendStockAllowed;

    event DividendStockAllowedSet(address indexed stock, bool allowed);

    constructor(address tokenFactory_, address owner_, address v3Factory_)
        StoxesBnbVaultFactoryBase(tokenFactory_, owner_)
    {
        if (v3Factory_ == address(0)) revert InvalidVaultConfiguration();
        v3Factory = v3Factory_;
    }

    function setDividendStockAllowed(address stock, bool allowed) external onlyOwner {
        if (stock == address(0)) revert InvalidVaultConfiguration();
        dividendStockAllowed[stock] = allowed;
        emit DividendStockAllowedSet(stock, allowed);
    }

    function wantsBalanceHook() external pure override returns (bool) {
        return true;
    }

    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Tax launches only; registered dividend stock; minimum holding at most 1% of supply; a live direct V3 market is required unless quote equals stock.";
    }

    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external view override {
        if (creator == address(0) || params.kind != BnbLaunchKind.Tax) {
            revert InvalidVaultConfiguration();
        }
        (address stock, uint256 minimum) = abi.decode(params.vaultData, (address, uint256));
        if (!dividendStockAllowed[stock] || minimum > MAX_MIN_HOLDING) {
            revert InvalidVaultConfiguration();
        }
        address quote = params.quoteToken;
        if (quote == address(0)) {
            (bool ok, bytes memory data) = tokenFactory.staticcall(abi.encodeWithSignature("WBNB()"));
            if (!ok || data.length != 32) revert InvalidVaultConfiguration();
            quote = abi.decode(data, (address));
        }
        if (stock != quote) {
            (address pool,) = _deepestPool(quote, stock);
            if (pool == address(0)) revert InvalidVaultConfiguration();
        }
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external
        onlyTokenFactory
        returns (address vault)
    {
        (address stock, uint256 minimum) = abi.decode(vaultData, (address, uint256));
        if (!dividendStockAllowed[stock] || minimum > MAX_MIN_HOLDING) {
            revert InvalidVaultConfiguration();
        }
        (address pool, uint24 fee) =
            stock == quoteToken ? (address(0), uint24(0)) : _deepestPool(quoteToken, stock);
        if (stock != quoteToken && pool == address(0)) revert InvalidVaultConfiguration();
        if (pool != address(0)) {
            IUniswapV3PoolMinimal(pool).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        }

        address portal = IStocksTokenFactory(tokenFactory).portal();
        address pair = IStocksV2Factory(IStocksTokenFactory(tokenFactory).v2Factory()).getPair(
            token, quoteToken
        );
        if (pair == address(0)) revert InvalidVaultConfiguration();
        address[] memory exclusions = new address[](5);
        exclusions[0] = portal;
        exclusions[1] = IStocksTokenFactory(tokenFactory).taxProcessor();
        exclusions[2] = IStocksPortal(portal).graduator();
        exclusions[3] = IStocksPortal(portal).locker();
        exclusions[4] = pair;
        vault = address(
            new StoxesBnbStocksVault(
                token, quoteToken, creator, wrappedNative, stock, minimum, pool, fee, exclusions
            )
        );
    }

    function deepestPool(address quote, address stock)
        external
        view
        returns (address pool, uint24 fee)
    {
        return _deepestPool(quote, stock);
    }

    function _deepestPool(address quote, address stock)
        private
        view
        returns (address bestPool, uint24 bestFee)
    {
        uint128 bestLiquidity;
        for (uint256 i; i < 4; ++i) {
            uint24 fee = _feeTiers[i];
            address pool = IUniswapV3FactoryMinimal(v3Factory).getPool(quote, stock, fee);
            if (pool == address(0)) continue;
            uint128 liquidity = IUniswapV3PoolMinimal(pool).liquidity();
            if (liquidity > bestLiquidity) {
                bestLiquidity = liquidity;
                bestPool = pool;
                bestFee = fee;
            }
        }
    }
}