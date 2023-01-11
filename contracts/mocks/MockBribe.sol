// SPDX-License-Identifier: ISC
pragma solidity ^0.8.16;

import "../interfaces/solidly/IBribe.sol";
import "../interfaces/IERC20.sol";

contract MockBribe {
    uint256 public rewardAmount = 100e18;

    function setRewardAmount(uint256 _rewardAmount) external {
        rewardAmount = _rewardAmount;
    }

    function getReward(uint256 tokenId, address[] memory tokens) external {
        for (uint8 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).transfer(msg.sender, rewardAmount);
        }
    }
}
