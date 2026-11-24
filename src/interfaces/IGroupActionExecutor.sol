// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IGroupActionIndexes} from "./IGroupActionIndexes.sol";
import {IGroupActionJoin} from "./IGroupActionJoin.sol";
import {IGroupActionVerify} from "./IGroupActionVerify.sol";
import {IGroupActionManager} from "./IGroupActionManager.sol";
import {IActionExecutor} from "./IActionExecutor.sol";
import {IMemberRewardExecutor} from "./IMemberRewardExecutor.sol";

struct GroupActionCreationParams {
    address joinTokenAddress;
    uint256 activationStakeAmount;
    uint256 maxJoinAmountRatio;
    uint256 activationMinGovRatio;
    uint256 verifierStakeAmount;
    uint256 verifierPunishmentRatio;
    string[] verificationKeys;
    string[] verificationDescriptions;
}

interface IGroupActionExecutorEvents {
    event GroupActionCreated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address joinTokenAddress,
        uint256 activationStakeAmount,
        uint256 maxJoinAmountRatio,
        uint256 activationMinGovRatio,
        uint256 verifierStakeAmount,
        uint256 verifierPunishmentRatio,
        string[] verificationKeys,
        string[] verificationDescriptions
    );
}

interface IGroupActionExecutorErrors {
    error ZeroJoinTokenAddress();
    error InvalidJoinTokenAddress(address joinTokenAddress);
    error InvalidMaxJoinAmountRatio(uint256 value);
    error InvalidActivationMinGovRatio(uint256 value);
    error InvalidVerifierPunishmentRatio(uint256 value);
    error InvalidGroupActionCreationData(uint256 length);
    error InvalidVoteDataLength(
        uint256 length,
        uint256 expectedLength
    );
    error VerificationInfoLengthMismatch(
        uint256 expected,
        uint256 actual
    );
    error DescriptionTooLong(
        uint256 length,
        uint256 maxLength
    );
}

interface IGroupActionExecutor is
    IGroupActionIndexes,
    IGroupActionJoin,
    IGroupActionVerify,
    IGroupActionManager,
    IActionExecutor,
    IMemberRewardExecutor,
    IGroupActionExecutorEvents,
    IGroupActionExecutorErrors
{
    function requiredActivationStake(address tokenAddress, uint256 actionId) external view returns (uint256);

    function maxJoinAmountRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function activationMinGovRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function requiredVerifierStake(address tokenAddress, uint256 actionId) external view returns (uint256);

    function verifierPunishmentRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function VOTE_ADDRESS() external view returns (address);

    function currentVerifyRound() external view returns (uint256);

    function generatedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256);

    function generatedActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256);

    function generatedActionRewardAttributionByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount);

    function totalGeneratedActionReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function totalGeneratedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function totalGeneratedActionRewardAttributionByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount);

    function totalGeneratedActionRewardByVerifierId(
        address tokenAddress,
        uint256 round,
        uint256 verifierId
    ) external view returns (uint256);

    function actionIdsWithGeneratedActionReward(
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount);

    function providerIdsWithPositiveScoreByActionIdByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory providerIds, uint256 totalCount);

    function groupIdsWithQuotaByProviderId(
        address tokenAddress,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount);

    function actionIdsWithQuotaByProviderIdByGroupId(
        address tokenAddress,
        uint256 providerId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount);
}
