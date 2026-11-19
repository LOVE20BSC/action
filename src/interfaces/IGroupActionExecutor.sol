// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IGroupActionIndexes} from "./IGroupActionIndexes.sol";
import {IGroupActionJoin} from "./IGroupActionJoin.sol";
import {IGroupActionVerify} from "./IGroupActionVerify.sol";
import {IGroupActionManager} from "./IGroupActionManager.sol";
import {IActionExecutor} from "./IActionExecutor.sol";

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
    event GroupRewardPreparationAdvanced(
        address indexed tokenAddress,
        uint256 indexed groupId,
        uint256 indexed round,
        uint256 startIndex,
        uint256 processedActionCount,
        uint256 totalActionCount,
        uint256 weightAdded,
        uint256 totalWeight
    );
}

interface IGroupActionExecutorErrors {
    error ZeroJoinTokenAddress();
    error InvalidJoinTokenAddress(address joinTokenAddress);
    error InvalidMaxJoinAmountRatio(uint256 value);
    error InvalidActivationMinGovRatio(uint256 value);
    error InvalidVerifierPunishmentRatio(uint256 value);
    error InsufficientTargetDataItems(
        uint256 count,
        uint256 minCount
    );
    error TooManyTargetDataItems(
        uint256 count,
        uint256 maxCount
    );
    error InvalidTargetDataShape(
        uint256 index,
        uint256 length
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
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function generatedActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256);

    function totalGeneratedActionReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function totalGeneratedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function groupRewardPreparation(
        address tokenAddress,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256 processedActionCount, uint256 totalActionCount);

    function prepareGeneratedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 limit
    ) external returns (uint256 processedActionCount, uint256 totalActionCount);

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
}
