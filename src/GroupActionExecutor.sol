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
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract GroupActionExecutor is IGroupActionExecutor, ExecutorBase {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    GroupActionStorage.Layout internal s;

    modifier onlyActionTarget() {
        if (msg.sender != s.actionTarget) {
            revert NotActionTarget(msg.sender);
        }
        _;
    }

    function JOIN_TOKEN_ADDRESS(address tokenAddress, uint256 actionId) external view returns (address) {
        return s.joinTokenAddress[tokenAddress][actionId];
    }

    function ACTIVATION_STAKE_AMOUNT(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return s.activationStakeAmount[tokenAddress][actionId];
    }

    function MAX_JOIN_AMOUNT_RATIO(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return s.maxJoinAmountRatio[tokenAddress][actionId];
    }

    function ACTIVATION_MIN_GOV_RATIO(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return s.activationMinGovRatio[tokenAddress][actionId];
    }

    function VERIFIER_STAKE_AMOUNT(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return s.verifierStakeAmount[tokenAddress][actionId];
    }

    function SPLITS() external view returns (uint256[] memory) {
        return s.splits;
    }

    function init(address actionTargetAddress, address stakeAddress, uint256[] calldata splits) external {
        if (s.initialized) {
            revert AlreadyInitialized();
        }
        s.initialized = true;

        IStake stake = IStake(stakeAddress);
        address memberNFTAddress = stake.MEMBER_NFT_ADDRESS();
        address phaseAddress = stake.PHASE_ADDRESS();
        address voteAddress = stake.VOTE_ADDRESS();

        s.actionTarget = actionTargetAddress;
        s.stakeAddress = stakeAddress;
        s.memberNFTAddress = memberNFTAddress;
        s.phaseAddress = phaseAddress;
        s.voteAddress = voteAddress;
        s.splits = splits;
    }

    function currentVerifyRound() external view returns (uint256) {
        uint256 round = GroupActionRoundAxis.verifyRound(s.phaseAddress);
        if (round == 0) {
            revert RoundNotStarted(1, 0);
        }
        return round;
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
        uint256 groupFinalScore = s.finalScoreByGroupId[tokenAddress][actionId][round][groupId];
        if (groupFinalScore == 0) {
            return 0;
        }
        (uint256 proposalReward, ) = IActionTarget(s.actionTarget).actionReward(tokenAddress, actionId, round);
        return Math.mulDiv(proposalReward, groupFinalScore, s.totalFinalScore[tokenAddress][actionId][round]);
    }

    function generatedActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256) {
        if (!_isRoundRewardable(tokenAddress, actionId, round)) {
            return 0;
        }
        (uint256 proposalReward, ) = IActionTarget(s.actionTarget).actionReward(tokenAddress, actionId, round);
        return proposalReward;
    }

    function onProposalCreated(address tokenAddress, uint256 actionId, bytes[] calldata targetData)
        external
        override
        onlyActionTarget
    {
        GroupActionManager.onProposalCreated(s, tokenAddress, actionId, targetData);
    }

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata)
        external
        virtual
        override
        onlyActionTarget
    {}

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 voterId,
        uint256 votes,
        bytes[] calldata targetData
    ) external override onlyActionTarget {
        GroupActionVerify.onProposalVoted(s, tokenAddress, actionId, round, voterId, votes, targetData);
    }

    function isGroupMember(uint256 groupId, uint256 memberId) external view returns (bool) {
        return s.membershipCountByGroupIdByMemberId[groupId][memberId] != 0;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationInfos_
    ) external nonReentrant {
        GroupActionJoin.join(s, tokenAddress, actionId, groupId, memberId, amount, providerId, verificationInfos_);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdraw(address tokenAddress, uint256 actionId, uint256 memberId, uint256 amount) external nonReentrant {
        GroupActionJoin.withdraw(s, tokenAddress, actionId, memberId, amount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function providerQuotaWithdraw(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) external nonReentrant {
        GroupActionJoin.providerQuotaWithdraw(s, tokenAddress, actionId, groupId, memberId, providerId, amount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(address tokenAddress, uint256 actionId, uint256 memberId) external nonReentrant {
        GroupActionJoin.exit(s, tokenAddress, actionId, memberId);
    }

    function joinInfo(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 joinedRound,
            uint256 amount,
            uint256 groupId,
            uint256 ownAmount,
            uint256 providerAmount
        )
    {
        return GroupActionJoin.joinInfo(s, tokenAddress, actionId, round, memberId);
    }

    function totalJoinedAmountByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return GroupActionJoin.totalJoinedAmountByGroupId(s, tokenAddress, actionId, round, groupId);
    }

    function groupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return GroupActionJoin.groupIds(s, tokenAddress, actionId, round, offset, limit, reverse);
    }

    function memberIdsByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return GroupActionJoin.memberIdsByGroupId(s, tokenAddress, actionId, round, groupId, offset, limit, reverse);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function providerQuotaAdd(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) external nonReentrant {
        GroupActionJoin.providerQuotaAdd(s, tokenAddress, actionId, groupId, providerId, memberIds, amounts);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function providerQuotaRemove(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds
    ) external nonReentrant {
        GroupActionJoin.providerQuotaRemove(s, tokenAddress, actionId, groupId, providerId, memberIds);
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
            uint256 total
        )
    {
        return GroupActionJoin.providerQuotas(s, tokenAddress, actionId, groupId, providerId, offset, limit, reverse);
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
            uint256 total
        )
    {
        return GroupActionJoin.providerAmountsByMemberId(s, tokenAddress, actionId, round, memberId, offset, limit, reverse);
    }

    function gGroupIds(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return GroupActionJoin.gGroupIds(s, offset, limit, reverse);
    }

    function gGroupIdsByMemberId(
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return GroupActionJoin.gGroupIdsByMemberId(s, memberId, offset, limit, reverse);
    }

    function gTokenAddressesByGroupIdByMemberId(
        uint256 groupId,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 total) {
        return GroupActionJoin.gTokenAddressesByGroupIdByMemberId(s, groupId, memberId, offset, limit, reverse);
    }

    function gMemberIds(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return GroupActionJoin.gMemberIds(s, offset, limit, reverse);
    }

    function gMemberIdsByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return GroupActionJoin.gMemberIdsByGroupId(s, groupId, offset, limit, reverse);
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
        GroupActionVerify.submitOriginScores(s, tokenAddress, actionId, verifierId, groupId, startIndex, originScores);
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
        return GroupActionVerify.originScore(s, tokenAddress, actionId, round, memberId);
    }

    function finalScore(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return GroupActionVerify.finalScore(s, tokenAddress, actionId, round, memberId);
    }

    function totalFinalScore(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return GroupActionVerify.totalFinalScore(s, tokenAddress, actionId, round);
    }

    function verifiedMemberCount(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return GroupActionVerify.verifiedMemberCount(s, tokenAddress, actionId, round, groupId);
    }

    function isRoundVerified(address tokenAddress, uint256 actionId, uint256 round) external view returns (bool) {
        return GroupActionVerify.isRoundVerified(s, tokenAddress, actionId, round);
    }

    function lockedVerifierId(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return GroupActionVerify.lockedVerifierId(s, tokenAddress, actionId, round);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function submitVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) external nonReentrant returns (uint256 applicationId) {
        return GroupActionVerify.submitVerifierApplication(s, tokenAddress, actionId, verifierId, description);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function cancelVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external nonReentrant {
        GroupActionVerify.cancelVerifierApplication(s, tokenAddress, actionId, verifierId);
    }

    function verifierStake(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (uint256) {
        return GroupActionVerify.verifierStake(s, tokenAddress, actionId, verifierId);
    }

    function verifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application) {
        return GroupActionVerify.verifierApplication(s, tokenAddress, actionId, round, verifierId);
    }

    function verifierApplications(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256 total) {
        return GroupActionVerify.verifierApplications(s, tokenAddress, actionId, offset, limit, reverse);
    }

    function votesByVerifierIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory votes) {
        return GroupActionVerify.votesByVerifierIds(s, tokenAddress, actionId, round, verifierIds);
    }

    function topVerifiers(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory verifierIds, uint256[] memory votes) {
        return GroupActionVerify.topVerifiers(s, tokenAddress, actionId, round);
    }

    function applicationVoters(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory votes, uint256 total) {
        return
            GroupActionVerify.applicationVoters(s, tokenAddress, actionId, round, applicationId, offset, limit, reverse);
    }

    function applicationVotersByVerifierId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory votes, uint256 total) {
        return GroupActionVerify.applicationVotersByVerifierId(
            s, tokenAddress, actionId, round, verifierId, offset, limit, reverse
        );
    }

    function verificationSchema(
        address tokenAddress,
        uint256 actionId
    ) external view returns (string[] memory keys, string[] memory descriptions) {
        return GroupActionVerify.verificationSchema(s, tokenAddress, actionId);
    }

    function verificationValue(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata key
    ) external view returns (string memory value) {
        return GroupActionVerify.verificationValue(s, tokenAddress, actionId, memberId, key);
    }

    function verificationInfos(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return GroupActionVerify.verificationInfos(s, tokenAddress, actionId, memberId);
    }

    function verificationInfosByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (string[] memory keys, string[] memory values) {
        return GroupActionVerify.verificationInfosByRound(s, tokenAddress, actionId, memberId, round);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function activateGroup(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external nonReentrant {
        GroupActionManager.activateGroup(s, tokenAddress, actionId, groupId, config);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function deactivateGroup(address tokenAddress, uint256 actionId, uint256 groupId) external nonReentrant {
        GroupActionManager.deactivateGroup(s, tokenAddress, actionId, groupId);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function updateGroupConfig(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external {
        GroupActionManager.updateGroupConfig(s, tokenAddress, actionId, groupId, config);
    }

    function groupInfo(
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
        return GroupActionManager.groupInfo(s, tokenAddress, actionId, groupId);
    }

    function descriptionByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory) {
        return GroupActionManager.descriptionByRound(s, tokenAddress, actionId, round, groupId);
    }

    function activeGroupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return GroupActionManager.activeGroupIds(s, tokenAddress, actionId, offset, limit, reverse);
    }

    function isGroupActive(address tokenAddress, uint256 actionId, uint256 groupId) external view returns (bool) {
        return GroupActionManager.isGroupActive(s, tokenAddress, actionId, groupId);
    }

    function maxJoinAmount(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return GroupActionManager.maxJoinAmount(s, tokenAddress, actionId);
    }

    function staked(address tokenAddress, uint256 actionId) external view returns (uint256) {
        return GroupActionManager.staked(s, tokenAddress, actionId);
    }

    function totalStaked(address tokenAddress) external view returns (uint256) {
        return GroupActionManager.totalStaked(s, tokenAddress);
    }

    function totalStakedByMemberId(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return GroupActionManager.totalStakedByMemberId(s, tokenAddress, memberId);
    }

    function tokenAddressesByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 total) {
        return GroupActionManager.tokenAddressesByGroupId(s, groupId, offset, limit, reverse);
    }

    function actionIdsByGroupId(
        address tokenAddress,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds_, uint256 total) {
        return GroupActionManager.actionIdsByGroupId(s, tokenAddress, groupId, offset, limit, reverse);
    }

    function actionIds(
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds_, uint256 total) {
        return GroupActionManager.actionIds(s, tokenAddress, offset, limit, reverse);
    }

    function hasActiveGroups(address tokenAddress, uint256 memberId) external view returns (bool) {
        return GroupActionManager.hasActiveGroups(s, tokenAddress, memberId);
    }

    function actionTarget() external view returns (address) {
        return s.actionTarget;
    }

    function initialized() external view returns (bool) {
        return s.initialized;
    }

    function joinedAmount(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        if (round > s.joinRound()) {
            return 0;
        }
        return s.totalJoinedAmount[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256) {
        if (round > s.joinRound()) {
            return 0;
        }
        return s.memberAmountAt(tokenAddress, actionId, round, memberId);
    }

    function joinedAmountTokenAddress(address tokenAddress, uint256 actionId) external view returns (address) {
        return s.joinTokenAddress[tokenAddress][actionId];
    }

    function memberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted) {
        minted = s.memberMinted[tokenAddress][actionId][round][memberId];
        if (minted) {
            return (
                s.memberMintedReward[tokenAddress][actionId][round][memberId],
                s.memberBurnedReward[tokenAddress][actionId][round][memberId],
                // forge-lint: disable-next-line(boolean-cst)
                true
            );
        }

        uint256 createdRound_ = s.createdRound[tokenAddress][actionId];
        if (createdRound_ == 0 || round < createdRound_ || round > _mintRound()) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        uint256 totalFinal = s.totalFinalScore[tokenAddress][actionId][round];
        if (totalFinal == 0 || !GroupActionVerify.isRoundVerified(s, tokenAddress, actionId, round)) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        uint256 memberFinalScore = _memberFinalScore(tokenAddress, actionId, round, memberId);
        if (memberFinalScore == 0) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }
        (uint256 proposalReward, ) = IActionTarget(s.actionTarget).actionReward(tokenAddress, actionId, round);
        // forge-lint: disable-next-line(boolean-cst)
        return (Math.mulDiv(proposalReward, memberFinalScore, totalFinal), 0, false);
    }

    function _isRoundRewardable(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) private view returns (bool) {
        return s.totalFinalScore[tokenAddress][actionId][round] != 0
            && GroupActionVerify.isRoundVerified(s, tokenAddress, actionId, round);
    }

    function _memberFinalScore(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (uint256) {
        (uint256 score, ) = GroupActionVerify.finalScore(s, tokenAddress, actionId, round, memberId);
        return score;
    }

    function _memberNFTAddress() internal view override returns (address) {
        return s.memberNFTAddress;
    }

    function _phaseAddress() internal view override returns (address) {
        return s.phaseAddress;
    }

    function _joinRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.joinRound(s.phaseAddress);
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.mintRound(s.phaseAddress);
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 createdRound_ = s.createdRound[tokenAddress][actionId];
        if (createdRound_ == 0) {
            revert ActionNotCreated(tokenAddress, actionId);
        }
        if (round < createdRound_) {
            revert RoundBeforeActionCreated(round, createdRound_);
        }
        uint256 mintRound = _mintRound();
        if (round > mintRound) {
            revert RoundAfterMintWindow(round, mintRound);
        }

        if (s.memberMinted[tokenAddress][actionId][round][memberId]) {
            revert RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }

        uint256 totalFinal = s.totalFinalScore[tokenAddress][actionId][round];
        if (totalFinal != 0 && GroupActionVerify.isRoundVerified(s, tokenAddress, actionId, round)) {
            uint256 memberFinalScore = _memberFinalScore(tokenAddress, actionId, round, memberId);
            if (memberFinalScore != 0) {
                (uint256 proposalReward, bool actionMinted) =
                    IActionTarget(s.actionTarget).actionReward(tokenAddress, actionId, round);
                if (!actionMinted && proposalReward != 0) {
                    // forge-lint: disable-next-line(reentrancy-no-eth)
                    proposalReward = IActionTarget(s.actionTarget).mintActionReward(tokenAddress, actionId, round);
                }
                mintAmount = Math.mulDiv(proposalReward, memberFinalScore, totalFinal);
            }
        }

        if (mintAmount == 0 && burnAmount == 0) {
            revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
        }

        s.memberMinted[tokenAddress][actionId][round][memberId] = true;
        s.memberMintedReward[tokenAddress][actionId][round][memberId] = mintAmount;
        s.memberBurnedReward[tokenAddress][actionId][round][memberId] = burnAmount;

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
