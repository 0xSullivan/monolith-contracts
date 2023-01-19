// SPDX-License-Identifier: ISC
pragma solidity ^0.8.16;

import "../interfaces/solidly/IGauge.sol";
import "../interfaces/IERC20.sol";

contract MockGauge {
    uint256 public rewardAmount = 100e18;

    address[] public rewards;

    constructor(address[] memory _rewards) public {
        rewards = _rewards;
    }

    function rewardsListLength() external returns (uint256) {
        return rewards.length;
    }

    function optIn(address[] memory rewardTokens) external {}

    function setRewardAmount(uint256 _rewardAmount) external {
        rewardAmount = _rewardAmount;
    }

    function deposit(uint256 amount, uint256 tokenId) external {}

    function withdraw(uint256 amount) external {}

    function getReward(address account, address[] memory tokens) external {
        for (uint8 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).transfer(account, rewardAmount);
        }
    }

    function earned(address token, address account)
        external
        view
        returns (uint256)
    {
        return 0;
    }
}
