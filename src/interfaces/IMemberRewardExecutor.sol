// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "./IActionExecutor.sol";

enum MemberRewardStatus {
    Unavailable,
    Pending,
    Settled
}

interface IMemberRewardExecutor is IActionExecutorEvents {
    function memberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status);

    function mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external returns (uint256 mintAmount);

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256[] calldata actionIds,
        uint256 memberId
    ) external returns (uint256[] memory mintAmounts);
}
