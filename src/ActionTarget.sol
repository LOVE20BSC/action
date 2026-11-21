// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutor} from "./interfaces/IActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {Pagination} from "@libs/Pagination.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IMint, ProposalRewardStatus} from "@core/interfaces/IMint.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IVote} from "@core/interfaces/IVote.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {ActionRoundAxis} from "./ActionRoundAxis.sol";

contract ActionTarget is IActionTarget {
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using Uint256Set for Uint256Set.Storage;

    uint256 private constant EXECUTOR_ADDRESS_BYTES = 20;

    address public MEMBER_NFT_ADDRESS;
    address public SUBMIT_ADDRESS;
    address public VOTE_ADDRESS;
    address public MINT_ADDRESS;
    address public PHASE_ADDRESS;

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
    constructor(address mintAddress) {
        IMint mint = IMint(mintAddress);
        PHASE_ADDRESS = mint.PHASE_ADDRESS();
        MEMBER_NFT_ADDRESS = mint.MEMBER_NFT_ADDRESS();
        SUBMIT_ADDRESS = mint.SUBMIT_ADDRESS();
        VOTE_ADDRESS = mint.VOTE_ADDRESS();
        MINT_ADDRESS = mintAddress;
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

        uint256 joinRound = _joinRound();

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
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (bool) {
        _checkJoinRound(round);
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
        uint256 round,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        _checkJoinRound(round);
        (memberIds, totalCount) = _memberIdsByActionId[tokenAddress][actionId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function mintActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
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
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 amount, bool minted) {
        if (_executorByActionId[tokenAddress][actionId] == address(0)) return (amount, minted);

        (uint256 reward, ProposalRewardStatus status) =
            IMint(MINT_ADDRESS).proposalRewardSettlement(tokenAddress, round, actionId);
        if (status != ProposalRewardStatus.Burned) {
            amount = reward;
            minted = status == ProposalRewardStatus.Minted;
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

    function votedActionIds(
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

    function votedActionIdsByExecutors(
        address tokenAddress,
        uint256 round,
        address[] calldata executors
    )
        external
        view
        returns (uint256[] memory actionIds, address[] memory actionExecutors)
    {
        (
            uint256[] memory boundIds,
            address[] memory boundExecutors,
            uint256 count
        ) = _boundActions(tokenAddress, round);

        uint256[] memory matchedIds = new uint256[](count);
        address[] memory matchedExecutors = new address[](count);
        uint256 matchedCount = 0;
        for (uint256 i = 0; i < count; ) {
            if (_containsExecutor(executors, boundExecutors[i])) {
                matchedIds[matchedCount] = boundIds[i];
                matchedExecutors[matchedCount] = boundExecutors[i];
                matchedCount++;
            }

            unchecked {
                i++;
            }
        }

        actionIds = new uint256[](matchedCount);
        actionExecutors = new address[](matchedCount);
        for (uint256 i = 0; i < matchedCount; ) {
            actionIds[i] = matchedIds[i];
            actionExecutors[i] = matchedExecutors[i];

            unchecked {
                i++;
            }
        }
    }

    function _containsExecutor(
        address[] calldata executors,
        address executor
    ) private pure returns (bool) {
        for (uint256 i = 0; i < executors.length; ) {
            if (executors[i] == executor) {
                return true;
            }

            unchecked {
                i++;
            }
        }
        return false;
    }

    function _currentRound() internal view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
    }

    function _joinRound() internal view returns (uint256) {
        return ActionRoundAxis.joinRound(PHASE_ADDRESS);
    }

    function _checkJoinRound(uint256 round) private view {
        uint256 joinRound = _joinRound();
        if (round > joinRound) revert RoundNotStarted(round, joinRound);
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
        (uint256[] memory votedIds, ) = IVote(VOTE_ADDRESS).votedProposalIdsByTarget(
            tokenAddress,
            round,
            address(this),
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
        bytes calldata creationData
    ) external onlySubmit {
        if (creationData.length < EXECUTOR_ADDRESS_BYTES) {
            revert CreationDataTooShort(creationData.length, EXECUTOR_ADDRESS_BYTES);
        }
        address executor = address(bytes20(creationData[:EXECUTOR_ADDRESS_BYTES]));
        if (executor.code.length == 0) {
            revert ExecutorNotContract(executor);
        }
        _checkExecutorHandshake(executor);
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
            creationData[EXECUTOR_ADDRESS_BYTES:]
        );
    }

    function onProposalSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 submitterId,
        bytes calldata submitData
    ) external onlySubmit {
        _boundExecutor(tokenAddress, proposalId).onProposalSubmitted(
            tokenAddress,
            round,
            proposalId,
            submitterId,
            submitData
        );
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external onlyVote {
        _boundExecutor(tokenAddress, proposalId).onProposalVoted(
            tokenAddress,
            round,
            proposalId,
            voterId,
            voteAmount,
            voteData
        );
    }

    function _checkExecutorHandshake(address executor) private view {
        (bool success, bytes32 targetWord, ) =
            LowLevelCall.staticcallReturn64Bytes(executor, abi.encodeCall(IActionExecutor.ACTION_TARGET_ADDRESS, ()));
        if (!success || LowLevelCall.returnDataSize() < 32 || uint256(targetWord) > type(uint160).max) {
            revert ExecutorHandshakeFailed(executor);
        }
        address acknowledged = address(uint160(uint256(targetWord)));
        if (acknowledged != address(this)) {
            revert ExecutorTargetMismatch(address(this), acknowledged);
        }
    }

    function _boundExecutor(
        address tokenAddress,
        uint256 proposalId
    ) private view returns (IActionExecutor) {
        address executor = _executorByActionId[tokenAddress][proposalId];
        if (executor == address(0)) {
            revert UnboundProposal(tokenAddress, proposalId);
        }
        return IActionExecutor(executor);
    }
}
