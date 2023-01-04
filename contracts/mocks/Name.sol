// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Name is Initializable {
    string public name;

    function initialize(string memory _name) external initializer {
        name = _name;
    }
}
