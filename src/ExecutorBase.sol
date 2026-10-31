// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IVote} from "@core/interfaces/IVote.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IActionExecutor, IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";

abstract contract ExecutorBase is IActionExecutor, ReentrancyGuard {
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

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata)
        external
        virtual
        override
        onlyActionTarget
    {}

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) public override nonReentrant onlyMemberOwner(memberId) returns (uint256 mintAmount, uint256 burnAmount) {
        return _mintMemberReward(tokenAddress, actionId, round, memberId);
    }

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256[] calldata rounds,
        uint256 memberId
    ) external
        override
        nonReentrant
        onlyMemberOwner(memberId)
        returns (uint256[] memory mintAmounts, uint256[] memory burnAmounts)
    {
        uint256 length = actionIds.length;
        if (length != rounds.length) {
            revert IActionExecutorErrors.BatchLengthMismatch(length, rounds.length);
        }

        mintAmounts = new uint256[](length);
        burnAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            (mintAmounts[i], burnAmounts[i]) = _mintMemberReward(tokenAddress, actionIds[i], rounds[i], memberId);
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

    function _requireMintWindow(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
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
        if (round > mintRound) {
            revert IActionExecutorErrors.RoundAfterMintWindow(round, mintRound);
        }
        if (alreadyMinted) {
            revert IActionExecutorErrors.RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }
    }

    function _joinRound() internal view virtual returns (uint256);

    function _mintRound() internal view virtual returns (uint256);

    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal virtual returns (uint256 mintAmount, uint256 burnAmount);
}
