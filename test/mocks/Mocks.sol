// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }
}

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

contract MockPair {
    address public token0;
    address public token1;
    uint256 public lpMinted;
    address public lpRecipient;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = IERC20View(token0).balanceOf(address(this));
        uint256 bal1 = IERC20View(token1).balanceOf(address(this));
        require(bal0 > 0 && bal1 > 0, "no liquidity");
        liquidity = bal0 < bal1 ? bal0 : bal1;
        lpMinted = liquidity;
        lpRecipient = to;
    }
}

contract MockUniV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "exists");
        pair = address(new MockPair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

/// @notice A FULL V2 pair mock: `mint` (graduation LP seeding, syncs reserves
///         from current balances) PLUS a faithful constant-product `swap` with
///         the real fee-adjusted K check (so fee-on-transfer tax tokens behave
///         exactly like on a live PotatoSwap pair). Lets an integration test run
///         graduation and then REAL StoxesFunRouter buys/sells against it.
contract MockSwapPairMintable {
    address public token0;
    address public token1;
    uint256 public immutable feeBps;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 public blockTimestampLast;
    // UQ112x112 price accumulators, faithful to a live V2 pair (so a TWAP oracle
    // can be computed from two observations `>=` a window apart).
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public lpMinted;
    address public lpRecipient;
    uint256 public totalSupply;

    uint256 private constant Q112 = 2 ** 112;

    constructor(address t0, address t1, uint256 feeBps_) {
        token0 = t0;
        token1 = t1;
        feeBps = feeBps_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @dev V2 `_update`: accrue price cumulatives over the elapsed time at the
    ///      OLD reserves, then adopt the new reserves + timestamp.
    function _update(uint256 balance0, uint256 balance1) internal {
        uint32 nowTs = uint32(block.timestamp % 2 ** 32);
        uint32 elapsed;
        unchecked {
            elapsed = nowTs - blockTimestampLast;
        }
        if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += (uint256(reserve1) * Q112 / reserve0) * elapsed;
            price1CumulativeLast += (uint256(reserve0) * Q112 / reserve1) * elapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = nowTs;
    }

    function sync() external {
        _update(_bal(token0), _bal(token1));
    }

    /// @dev Graduation LP mint: adopt the deposited balances as reserves and
    ///      record the burn recipient (LP is burned to 0xdead by the Portal).
    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = _bal(token0);
        uint256 bal1 = _bal(token1);
        require(bal0 > 0 && bal1 > 0, "no liquidity");
        _update(bal0, bal1);
        liquidity = bal0 < bal1 ? bal0 : bal1;
        lpMinted = liquidity;
        lpRecipient = to;
        totalSupply += liquidity;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out < reserve0 && amount1Out < reserve1, "liquidity");
        if (amount0Out > 0) _transfer(token0, to, amount0Out);
        if (amount1Out > 0) _transfer(token1, to, amount1Out);
        uint256 balance0 = _bal(token0);
        uint256 balance1 = _bal(token1);
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "no input");
        uint256 adj0 = balance0 * 10_000 - amount0In * feeBps;
        uint256 adj1 = balance1 * 10_000 - amount1In * feeBps;
        require(adj0 * adj1 >= uint256(reserve0) * reserve1 * 10_000 ** 2, "K");
        _update(balance0, balance1);
    }

    function _bal(address t) internal view returns (uint256) {
        return IERC20View(t).balanceOf(address(this));
    }

    function _transfer(address t, address to, uint256 v) internal {
        (bool ok, bytes memory data) = t.call(abi.encodeWithSignature("transfer(address,uint256)", to, v));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "xfer");
    }
}

/// @notice V2 factory that produces full swap-capable pairs (integration flow).
contract MockSwapV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) {
        feeBps = feeBps_;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "exists");
        pair = address(new MockSwapPairMintable(tokenA, tokenB, feeBps));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}
