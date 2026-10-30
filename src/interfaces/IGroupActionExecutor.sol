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
        string[] verificationKeys,
        string[] verificationDescriptions
    );
}

interface IGroupActionExecutorErrors {
    error ZeroJoinTokenAddress();
    error InvalidMaxJoinAmountRatio(uint256 value);
    error InvalidActivationMinGovRatio(uint256 value);
    error TargetDataLengthMismatch(
        uint256 expected,
        uint256 actual
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
    function activationStakeAmount(address tokenAddress, uint256 actionId) external view returns (uint256);

    function maxJoinAmountRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function activationMinGovRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function verifierStakeAmount(address tokenAddress, uint256 actionId) external view returns (uint256);

    function SPLITS() external view returns (uint256[] memory);

    function init(
        address actionTargetAddress,
        address stakeAddress,
        uint256[] calldata splits
    ) external;

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
}
