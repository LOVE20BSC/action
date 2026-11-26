// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {GroupServiceRecipients} from "./GroupServiceRecipients.sol";
import {GroupServiceMemberRewards} from "./GroupServiceMemberRewards.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {MemberOwner} from "./MemberOwner.sol";
import {
    IGroupServiceExecutor, GroupServiceCreationParams, MemberRewardSummary
} from "./interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";

contract GroupServiceExecutor is IGroupServiceExecutor, ExecutorBase {
    uint256 public constant PRECISION = GroupServiceStorage.PRECISION;
    uint256 public constant MAX_RECIPIENTS_PER_ACTION = GroupServiceStorage.MAX_RECIPIENTS_PER_ACTION;
    uint256 public constant MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP = GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;

    uint256 private constant CREATION_DATA_BYTES = 128;

    GroupServiceStorage.Layout internal _layout;

    address public immutable GROUP_ACTION_EXECUTOR_ADDRESS;
    address public immutable override LAUNCH_ADDRESS;
    address public immutable override MINT_ADDRESS;

    modifier onlyGroupOwner(uint256 groupId) {
        address owner = MemberOwner.ownerOrZero(MEMBER_NFT_ADDRESS, groupId);
        if (owner == address(0)) {
            revert GroupNotExist(groupId);
        }
        if (owner != msg.sender) {
            revert NotGroupOwner(groupId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address groupActionExecutorAddress)
        ExecutorBase(IGroupActionExecutor(groupActionExecutorAddress).ACTION_TARGET_ADDRESS())
    {
        GROUP_ACTION_EXECUTOR_ADDRESS = groupActionExecutorAddress;
        LAUNCH_ADDRESS = IStake(STAKE_ADDRESS).LAUNCH_ADDRESS();
        MINT_ADDRESS = IActionTarget(ACTION_TARGET_ADDRESS).MINT_ADDRESS();
    }

    function _protocol() internal view returns (GroupServiceStorage.Protocol memory protocol) {
        protocol.memberNFTAddress = MEMBER_NFT_ADDRESS;
        protocol.groupActionExecutorAddress = GROUP_ACTION_EXECUTOR_ADDRESS;
        protocol.actionTargetAddress = ACTION_TARGET_ADDRESS;
        protocol.stakeAddress = STAKE_ADDRESS;
    }

    // Load-bearing: the service rounds are the served GroupAction rounds shifted by the same phase
    // base (vote = phase, join = phase - 1, verify = phase - 2, mint = phase - 3). The service runs
    // no verification of its own: it settles the finished GroupAction totals and group slices
    // at phase - 3, after the source verification window has closed.
    function currentVerifyRound() public view returns (uint256) {
        return GroupActionRoundAxis.currentVerifyRound(PHASE_ADDRESS);
    }

    function govRatioMultiplier(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.govRatioMultiplierByActionId[serviceTokenAddress][serviceActionId];
    }

    function actionTokenAddress(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (address) {
        return _layout.actionTokenAddressByActionId[serviceTokenAddress][serviceActionId];
    }

    function publicVerifierRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.publicVerifierRatioByActionId[serviceTokenAddress][serviceActionId];
    }

    function providerIncentiveRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.providerIncentiveRatioByActionId[serviceTokenAddress][serviceActionId];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = currentJoinRound();

        if (_layout.createdRoundByActionId[serviceTokenAddress][serviceActionId] == 0) {
            revert ActionNotCreated(serviceTokenAddress, serviceActionId);
        }
        if (IActionTarget(ACTION_TARGET_ADDRESS).isJoined(serviceTokenAddress, serviceActionId, memberId)) {
            revert AlreadyJoined(serviceTokenAddress, serviceActionId, memberId);
        }

        IActionTarget(ACTION_TARGET_ADDRESS).registerJoinState(serviceTokenAddress, serviceActionId, memberId);

        emit ServiceJoined({
            serviceTokenAddress: serviceTokenAddress,
            serviceActionId: serviceActionId,
            memberId: memberId,
            round: round
        });
    }

    function recipientRewardBySourceActionIdByGroupId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 rewardAmount, bool isMinted) {
        return GroupServiceMemberRewards.recipientRewardForSource(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            sourceActionId,
            groupId,
            _mintRound()
        );
    }

    function providerRewardBySourceActionIdByGroupId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 rewardAmount, bool isMinted) {
        return GroupServiceMemberRewards.providerRewardForSource(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            sourceActionId,
            groupId,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintRecipientRewardBySourceActionIdByGroupId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external nonReentrant onlyMemberOwner(recipientId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintRecipientRewardForSource(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            sourceActionId,
            groupId,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintProviderRewardBySourceActionIdByGroupId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external nonReentrant onlyMemberOwner(providerId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintProviderRewardForSource(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            sourceActionId,
            groupId,
            _mintRound()
        );
    }

    function recipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        MemberRewardSummary memory reward = GroupServiceMemberRewards.recipientReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            _mintRound()
        );
        return (reward.pendingAmount, reward.mintedAmount, reward.status);
    }

    function providerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        MemberRewardSummary memory reward = GroupServiceMemberRewards.providerReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            _mintRound()
        );
        return (reward.pendingAmount, reward.mintedAmount, reward.status);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintRecipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId
    ) external nonReentrant onlyMemberOwner(recipientId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintRecipientReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            PHASE_ADDRESS
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintProviderReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId
    ) external nonReentrant onlyMemberOwner(providerId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintProviderReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            PHASE_ADDRESS
        );
    }

    function groupIdsWithProviderRewardByProviderId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        address sourceTokenAddress =
            GroupServiceStorage.sourceTokenAddressForRound(_layout, serviceTokenAddress, round, serviceActionId);
        if (sourceTokenAddress == address(0)) return (new uint256[](0), 0);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).groupIdsWithProviderRewardByProviderId(
            sourceTokenAddress, round, providerId, offset, limit, reverse
        );
    }

    function actionIdsWithProviderRewardByGroupIdByProviderId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        address sourceTokenAddress =
            GroupServiceStorage.sourceTokenAddressForRound(_layout, serviceTokenAddress, round, serviceActionId);
        if (sourceTokenAddress == address(0)) return (new uint256[](0), 0);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).actionIdsWithProviderRewardByGroupIdByProviderId(
            sourceTokenAddress, round, groupId, providerId, offset, limit, reverse
        );
    }

    function groupIdsWithRecipientRewardByRecipientId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        address sourceTokenAddress =
            GroupServiceStorage.sourceTokenAddressForRound(_layout, serviceTokenAddress, round, serviceActionId);
        if (sourceTokenAddress == address(0)) return (new uint256[](0), 0);
        return GroupServiceRecipients.groupIdsByRecipientId(
            _layout, sourceTokenAddress, round, recipientId, offset, limit, reverse
        );
    }

    function actionIdsWithRecipientRewardByGroupIdByRecipientId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        address sourceTokenAddress =
            GroupServiceStorage.sourceTokenAddressForRound(_layout, serviceTokenAddress, round, serviceActionId);
        if (sourceTokenAddress == address(0)) return (new uint256[](0), 0);
        return GroupServiceRecipients.actionIdsByGroupIdByRecipientId(
            _layout, sourceTokenAddress, round, groupId, recipientId, offset, limit, reverse
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintProviderRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        uint256[] calldata sourceActionIds,
        uint256[] calldata groupIds
    ) external nonReentrant onlyMemberOwner(providerId) returns (uint256[] memory mintAmounts) {
        _checkSourceRewardBatchLength(sourceActionIds.length, groupIds.length);
        return GroupServiceMemberRewards.mintProviderRewards(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            sourceActionIds,
            groupIds,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintRecipientRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        uint256[] calldata sourceActionIds,
        uint256[] calldata groupIds
    ) external nonReentrant onlyMemberOwner(recipientId) returns (uint256[] memory mintAmounts) {
        _checkSourceRewardBatchLength(sourceActionIds.length, groupIds.length);
        return GroupServiceMemberRewards.mintRecipientRewards(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            sourceActionIds,
            groupIds,
            _mintRound()
        );
    }

    function joinedAmountByActionId(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).totalActivationStakeByRound(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId], round
        );
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).activationStakeByGroupIdByRound(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId], round, memberId
        );
    }

    function joinTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return _layout.actionTokenAddressByActionId[tokenAddress][actionId];
    }

    function groupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) {
            return (0, 0, MemberRewardStatus.Unavailable);
        }
        return GroupServiceMemberRewards.groupOwnerReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId)
        );
    }

    function groupOwnerRewardBudget(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 ownerBudgetAmount, uint256 ownerBudgetAmountBeforeCap) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) return (0, 0);
        return GroupServiceMemberRewards.groupOwnerRewardBudget(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId)
        );
    }

    function verifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) {
            return (0, 0, MemberRewardStatus.Unavailable);
        }
        return GroupServiceMemberRewards.verifierReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, verifierId)
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintGroupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external nonReentrant onlyMemberOwner(groupId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintGroupOwnerReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId),
            PHASE_ADDRESS
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintVerifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external nonReentrant onlyMemberOwner(verifierId) returns (uint256 mintAmount) {
        return GroupServiceMemberRewards.mintVerifierReward(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, verifierId),
            PHASE_ADDRESS
        );
    }

    function memberRewardDetail(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 memberId
    ) external view returns (
        MemberRewardSummary memory verifierRewardSummary,
        MemberRewardSummary memory groupOwnerRewardSummary,
        MemberRewardSummary memory recipientRewardSummary,
        MemberRewardSummary memory providerRewardSummary,
        uint256 ownerBudgetAmount,
        uint256 ownerBudgetAmountBeforeCap
    ) {
        GroupServiceMemberRewards.MemberRewardDetails memory details =
            _memberDetails(GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, memberId));
        return (
            details.verifier,
            details.groupOwner,
            details.recipient,
            details.provider,
            details.ownerBudgetAmount,
            details.ownerBudgetAmountBeforeCap
        );
    }

    function memberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        GroupServiceMemberRewards.MemberRewardDetails memory details =
            _memberDetails(GroupServiceStorage.MemberRewardKey(tokenAddress, round, actionId, memberId));
        pendingAmount = details.groupOwner.pendingAmount + details.verifier.pendingAmount
            + details.recipient.pendingAmount + details.provider.pendingAmount;
        mintedAmount = details.groupOwner.mintedAmount + details.verifier.mintedAmount
            + details.recipient.mintedAmount + details.provider.mintedAmount;
        bool hasPending = pendingAmount != 0 || details.groupOwner.status == MemberRewardStatus.Pending;
        bool hasSettled = mintedAmount != 0 || details.groupOwner.status == MemberRewardStatus.Settled;
        status = _status(hasPending, hasSettled);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setRecipients(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external onlyGroupOwner(groupId) {
        GroupServiceRecipients.setRecipients(
            _layout,
            _protocol(),
            tokenAddress,
            currentVerifyRound(),
            actionId,
            groupId,
            recipientIds,
            ratios,
            remarks
        );
    }

    function recipients(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            string[] memory remarks
        )
    {
        return GroupServiceRecipients.recipients(_layout, tokenAddress, round, actionId, groupId);
    }

    function recipientRatio(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 ratio) {
        return GroupServiceRecipients.recipientRatio(_layout, tokenAddress, round, actionId, groupId, recipientId);
    }

    function actionIdsWithRecipients(
        address tokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupServiceRecipients.actionIdsWithRecipients(
            _layout, tokenAddress, groupId, round, offset, limit, reverse
        );
    }

    function groupIdsByRecipientId(
        address tokenAddress,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return GroupServiceRecipients.groupIdsByRecipientId(
            _layout, tokenAddress, currentVerifyRound(), recipientId, offset, limit, reverse
        );
    }

    function actionIdsByGroupIdByRecipientId(
        address tokenAddress,
        uint256 groupId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupServiceRecipients.actionIdsByGroupIdByRecipientId(
            _layout, tokenAddress, currentVerifyRound(), groupId, recipientId, offset, limit, reverse
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = currentJoinRound();
        if (!IActionTarget(ACTION_TARGET_ADDRESS).isJoined(tokenAddress, actionId, memberId)) {
            revert NotJoined(tokenAddress, actionId, memberId);
        }

        IActionTarget(ACTION_TARGET_ADDRESS).clearJoinState(tokenAddress, actionId, memberId);

        emit ServiceExited({
            serviceTokenAddress: tokenAddress,
            serviceActionId: actionId,
            memberId: memberId,
            round: round
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes calldata creationData
    ) external override onlyActionTarget {
        if (creationData.length != CREATION_DATA_BYTES) {
            revert InvalidCreationDataLength(creationData.length, CREATION_DATA_BYTES);
        }
        if (abi.decode(creationData, (uint256)) > type(uint160).max) {
            revert InvalidCreationDataEncoding();
        }
        GroupServiceCreationParams memory params = abi.decode(creationData, (GroupServiceCreationParams));

        if (params.actionTokenAddress == address(0)) {
            revert ZeroActionTokenAddress();
        }
        if (params.publicVerifierRatio == 0 || params.publicVerifierRatio >= PRECISION) {
            revert InvalidRatioForPublicVerifier(params.publicVerifierRatio);
        }
        if (params.providerIncentiveRatio > PRECISION) {
            revert InvalidProviderIncentiveRatio(params.providerIncentiveRatio);
        }
        if (params.actionTokenAddress != tokenAddress) {
            address parentTokenAddress = ILaunch(LAUNCH_ADDRESS).parentToken(params.actionTokenAddress);
            if (parentTokenAddress != tokenAddress) {
                revert ActionTokenParentMismatch(params.actionTokenAddress, tokenAddress, parentTokenAddress);
            }
        }

        uint256 serviceActionId = proposalId;
        _layout.actionTokenAddressByActionId[tokenAddress][serviceActionId] = params.actionTokenAddress;
        _layout.govRatioMultiplierByActionId[tokenAddress][serviceActionId] = params.govRatioMultiplier;
        _layout.publicVerifierRatioByActionId[tokenAddress][serviceActionId] = params.publicVerifierRatio;
        _layout.providerIncentiveRatioByActionId[tokenAddress][serviceActionId] = params.providerIncentiveRatio;
        _layout.createdRoundByActionId[tokenAddress][serviceActionId] = IPhase(PHASE_ADDRESS).currentPhase();

        emit ServiceActionCreated({
            tokenAddress: tokenAddress,
            actionId: serviceActionId,
            actionTokenAddress: params.actionTokenAddress,
            govRatioMultiplier: params.govRatioMultiplier,
            publicVerifierRatio: params.publicVerifierRatio,
            providerIncentiveRatio: params.providerIncentiveRatio
        });
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external virtual override onlyActionTarget {
        (tokenAddress, round, proposalId, voterId, voteAmount);
        if (voteData.length != 0) revert UnexpectedVoteData();
    }

    function _memberDetails(
        GroupServiceStorage.MemberRewardKey memory key
    ) private view returns (GroupServiceMemberRewards.MemberRewardDetails memory details) {
        if (!_isSettleableRound(key.tokenAddress, key.round, key.actionId)) return details;
        return GroupServiceMemberRewards.memberRewardDetail(_layout, _protocol(), key);
    }

    function _status(
        bool hasPending,
        bool hasSettled
    ) private pure returns (MemberRewardStatus) {
        if (hasPending) return MemberRewardStatus.Pending;
        return hasSettled ? MemberRewardStatus.Settled : MemberRewardStatus.Unavailable;
    }

    function _isSettleableRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) internal view returns (bool) {
        uint256 createdRound = _layout.createdRoundByActionId[tokenAddress][actionId];
        return createdRound != 0 && round >= createdRound && round <= _mintRound();
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.mintRound(PHASE_ADDRESS);
    }

    function _checkSourceRewardBatchLength(
        uint256 actionCount,
        uint256 groupCount
    ) private pure {
        if (actionCount != groupCount) revert RewardArraysLengthMismatch(actionCount, groupCount);
        uint256 limit = GroupServiceStorage.MAX_REWARDS_PER_BATCH;
        if (actionCount > limit) revert TooManyRewards(actionCount, limit);
    }

    function _mintMemberRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256[] calldata actionIds,
        uint256 memberId
    ) internal override returns (uint256[] memory mintAmounts) {
        GroupServiceMemberRewards.MemberRewardBatch memory batch = GroupServiceMemberRewards.MemberRewardBatch({
            tokenAddress: tokenAddress, memberId: memberId, rounds: rounds, actionIds: actionIds
        });
        return GroupServiceMemberRewards.mintMemberRewards(_layout, _protocol(), batch, PHASE_ADDRESS);
    }

    function _mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        return GroupServiceMemberRewards.mintMemberReward(
            _layout, _protocol(), GroupServiceStorage.MemberRewardKey(tokenAddress, round, actionId, memberId), PHASE_ADDRESS
        );
    }
}
