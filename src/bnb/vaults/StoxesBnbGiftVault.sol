// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20Lite} from "../../base/Common.sol";
import {StoxesBnbVaultBase} from "./StoxesBnbVaultBase.sol";

interface IStoxesBnbGiftVaultFactorySigner {
    function proofSigner() external view returns (address);
}

contract StoxesBnbGiftVault is StoxesBnbVaultBase {
    using SafeERC20Lite for address;

    uint256 public constant FALLBACK_DELAY = 7 days;
    bytes32 private constant HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable vaultFactory;
    bytes32 public immutable handleHash;
    address public recipient;
    uint256 public firstFundedAt;
    mapping(uint256 => bool) public nonceUsed;

    event RecipientManaged(address indexed recipient, uint256 indexed nonce);
    event Claimed(address indexed recipient, uint256 amount);
    event FallbackPaid(address indexed creator, uint256 amount);

    error InvalidProof();
    error ProofExpired();
    error NonceAlreadyUsed();
    error RecipientNotSet();
    error FallbackUnavailable();

    constructor(
        address token_,
        address quoteToken_,
        address creator_,
        address wrappedNative_,
        address vaultFactory_,
        bytes32 handleHash_
    ) StoxesBnbVaultBase(token_, quoteToken_, creator_, wrappedNative_) {
        if (vaultFactory_ == address(0) || handleHash_ == bytes32(0)) revert InvalidParams();
        vaultFactory = vaultFactory_;
        handleHash = handleHash_;
    }

    function manageByProof(address recipient_, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
    {
        if (recipient_ == address(0)) revert InvalidProof();
        if (block.timestamp > deadline) revert ProofExpired();
        if (nonceUsed[nonce]) revert NonceAlreadyUsed();
        bytes32 payload =
            keccak256(abi.encode(block.chainid, address(this), handleHash, recipient_, deadline, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        if (_recover(digest, signature) != IStoxesBnbGiftVaultFactorySigner(vaultFactory).proofSigner()) {
            revert InvalidProof();
        }
        nonceUsed[nonce] = true;
        recipient = recipient_;
        emit RecipientManaged(recipient_, nonce);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert RecipientNotSet();
        ping();
        amount = accountedQuote;
        if (amount == 0) revert InsufficientAccountedQuote();
        _consume(amount);
        _payoutQuote(recipient, amount);
        emit Claimed(recipient, amount);
    }

    function fallbackToCreator() external nonReentrant returns (uint256 amount) {
        ping();
        if (recipient != address(0) || firstFundedAt == 0 || block.timestamp < firstFundedAt + FALLBACK_DELAY)
        {
            revert FallbackUnavailable();
        }
        amount = accountedQuote;
        if (amount == 0) revert InsufficientAccountedQuote();
        _consume(amount);
        _payoutQuote(creator, amount);
        emit FallbackPaid(creator, amount);
    }

    function description() external pure override returns (string memory) {
        return "Lets a verified social-handle owner claim quote proceeds.";
    }

    function vaultUISchema() external pure override returns (string memory) {
        return '{"type":"bytes32","name":"handleHash","description":"keccak256 of the lowercase handle"}';
    }

    function _afterQuoteAccounted(uint256 delta) internal override {
        if (delta != 0 && firstFundedAt == 0) firstFundedAt = block.timestamp;
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (uint256(s) > uint256(HALF_ORDER) || (v != 27 && v != 28)) return address(0);
        signer = ecrecover(digest, v, r, s);
    }
}
