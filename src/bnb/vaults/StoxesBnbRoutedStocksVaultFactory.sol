// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BnbCreateParams, BnbLaunchKind} from "../IStoxesBnb.sol";
import {IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal} from "../../interfaces/IUniswapV3.sol";
import {StoxesBnbVaultFactoryBase} from "./StoxesBnbVaultFactoryBase.sol";
import {StoxesBnbRoutedStocksVault} from "./StoxesBnbRoutedStocksVault.sol";
import {IStocksTokenFactory, IStocksV2Factory, IStocksPortal} from "./StoxesBnbStocksVaultFactory.sol";

contract StoxesBnbRoutedStocksVaultFactory is StoxesBnbVaultFactoryBase {
    uint256 public constant MAX_MIN_HOLDING = 10_000_000 ether;
    uint16 public constant ORACLE_CARDINALITY = 200;
    address public immutable v3Factory;
    address public immutable usdt;
    mapping(address => bool) public dividendStockAllowed;
    struct Route {
        address pool0;
        address pool1;
        uint24 fee0;
        uint24 fee1;
        uint256 maxAmountIn;
    }
    mapping(address => Route) public dividendRoute;

    event DividendStockAllowedSet(address indexed stock, bool allowed);
    event DividendRouteSet(address indexed stock, address pool0, address pool1, uint24 fee0, uint24 fee1, uint256 maxAmountIn);

    constructor(address tokenFactory_, address owner_, address v3Factory_, address usdt_)
        StoxesBnbVaultFactoryBase(tokenFactory_, owner_)
    {
        if (v3Factory_.code.length == 0 || usdt_.code.length == 0 || usdt_ == wrappedNative) revert InvalidVaultConfiguration();
        v3Factory = v3Factory_;
        usdt = usdt_;
    }

    function routeVersion() external pure returns (uint16) { return 2; }

    function setDividendStockAllowed(address stock, bool allowed) external onlyOwner {
        if (stock.code.length == 0 || stock == wrappedNative || stock == usdt) revert InvalidVaultConfiguration();
        dividendStockAllowed[stock] = allowed;
        emit DividendStockAllowedSet(stock, allowed);
    }

    function setDividendRoute(address stock, address pool0, address pool1, uint256 maxAmountIn) external onlyOwner {
        if (pool0 == address(0) && pool1 == address(0) && maxAmountIn == 0) {
            delete dividendRoute[stock];
            emit DividendRouteSet(stock, address(0), address(0), 0, 0, 0);
            return;
        }
        if (!dividendStockAllowed[stock] || maxAmountIn == 0 || maxAmountIn > uint256(type(int256).max)) {
            revert InvalidVaultConfiguration();
        }
        uint24 fee0 = _validatePool(pool0, wrappedNative, pool1 == address(0) ? stock : usdt);
        uint24 fee1;
        if (pool1 != address(0)) fee1 = _validatePool(pool1, usdt, stock);
        dividendRoute[stock] = Route(pool0, pool1, fee0, fee1, maxAmountIn);
        IUniswapV3PoolMinimal(pool0).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        if (pool1 != address(0)) IUniswapV3PoolMinimal(pool1).increaseObservationCardinalityNext(ORACLE_CARDINALITY);
        emit DividendRouteSet(stock, pool0, pool1, fee0, fee1, maxAmountIn);
    }

    function wantsBalanceHook() external pure override returns (bool) { return true; }
    function tokenCreationPolicies() external pure override returns (string memory) {
        return "Tax only; allowed stock; stock quotes must pay the same stock; native quotes use an owner-validated immutable WBNB route; minimum holding at most 1%.";
    }
    function onBeforeLaunch(BnbCreateParams calldata params, address creator) external view override {
        if (creator == address(0) || params.kind != BnbLaunchKind.Tax) revert InvalidVaultConfiguration();
        (address stock, uint256 minimum) = abi.decode(params.vaultData, (address, uint256));
        _configuration(params.quoteToken, stock, minimum);
    }

    function newVault(address token, address quoteToken, address creator, bytes calldata vaultData)
        external onlyTokenFactory returns (address vault)
    {
        (address stock, uint256 minimum) = abi.decode(vaultData, (address, uint256));
        Route memory route = _configuration(quoteToken, stock, minimum);
        address quote = quoteToken == address(0) ? wrappedNative : quoteToken;
        address portal = IStocksTokenFactory(tokenFactory).portal();
        address pair = IStocksV2Factory(IStocksTokenFactory(tokenFactory).v2Factory()).getPair(token, quote);
        if (pair == address(0)) revert InvalidVaultConfiguration();
        address[] memory exclusions = new address[](5);
        exclusions[0] = portal;
        exclusions[1] = IStocksTokenFactory(tokenFactory).taxProcessor();
        exclusions[2] = IStocksPortal(portal).graduator();
        exclusions[3] = IStocksPortal(portal).locker();
        exclusions[4] = pair;
        vault = address(new StoxesBnbRoutedStocksVault(
            token, quote, creator, wrappedNative, stock, minimum,
            StoxesBnbRoutedStocksVault.RouteConfig(v3Factory, usdt, route.pool0, route.pool1, route.maxAmountIn), exclusions
        ));
    }

    function _configuration(address quote, address stock, uint256 minimum) private view returns (Route memory route) {
        if (!dividendStockAllowed[stock] || minimum > MAX_MIN_HOLDING) revert InvalidVaultConfiguration();
        if (quote == address(0)) quote = wrappedNative;
        if (quote == stock) return route;
        if (quote != wrappedNative) revert InvalidVaultConfiguration();
        route = dividendRoute[stock];
        if (route.maxAmountIn == 0) revert InvalidVaultConfiguration();
        if (_validatePool(route.pool0, wrappedNative, route.pool1 == address(0) ? stock : usdt) != route.fee0) revert InvalidVaultConfiguration();
        if (route.pool1 != address(0) && _validatePool(route.pool1, usdt, stock) != route.fee1) revert InvalidVaultConfiguration();
    }

    function _validatePool(address pool, address input, address output) private view returns (uint24 fee) {
        if (pool.code.length == 0 || input == output) revert InvalidVaultConfiguration();
        IUniswapV3PoolMinimal p = IUniswapV3PoolMinimal(pool);
        fee = p.fee();
        if (fee != 100 && fee != 500 && fee != 2500 && fee != 10_000) revert InvalidVaultConfiguration();
        (address a, address b) = input < output ? (input, output) : (output, input);
        if (p.token0() != a || p.token1() != b || IUniswapV3FactoryMinimal(v3Factory).getPool(a, b, fee) != pool || p.liquidity() == 0) {
            revert InvalidVaultConfiguration();
        }
    }
}