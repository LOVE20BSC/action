// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {GroupActionManager} from "./GroupActionManager.sol";
import {GroupActionJoin} from "./GroupActionJoin.sol";
import {GroupActionVerify} from "./GroupActionVerify.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {GroupConfig} from "./interfaces/IGroupActionManager.sol";
import {VerifierApplication} from "./interfaces/IGroupActionVerify.sol";
import {JoinInfo} from "./interfaces/IGroupActionJoin.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract GroupActionExecutor is IGroupActionExecutor, ExecutorBase {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    GroupActionStorage.Layout internal _layout;

    address public immutable override VOTE_ADDRESS;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address actionTargetAddress, uint256[] memory splits) ExecutorBase(actionTargetAddress) {
        VOTE_ADDRESS = IStake(STAKE_ADDRESS).VOTE_ADDRESS();
        _layout.SPLITS = splits;
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

    function activationStakeAmount(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.activationStakeAmountByActionId[tokenAddress][actionId];
    }

    function maxJoinAmountRatio(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.maxJoinAmountRatioByActionId[tokenAddress][actionId];
    }

    function activationMinGovRatio(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.activationMinGovRatioByActionId[tokenAddress][actionId];
    }

    function verifierStakeAmount(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return _layout.verifierStakeAmountByActionId[tokenAddress][actionId];
    }

    function SPLITS() external view returns (uint256[] memory) {
        return _layout.SPLITS;
    }

    function currentVerifyRound() external view returns (uint256) {
        return GroupActionVerify.currentVerifyRound(PHASE_ADDRESS);
    }

    function generatedActionRewardByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        if (!_isRoundRewardable(tokenAddress, actionId, round)) {
            return 0;
        }
        uint256 groupFinalScore = _layout.finalScoreByGroupId[tokenAddress][actionId][round][groupId];
        if (groupFinalScore == 0) {
            return 0;
        }
        (uint256 proposalReward, ) = IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
        return Math.mulDiv(proposalReward, groupFinalScore, _layout.totalFinalScore[tokenAddress][actionId][round]);
    }

    function generatedActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256) {
        if (!_isRoundRewardable(tokenAddress, actionId, round)) {
            return 0;
        }
        (uint256 proposalReward, ) = IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
        return proposalReward;
    }

    function onProposalCreated(address tokenAddress, uint256 actionId, bytes[] calldata targetData)
        external
        override
        onlyActionTarget
    {
        GroupActionManager.onProposalCreated(_layout, _protocol(), tokenAddress, actionId, targetData);
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 voterId,
        uint256 voteAmount,
        bytes[] calldata targetData
    ) external override onlyActionTarget {
        GroupActionVerify.onProposalVoted(_layout, tokenAddress, actionId, round, voterId, voteAmount, targetData);
    }

    function isGroupMember(uint256 groupId, uint256 memberId) external view returns (bool) {
        return _layout.membershipCountByGroupIdByMemberId[groupId][memberId] != 0;
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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (JoinInfo memory info) {
        return GroupActionJoin.joinInfo(_layout, tokenAddress, actionId, round, memberId);
    }

    function joinedAmountByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return GroupActionJoin.joinedAmountByGroupId(_layout, tokenAddress, actionId, round, groupId);
    }

    function groupIdsByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return GroupActionJoin.groupIdsByRound(_layout, tokenAddress, actionId, round, offset, limit, reverse);
    }

    function memberIdsByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 totalCount) {
        return GroupActionJoin.memberIdsByGroupId(_layout, tokenAddress, actionId, round, groupId, offset, limit, reverse);
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
        uint256 actionId,
        uint256 round,
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
        return GroupActionJoin.providerAmountsByMemberId(_layout, tokenAddress, actionId, round, memberId, offset, limit, reverse);
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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 score,
            bool verified
        )
    {
        return GroupActionVerify.originScore(_layout, tokenAddress, actionId, round, memberId);
    }

    function finalScore(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return GroupActionVerify.finalScore(_layout, tokenAddress, actionId, round, memberId);
    }

    function totalFinalScore(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return GroupActionVerify.totalFinalScore(_layout, tokenAddress, actionId, round);
    }

    function verifiedMemberCount(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return GroupActionVerify.verifiedMemberCount(_layout, tokenAddress, actionId, round, groupId);
    }

    function isRoundVerified(address tokenAddress, uint256 actionId, uint256 round) external view returns (bool) {
        return GroupActionVerify.isRoundVerified(_layout, tokenAddress, actionId, round);
    }

    function lockedVerifierId(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return GroupActionVerify.lockedVerifierId(_layout, tokenAddress, actionId, round);
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
        uint256 actionId,
        uint256 round,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application) {
        return GroupActionVerify.verifierApplication(_layout, tokenAddress, actionId, round, verifierId);
    }

    function verifierApplications(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256 totalCount) {
        return GroupActionVerify.verifierApplications(_layout, tokenAddress, actionId, offset, limit, reverse);
    }

    function voteAmountsByVerifierIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory voteAmounts) {
        return GroupActionVerify.voteAmountsByVerifierIds(_layout, tokenAddress, actionId, round, verifierIds);
    }

    function topVerifiers(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory verifierIds, uint256[] memory voteAmounts) {
        return GroupActionVerify.topVerifiers(_layout, tokenAddress, actionId, round);
    }

    function applicationVoters(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        return
            GroupActionVerify.applicationVoters(_layout, tokenAddress, actionId, round, applicationId, offset, limit, reverse);
    }

    function applicationVotersByVerifierId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        return GroupActionVerify.applicationVotersByVerifierId(
            _layout, tokenAddress, actionId, round, verifierId, offset, limit, reverse
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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return GroupActionVerify.verificationInfosByRound(_layout, tokenAddress, actionId, round, memberId);
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
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory) {
        return GroupActionManager.descriptionByRound(_layout, tokenAddress, actionId, round, groupId);
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

    function staked(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return GroupActionManager.staked(_layout, tokenAddress, actionId);
    }

    function totalStaked(address tokenAddress) external view returns (uint256) {
        return GroupActionManager.totalStaked(_layout, tokenAddress);
    }

    function stakedByMemberId(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return GroupActionManager.stakedByMemberId(_layout, tokenAddress, memberId);
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

    function joinedAmountByActionId(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256 amount) {
        if (round > _joinRound()) {
            return 0;
        }
        return _layout.joinedAmountByActionId[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 amount) {
        if (round > _joinRound()) {
            return 0;
        }
        return _layout.memberAmountAt(tokenAddress, actionId, round, memberId);
    }

    function memberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted) {
        minted = _layout.memberMinted[tokenAddress][actionId][round][memberId];
        if (minted) {
            return (
                _layout.memberMintedReward[tokenAddress][actionId][round][memberId],
                _layout.memberBurnedReward[tokenAddress][actionId][round][memberId],
                // forge-lint: disable-next-line(boolean-cst)
                true
            );
        }

        uint256 createdRound = _layout.createdRoundByActionId[tokenAddress][actionId];
        if (createdRound == 0 || round < createdRound || round > _mintRound()) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        uint256 totalFinal = _layout.totalFinalScore[tokenAddress][actionId][round];
        if (totalFinal == 0 || !GroupActionVerify.isRoundVerified(_layout, tokenAddress, actionId, round)) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        uint256 memberFinalScore = _memberFinalScore(tokenAddress, actionId, round, memberId);
        if (memberFinalScore == 0) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        (uint256 proposalReward, ) = IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
        // forge-lint: disable-next-line(boolean-cst)
        return (Math.mulDiv(proposalReward, memberFinalScore, totalFinal), 0, false);
    }

    function _isRoundRewardable(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) private view returns (bool) {
        return _layout.totalFinalScore[tokenAddress][actionId][round] != 0
            && GroupActionVerify.isRoundVerified(_layout, tokenAddress, actionId, round);
    }

    function _memberFinalScore(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (uint256) {
        (uint256 score, ) = GroupActionVerify.finalScore(_layout, tokenAddress, actionId, round, memberId);
        return score;
    }

    function _joinRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.joinRound(PHASE_ADDRESS);
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.mintRound(PHASE_ADDRESS);
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(
            tokenAddress,
            actionId,
            round,
            memberId,
            _layout.createdRoundByActionId[tokenAddress][actionId],
            _layout.memberMinted[tokenAddress][actionId][round][memberId]
        );

        uint256 totalFinal = _layout.totalFinalScore[tokenAddress][actionId][round];
        if (totalFinal != 0 && GroupActionVerify.isRoundVerified(_layout, tokenAddress, actionId, round)) {
            uint256 memberFinalScore = _memberFinalScore(tokenAddress, actionId, round, memberId);
            if (memberFinalScore != 0) {
                (uint256 proposalReward, bool actionMinted) =
                    IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
                if (!actionMinted && proposalReward != 0) {
                    // forge-lint: disable-next-line(reentrancy-no-eth)
                    proposalReward = IActionTarget(ACTION_TARGET_ADDRESS).mintActionReward(tokenAddress, actionId, round);
                }
                mintAmount = Math.mulDiv(proposalReward, memberFinalScore, totalFinal);
            }
        }

        if (mintAmount == 0 && burnAmount == 0) {
            revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
        }

        _layout.memberMinted[tokenAddress][actionId][round][memberId] = true;
        _layout.memberMintedReward[tokenAddress][actionId][round][memberId] = mintAmount;
        _layout.memberBurnedReward[tokenAddress][actionId][round][memberId] = burnAmount;

        if (mintAmount != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, mintAmount);
        }

        emit MemberRewardMinted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            mintAmount: mintAmount,
            burnAmount: burnAmount
        });
    }
}
