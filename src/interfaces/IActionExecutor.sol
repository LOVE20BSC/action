// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IProposalTarget} from "core/src/interfaces/IProposalTarget.sol";

interface IActionExecutorEvents {
    event MemberRewardMinted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 mintAmount,
        uint256 burnAmount
    );
}

interface IActionExecutorErrors {
    error AlreadyInitialized();
    error UnauthorizedCallback();
    error InvalidRound(uint256 round);
    error RoundNotStarted();
    error NotMemberOwner(uint256 memberId);
    error ProposalNotVoted(address tokenAddress, uint256 proposalId);
    error RewardAlreadyMinted(address tokenAddress, uint256 actionId, uint256 memberId, uint256 round);
    error BatchLengthMismatch(uint256 actionIdsLength, uint256 roundsLength);
}

interface IActionExecutor is IProposalTarget, IActionExecutorEvents, IActionExecutorErrors {
    function actionTarget() external view returns (address);
    function initialized() external view returns (bool);

    function exit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external;
    function mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external returns (uint256 mintAmount, uint256 burnAmount);
    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256 memberId,
        uint256[] calldata rounds
    ) external returns (uint256[] memory mintAmounts, uint256[] memory burnAmounts);
    function needBurnReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (bool needed);

    function currentVoteRound() external view returns (uint256);
    function currentJoinRound() external view returns (uint256);
    function currentMintRound() external view returns (uint256);
    function memberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted);
    function joinedAmount(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount);
    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 amount);
    function joinedAmountTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress);
}
