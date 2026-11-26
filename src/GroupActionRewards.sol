// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IActionExecutorErrors, IActionExecutorEvents} from "./interfaces/IActionExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pagination} from "@libs/Pagination.sol";

library GroupActionRewards {
    using GroupActionStorage for GroupActionStorage.Layout;
    using SafeERC20 for IERC20;

    struct MemberRewardKey {
        address tokenAddress;
        uint256 round;
        uint256 actionId;
        uint256 memberId;
    }

    struct MemberRewardBatch {
        address tokenAddress;
        uint256 memberId;
        uint256[] rounds;
        uint256[] actionIds;
    }

    function totalGeneratedActionRewardByProviderId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount) {
        uint256[] storage ownGroupActionIds = self.verifiedActionIdsByGroupId[tokenAddress][round][providerId];
        attributedRewardAmount = self.totalGeneratedActionRewardByGroupIdByProviderId(
            tokenAddress, round, providerId, providerId, ownGroupActionIds
        );

        uint256[] storage externalGroupIds = self.providerGroupIdsByProviderId[tokenAddress][round][providerId];
        for (uint256 i = 0; i < externalGroupIds.length; ++i) {
            uint256 groupId = externalGroupIds[i];
            uint256[] storage actionIds =
                self.providerActionIdsByGroupIdByProviderId[tokenAddress][round][providerId][groupId];
            attributedRewardAmount += self.totalGeneratedActionRewardByGroupIdByProviderId(
                tokenAddress, round, groupId, providerId, actionIds
            );
        }
    }

    function actionIdsWithGeneratedActionReward(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return Pagination.paginate(self.actionIdsWithGeneratedActionReward[tokenAddress][round], offset, limit, reverse);
    }

    function memberReward(
        GroupActionStorage.Layout storage self,
        address actionTargetAddress,
        address phaseAddress,
        MemberRewardKey memory key
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        if (self.memberMinted[key.tokenAddress][key.actionId][key.round][key.memberId]) {
            return (0, self.memberMintedReward[key.tokenAddress][key.actionId][key.round][key.memberId], MemberRewardStatus.Settled);
        }
        {
            uint256 createdRound = self.createdRoundByActionId[key.tokenAddress][key.actionId];
            if (createdRound == 0 || key.round < createdRound || key.round > GroupActionRoundAxis.mintRound(phaseAddress)) {
                return (0, 0, MemberRewardStatus.Unavailable);
            }
        }
        uint256 totalScore = self.totalActionFinalScore[key.tokenAddress][key.actionId][key.round];
        if (totalScore == 0 || !self.roundVerified[key.tokenAddress][key.actionId][key.round]) {
            return (0, 0, MemberRewardStatus.Unavailable);
        }
        (uint256 score, ) = self.finalScoreAt(key.tokenAddress, key.round, key.actionId, key.memberId);
        if (score == 0) return (0, 0, MemberRewardStatus.Unavailable);

        (uint256 proposalReward, ) = IActionTarget(actionTargetAddress).actionReward(key.tokenAddress, key.round, key.actionId);
        pendingAmount = Math.mulDiv(proposalReward, score, totalScore);
        status = pendingAmount == 0 ? MemberRewardStatus.Unavailable : MemberRewardStatus.Pending;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintMemberReward(
        GroupActionStorage.Layout storage self,
        address actionTargetAddress,
        address phaseAddress,
        MemberRewardKey memory key
    ) external returns (uint256 mintAmount) {
        _checkMemberMintWindow(self, key.tokenAddress, key.round, key.actionId, key.memberId, phaseAddress);
        return _mintMemberReward(self, actionTargetAddress, key);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function mintMemberRewards(
        GroupActionStorage.Layout storage self,
        address actionTargetAddress,
        address phaseAddress,
        MemberRewardBatch memory batch
    ) external returns (uint256[] memory mintAmounts) {
        uint256 length = batch.actionIds.length;
        mintAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            uint256 round = batch.rounds[i];
            uint256 actionId = batch.actionIds[i];
            _checkMemberMintWindow(
                self, batch.tokenAddress, round, actionId, batch.memberId, phaseAddress
            );
            mintAmounts[i] = _mintMemberReward(
                self,
                actionTargetAddress,
                MemberRewardKey(batch.tokenAddress, round, actionId, batch.memberId)
            );
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkMemberMintWindow(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        address phaseAddress
    ) private view {
        uint256 createdRound = self.createdRoundByActionId[tokenAddress][actionId];
        if (createdRound == 0) revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        if (round < createdRound) revert IActionExecutorErrors.RoundBeforeActionCreated(round, createdRound);
        uint256 mintRound = GroupActionRoundAxis.mintRound(phaseAddress);
        if (mintRound == 0) revert IActionExecutorErrors.RoundNotStarted(1, 0);
        if (round > mintRound) revert IActionExecutorErrors.RoundAfterMintWindow(round, mintRound);
        if (self.memberMinted[tokenAddress][actionId][round][memberId]) {
            revert IActionExecutorErrors.RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }
    }

    function _mintMemberReward(
        GroupActionStorage.Layout storage self,
        address actionTargetAddress,
        MemberRewardKey memory key
    ) private returns (uint256 mintAmount) {
        uint256 totalScore = self.totalActionFinalScore[key.tokenAddress][key.actionId][key.round];
        if (totalScore == 0 || !self.roundVerified[key.tokenAddress][key.actionId][key.round]) {
            revert IActionExecutorErrors.MemberRewardPoolEmpty(key.tokenAddress, key.round);
        }
        (uint256 score, ) = self.finalScoreAt(key.tokenAddress, key.round, key.actionId, key.memberId);
        if (score == 0) revert IActionExecutorErrors.ZeroFinalScore(key.tokenAddress, key.actionId, key.memberId);

        IActionTarget actionTarget = IActionTarget(actionTargetAddress);
        (uint256 proposalReward, bool actionMinted) = actionTarget.actionReward(key.tokenAddress, key.round, key.actionId);
        if (proposalReward != 0 && !actionMinted) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            proposalReward = actionTarget.mintActionReward(key.tokenAddress, key.round, key.actionId);
        }
        if (proposalReward == 0) revert IActionExecutorErrors.MemberRewardPoolEmpty(key.tokenAddress, key.round);

        mintAmount = Math.mulDiv(proposalReward, score, totalScore);
        if (mintAmount == 0) revert IActionExecutorErrors.MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);

        self.memberMinted[key.tokenAddress][key.actionId][key.round][key.memberId] = true;
        self.memberMintedReward[key.tokenAddress][key.actionId][key.round][key.memberId] = mintAmount;
        IERC20(key.tokenAddress).safeTransfer(msg.sender, mintAmount);

        emit IActionExecutorEvents.MemberRewardMinted({
            tokenAddress: key.tokenAddress,
            actionId: key.actionId,
            memberId: key.memberId,
            round: key.round,
            mintAmount: mintAmount,
            burnAmount: 0
        });
    }
}
