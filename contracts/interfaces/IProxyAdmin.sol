// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

interface IProxyAdmin {
    function transferOwnership(address newOwner) external;

    function upgrade(address proxy, address implementation) external;
}
