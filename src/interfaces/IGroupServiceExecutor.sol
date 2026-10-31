// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./IActionExecutor.sol";
import {IGroupRecipients} from "./IGroupRecipients.sol";

interface IGroupServiceExecutorEvents {
    event ServiceActionCreated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address actionTokenAddress,
        uint256 govRatioMultiplier,
        uint256 publicVerifierRatio
    );
    event RecipientPaid(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        uint256 indexed groupId,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 recipientId,
        uint256 amount
    );
    event ServiceRewardsDistributed(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        address indexed actionTokenAddress,
        uint256 memberId,
        uint256 verifierReward,
        uint256 ownerReward,
        uint256 ownerBurned,
        uint256 ownerDistributed,
        uint256 ownerRemaining
    );
    event ServiceJoined(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 indexed memberId,
        uint256 round
    );
    event ServiceExited(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 indexed memberId,
        uint256 round
    );
}

interface IGroupServiceExecutorErrors {
    error NotQualified(
        address actionTokenAddress,
        uint256 round,
        uint256 memberId
    );
    error ZeroActionTokenAddress();
    error InvalidRatioForPublicVerifier(uint256 value);
    error ActionTokenParentMismatch(
        address actionTokenAddress,
        address serviceTokenAddress,
        address actualParentTokenAddress
    );
    error TargetDataLengthMismatch(
        uint256 expected,
        uint256 actual
    );
    error InvalidTargetDataShape(
        uint256 index,
        uint256 length
    );
    error NotJoined(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    );
    error AlreadyJoined(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    );
    error GroupNotExist(uint256 groupId);
    error NotGroupOwner(uint256 groupId);
}

interface IGroupServiceExecutor is
    IActionExecutor,
    IGroupRecipients,
    IGroupServiceExecutorEvents,
    IGroupServiceExecutorErrors
{
    function GROUP_ACTION_EXECUTOR_ADDRESS() external view returns (address);
    function LAUNCH_ADDRESS() external view returns (address);
    function MINT_ADDRESS() external view returns (address);
    function currentVerifyRound() external view returns (uint256);

    function govRatioMultiplier(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256);

    function actionTokenAddress(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (address);
    function publicVerifierRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256);

    function rewardByRecipientId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256);

    function rewardDistribution(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            uint256[] memory amounts,
            uint256 ownerAmount
        );

    function serviceRewardByMemberId(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 verifierReward,
            uint256 ownerReward,
            uint256 ownerBurned,
            uint256 ownerDistributed,
            uint256 ownerRemaining,
            bool claimed
        );
    function totalGroupActionReward(
        address sourceTokenAddress,
        uint256 round
    ) external view returns (uint256);

    function join(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 memberId
    ) external;
}
