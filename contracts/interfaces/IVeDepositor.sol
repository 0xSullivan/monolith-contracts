// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IVeDepositor {
    function burnFrom(address user, uint256 amount) external;

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}
