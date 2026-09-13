// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Shared test fixture: the one ERC-20 mock of the suite. Test files import it. src/ never does.

/// @dev Stands in for USDC. transferFrom spends the allowance, so a test that forgets an
///      approve fails the way it would against the real token. Both transfers emit Transfer,
///      as the real token does, so a test can assert the order of a transfer and a vault event.
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
