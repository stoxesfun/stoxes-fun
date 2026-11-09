// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite, ReentrancyGuardLite, SafeERC20Lite} from "../base/Common.sol";
import {Clones} from "../vendor/Clones.sol";
import {
    BnbCreateParams,
    BnbLaunchKind,
    BnbFeeMode,
    IStoxesBnbPortal,
    IStoxesBnbVaultFactory
} from "./IStoxesBnb.sol";
import {StoxesBnbSimpleToken} from "./StoxesBnbSimpleToken.sol";
import {StoxesBnbTaxToken} from "./StoxesBnbTaxToken.sol";
import {BnbQuotePayout} from "./libraries/BnbQuotePayout.sol";

interface IBnbV2Factory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IBnbPortalGraduator {
    function graduator() external view returns (address);
}

interface IBnbGraduatorPool {
    function simplePool(address token, address quote) external view returns (address);
}

interface IBnbV3PoolLiquidity {
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

interface IERC20PoolBalance {
    function balanceOf(address account) external view returns (uint256);
}

interface IBnbAdminTestPortal {
    function registerTestToken(IStoxesBnbPortal.Registration calldata reg, uint256 graduationQuote) external;
}

contract StoxesBnbFactory is OwnableLite, ReentrancyGuardLite {
    using SafeERC20Lite for address;

    uint16 public constant PARAMS_VERSION = 1;
    uint16 public constant MAX_CREATOR_FEE_SHARE_BPS = 5000;
    uint256 public constant TOTAL_SUPPLY = 1e9 ether;

    address public immutable simpleTokenImplementation;
    address public immutable taxTokenImplementation;
    address public immutable portal;
    address public immutable WBNB;
    address public immutable v2Factory;
    address public immutable taxProcessor;
    bool public launchesOpen;
    mapping(address => bool) public creatorWhitelist;
    mapping(address => bool) public quoteAllowed;
    mapping(address => bool) public vaultFactoryAllowed;
    mapping(address => bool) private _testLaunchAdmins;
    /// @notice Zero for ordinary launches; otherwise the admin test target in raw quote units.
    mapping(address => uint256) public testCurveQuote;
    address[] public allTokens;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        BnbLaunchKind kind,
        address quoteToken,
        address vault,
        address vaultFactory,
        uint16 paramsVersion,
        bytes params
    );
    event LaunchesOpenSet(bool open);
    event CreatorWhitelistSet(address indexed creator, bool allowed);
    event QuoteAllowedSet(address indexed quote, bool allowed);
    event VaultFactoryAllowedSet(address indexed vaultFactory, bool allowed);
    event TestLaunchAdminSet(address indexed admin, bool allowed);
    event TestTokenCreated(address indexed token, address indexed creator, uint256 graduationQuote);

    error InvalidParams();
    error LaunchesClosed();
    error QuoteNotAllowed();
    error VaultFactoryNotAllowed();
    error UnexpectedValue();
    error QuoteTransferShortfall();
    error PoolPreexists();
    error NotTestLaunchAdmin();

    constructor(
        address simpleImpl_,
        address taxImpl_,
        address portal_,
        address wbnb_,
        address v2Factory_,
        address taxProcessor_,
        address admin_
    ) {
        if (
            simpleImpl_ == address(0) || taxImpl_ == address(0) || portal_ == address(0)
                || wbnb_ == address(0) || v2Factory_ == address(0) || taxProcessor_ == address(0)
        ) revert InvalidParams();
        simpleTokenImplementation = simpleImpl_;
        taxTokenImplementation = taxImpl_;
        portal = portal_;
        WBNB = wbnb_;
        v2Factory = v2Factory_;
        taxProcessor = taxProcessor_;
        quoteAllowed[address(0)] = true;
        _initOwner(admin_);
    }

    receive() external payable {
        if (msg.sender != WBNB) revert UnexpectedValue();
    }

    function setLaunchesOpen(bool open) external onlyOwner {
        launchesOpen = open;
        emit LaunchesOpenSet(open);
    }

    /// @notice Normal launches use identical params/economics in private and public mode.
    function setCreatorWhitelisted(address creator, bool allowed) external onlyOwner {
        if (creator == address(0)) revert InvalidParams();
        creatorWhitelist[creator] = allowed;
        emit CreatorWhitelistSet(creator, allowed);
    }

    function setQuoteAllowed(address quote, bool allowed) external onlyOwner {
        quoteAllowed[quote] = allowed;
        emit QuoteAllowedSet(quote, allowed);
    }

    function setVaultFactoryAllowed(address vf, bool allowed) external onlyOwner {
        vaultFactoryAllowed[vf] = allowed;
        emit VaultFactoryAllowedSet(vf, allowed);
    }

    /// @notice Owner is always authorized; delegates can only create test launches,
    /// not administer quote permissions, vault factories, or public launch gates.
    function isTestLaunchAdmin(address account) public view returns (bool) {
        return account != address(0) && (account == owner() || _testLaunchAdmins[account]);
    }

    function setTestLaunchAdmin(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidParams();
        _testLaunchAdmins[account] = allowed;
        emit TestLaunchAdminSet(account, allowed);
    }

    function cloneInitCodeHash(BnbLaunchKind kind) external view returns (bytes32) {
        address implementation = kind == BnbLaunchKind.Simple
            ? simpleTokenImplementation
            : kind == BnbLaunchKind.Tax ? taxTokenImplementation : address(0);
        if (implementation == address(0)) revert InvalidParams();
        return Clones.initCodeHash(implementation);
    }

    function createToken(BnbCreateParams calldata params)
        external
        payable
        nonReentrant
        returns (address token, address vault, uint256 tokensOut, uint256 quoteSpent)
    {
        _validate(params);
        if (!launchesOpen && msg.sender != owner() && !creatorWhitelist[msg.sender]) revert LaunchesClosed();
        return _createToken(params, 0);
    }

    /// @notice Per-launch test curve. Never changes the shared quote defaults.
    /// The normal quote/vault permissions, fees and anti-whale limits still apply.
    function createTestToken(BnbCreateParams calldata params, uint256 graduationQuote)
        external
        payable
        nonReentrant
        returns (address token, address vault, uint256 tokensOut, uint256 quoteSpent)
    {
        if (!isTestLaunchAdmin(msg.sender)) revert NotTestLaunchAdmin();
        if (graduationQuote == 0 || graduationQuote > type(uint128).max) revert InvalidParams();
        _validate(params);
        return _createToken(params, graduationQuote);
    }

    function _createToken(BnbCreateParams calldata params, uint256 graduationQuote)
        internal
        returns (address token, address vault, uint256 tokensOut, uint256 quoteSpent)
    {
        (token, vault) = _deployAndRegister(params, graduationQuote);
        if (graduationQuote != 0) testCurveQuote[token] = graduationQuote;
        (tokensOut, quoteSpent) = _creatorBuy(params, token);
        allTokens.push(token);
        _emitTokenCreated(token, vault, params);
        if (graduationQuote != 0) emit TestTokenCreated(token, msg.sender, graduationQuote);
    }

    function _emitTokenCreated(address token, address vault, BnbCreateParams calldata params) internal {
        emit TokenCreated(
            token,
            msg.sender,
            params.kind,
            params.quoteToken,
            vault,
            params.vaultFactory,
            params.version,
            abi.encode(params)
        );
    }

    function _deployAndRegister(BnbCreateParams calldata params, uint256 graduationQuote)
        internal
        returns (address token, address vault)
    {
        if (params.vaultFactory != address(0)) {
            IStoxesBnbVaultFactory(params.vaultFactory).onBeforeLaunch(params, msg.sender);
        }
        bytes32 salt = keccak256(abi.encode(msg.sender, params.salt));
        token = Clones.cloneDeterministic(
            params.kind == BnbLaunchKind.Simple ? simpleTokenImplementation : taxTokenImplementation, salt
        );
        address effectiveQuote = params.quoteToken == address(0) ? WBNB : params.quoteToken;
        if (params.kind == BnbLaunchKind.Simple) _rejectLiveSimplePool(token, effectiveQuote);
        address pair;
        if (params.kind == BnbLaunchKind.Tax) {
            pair = IBnbV2Factory(v2Factory).getPair(token, effectiveQuote);
            if (pair == address(0)) pair = IBnbV2Factory(v2Factory).createPair(token, effectiveQuote);
        }
        address balanceHook;
        if (params.vaultFactory != address(0)) {
            vault = IStoxesBnbVaultFactory(params.vaultFactory).newVault(
                token, effectiveQuote, msg.sender, params.vaultData
            );
            if (vault == address(0)) revert InvalidParams();
            if (IStoxesBnbVaultFactory(params.vaultFactory).wantsBalanceHook()) balanceHook = vault;
        }

        if (params.kind == BnbLaunchKind.Simple) {
            _initializeSimple(token, params, vault, effectiveQuote);
        } else {
            _initializeTax(token, params, vault, balanceHook, effectiveQuote);
        }

        token.safeTransfer(portal, TOTAL_SUPPLY);
        IStoxesBnbPortal.Registration memory registration =
            IStoxesBnbPortal.Registration({
                token: token,
                quoteToken: effectiveQuote,
                kind: params.kind,
                creator: msg.sender,
                vault: vault,
                pair: pair
            });
        if (graduationQuote == 0) IStoxesBnbPortal(portal).registerToken(registration);
        else IBnbAdminTestPortal(portal).registerTestToken(registration, graduationQuote);
    }

    function _rejectLiveSimplePool(address token, address quote) private view {
        (bool ok, bytes memory data) =
            portal.staticcall(abi.encodeWithSelector(IBnbPortalGraduator.graduator.selector));
        if (!ok || data.length < 32) return;
        address graduator_ = abi.decode(data, (address));
        (ok, data) =
            graduator_.staticcall(abi.encodeWithSelector(IBnbGraduatorPool.simplePool.selector, token, quote));
        if (!ok || data.length < 32) return;
        address pool = abi.decode(data, (address));
        if (pool == address(0) || pool.code.length == 0) return;
        _rejectFundedPool(pool, token, quote);
        (uint160 sqrtPriceX96,,,,,,) = IBnbV3PoolLiquidity(pool).slot0();
        if (sqrtPriceX96 != 0 && IBnbV3PoolLiquidity(pool).liquidity() != 0) revert PoolPreexists();
    }

    function _rejectFundedPool(address pool, address token, address quote) private view {
        if (
            IERC20PoolBalance(token).balanceOf(pool) != 0
                || IERC20PoolBalance(quote).balanceOf(pool) != 0
        ) revert PoolPreexists();
    }

    function _initializeSimple(
        address token,
        BnbCreateParams calldata p,
        address vault,
        address effectiveQuote
    ) internal {
        StoxesBnbSimpleToken(token).initialize(
            StoxesBnbSimpleToken.InitParams({
                name: p.name,
                symbol: p.symbol,
                metaURI: p.metaURI,
                portal: portal,
                creator: msg.sender,
                quoteToken: effectiveQuote,
                vault: vault,
                feeMode: p.feeMode,
                creatorFeeShareBps: p.creatorFeeShareBps
            })
        );
    }

    function _initializeTax(
        address token,
        BnbCreateParams calldata p,
        address vault,
        address balanceHook,
        address effectiveQuote
    ) internal {
        StoxesBnbTaxToken(token).initialize(
            StoxesBnbTaxToken.InitParams({
                name: p.name,
                symbol: p.symbol,
                metaURI: p.metaURI,
                buyTaxBps: p.buyTaxBps,
                sellTaxBps: p.sellTaxBps,
                allocation: p.allocation,
                commissionReceiver: p.commissionReceiver,
                vault: vault,
                balanceHook: balanceHook,
                creator: msg.sender,
                quoteToken: effectiveQuote,
                portal: portal,
                taxProcessor: taxProcessor
            })
        );
    }

    function _creatorBuy(BnbCreateParams calldata params, address token)
        internal
        returns (uint256 tokensOut, uint256 quoteSpent)
    {
        if (params.creatorBuyQuoteAmount != 0) {
            if (params.quoteToken == address(0)) {
                (tokensOut, quoteSpent) = IStoxesBnbPortal(portal).buyFor{
                    value: params.creatorBuyQuoteAmount
                }(
                    token, msg.sender, msg.sender, params.creatorBuyQuoteAmount, params.creatorBuyMinTokensOut
                );
            } else {
                uint256 beforeBalance = _balance(params.quoteToken);
                params.quoteToken.safeTransferFrom(msg.sender, address(this), params.creatorBuyQuoteAmount);
                uint256 pulled = _balance(params.quoteToken) - beforeBalance;
                if (pulled != params.creatorBuyQuoteAmount) revert QuoteTransferShortfall();
                _approve(params.quoteToken, portal, params.creatorBuyQuoteAmount);
                (tokensOut, quoteSpent) = IStoxesBnbPortal(portal).buyFor(
                    token, msg.sender, msg.sender, params.creatorBuyQuoteAmount, params.creatorBuyMinTokensOut
                );
                uint256 leftover = _balance(params.quoteToken) - beforeBalance;
                if (leftover != 0) {
                    BnbQuotePayout.payoutQuote(params.quoteToken, WBNB, msg.sender, leftover);
                }
            }
        }
    }

    function _validate(BnbCreateParams calldata p) internal view {
        if (
            p.version != PARAMS_VERSION || (p.kind != BnbLaunchKind.Simple && p.kind != BnbLaunchKind.Tax)
                || bytes(p.name).length == 0 || bytes(p.symbol).length == 0
        ) revert InvalidParams();
        if (!quoteAllowed[p.quoteToken]) revert QuoteNotAllowed();
        if (p.vaultFactory != address(0) && !vaultFactoryAllowed[p.vaultFactory]) {
            revert VaultFactoryNotAllowed();
        }
        if (p.quoteToken == address(0)) {
            if (msg.value != p.creatorBuyQuoteAmount) revert UnexpectedValue();
        } else if (msg.value != 0) revert UnexpectedValue();

        uint256 sum = uint256(p.allocation.vaultBps) + p.allocation.creatorBps
            + p.allocation.burnBps + p.allocation.liquidityBps;
        if (p.kind == BnbLaunchKind.Simple) {
            if (
                p.buyTaxBps != 0 || p.sellTaxBps != 0 || sum != 0 || p.commissionReceiver != address(0)
                    || p.creatorFeeShareBps > MAX_CREATOR_FEE_SHARE_BPS
            ) revert InvalidParams();
        } else {
            if (
                p.buyTaxBps > 1000 || p.sellTaxBps > 1000 || p.buyTaxBps % 50 != 0
                    || p.sellTaxBps % 50 != 0 || p.creatorFeeShareBps != 0
                    || p.feeMode != BnbFeeMode.Creator
            ) revert InvalidParams();
            if ((p.buyTaxBps == 0 && p.sellTaxBps == 0) ? sum != 0 : sum != 10_000) revert InvalidParams();
            if (p.allocation.vaultBps != 0 && p.vaultFactory == address(0)) revert InvalidParams();
        }
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert InvalidParams();
    }

    function _balance(address token) private view returns (uint256 amount) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok) revert InvalidParams();
        amount = abi.decode(data, (uint256));
    }
}