// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./IActionExecutor.sol";
import {IMemberRewardExecutor} from "./IMemberRewardExecutor.sol";

struct LpCreationParams {
    address joinTokenAddress;
    uint256 govRatioMultiplier;
    uint256 minGovRatio;
}

interface ILpExecutorErrors {
    error ZeroJoinTokenAddress();
    error InvalidJoinTokenFactory(
        address joinToken,
        address factory
    );
    error InvalidMinGovRatio(uint256 value);
    error InsufficientGovRatio(
        uint256 required,
        uint256 actual
    );
    error InvalidCreationDataLength(
        uint256 length,
        uint256 expectedLength
    );
    error InvalidCreationDataEncoding();
    error UnexpectedVoteData();
    error ZeroParticipationAmount();
    error WithdrawAmountExceeded(
        uint256 amount,
        uint256 joined
    );
    error NotJoined(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    );
}

interface ILpExecutorEvents {
    event LpActionCreated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address joinTokenAddress,
        uint256 govRatioMultiplier,
        uint256 minGovRatio
    );
    event LpJoined(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount
    );
    event LpWithdrawn(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount
    );
    event LpExited(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round
    );
}

interface ILpExecutor is IActionExecutor, IMemberRewardExecutor, ILpExecutorErrors, ILpExecutorEvents {
    function PAIR_FACTORY_ADDRESS() external view returns (address);

    function govRatioMultiplier(address tokenAddress, uint256 actionId) external view returns (uint256);
    function minGovRatio(address tokenAddress, uint256 actionId) external view returns (uint256);

    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external;

    function withdraw(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external;

    function deduction(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 amount,
            uint256[] memory joinBlocks,
            uint256[] memory joinAmounts
        );

    function deductionByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256);

    function govRatio(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 ratio, bool minted);

    function lpRewardBurn(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 burnedAmount);
}
