// SPDX-License-Identifier: ISC
pragma solidity ^0.8.16;

contract MockERC20 {
    uint256 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    string public name = "Mock ERC20";
    string public symbol = "MERC20";

    function setBalance(address user, uint256 amount) public {
        balanceOf[user] = amount;
    }

    function allowance(address from, address spender) public returns(uint256) {
        return type(uint256).max;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
