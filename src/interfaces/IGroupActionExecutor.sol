// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IGroupActionIndexes} from "./IGroupActionIndexes.sol";
import {IGroupActionJoin} from "./IGroupActionJoin.sol";
import {IGroupActionVerify} from "./IGroupActionVerify.sol";
import {IGroupActionManager} from "./IGroupActionManager.sol";
import {IActionExecutor} from "./IActionExecutor.sol";

interface IGroupActionExecutorErrors {
    error InvalidAddress();
    error InvalidSplits();
    error InvalidTargetDataLength();
    error VerificationInfoLengthMismatch();
    error DescriptionTooLong();
}

interface IGroupActionExecutor is
    IGroupActionIndexes,
    IGroupActionJoin,
    IGroupActionVerify,
    IGroupActionManager,
    IActionExecutor,
    IGroupActionExecutorErrors
{
    function JOIN_TOKEN_ADDRESS(address tokenAddress, uint256 actionId) external view returns (address);

    function ACTIVATION_STAKE_AMOUNT(address tokenAddress, uint256 actionId) external view returns (uint256);

    function MAX_JOIN_AMOUNT_RATIO(address tokenAddress, uint256 actionId) external view returns (uint256);

    function ACTIVATION_MIN_GOV_RATIO(address tokenAddress, uint256 actionId) external view returns (uint256);

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
}
