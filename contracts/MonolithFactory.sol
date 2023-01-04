// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

interface IProxy {
    function upgradeTo(address newImplementation) external;
}

contract MonolithFactory is Initializable, AccessControlEnumerableUpgradeable {
    address[] public deployedProxies;
    address public proxyAdmin;

    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    function initialize(
        address _proxyAdmin,
        address admin,
        address deployer
    ) public initializer {
        __AccessControlEnumerable_init();

        proxyAdmin = _proxyAdmin;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYER_ROLE, deployer);
    }

    function deployedProxiesLength() public view returns (uint256) {
        return deployedProxies.length;
    }

    function deployProxyContract(address implementation, string memory _salt)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(_salt));

        return _deployProxy(implementation, salt);
    }

    function _deployProxy(address implementation, bytes32 salt)
        internal
        returns (address proxyAddress)
    {
        bytes memory bytecode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, "")
        );

        proxyAddress = _deployContract(bytecode, salt);

        deployedProxies.push(proxyAddress);
    }

    function _deployContract(bytes memory bytecode, bytes32 salt)
        internal
        returns (address contractAddress)
    {
        assembly {
            contractAddress := create2(
                0,
                add(bytecode, 32),
                mload(bytecode),
                salt
            )
        }
        require(contractAddress != address(0), "create2 failed");
        return contractAddress;
    }
}
