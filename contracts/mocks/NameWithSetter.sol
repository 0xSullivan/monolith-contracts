// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract NameWithSetter is Initializable {
    string public name;

    function initialize(string memory _name) external initializer {
        name = _name;
    }

    function setName(string memory _name) external {
        name = _name;
    }
}
