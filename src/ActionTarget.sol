// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./interfaces/IActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {Pagination} from "@libs/Pagination.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IMint} from "@core/interfaces/IMint.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IVote} from "@core/interfaces/IVote.sol";

contract ActionTarget is IActionTarget {
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using Uint256Set for Uint256Set.Storage;

    address public MEMBER_NFT_ADDRESS;
    address public SUBMIT_ADDRESS;
    address public VOTE_ADDRESS;
    address public MINT_ADDRESS;
    address public PHASE_ADDRESS;
    bool public initialized;

    // tokenAddress => memberId => actionIds
    mapping(address => mapping(uint256 => Uint256Set.Storage))
        internal _actionIdsByMemberId;

    // tokenAddress => actionId => RoundHistoryUint256Set.Storage
    mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage))
        internal _memberIdsByActionId;

    // tokenAddress => actionId => memberId => joined round
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _joinedRoundByMemberId;

    // tokenAddress => actionId => executor
    mapping(address => mapping(uint256 => address))
        internal _executorByActionId;

    // tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRoundByActionId;

    // tokenAddress => all bound actionIds
    mapping(address => uint256[]) internal _actionIds;

    // tokenAddress => executor => bound actionIds
    mapping(address => mapping(address => uint256[])) internal _actionIdsByExecutor;

    // forge-lint: disable-next-item(missing-zero-check)
    function init(address mintAddress) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        IMint mint = IMint(mintAddress);
        address voteAddress = mint.VOTE_ADDRESS();
        address submitAddress = mint.SUBMIT_ADDRESS();
        address memberNFTAddress = mint.MEMBER_NFT_ADDRESS();
        address phaseAddress = mint.PHASE_ADDRESS();

        MEMBER_NFT_ADDRESS = memberNFTAddress;
        SUBMIT_ADDRESS = submitAddress;
        VOTE_ADDRESS = voteAddress;
        MINT_ADDRESS = mintAddress;
        PHASE_ADDRESS = phaseAddress;
    }

    modifier onlyBoundExecutor(address tokenAddress, uint256 actionId) {
        if (!_isBoundExecutor(tokenAddress, actionId)) {
            revert UnauthorizedExecutor(tokenAddress, actionId);
        }
        _;
    }

    modifier onlySubmit() {
        if (msg.sender != SUBMIT_ADDRESS) {
            revert NotSubmit(msg.sender);
        }
        _;
    }

    modifier onlyVote() {
        if (msg.sender != VOTE_ADDRESS) {
            revert NotVote(msg.sender);
        }
        _;
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
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

    function executorByActionId(
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
        uint256 createdRound = _createdRoundByActionId[tokenAddress][actionId];
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
        _joinedRoundByMemberId[tokenAddress][actionId][memberId] = joinRound;

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
        delete _joinedRoundByMemberId[tokenAddress][actionId][memberId];

        emit JoinStateCleared({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound,
            forced: false
        });
    }

    function forceClearJoinState(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyMemberOwner(memberId) {
        if (!_memberIdsByActionId[tokenAddress][actionId].contains(memberId)) {
            return;
        }

        uint256 joinRound = _joinRound();

        _memberIdsByActionId[tokenAddress][actionId].remove(
            joinRound,
            memberId
        );
        _actionIdsByMemberId[tokenAddress][memberId].remove(actionId);
        delete _joinedRoundByMemberId[tokenAddress][actionId][memberId];

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
        uint256 round,
        uint256 memberId
    ) external view returns (bool) {
        if (round > _joinRound()) {
            return false;
        }
        return _memberIdsByActionId[tokenAddress][actionId].containsByRound(
            memberId,
            round
        );
    }

    function joinedRounds(
        address tokenAddress,
        uint256 actionId,
        uint256[] calldata memberIds
    ) external view returns (uint256[] memory rounds) {
        rounds = new uint256[](memberIds.length);
        for (uint256 i = 0; i < memberIds.length; ) {
            rounds[i] = _joinedRoundByMemberId[tokenAddress][actionId][
                memberIds[i]
            ];

            unchecked {
                i++;
            }
        }
    }

    function actionIdsByMemberId(
        address tokenAddress,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        (actionIds, totalCount) = _actionIdsByMemberId[tokenAddress][memberId]
            .values(offset, limit, reverse);
    }

    function memberIdsByActionId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        if (round > _joinRound()) {
            return (new uint256[](0), 0);
        }
        (memberIds, totalCount) = _memberIdsByActionId[tokenAddress][actionId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function mintActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external onlyBoundExecutor(tokenAddress, actionId) returns (uint256 amount) {
        if (!IVote(VOTE_ADDRESS).isProposalIdVoted(tokenAddress, round, actionId)) {
            revert ProposalNotVoted(tokenAddress, actionId);
        }

        address bound = _executorByActionId[tokenAddress][actionId];
        // forge-lint: disable-next-line(reentrancy-no-eth)
        amount = IMint(MINT_ADDRESS).mintProposalReward(tokenAddress, round, actionId, bound);

        emit ActionRewardMinted({
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
        bool isBound = _executorByActionId[tokenAddress][actionId] != address(0);
        if (isBound) {
            (amount, minted) = IMint(MINT_ADDRESS).proposalRewardByProposalId(tokenAddress, round, actionId);
        }
    }

    function actionIdsByExecutor(
        address tokenAddress,
        address executor,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        (actionIds, totalCount) = Pagination.paginate(
            _actionIdsByExecutor[tokenAddress][executor],
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
            uint256 totalCount
        )
    {
        (actionIds, totalCount) = Pagination.paginate(
            _actionIds[tokenAddress],
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
            uint256 totalCount
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
        totalCount = count;
    }

    function _currentRound() internal view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
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
        (uint256[] memory votedIds, ) = IVote(VOTE_ADDRESS).votedProposalIds(
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
    ) external onlySubmit {
        if (targetData.length == 0) {
            revert TargetDataLengthMismatch(1, 0);
        }
        if (targetData[0].length != 32) {
            revert InvalidTargetDataShape(0, targetData[0].length);
        }
        address executor = abi.decode(targetData[0], (address));
        if (executor.code.length == 0) {
            revert ExecutorNotContract(executor);
        }
        try IActionExecutor(executor).ACTION_TARGET_ADDRESS() returns (address acknowledged) {
            if (acknowledged != address(this)) {
                revert ExecutorTargetMismatch(address(this), acknowledged);
            }
        } catch {
            revert ExecutorHandshakeFailed(executor);
        }
        if (_executorByActionId[tokenAddress][proposalId] != address(0)) {
            revert AlreadyCreated(tokenAddress, proposalId);
        }

        // forge-lint: disable-next-line(missing-events-access-control)
        _executorByActionId[tokenAddress][proposalId] = executor;

        uint256 createdRound = _currentRound();
        _createdRoundByActionId[tokenAddress][proposalId] = createdRound;
        _actionIds[tokenAddress].push(proposalId);
        _actionIdsByExecutor[tokenAddress][executor].push(proposalId);

        emit ActionRegistered({
            tokenAddress: tokenAddress,
            actionId: proposalId,
            round: createdRound,
            executor: executor
        });

        IActionExecutor(executor).onProposalCreated(
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
    ) external onlySubmit {
        address bound = _executorByActionId[tokenAddress][proposalId];
        if (bound == address(0)) {
            revert UnboundProposal(tokenAddress, proposalId);
        }
        if (targetData.length == 0) {
            revert TargetDataLengthMismatch(1, 0);
        }
        if (targetData[0].length != 32) {
            revert InvalidTargetDataShape(0, targetData[0].length);
        }
        address targetDataExecutor = abi.decode(targetData[0], (address));
        if (targetDataExecutor != bound) {
            revert TargetDataExecutorMismatch(bound, targetDataExecutor);
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
        uint256 voteAmount,
        bytes[] calldata targetData
    ) external onlyVote {
        address bound = _executorByActionId[tokenAddress][proposalId];
        if (bound == address(0)) {
            revert UnboundProposal(tokenAddress, proposalId);
        }
        if (targetData.length != 0) {
            if (targetData[0].length != 32) {
                revert InvalidTargetDataShape(0, targetData[0].length);
            }
            address targetDataExecutor = abi.decode(targetData[0], (address));
            if (targetDataExecutor != bound) {
                revert TargetDataExecutorMismatch(bound, targetDataExecutor);
            }
        }

        IActionExecutor(bound).onProposalVoted(
            tokenAddress,
            round,
            proposalId,
            voterId,
            voteAmount,
            targetData
        );
    }
}
