// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

interface ISolidlyLens {
    function poolsAddresses() external view returns (address[] memory);

    function gaugesAddresses() external view returns (address[] memory);
}
