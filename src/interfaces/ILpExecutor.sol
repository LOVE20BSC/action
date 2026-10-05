// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./IActionExecutor.sol";

interface ILpExecutorErrors {
    error InvalidAddress();
    error InvalidJoinTokenAddress();
    error InvalidJoinTokenFactory();
    error InvalidTargetDataLength();
    error InvalidMinGovRatio();
    error InsufficientGovRatio();
    error InvalidParticipationAmount();
    error NotJoined();
}

interface ILpExecutorEvents {
    event Joined(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount
    );
    event Withdrawn(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount
    );
    event Exited(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round
    );
}

interface ILpExecutor is IActionExecutor, ILpExecutorErrors, ILpExecutorEvents {
    function GOV_RATIO_MULTIPLIER(address tokenAddress, uint256 actionId) external view returns (uint256);

    function MIN_GOV_RATIO(address tokenAddress, uint256 actionId) external view returns (uint256);

    function init(address actionTargetAddress, address stakeAddress) external;

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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 amount,
            uint256[] memory joinBlocks,
            uint256[] memory joinAmounts
        );

    function totalDeduction(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256);

    function govRatio(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 ratio, bool minted);
}
