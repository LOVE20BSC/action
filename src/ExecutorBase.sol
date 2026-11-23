// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IVote} from "@core/interfaces/IVote.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IActionExecutor, IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IMemberRewardExecutor} from "./interfaces/IMemberRewardExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {ActionRoundAxis} from "./ActionRoundAxis.sol";

abstract contract ExecutorBase is IActionExecutor, IMemberRewardExecutor, ReentrancyGuard {
    uint256 private constant MAX_MEMBER_REWARD_BATCH_SIZE = 4;

    address public immutable ACTION_TARGET_ADDRESS;
    address public immutable STAKE_ADDRESS;
    address public immutable MEMBER_NFT_ADDRESS;
    address public immutable PHASE_ADDRESS;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address actionTargetAddress) {
        ACTION_TARGET_ADDRESS = actionTargetAddress;
        // Load-bearing: Stake is resolved through ActionTarget's Vote, so the executor trusts a single
        // constructor input and cannot be wired to a Stake that disagrees with its ActionTarget.
        STAKE_ADDRESS = IVote(IActionTarget(actionTargetAddress).VOTE_ADDRESS()).STAKE_ADDRESS();
        MEMBER_NFT_ADDRESS = IStake(STAKE_ADDRESS).MEMBER_NFT_ADDRESS();
        PHASE_ADDRESS = IStake(STAKE_ADDRESS).PHASE_ADDRESS();
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    modifier onlyActionTarget() {
        if (msg.sender != ACTION_TARGET_ADDRESS) {
            revert IActionExecutorErrors.NotActionTarget(msg.sender);
        }
        _;
    }

    function onProposalSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 submitterId,
        bytes calldata submitData
    ) external virtual override onlyActionTarget {
        (tokenAddress, round, proposalId, submitterId, submitData);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) public override nonReentrant onlyMemberOwner(memberId) returns (uint256 mintAmount) {
        (mintAmount, ) = _mintMemberReward(tokenAddress, round, actionId, memberId);
    }

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256[] calldata actionIds,
        uint256 memberId
    ) external
        override
        nonReentrant
        onlyMemberOwner(memberId)
        returns (uint256[] memory mintAmounts)
    {
        uint256 length = actionIds.length;
        if (length != rounds.length) {
            revert IActionExecutorErrors.BatchLengthMismatch(length, rounds.length);
        }
        if (length > MAX_MEMBER_REWARD_BATCH_SIZE) {
            revert IActionExecutorErrors.TooManyMemberRewardActions(length, MAX_MEMBER_REWARD_BATCH_SIZE);
        }

        return _mintMemberRewards(tokenAddress, rounds, actionIds, memberId);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintMemberRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256[] calldata actionIds,
        uint256 memberId
    ) internal virtual returns (uint256[] memory mintAmounts) {
        uint256 length = actionIds.length;
        mintAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            (mintAmounts[i], ) = _mintMemberReward(tokenAddress, rounds[i], actionIds[i], memberId);
        }
    }

    function currentVoteRound() external view override returns (uint256) {
        uint256 phase = IPhase(PHASE_ADDRESS).currentPhase();
        if (phase < 1) {
            revert IActionExecutorErrors.RoundNotStarted(1, phase);
        }
        return phase;
    }

    function currentJoinRound() public view override returns (uint256) {
        uint256 round = _joinRound();
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    function currentMintRound() external view override returns (uint256) {
        uint256 round = _mintRound();
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    // Every item must pass these checks for an atomic batch to settle.
    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkMintWindow(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 createdRound,
        bool alreadyMinted
    ) internal view {
        if (createdRound == 0) {
            revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        }
        if (round < createdRound) {
            revert IActionExecutorErrors.RoundBeforeActionCreated(round, createdRound);
        }
        uint256 mintRound = _mintRound();
        if (mintRound == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        if (round > mintRound) {
            revert IActionExecutorErrors.RoundAfterMintWindow(round, mintRound);
        }
        if (alreadyMinted) {
            revert IActionExecutorErrors.RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }
    }

    function _joinRound() internal view returns (uint256) {
        return ActionRoundAxis.joinRound(PHASE_ADDRESS);
    }

    function _checkJoinRound(uint256 round) internal view {
        uint256 joinRound = _joinRound();
        if (round > joinRound) revert IActionExecutorErrors.RoundNotStarted(round, joinRound);
    }

    function _mintRound() internal view virtual returns (uint256);

    function _mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal virtual returns (uint256 mintAmount, uint256 burnAmount);
}
