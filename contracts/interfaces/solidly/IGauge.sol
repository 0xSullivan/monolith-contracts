// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IGauge {
    function balanceOf(address user) external returns (uint256);

    function deposit(uint256 amount, uint256 tokenId) external;

    function withdraw(uint256 amount) external;

    function withdrawToken(uint256 amount, uint256 tokenId) external;

    function getReward(address account, address[] memory tokens) external;

    function earned(address token, address account)
        external
        view
        returns (uint256);

    function tokenIds(address account) external view returns (uint256);

    function optIn(address[] calldata tokens) external;

    function rewardsListLength() external view returns (uint256);

    function rewards(uint256 index) external view returns (address);

    function isOptIn(address user, address token) external view returns (bool);

    function optOut(address[] calldata tokens) external;

    function emergencyOptOut(address[] calldata tokens) external;
}
