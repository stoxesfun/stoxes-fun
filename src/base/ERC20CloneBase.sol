// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Minimal initializable ERC-20 base for stoxes.fun clone tokens
/// @notice Storage-based name/symbol so EIP-1167 clones can be initialized per launch.
///         Semantics follow the OpenZeppelin ERC20Upgradeable base that flap.sh's
///         verified FlapTaxTokenV3 builds on (MIT), trimmed of permit/hooks we don't use.
abstract contract ERC20CloneBase {
    string private _name;
    string private _symbol;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ERC20InsufficientBalance(address from, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);

    function _initERC20(string memory name_, string memory symbol_) internal {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert ERC20InsufficientAllowance(msg.sender, allowed, value);
            unchecked {
                _allowances[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _approve(address owner_, address spender, uint256 value) internal {
        _allowances[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    /// @dev Virtual so the tax token can intercept every transfer, exactly like
    ///      flap's `_transfer` override in FlapTaxTokenV3.
    function _transfer(address from, address to, uint256 value) internal virtual {
        _rawTransfer(from, to, value);
        _afterTokenTransfer(from, to, value);
    }

    /// @dev Balance move with no hooks — the "plain transfer" primitive.
    function _rawTransfer(address from, address to, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        _totalSupply += value;
        unchecked {
            _balances[to] += value;
        }
        emit Transfer(address(0), to, value);
        _afterTokenTransfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        if (from == address(0)) revert ERC20InvalidSender(from);
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            _balances[from] = fromBalance - value;
            _totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
        _afterTokenTransfer(from, address(0), value);
    }

    function _afterTokenTransfer(address from, address to, uint256 value) internal virtual {}
}
