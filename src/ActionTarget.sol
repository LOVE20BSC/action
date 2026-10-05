// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./interfaces/IActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {Pagination} from "libs/Pagination.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "libs/Uint256Set.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IMint} from "core/src/interfaces/IMint.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IVote} from "core/src/interfaces/IVote.sol";
import {ILOVE20Token} from "core/src/interfaces/ILOVE20Token.sol";

contract ActionTarget is IActionTarget {
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using Uint256Set for Uint256Set.Storage;

    address public memberNFTAddress;
    address public submitAddress;
    address public voteAddress;
    address public mintAddress;
    address public phaseAddress;
    bool public initialized;

    // tokenAddress => memberId => actionIds
    mapping(address => mapping(uint256 => Uint256Set.Storage))
        internal _actionIdsByMemberId;

    // tokenAddress => actionId => RoundHistoryUint256Set.Storage
    mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage))
        internal _memberIdsByActionId;

    // tokenAddress => actionId => executor
    mapping(address => mapping(uint256 => address))
        internal _executorByActionId;

    // tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRound;

    // tokenAddress => actionId => round => minted amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _actionReward;

    // tokenAddress => actionId => round => whether this round's reward was minted
    mapping(address => mapping(uint256 => mapping(uint256 => bool)))
        internal _actionMinted;

    // tokenAddress => actionId => round => burned amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _burnedReward;

    // tokenAddress => actionId => round => whether this round's reward was burned
    mapping(address => mapping(uint256 => mapping(uint256 => bool)))
        internal _rewardBurned;

    // tokenAddress => all bound actionIds
    mapping(address => uint256[]) internal _allActionIds;

    // tokenAddress => executor => bound actionIds
    mapping(address => mapping(address => uint256[])) internal _actionIdsByExecutor;

    function init(
        address memberNFTAddress_,
        address submitAddress_,
        address voteAddress_,
        address mintAddress_
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        if (
            memberNFTAddress_ == address(0) ||
            submitAddress_ == address(0) ||
            voteAddress_ == address(0) ||
            mintAddress_ == address(0)
        ) {
            revert InvalidAddress();
        }

        address phaseAddress_ = IVote(voteAddress_).phaseAddress();
        if (phaseAddress_ == address(0)) {
            revert InvalidAddress();
        }

        memberNFTAddress = memberNFTAddress_;
        submitAddress = submitAddress_;
        voteAddress = voteAddress_;
        mintAddress = mintAddress_;
        phaseAddress = phaseAddress_;
    }

    modifier onlyBoundExecutor(address tokenAddress, uint256 actionId) {
        if (!_isBoundExecutor(tokenAddress, actionId)) {
            revert UnauthorizedExecutor(tokenAddress, actionId);
        }
        _;
    }

    function _isBoundExecutor(
        address tokenAddress,
        uint256 actionId
    ) internal view returns (bool) {
        address bound = _executorByActionId[tokenAddress][actionId];
        return bound != address(0) && bound == msg.sender;
    }

    function executor(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address) {
        return _executorByActionId[tokenAddress][actionId];
    }

    function registerJoinState(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyBoundExecutor(tokenAddress, actionId) {
        uint256 currentRound = _currentRound();
        uint256 createdRound = _createdRound[tokenAddress][actionId];
        if (currentRound <= createdRound) {
            revert JoinNotOpen(tokenAddress, actionId, currentRound, createdRound);
        }
        if (_memberIdsByActionId[tokenAddress][actionId].contains(memberId)) {
            return;
        }

        uint256 joinRound = currentRound - 1;

        _memberIdsByActionId[tokenAddress][actionId].add(
            joinRound,
            memberId
        );
        _actionIdsByMemberId[tokenAddress][memberId].add(actionId);

        emit JoinStateRegistered({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound
        });
    }

    function clearJoinState(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyBoundExecutor(tokenAddress, actionId) {
        if (!_memberIdsByActionId[tokenAddress][actionId].contains(memberId)) {
            return;
        }

        uint256 joinRound = _joinRound();

        _memberIdsByActionId[tokenAddress][actionId].remove(
            joinRound,
            memberId
        );
        _actionIdsByMemberId[tokenAddress][memberId].remove(actionId);

        emit JoinStateCleared({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound,
            forced: false
        });
    }

    function forceExit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external {
        if (IMemberNFT(memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        if (!_memberIdsByActionId[tokenAddress][actionId].contains(memberId)) {
            return;
        }

        uint256 joinRound = _joinRound();

        _memberIdsByActionId[tokenAddress][actionId].remove(
            joinRound,
            memberId
        );
        _actionIdsByMemberId[tokenAddress][memberId].remove(actionId);

        emit JoinStateCleared({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound,
            forced: true
        });
    }

    function isJoined(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (bool) {
        return _memberIdsByActionId[tokenAddress][actionId].contains(memberId);
    }

    function isJoinedByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (bool) {
        if (round > _joinRound()) {
            return false;
        }
        return _memberIdsByActionId[tokenAddress][actionId].containsByRound(
            memberId,
            round
        );
    }

    function actionIdsByMemberId(
        address tokenAddress,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total) {
        (actionIds, total) = _actionIdsByMemberId[tokenAddress][memberId]
            .values(offset, limit, reverse);
    }

    function memberIdsByActionId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        if (round > _joinRound()) {
            return (new uint256[](0), 0);
        }
        (memberIds, total) = _memberIdsByActionId[tokenAddress][actionId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function mintActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external onlyBoundExecutor(tokenAddress, actionId) returns (uint256 amount) {
        if (_actionMinted[tokenAddress][actionId][round]) {
            revert AlreadyMinted(tokenAddress, actionId, round);
        }
        if (!IVote(voteAddress).isProposalIdVoted(tokenAddress, round, actionId)) {
            revert ProposalNotVoted(tokenAddress, actionId);
        }

        // forge-lint: disable-next-line(reentrancy-no-eth)
        amount = IMint(mintAddress).mintProposalReward(tokenAddress, round, actionId);
        _actionMinted[tokenAddress][actionId][round] = true;
        _actionReward[tokenAddress][actionId][round] = amount;

        address bound = _executorByActionId[tokenAddress][actionId];
        if (!ILOVE20Token(tokenAddress).transfer(bound, amount)) {
            revert TransferFailed(tokenAddress, bound, amount);
        }

        emit ActionRewardMinted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            amount: amount
        });
    }

    function burnRewardIfNeeded(address tokenAddress, uint256 actionId, uint256 round) external {
        address bound = _executorByActionId[tokenAddress][actionId];
        if (bound == address(0)) {
            return;
        }
        if (_rewardBurned[tokenAddress][actionId][round]) {
            return;
        }
        if (!IVote(voteAddress).isRoundEnded(round)) {
            revert InvalidRound(round);
        }

        (uint256 mintableAmount, bool minted) =
            IMint(mintAddress).proposalRewardByProposalId(tokenAddress, round, actionId);
        if (minted || mintableAmount == 0) {
            return;
        }

        if (!IActionExecutor(bound).needBurnReward(tokenAddress, actionId, round)) {
            return;
        }

        // Mint is a fixed dependency and its burn path makes no calls back into this
        // contract; the ledger writes are safe to follow the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 amount = IMint(mintAddress).burnUnmintedProposalReward(tokenAddress, round, actionId);
        _rewardBurned[tokenAddress][actionId][round] = true;
        _burnedReward[tokenAddress][actionId][round] = amount;

        emit RewardBurned({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            amount: amount
        });
    }

    function actionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount, bool minted) {
        address bound = _executorByActionId[tokenAddress][actionId];
        if (bound != address(0)) {
            minted = _actionMinted[tokenAddress][actionId][round];
            if (minted) {
                amount = _actionReward[tokenAddress][actionId][round];
            } else if (!_rewardBurned[tokenAddress][actionId][round]) {
                (amount, ) = IMint(mintAddress).proposalRewardByProposalId(tokenAddress, round, actionId);
            }
        }
    }

    function burnInfo(address tokenAddress, uint256 actionId, uint256 round)
        external view
        returns (uint256 amount, bool burned)
    {
        amount = _burnedReward[tokenAddress][actionId][round];
        burned = _rewardBurned[tokenAddress][actionId][round];
    }

    function actionIdsByExecutor(
        address tokenAddress,
        address executor_,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total) {
        (actionIds, total) = Pagination.paginate(
            _actionIdsByExecutor[tokenAddress][executor_],
            offset,
            limit,
            reverse
        );
    }

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
        )
    {
        (actionIds, total) = Pagination.paginate(
            _allActionIds[tokenAddress],
            offset,
            limit,
            reverse
        );
        executors = new address[](actionIds.length);
        for (uint256 i = 0; i < actionIds.length; ) {
            executors[i] = _executorByActionId[tokenAddress][actionIds[i]];

            unchecked {
                i++;
            }
        }
    }

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
        )
    {
        (uint256[] memory boundIds, address[] memory boundExecutors, uint256 count) =
            _boundActions(tokenAddress, round);

        uint256[] memory indices = Pagination.paginateIndices(
            count,
            offset,
            limit,
            reverse
        );
        actionIds = new uint256[](indices.length);
        executors = new address[](indices.length);
        for (uint256 i = 0; i < indices.length; ) {
            actionIds[i] = boundIds[indices[i]];
            executors[i] = boundExecutors[indices[i]];

            unchecked {
                i++;
            }
        }
        total = count;
    }

    function _currentRound() internal view returns (uint256) {
        return IPhase(phaseAddress).currentPhase();
    }

    function _joinRound() internal view returns (uint256) {
        uint256 currentRound = _currentRound();
        return currentRound == 0 ? 0 : currentRound - 1;
    }

    function _boundActions(
        address tokenAddress,
        uint256 round
    )
        internal
        view
        returns (
            uint256[] memory actionIds,
            address[] memory executors,
            uint256 count
        )
    {
        (uint256[] memory votedIds, ) = IVote(voteAddress).votedProposalIds(
            tokenAddress,
            round,
            0,
            type(uint256).max,
            false
        );

        actionIds = new uint256[](votedIds.length);
        executors = new address[](votedIds.length);
        for (uint256 i = 0; i < votedIds.length; ) {
            address bound = _executorByActionId[tokenAddress][votedIds[i]];
            if (bound != address(0)) {
                actionIds[count] = votedIds[i];
                executors[count] = bound;
                count++;
            }

            unchecked {
                i++;
            }
        }
    }

    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes[] calldata targetData
    ) external {
        if (msg.sender != submitAddress) {
            revert UnauthorizedCallback();
        }

        if (targetData.length == 0) {
            revert InvalidExecutor();
        }
        if (targetData[0].length != 32) {
            revert InvalidExecutor();
        }
        address executor_ = abi.decode(targetData[0], (address));
        if (executor_ == address(0) || executor_.code.length == 0) {
            revert InvalidExecutor();
        }
        try IActionExecutor(executor_).actionTarget() returns (address acknowledged) {
            if (acknowledged != address(this)) {
                revert InvalidExecutor();
            }
        } catch {
            revert InvalidExecutor();
        }
        if (_executorByActionId[tokenAddress][proposalId] != address(0)) {
            revert AlreadyCreated(tokenAddress, proposalId);
        }

        // forge-lint: disable-next-line(missing-events-access-control)
        _executorByActionId[tokenAddress][proposalId] = executor_;

        uint256 createdRound = _currentRound();
        _createdRound[tokenAddress][proposalId] = createdRound;
        _allActionIds[tokenAddress].push(proposalId);
        _actionIdsByExecutor[tokenAddress][executor_].push(proposalId);

        emit ActionCreated({
            tokenAddress: tokenAddress,
            actionId: proposalId,
            executor: executor_,
            round: createdRound
        });

        IActionExecutor(executor_).onProposalCreated(
            tokenAddress,
            proposalId,
            targetData
        );
    }

    function onProposalSubmitted(
        address tokenAddress,
        uint256 proposalId,
        uint256 submitterId,
        bytes[] calldata targetData
    ) external {
        if (msg.sender != submitAddress) {
            revert UnauthorizedCallback();
        }

        address bound = _executorByActionId[tokenAddress][proposalId];
        if (bound == address(0)) {
            revert UnboundProposal(tokenAddress, proposalId);
        }
        if (targetData.length == 0 || targetData[0].length != 32 || abi.decode(targetData[0], (address)) != bound) {
            revert InvalidExecutor();
        }

        IActionExecutor(bound).onProposalSubmitted(
            tokenAddress,
            proposalId,
            submitterId,
            targetData
        );
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 votes,
        bytes[] calldata targetData
    ) external {
        if (msg.sender != voteAddress) {
            revert UnauthorizedCallback();
        }

        address bound = _executorByActionId[tokenAddress][proposalId];
        if (bound == address(0)) {
            revert UnboundProposal(tokenAddress, proposalId);
        }
        if (targetData.length != 0) {
            if (targetData[0].length != 32 || abi.decode(targetData[0], (address)) != bound) {
                revert InvalidExecutor();
            }
        }

        IActionExecutor(bound).onProposalVoted(
            tokenAddress,
            round,
            proposalId,
            voterId,
            votes,
            targetData
        );
    }
}
