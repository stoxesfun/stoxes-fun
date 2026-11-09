// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BnbCreateParams,
    BnbLaunchKind,
    BnbFeeMode,
    IStoxesBnbPortal,
    IStoxesBnbVaultFactory,
    IStoxesBnbVault
} from "../../../src/bnb/IStoxesBnb.sol";
import {Clones} from "../../../src/vendor/Clones.sol";
import {StoxesBnbV3Locker} from "../../../src/bnb/StoxesBnbV3Locker.sol";

interface ITokenLaneERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract TokenLaneCloneDeployer {
    function clone(address implementation, bytes32 salt) external returns (address) {
        return Clones.cloneDeterministic(implementation, salt);
    }
}

contract TokenLanePortal is IStoxesBnbPortal {
    address public immutable WBNB;
    mapping(address => Registration) public registrations;
    uint256 public spendBps = 10_000;
    uint256 public tokensPerQuote = 1;

    constructor(address wbnb_) {
        WBNB = wbnb_;
    }

    function setBuy(uint256 spendBps_, uint256 tokensPerQuote_) external {
        spendBps = spendBps_;
        tokensPerQuote = tokensPerQuote_;
    }

    function registerToken(Registration calldata reg) external {
        registrations[reg.token] = reg;
    }

    function sellFor(address, address, uint256, uint256) external pure returns (uint256) {
        revert("TokenLanePortal: sellFor not mocked");
    }

    function buyFor(address token, address recipient, address refundTo, uint256 quoteAmount, uint256)
        external
        payable
        returns (uint256 tokensOut, uint256 quoteSpent)
    {
        Registration memory reg = registrations[token];
        quoteSpent = quoteAmount * spendBps / 10_000;
        tokensOut = quoteSpent * tokensPerQuote;
        if (msg.value != 0) {
            require(msg.value == quoteAmount, "value");
            if (quoteAmount > quoteSpent) {
                (bool ok,) = refundTo.call{value: quoteAmount - quoteSpent}("");
                require(ok, "refund");
            }
        } else {
            require(ITokenLaneERC20(reg.quoteToken).transferFrom(msg.sender, address(this), quoteAmount), "pull");
            if (quoteAmount > quoteSpent) {
                require(ITokenLaneERC20(reg.quoteToken).transfer(refundTo, quoteAmount - quoteSpent), "refund");
            }
        }
        require(ITokenLaneERC20(token).transfer(recipient, tokensOut), "token");
    }

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
        )
    {
        Registration memory r = registrations[token];
        return (r.kind, r.quoteToken, false, false, 0, 0);
    }

    function curvePrice(address) external pure returns (uint256) {
        return 1e18;
    }

    function startTax(address token) external {
        (bool ok,) = token.call(abi.encodeWithSignature("startMigration()"));
        require(ok, "start");
    }

    function finishTax(address token, address pair) external {
        (bool ok,) = token.call(abi.encodeWithSignature("finalizeMigration(address)", pair));
        require(ok, "finish");
    }

    function move(address token, address to, uint256 amount) external {
        require(ITokenLaneERC20(token).transfer(to, amount), "move");
    }

    function registerLocker(
        StoxesBnbV3Locker locker,
        address token,
        uint256 tokenId,
        BnbFeeMode mode,
        uint16 share,
        address creator,
        address quote
    ) external {
        locker.register(token, tokenId, mode, share, creator, quote);
    }
}

contract TokenLaneVault is IStoxesBnbVault {
    address public token;
    address public vaultQuoteToken;
    address public creator;
    uint256 public accountedQuote;
    uint256 public pingCount;

    constructor(address token_, address quote_, address creator_) {
        token = token_;
        vaultQuoteToken = quote_;
        creator = creator_;
    }

    function ping() external {
        accountedQuote = ITokenLaneERC20(vaultQuoteToken).balanceOf(address(this));
        pingCount++;
        emit QuoteAccounted(accountedQuote, accountedQuote);
    }

    function description() external pure returns (string memory) { return "test vault"; }
    function vaultUISchema() external pure returns (string memory) { return "{}"; }
}

contract TokenLaneVaultFactory is IStoxesBnbVaultFactory {
    address public lastVault;
    bool public reject;
    uint256 public beforeCount;

    function setReject(bool value) external { reject = value; }
    function factorySpecVersion() external pure returns (uint16) { return 1; }
    function wantsBalanceHook() external pure returns (bool) { return false; }
    function tokenCreationPolicies() external pure returns (string memory) { return "test"; }
    function onBeforeLaunch(BnbCreateParams calldata, address) external view {
        require(!reject, "rejected");
    }
    function newVault(address token, address quote, address creator, bytes calldata)
        external
        returns (address vault)
    {
        vault = address(new TokenLaneVault(token, quote, creator));
        lastVault = vault;
        beforeCount++;
    }
}

contract TokenLanePair {
    uint256 private constant Q112 = 2 ** 112;
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint16 public outputBps = 10_000;
    address public lpRecipient;
    uint256 public lpMinted;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }

    function seed(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function setOutputBps(uint16 bps) external { outputBps = bps; }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function price0CumulativeLast() external view returns (uint256) {
        return reserve0 == 0 ? 0 : uint256(reserve1) * Q112 / reserve0 * block.timestamp;
    }

    function price1CumulativeLast() external view returns (uint256) {
        return reserve1 == 0 ? 0 : uint256(reserve0) * Q112 / reserve1 * block.timestamp;
    }

    function swap(uint256 out0, uint256 out1, address to, bytes calldata) external {
        uint256 out = (out0 + out1) * outputBps / 10_000;
        address output = out0 != 0 ? token0 : token1;
        require(ITokenLaneERC20(output).transfer(to, out), "out");
    }

    function mint(address to) external returns (uint256 amount) {
        lpRecipient = to;
        amount = 1;
        lpMinted += amount;
    }

    function sendToken(address token, address to, uint256 amount) external {
        require(ITokenLaneERC20(token).transfer(to, amount), "send");
    }
}

contract TokenLaneV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    function createPair(address a, address b) external returns (address pair) {
        pair = address(new TokenLanePair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}