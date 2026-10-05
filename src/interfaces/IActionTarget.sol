// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IProposalTarget} from "core/src/interfaces/IProposalTarget.sol";

interface IActionTargetEvents {
    event JoinStateRegistered(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round
    );
    event JoinStateCleared(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        bool forced
    );
    event ActionCreated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address indexed executor,
        uint256 round
    );
    event ActionRewardMinted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed round,
        uint256 amount
    );
    event RewardBurned(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed round,
        uint256 amount
    );
}

interface IActionTargetErrors {
    error AlreadyInitialized();
    error InvalidAddress();
    error UnauthorizedCallback();
    error UnboundProposal(address tokenAddress, uint256 proposalId);
    error UnauthorizedExecutor(address tokenAddress, uint256 actionId);
    error JoinNotOpen(
        address tokenAddress,
        uint256 actionId,
        uint256 currentRound,
        uint256 createdRound
    );
    error NotMemberOwner(uint256 memberId);
    error ProposalNotVoted(address tokenAddress, uint256 proposalId);
    error InvalidExecutor();
    error AlreadyCreated(address tokenAddress, uint256 actionId);
    error AlreadyMinted(address tokenAddress, uint256 actionId, uint256 round);
    error InvalidRound(uint256 round);
    error TransferFailed(address tokenAddress, address to, uint256 amount);
}

interface IActionTarget is IProposalTarget, IActionTargetEvents, IActionTargetErrors {
    function memberNFTAddress() external view returns (address);
    function submitAddress() external view returns (address);
    function voteAddress() external view returns (address);
    function mintAddress() external view returns (address);
    function phaseAddress() external view returns (address);

    function initialized() external view returns (bool);
    function init(
        address memberNFTAddress,
        address submitAddress,
        address voteAddress,
        address mintAddress
    ) external;

    function registerJoinState(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external;
    function clearJoinState(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external;
    function forceExit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external;
    function mintActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external returns (uint256 amount);
    function burnRewardIfNeeded(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external;

    function isJoined(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (bool);
    function isJoinedByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (bool);
    function joinedRounds(
        address tokenAddress,
        uint256 actionId,
        uint256[] calldata memberIds
    ) external view returns (uint256[] memory rounds);
    function executor(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address);
    function actionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount, bool minted);
    function burnInfo(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount, bool burned);
    function actionIdsByMemberId(
        address tokenAddress,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total);
    function memberIdsByActionId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total);
    function actionIdsByExecutor(
        address tokenAddress,
        address executor,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total);
    function actions(
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            address[] memory executors,
            uint256 total
        );
    function votedActions(
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            address[] memory executors,
            uint256 total
        );
}
