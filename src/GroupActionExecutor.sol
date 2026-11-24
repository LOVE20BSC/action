// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {Pagination} from "@libs/Pagination.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {GroupActionManager} from "./GroupActionManager.sol";
import {GroupActionJoin} from "./GroupActionJoin.sol";
import {GroupActionVerify} from "./GroupActionVerify.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {IGroupActionExecutor, IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {GroupConfig} from "./interfaces/IGroupActionManager.sol";
import {VerifierApplication} from "./interfaces/IGroupActionVerify.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {JoinInfo} from "./interfaces/IGroupActionJoin.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";

contract GroupActionExecutor is IGroupActionExecutor, ExecutorBase {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using Uint256Set for Uint256Set.Storage;

    GroupActionStorage.Layout internal _layout;

    address public immutable override VOTE_ADDRESS;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address actionTargetAddress) ExecutorBase(actionTargetAddress) {
        VOTE_ADDRESS = IStake(STAKE_ADDRESS).VOTE_ADDRESS();
    }

    function _protocol() internal view returns (GroupActionStorage.Protocol memory protocol) {
        protocol.actionTargetAddress = ACTION_TARGET_ADDRESS;
        protocol.stakeAddress = STAKE_ADDRESS;
        protocol.memberNFTAddress = MEMBER_NFT_ADDRESS;
        protocol.phaseAddress = PHASE_ADDRESS;
        protocol.voteAddress = VOTE_ADDRESS;
    }

    function joinTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return _layout.joinTokenAddressByActionId[tokenAddress][actionId];
    }

    function requiredActivationStake(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.requiredActivationStakeByActionId[tokenAddress][actionId];
    }

    function maxJoinAmountRatio(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.maxJoinAmountRatioByActionId[tokenAddress][actionId];
    }

    function activationMinGovRatio(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.activationMinGovRatioByActionId[tokenAddress][actionId];
    }

    function requiredVerifierStake(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.requiredVerifierStakeByActionId[tokenAddress][actionId];
    }

    function verifierPunishmentRatio(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.verifierPunishmentRatioByActionId[tokenAddress][actionId];
    }

    function currentVerifyRound() external view returns (uint256) {
        return GroupActionVerify.currentVerifyRound(PHASE_ADDRESS);
    }

    function generatedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256) {
        return _layout.generatedActionRewardByGroupId(tokenAddress, round, actionId, groupId);
    }

    function providerScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 score, uint256 groupFinalScore) {
        groupFinalScore = _groupFinalScoreForReward(tokenAddress, round, actionId, groupId);
        if (groupFinalScore != 0) {
            GroupActionStorage.ProviderScores storage providerScores =
                _layout.providerScoresByGroupId[tokenAddress][actionId][round][groupId];
            score = providerScores.scoreByProviderId[providerId];
        }
    }

    function providerIdsWithPositiveScoreByActionIdByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory providerIds, uint256 totalCount) {
        return Pagination.paginate(
            _layout.providerIdsByGroupIdByActionId[tokenAddress][round][actionId][groupId], offset, limit, reverse
        );
    }

    function groupIdsWithProviderRewardByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return Pagination.paginate(
            _layout.providerGroupIdsByProviderId[tokenAddress][round][providerId], offset, limit, reverse
        );
    }

    function actionIdsWithProviderRewardByGroupIdByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return Pagination.paginate(
            _layout.providerActionIdsByGroupIdByProviderId[tokenAddress][round][providerId][groupId],
            offset,
            limit,
            reverse
        );
    }

    function _groupFinalScoreForReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) private view returns (uint256) {
        if (_layout.generatedActionReward[tokenAddress][actionId][round] == 0) return 0;
        return _layout.finalScoreByGroupId[tokenAddress][actionId][round][groupId];
    }

    function generatedActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256) {
        return _layout.generatedActionReward[tokenAddress][actionId][round];
    }

    function totalGeneratedActionReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256) {
        return _layout.totalGeneratedActionReward[tokenAddress][round];
    }

    function totalGeneratedActionRewardByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256 rewardAmount) {
        uint256[] storage actionIds = _layout.verifiedActionIdsByGroupId[tokenAddress][round][groupId];
        for (uint256 i = 0; i < actionIds.length; ++i) {
            rewardAmount += _layout.generatedActionRewardByGroupId(tokenAddress, round, actionIds[i], groupId);
        }
    }

    function totalGeneratedActionRewardAttributionByGroupOwnerId(
        address tokenAddress,
        uint256 round,
        uint256 groupOwnerId
    ) external view returns (uint256 attributedRewardAmount) {
        uint256[] storage actionIds = _layout.verifiedActionIdsByGroupId[tokenAddress][round][groupOwnerId];
        for (uint256 i = 0; i < actionIds.length; ++i) {
            attributedRewardAmount += _layout.generatedActionRewardAttributionByProviderId(
                tokenAddress, round, actionIds[i], groupOwnerId, groupOwnerId
            );
        }
    }

    function generatedActionRewardAttributionByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount) {
        return _layout.generatedActionRewardAttributionByProviderId(tokenAddress, round, actionId, groupId, providerId);
    }

    function totalGeneratedActionRewardAttributionByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount) {
        return GroupActionVerify.totalGeneratedActionRewardAttributionByProviderId(_layout, tokenAddress, round, providerId);
    }

    function groupIdsWithQuotaByProviderId(
        address tokenAddress,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return _layout.quotaGroupIdsByProviderId[tokenAddress][providerId].values(offset, limit, reverse);
    }

    function actionIdsWithQuotaByProviderIdByGroupId(
        address tokenAddress,
        uint256 providerId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return _layout.quotaActionIdsByProviderIdByGroupId[tokenAddress][providerId][groupId]
            .values(offset, limit, reverse);
    }

    function totalGeneratedActionRewardByVerifierId(
        address tokenAddress,
        uint256 round,
        uint256 verifierId
    ) external view returns (uint256) {
        return _layout.totalGeneratedActionRewardByVerifierId[tokenAddress][round][verifierId];
    }

    function actionIdsWithGeneratedActionReward(
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupActionManager.actionIdsWithGeneratedActionReward(_layout, tokenAddress, round, offset, limit, reverse);
    }

    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes calldata creationData
    ) external override onlyActionTarget {
        try GroupActionManager.onProposalCreated(_layout, _protocol(), tokenAddress, proposalId, creationData) {}
        catch (bytes memory reason) {
            try GroupActionManager.checkCreationEncoding(creationData) {} catch {
                revert IGroupActionExecutorErrors.InvalidGroupActionCreationData(creationData.length);
            }
            LowLevelCall.bubbleRevert(reason);
        }
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external override onlyActionTarget {
        GroupActionVerify.onProposalVoted(_layout, tokenAddress, round, proposalId, voterId, voteAmount, voteData);
    }

    function isGroupMember(uint256 groupId, uint256 memberId) external view returns (bool) {
        return _layout.membershipCountByGroupIdByMemberId[groupId][memberId] != 0;
    }

    function providerAttribution(
        uint256 groupId,
        uint256 memberId
    ) external view returns (uint256 providerId, uint256 joinedBlockNumber) {
        GroupActionStorage.ProviderAttribution storage attribution = _layout.providerAttribution[groupId][memberId];
        return (attribution.providerId, attribution.joinedBlock);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationValues
    ) external nonReentrant {
        GroupActionJoin.join(
            _layout, _protocol(), tokenAddress, actionId, groupId, memberId, amount, providerId, verificationValues
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdraw(address tokenAddress, uint256 actionId, uint256 memberId, uint256 amount) external nonReentrant {
        GroupActionJoin.withdraw(_layout, _protocol(), tokenAddress, actionId, memberId, amount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdrawProviderQuota(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) external nonReentrant {
        GroupActionJoin.withdrawProviderQuota(
            _layout, _protocol(), tokenAddress, actionId, groupId, memberId, providerId, amount
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(address tokenAddress, uint256 actionId, uint256 memberId) external nonReentrant {
        GroupActionJoin.exit(_layout, _protocol(), tokenAddress, actionId, memberId);
    }

    function joinInfo(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (JoinInfo memory info) {
        _checkJoinRound(round);
        return GroupActionJoin.joinInfo(_layout, tokenAddress, round, actionId, memberId);
    }

    function joinedAmountByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256) {
        _checkJoinRound(round);
        return GroupActionJoin.joinedAmountByGroupId(_layout, tokenAddress, round, actionId, groupId);
    }

    function groupIdsByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        _checkJoinRound(round);
        return GroupActionJoin.groupIdsByRound(_layout, tokenAddress, round, actionId, offset, limit, reverse);
    }

    function joinedActionIdsByGroupId(
        address tokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        _checkJoinRound(round);
        return GroupActionJoin.joinedActionIdsByGroupId(_layout, tokenAddress, groupId, round, offset, limit, reverse);
    }

    function memberIdsByGroupId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        _checkJoinRound(round);
        return GroupActionJoin.memberIdsByGroupId(_layout, tokenAddress, round, actionId, groupId, offset, limit, reverse);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function addProviderQuota(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        GroupActionJoin.addProviderQuota(
            _layout, _protocol(), tokenAddress, actionId, groupId, providerId, memberIds, amounts
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function removeProviderQuota(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds
    ) external nonReentrant {
        GroupActionJoin.removeProviderQuota(
            _layout, _protocol(), tokenAddress, actionId, groupId, providerId, memberIds
        );
    }

    function providerQuotas(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256[] memory quotaAmounts,
            uint256[] memory usedAmounts,
            uint256 totalCount
        )
    {
        return GroupActionJoin.providerQuotas(_layout, tokenAddress, actionId, groupId, providerId, offset, limit, reverse);
    }

    function providerAmountsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory providerIds,
            uint256[] memory amounts,
            uint256 totalCount
        )
    {
        _checkJoinRound(round);
        return GroupActionJoin.providerAmountsByMemberId(_layout, tokenAddress, round, actionId, memberId, offset, limit, reverse);
    }

    function joinedGroupIds(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return GroupActionJoin.joinedGroupIds(_layout, offset, limit, reverse);
    }

    function joinedGroupIdsByMemberId(
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return GroupActionJoin.joinedGroupIdsByMemberId(_layout, memberId, offset, limit, reverse);
    }

    function joinedTokenAddressesByGroupIdByMemberId(
        uint256 groupId,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 totalCount) {
        return GroupActionJoin.joinedTokenAddressesByGroupIdByMemberId(_layout, groupId, memberId, offset, limit, reverse);
    }

    function joinedMemberIds(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        return GroupActionJoin.joinedMemberIds(_layout, offset, limit, reverse);
    }

    function joinedMemberIdsByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        return GroupActionJoin.joinedMemberIdsByGroupId(_layout, groupId, offset, limit, reverse);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function submitOriginScores(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external {
        GroupActionVerify.submitOriginScores(
            _layout, _protocol(), tokenAddress, actionId, verifierId, groupId, startIndex, originScores
        );
    }

    function originScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 score,
            bool verified
        )
    {
        return GroupActionVerify.originScore(_layout, tokenAddress, round, actionId, memberId);
    }

    function finalScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return GroupActionVerify.finalScore(_layout, tokenAddress, round, actionId, memberId);
    }

    function totalActionFinalScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256) {
        return GroupActionVerify.totalActionFinalScore(_layout, tokenAddress, round, actionId);
    }

    function verifiedMemberCount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256) {
        return GroupActionVerify.verifiedMemberCount(_layout, tokenAddress, round, actionId, groupId);
    }

    function isRoundVerified(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool) {
        return GroupActionVerify.isRoundVerified(_layout, tokenAddress, round, actionId);
    }

    function verifier(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    )
        external view returns (uint256 verifierId, uint256 applicationId, uint256 voteAmount)
    {
        return GroupActionVerify.verifier(_layout, tokenAddress, round, actionId);
    }

    function verifierElectedRounds(
        address tokenAddress, uint256 actionId, uint256 applicationId, uint256 offset, uint256 limit, bool reverse
    ) external view returns (uint256[] memory rounds, uint256 totalCount) {
        return GroupActionVerify.verifierElectedRounds(_layout, tokenAddress, actionId, applicationId,
            GroupActionVerify.ApplicationPage({round: IPhase(PHASE_ADDRESS).currentPhase(), offset: offset, limit: limit, reverse: reverse}));
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function stopVerifierApplication(address tokenAddress, uint256 actionId, uint256 verifierId) external nonReentrant {
        GroupActionVerify.stopVerifierApplication(_layout, _protocol(), tokenAddress, actionId, verifierId);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function submitVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) external nonReentrant returns (uint256 applicationId) {
        return GroupActionVerify.submitVerifierApplication(
            _layout, _protocol(), tokenAddress, actionId, verifierId, description
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function cancelVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external nonReentrant {
        GroupActionVerify.cancelVerifierApplication(_layout, _protocol(), tokenAddress, actionId, verifierId);
    }

    function verifierStake(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (uint256) {
        return GroupActionVerify.verifierStake(_layout, tokenAddress, actionId, verifierId);
    }

    function verifierApplication(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application) {
        return GroupActionVerify.verifierApplication(_layout, _protocol(), tokenAddress, round, actionId, verifierId);
    }

    function hasVerifierApplicationByRound(
        address tokenAddress,
        uint256 round,
        uint256 verifierId
    ) external view returns (bool) {
        return GroupActionVerify.hasVerifierApplicationByRound(_layout, tokenAddress, round, verifierId);
    }

    function verifierApplications(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256 totalCount) {
        return GroupActionVerify.verifierApplications(_layout, _protocol(), tokenAddress, actionId, offset, limit, reverse);
    }

    function verifierApplicationsByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256[] memory voteAmounts, uint256 totalCount) {
        return GroupActionVerify.verifierApplicationsByRound(
            _layout,
            _protocol(),
            tokenAddress,
            actionId,
            GroupActionVerify.ApplicationPage({round: round, offset: offset, limit: limit, reverse: reverse})
        );
    }

    function voteAmountsByVerifierIds(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory voteAmounts) {
        return GroupActionVerify.voteAmountsByVerifierIds(_layout, tokenAddress, round, actionId, verifierIds);
    }

    function applicationVoters(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        return
            GroupActionVerify.applicationVoters(_layout, tokenAddress, round, actionId, applicationId, offset, limit, reverse);
    }

    function applicationVotersByVerifierId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        return GroupActionVerify.applicationVotersByVerifierId(
            _layout, tokenAddress, round, actionId, verifierId, offset, limit, reverse
        );
    }

    function verificationSchema(
        address tokenAddress,
        uint256 actionId
    ) external view returns (string[] memory keys, string[] memory descriptions) {
        return GroupActionVerify.verificationSchema(_layout, tokenAddress, actionId);
    }

    function verificationValue(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata key
    ) external view returns (string memory value) {
        return GroupActionVerify.verificationValue(_layout, tokenAddress, actionId, memberId, key);
    }

    function verificationInfos(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return GroupActionVerify.verificationInfos(_layout, tokenAddress, actionId, memberId);
    }

    function verificationInfosByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        _checkJoinRound(round);
        return GroupActionVerify.verificationInfosByRound(_layout, tokenAddress, round, actionId, memberId);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function activateGroup(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external nonReentrant {
        GroupActionManager.activateGroup(_layout, _protocol(), tokenAddress, actionId, groupId, config);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function deactivateGroup(address tokenAddress, uint256 actionId, uint256 groupId) external nonReentrant {
        GroupActionManager.deactivateGroup(_layout, _protocol(), tokenAddress, actionId, groupId);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setGroupConfig(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external {
        GroupActionManager.setGroupConfig(_layout, _protocol(), tokenAddress, actionId, groupId, config);
    }

    function groupState(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    )
        external
        view
        returns (
            GroupConfig memory config,
            bool active,
            uint256 activatedRound,
            uint256 deactivatedRound
        )
    {
        return GroupActionManager.groupState(_layout, tokenAddress, actionId, groupId);
    }

    function descriptionByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (string memory) {
        return GroupActionManager.descriptionByRound(_layout, tokenAddress, round, actionId, groupId);
    }

    function activeGroupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return GroupActionManager.activeGroupIds(_layout, tokenAddress, actionId, offset, limit, reverse);
    }

    function isGroupActive(address tokenAddress, uint256 actionId, uint256 groupId) external view returns (bool) {
        return GroupActionManager.isGroupActive(_layout, tokenAddress, actionId, groupId);
    }

    function maxJoinAmount(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return GroupActionManager.maxJoinAmount(_layout, _protocol(), tokenAddress, actionId);
    }

    function activationStakeByActionId(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return GroupActionManager.activationStakeByActionId(_layout, tokenAddress, actionId);
    }

    function totalActivationStake(address tokenAddress) external view returns (uint256) {
        return GroupActionManager.totalActivationStake(_layout, tokenAddress);
    }

    function totalActivationStakeByRound(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkJoinRound(round);
        return _layout.totalActivationStakeHistory[tokenAddress].value(round);
    }

    function activationStakeByGroupIdByRound(address tokenAddress, uint256 round, uint256 groupId) external view returns (uint256) {
        _checkJoinRound(round);
        return _layout.activationStakeHistoryByGroupId[tokenAddress][groupId].value(round);
    }

    function activationStakeByGroupId(address tokenAddress, uint256 groupId) external view returns (uint256) {
        return GroupActionManager.activationStakeByGroupId(_layout, tokenAddress, groupId);
    }

    function tokenAddressesByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 totalCount) {
        return GroupActionManager.tokenAddressesByGroupId(_layout, groupId, offset, limit, reverse);
    }

    function actionIdsByGroupId(
        address tokenAddress,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupActionManager.actionIdsByGroupId(_layout, tokenAddress, groupId, offset, limit, reverse);
    }

    function actionIdsWithActiveGroups(
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupActionManager.actionIdsWithActiveGroups(_layout, tokenAddress, offset, limit, reverse);
    }

    function hasActiveGroups(address tokenAddress, uint256 memberId) external view returns (bool) {
        return GroupActionManager.hasActiveGroups(_layout, tokenAddress, memberId);
    }

    function joinedAmountByActionId(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return _layout.joinedAmountByActionId[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return _layout.memberAmountAt(tokenAddress, round, actionId, memberId);
    }

    function memberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        return GroupActionJoin.memberReward(
            _layout,
            ACTION_TARGET_ADDRESS,
            PHASE_ADDRESS,
            GroupActionJoin.MemberRewardKey({tokenAddress: tokenAddress, round: round, actionId: actionId, memberId: memberId})
        );
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.mintRound(PHASE_ADDRESS);
    }

    function _mintMemberRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256[] calldata actionIds,
        uint256 memberId
    ) internal override returns (uint256[] memory mintAmounts) {
        GroupActionJoin.MemberRewardBatch memory batch = GroupActionJoin.MemberRewardBatch({
            tokenAddress: tokenAddress, memberId: memberId, rounds: rounds, actionIds: actionIds
        });
        return GroupActionJoin.mintMemberRewards(_layout, _protocol(), batch);
    }

    function _mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(
            tokenAddress,
            round,
            actionId,
            memberId,
            _layout.createdRoundByActionId[tokenAddress][actionId],
            _layout.memberMinted[tokenAddress][actionId][round][memberId]
        );

        mintAmount = GroupActionJoin.mintMemberReward(
            _layout,
            ACTION_TARGET_ADDRESS,
            GroupActionJoin.MemberRewardKey({tokenAddress: tokenAddress, round: round, actionId: actionId, memberId: memberId})
        );
        burnAmount = 0;
    }
}
