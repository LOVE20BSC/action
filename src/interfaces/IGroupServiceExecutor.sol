// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./IActionExecutor.sol";
import {IGroupRecipients} from "./IGroupRecipients.sol";
import {GroupRewardKey} from "./IGroupActionVerify.sol";
import {IMemberRewardExecutor, MemberRewardStatus} from "./IMemberRewardExecutor.sol";

struct GroupServiceCreationParams {
    address actionTokenAddress;
    uint256 govRatioMultiplier;
    uint256 publicVerifierRatio;
    uint256 providerIncentiveRatio;
}

struct MemberRewardSummary {
    uint256 pendingAmount;
    uint256 mintedAmount;
    MemberRewardStatus status;
}

struct ServiceRewardDetails {
    MemberRewardSummary verifier;
    MemberRewardSummary owner;
    MemberRewardSummary recipient;
    MemberRewardSummary provider;
    uint256 ownerBudget;
    uint256 ownerBudgetBeforeCap;
}

interface IGroupServiceExecutorEvents {
    event ServiceActionCreated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address actionTokenAddress,
        uint256 govRatioMultiplier,
        uint256 publicVerifierRatio,
        uint256 providerIncentiveRatio
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
    event ProviderPaid(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        uint256 indexed groupId,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 providerId,
        uint256 amount
    );
    event ServiceOwnerRewardBurned(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 amount
    );
    event ProviderReservePreparationAdvanced(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 ownerReward,
        uint256 processedActionCount,
        uint256 totalActionCount,
        uint256 providerReserve
    );
    event ServiceRewardsDistributed(
        address indexed serviceTokenAddress,
        uint256 indexed serviceActionId,
        uint256 round,
        address indexed actionTokenAddress,
        uint256 memberId,
        uint256 verifierReward,
        uint256 ownerReward,
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
    error ZeroActionTokenAddress();
    error InvalidRatioForPublicVerifier(uint256 value);
    error InvalidProviderIncentiveRatio(uint256 ratio);
    error ActionTokenParentMismatch(
        address actionTokenAddress,
        address serviceTokenAddress,
        address actualParentTokenAddress
    );
    error InvalidCreationDataLength(
        uint256 length,
        uint256 expectedLength
    );
    error InvalidCreationDataEncoding();
    error UnexpectedVoteData();
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
    error RecipientRewardAlreadyMinted(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    );
    error ZeroRecipientReward(
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    );
    error ProviderRewardAlreadyMinted(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    );
    error ZeroProviderReward(
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    );
    error ZeroOwnerRewardRemaining(uint256 groupId);
    error ProviderReservePreparationRequired(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 groupId,
        uint256 processedActionCount,
        uint256 totalActionCount
    );
    error TooManyRewardKeys(
        uint256 actual,
        uint256 limit
    );
}

interface IGroupServiceExecutor is
    IActionExecutor,
    IMemberRewardExecutor,
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

    function providerIncentiveRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256);

    function groupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 amount, bool isMinted);

    function prepareProviderReserve(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId,
        uint256 limit
    ) external returns (uint256 processedActionCount, uint256 totalActionCount, uint256 providerReserve);

    function providerReservePreparation(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (
        uint256 ownerWeight,
        uint256 processedActionCount,
        uint256 totalActionCount,
        uint256 providerReserve
    );

    function verifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external view returns (uint256 amount, bool isMinted);

    function mintGroupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external returns (uint256 amount);

    function mintVerifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external returns (uint256 amount);

    function groupOwnerBurn(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 pendingAmount, uint256 burnedAmount);

    function recipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 amount, bool isMinted);

    function mintRecipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external returns (uint256 amount);

    function providerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 amount, bool isMinted);

    function mintProviderReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external returns (uint256 amount);

    function providerRewardKeys(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount);

    function recipientRewardKeys(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount);

    function mintProviderRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        GroupRewardKey[] calldata keys
    ) external returns (uint256[] memory amounts);

    function mintRecipientRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        GroupRewardKey[] calldata keys
    ) external returns (uint256[] memory amounts);

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
            uint256 totalRecipientAmount,
            uint256 ownerAmount,
            uint256 providerReserve
        );

    function serviceRewardDetail(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 memberId
    ) external view returns (ServiceRewardDetails memory details);
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
