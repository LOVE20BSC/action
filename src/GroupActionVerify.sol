// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {
    VerifierApplication,
    IGroupActionVerifyEvents,
    IGroupActionVerifyErrors
} from "./interfaces/IGroupActionVerify.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {RoundHistoryString} from "@libs/RoundHistoryString.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {Pagination} from "@libs/Pagination.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

library GroupActionVerify {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using SafeERC20 for IERC20;
    using Uint256Set for Uint256Set.Storage;

    uint256 private constant VERIFIER_VOTE_DATA_BYTES = 32;

    struct Penalty {
        uint256 amount;
        uint256[] failedRounds;
        uint256 pendingRound;
    }

    struct OriginSubmission {
        address tokenAddress;
        uint256 actionId;
        uint256 groupId;
        uint256 verifierId;
        uint256 startIndex;
    }

    struct VoteRecord {
        address tokenAddress;
        uint256 actionId;
        uint256 applicationId;
        uint256 round;
        uint256 voterId;
        uint256 verifierId;
        uint256 voteAmountAdded;
    }

    struct ApplicationPage {
        uint256 round;
        uint256 offset;
        uint256 limit;
        bool reverse;
    }

    modifier onlyMemberOwner(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        uint256 memberId
    ) {
        if (IMemberNFT(protocol.memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    function submitOriginScores(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external onlyMemberOwner(self, protocol, verifierId) {
        _submitOriginScores(
            self,
            protocol,
            OriginSubmission({
                tokenAddress: tokenAddress,
                actionId: actionId,
                groupId: groupId,
                verifierId: verifierId,
                startIndex: startIndex
            }),
            originScores
        );
    }

    function originScore(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return self.originScoreAt(tokenAddress, round, actionId, memberId);
    }

    function finalScore(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return self.finalScoreAt(tokenAddress, round, actionId, memberId);
    }

    function totalActionFinalScore(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 score) {
        return self.totalActionFinalScore[tokenAddress][actionId][round];
    }

    function verifiedMemberCount(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256) {
        return self.verifiedMemberCountByGroupId[tokenAddress][actionId][round][groupId];
    }

    function isRoundVerified(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool) {
        return self.roundVerified[tokenAddress][actionId][round];
    }

    function verifier(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 verifierId, uint256 applicationId, uint256 voteAmount) {
        applicationId = self.electedApplicationId[tokenAddress][actionId][round];
        verifierId = self.applicationVerifierId[tokenAddress][actionId][applicationId];
        voteAmount = self.voteAmountByApplicationId[tokenAddress][actionId][round][applicationId];
    }

    function verifierElectedRounds(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 applicationId,
        ApplicationPage memory page
    ) external view returns (uint256[] memory rounds, uint256 totalCount) {
        uint256[] storage history = self.electedRoundsByApplicationId[tokenAddress][actionId][applicationId];
        totalCount = history.length;
        if (totalCount != 0 && history[totalCount - 1] >= page.round) --totalCount;
        uint256[] memory indices = Pagination.paginateIndices(totalCount, page.offset, page.limit, page.reverse);
        rounds = new uint256[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) rounds[i] = history[indices[i]];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function submitVerifierApplication(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) external onlyMemberOwner(self, protocol, verifierId) returns (uint256 applicationId) {
        uint256 round = _checkApplicationSubmission(self, protocol, tokenAddress, actionId, verifierId, description);
        applicationId = self.currentApplicationId[tokenAddress][actionId][verifierId];
        if (applicationId != 0) {
            _checkAcceptingVotes(self, tokenAddress, round, actionId, applicationId);
            self.applicationDescription[tokenAddress][actionId][applicationId].record(round + 1, description);
            emit IGroupActionVerifyEvents.VerifierApplicationDescriptionUpdated({
                tokenAddress: tokenAddress,
                actionId: actionId,
                applicationId: applicationId,
                effectiveRound: round + 1,
                description: description
            });
            return applicationId;
        }
        uint256 previousApplicationId = self.applicationIdHistory[tokenAddress][actionId][verifierId].latestValue();
        if (previousApplicationId != 0
            && self.applicationStoppedRound[tokenAddress][actionId][previousApplicationId] == round) {
            revert IGroupActionVerifyErrors.ReapplicationInStoppedRound(round);
        }
        applicationId = ++self.applicationIdCount[tokenAddress][actionId];
        self.currentApplicationId[tokenAddress][actionId][verifierId] = applicationId;
        self.applicationVerifierId[tokenAddress][actionId][applicationId] = verifierId;
        self.activeApplicationIds[tokenAddress][actionId].add(round, applicationId);
        self.applicationIdHistory[tokenAddress][actionId][verifierId].record(round, applicationId);
        self.applicationActionIdsByVerifierId[tokenAddress][verifierId].add(round, actionId);
        self.withdrawnApplicationActionIds[tokenAddress][verifierId][round].remove(actionId);
        self.applicationDescription[tokenAddress][actionId][applicationId].record(round, description);
        uint256 requiredStake = self.requiredVerifierStakeByActionId[tokenAddress][actionId];
        self.verifierStakeByVerifierId[tokenAddress][actionId][verifierId] = requiredStake;
        if (requiredStake != 0) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), requiredStake);
            emit IGroupActionVerifyEvents.VerifierStakeDeposited({
                tokenAddress: tokenAddress,
                actionId: actionId,
                verifierId: verifierId,
                round: round,
                amount: requiredStake
            });
        }
        _emitVerifierApplicationSubmitted(
            tokenAddress, round, actionId, verifierId, applicationId, previousApplicationId, description
        );
    }

    function stopVerifierApplication(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external onlyMemberOwner(self, protocol, verifierId) {
        uint256 applicationId = self.currentApplicationId[tokenAddress][actionId][verifierId];
        if (applicationId == 0) revert IGroupActionVerifyErrors.NoActiveApplication(verifierId);
        if (self.applicationStoppedRound[tokenAddress][actionId][applicationId] != 0) {
            revert IGroupActionVerifyErrors.ApplicationStopped(applicationId);
        }
        _stopApplication(
            self, tokenAddress, IPhase(protocol.phaseAddress).currentPhase(), actionId, verifierId, applicationId
        );
    }

    function _stopApplication(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId,
        uint256 applicationId
    ) private {
        self.applicationStoppedRound[tokenAddress][actionId][applicationId] = round;
        emit IGroupActionVerifyEvents.VerifierApplicationStopped({
            tokenAddress: tokenAddress,
            actionId: actionId,
            verifierId: verifierId,
            applicationId: applicationId,
            round: round
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function cancelVerifierApplication(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external onlyMemberOwner(self, protocol, verifierId) {
        uint256 round = IPhase(protocol.phaseAddress).currentPhase();
        uint256 applicationId = self.currentApplicationId[tokenAddress][actionId][verifierId];
        if (applicationId == 0) revert IGroupActionVerifyErrors.NoActiveApplication(verifierId);
        Penalty memory penalty = _applicationPenalty(self, tokenAddress, round, actionId, applicationId);
        if (penalty.pendingRound != 0) {
            revert IGroupActionVerifyErrors.ApplicationStillResponsible(applicationId, penalty.pendingRound);
        }
        if (self.applicationStoppedRound[tokenAddress][actionId][applicationId] == 0) {
            _stopApplication(self, tokenAddress, round, actionId, verifierId, applicationId);
        }
        self.applicationWithdrawnRound[tokenAddress][actionId][applicationId] = round;
        self.activeApplicationIds[tokenAddress][actionId].remove(round, applicationId);
        self.applicationActionIdsByVerifierId[tokenAddress][verifierId].remove(round, actionId);
        self.withdrawnApplicationActionIds[tokenAddress][verifierId][round].add(actionId);
        if (self.voteAmountByApplicationId[tokenAddress][actionId][round][applicationId] != 0) {
            self.withdrawnVotedApplicationIds[tokenAddress][actionId][round].push(applicationId);
        }
        self.currentApplicationId[tokenAddress][actionId][verifierId] = 0;
        uint256 refund = self.verifierStakeByVerifierId[tokenAddress][actionId][verifierId] - penalty.amount;
        delete self.verifierStakeByVerifierId[tokenAddress][actionId][verifierId];
        if (penalty.amount != 0) ILOVE20Token(tokenAddress).burn(penalty.amount);
        if (penalty.failedRounds.length != 0) {
            emit IGroupActionVerifyEvents.VerifierApplicationPunished({
                tokenAddress: tokenAddress,
                actionId: actionId,
                applicationId: applicationId,
                verifierId: verifierId,
                failedRounds: penalty.failedRounds,
                burnedAmount: penalty.amount
            });
        }
        if (refund != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, refund);
            emit IGroupActionVerifyEvents.VerifierStakeRefunded({
                tokenAddress: tokenAddress,
                actionId: actionId,
                verifierId: verifierId,
                round: round,
                amount: refund
            });
        }
        emit IGroupActionVerifyEvents.VerifierApplicationCancelled({
            tokenAddress: tokenAddress,
            actionId: actionId,
            verifierId: verifierId,
            round: round,
            applicationId: applicationId
        });
    }

    function hasVerifierApplicationByRound(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 verifierId
    ) external view returns (bool) {
        return self.applicationActionIdsByVerifierId[tokenAddress][verifierId].countByRound(round) != 0
            || self.withdrawnApplicationActionIds[tokenAddress][verifierId][round].count() != 0;
    }

    function verifierStake(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (uint256) {
        return self.verifierStakeByVerifierId[tokenAddress][actionId][verifierId];
    }

    function verifierApplication(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application) {
        return _verifierApplication(
            self,
            tokenAddress,
            round,
            actionId,
            _applicationAtRound(self, tokenAddress, round, actionId, verifierId),
            IPhase(protocol.phaseAddress).currentPhase()
        );
    }

    function verifierApplications(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256 totalCount) {
        uint256[] memory applicationIds;
        (applicationIds, totalCount) = self.activeApplicationIds[tokenAddress][actionId].values(offset, limit, reverse);
        uint256 round = IPhase(protocol.phaseAddress).currentPhase();
        applications = new VerifierApplication[](applicationIds.length);
        for (uint256 i = 0; i < applicationIds.length; i++) {
            applications[i] = _verifierApplication(self, tokenAddress, round, actionId, applicationIds[i], round);
        }
    }

    function verifierApplicationsByRound(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        ApplicationPage memory page
    ) external view returns (VerifierApplication[] memory applications, uint256[] memory voteAmounts, uint256 totalCount) {
        uint256[] memory applicationIds;
        {
            RoundHistoryUint256Set.Storage storage active = self.activeApplicationIds[tokenAddress][actionId];
            uint256 activeCount = active.countByRound(page.round);
            uint256[] storage withdrawn = self.withdrawnVotedApplicationIds[tokenAddress][actionId][page.round];
            totalCount = activeCount + withdrawn.length;
            applicationIds = Pagination.paginateIndices(totalCount, page.offset, page.limit, page.reverse);
            for (uint256 i = 0; i < applicationIds.length; i++) {
                uint256 index = applicationIds[i];
                applicationIds[i] = index < activeCount
                    ? active.slotHistory[index].value(page.round) : withdrawn[index - activeCount];
            }
        }
        applications = new VerifierApplication[](applicationIds.length);
        voteAmounts = new uint256[](applicationIds.length);
        uint256 currentRound = IPhase(protocol.phaseAddress).currentPhase();
        for (uint256 i = 0; i < applicationIds.length; i++) {
            applications[i] = _verifierApplication(self, tokenAddress, page.round, actionId, applicationIds[i], currentRound);
            voteAmounts[i] = self.voteAmountByApplicationId[tokenAddress][actionId][page.round][applicationIds[i]];
        }
    }

    function voteAmountsByVerifierIds(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory voteAmounts) {
        voteAmounts = new uint256[](verifierIds.length);
        for (uint256 i = 0; i < verifierIds.length; i++) {
            uint256 applicationId = _applicationAtRound(self, tokenAddress, round, actionId, verifierIds[i]);
            if (applicationId != 0) {
                voteAmounts[i] = self.voteAmountByApplicationId[tokenAddress][actionId][round][applicationId];
            }
        }
    }


    function applicationVoters(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        return _applicationVoters(self, tokenAddress, round, actionId, applicationId, offset, limit, reverse);
    }

    function applicationVotersByVerifierId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 totalCount) {
        uint256 applicationId = _applicationAtRound(self, tokenAddress, round, actionId, verifierId);
        if (applicationId == 0) {
            return (new uint256[](0), new uint256[](0), 0);
        }
        return _applicationVoters(self, tokenAddress, round, actionId, applicationId, offset, limit, reverse);
    }

    function verificationSchema(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId
    ) external view returns (string[] memory keys, string[] memory descriptions) {
        return (self.verificationKeysByActionId[tokenAddress][actionId], self.verificationDescriptionsByActionId[tokenAddress][actionId]);
    }

    function verificationValue(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata key
    ) external view returns (string memory value) {
        string[] storage keys = self.verificationKeysByActionId[tokenAddress][actionId];
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) {
                return self.verificationValueHistory[tokenAddress][actionId][memberId][i].latestValue();
            }
        }
        return "";
    }

    function verificationInfos(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return _verificationValues(self, tokenAddress, 0, actionId, memberId, true);
    }

    function verificationInfosByRound(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return _verificationValues(self, tokenAddress, round, actionId, memberId, false);
    }

    function onProposalVoted(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external {
        if (voteData.length == 0) return;
        if (voteData.length != VERIFIER_VOTE_DATA_BYTES) {
            revert IGroupActionExecutorErrors.InvalidVoteDataLength(voteData.length, VERIFIER_VOTE_DATA_BYTES);
        }
        uint256 verifierId = abi.decode(voteData, (uint256));
        uint256 applicationId = self.currentApplicationId[tokenAddress][actionId][verifierId];
        if (applicationId == 0) revert IGroupActionVerifyErrors.NoActiveApplication(verifierId);
        _checkAcceptingVotes(self, tokenAddress, round, actionId, applicationId);
        if (voteAmount == 0) return;
        self.voteAmountByApplicationId[tokenAddress][actionId][round][applicationId] += voteAmount;
        self.voterIdsByApplicationId[tokenAddress][actionId][round][applicationId].add(voterId);
        self.voteAmountByApplicationIdByVoterId[tokenAddress][actionId][round][applicationId][voterId] += voteAmount;
        _updateElectedVerifier(self, tokenAddress, round, actionId, applicationId);
        _emitApplicationVoteRecorded(self, VoteRecord({
            tokenAddress: tokenAddress, actionId: actionId, applicationId: applicationId,
            round: round, voterId: voterId, verifierId: verifierId, voteAmountAdded: voteAmount
        }));
    }

    function _verifierApplication(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 descriptionRound,
        uint256 actionId,
        uint256 applicationId,
        uint256 currentRound
    ) private view returns (VerifierApplication memory application) {
        if (applicationId == 0) return application;
        application.applicationId = applicationId;
        application.verifierId = self.applicationVerifierId[tokenAddress][actionId][applicationId];
        application.description = self.applicationDescription[tokenAddress][actionId][applicationId].value(descriptionRound);
        application.stoppedRound = self.applicationStoppedRound[tokenAddress][actionId][applicationId];
        application.withdrawnRound = self.applicationWithdrawnRound[tokenAddress][actionId][applicationId];
        Penalty memory penalty = _applicationPenalty(self, tokenAddress, currentRound, actionId, applicationId);
        application.punishmentAmount = penalty.amount;
        application.failedRounds = penalty.failedRounds;
        application.pendingRound = penalty.pendingRound;
    }

    function _applicationAtRound(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId
    ) private view returns (uint256 applicationId) {
        applicationId = self.applicationIdHistory[tokenAddress][actionId][verifierId].value(round);
        uint256 withdrawnRound = self.applicationWithdrawnRound[tokenAddress][actionId][applicationId];
        if (withdrawnRound != 0 && round > withdrawnRound) return 0;
    }

    function _applicationPenalty(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 currentRound,
        uint256 actionId,
        uint256 applicationId
    ) private view returns (Penalty memory penalty) {
        uint256[] storage rounds = self.electedRoundsByApplicationId[tokenAddress][actionId][applicationId];
        uint256 start = rounds.length > 3 ? rounds.length - 3 : 0;
        uint256[3] memory failed;
        uint256 failedCount = 0;
        for (uint256 i = start; i < rounds.length; i++) {
            uint256 round = rounds[i];
            if (self.roundVerified[tokenAddress][actionId][round]) continue;
            // Joining is still open in R+1, so an empty roster cannot release the collateral yet.
            if (currentRound <= round + 1) {
                penalty.pendingRound = round;
            } else if (self.groupIdsByRound[tokenAddress][actionId].countByRound(round) != 0) {
                if (currentRound <= round + 2) penalty.pendingRound = round;
                else failed[failedCount++] = round;
            }
        }
        penalty.failedRounds = new uint256[](failedCount);
        for (uint256 i = 0; i < failedCount; i++) penalty.failedRounds[i] = failed[i];
        penalty.amount = Math.mulDiv(self.requiredVerifierStakeByActionId[tokenAddress][actionId],
            self.verifierPunishmentRatioByActionId[tokenAddress][actionId] * failedCount,
            3 * GroupActionStorage.PRECISION);
    }

    function _checkAcceptingVotes(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 currentRound,
        uint256 actionId,
        uint256 applicationId
    ) private view {
        if (self.applicationStoppedRound[tokenAddress][actionId][applicationId] != 0) {
            revert IGroupActionVerifyErrors.ApplicationStopped(applicationId);
        }
        Penalty memory penalty = _applicationPenalty(self, tokenAddress, currentRound, actionId, applicationId);
        if (penalty.failedRounds.length != 0) {
            revert IGroupActionVerifyErrors.ApplicationOverdue(applicationId, penalty.failedRounds[0]);
        }
    }

    function _scoreBatch(
        GroupActionStorage.Layout storage self,
        OriginSubmission memory submission,
        uint256 round,
        uint256 verifiedCount,
        uint256 memberCount,
        uint256[] calldata originScores
    ) internal returns (bool groupVerified) {
        (uint256[] memory memberIds, ) =
            _memberIds(self, submission.tokenAddress, round, submission.actionId, submission.groupId, verifiedCount, originScores.length);
        uint256 batchTotal = _scoreMembers(self, submission, round, memberIds, originScores);
        uint256 groupScore =
            self.finalScoreByGroupId[submission.tokenAddress][submission.actionId][round][submission.groupId] + batchTotal;
        self.finalScoreByGroupId[submission.tokenAddress][submission.actionId][round][submission.groupId] = groupScore;
        self.totalActionFinalScore[submission.tokenAddress][submission.actionId][round] += batchTotal;
        uint256 newVerifiedCount = verifiedCount + originScores.length;
        self.verifiedMemberCountByGroupId[submission.tokenAddress][submission.actionId][round][submission.groupId] = newVerifiedCount;
        groupVerified = _markGroupVerified(self, submission.tokenAddress, round, submission.actionId, newVerifiedCount, memberCount);
        if (groupVerified && groupScore != 0) {
            self.verifiedActionIdsByGroupId[submission.tokenAddress][round][submission.groupId].push(submission.actionId);
        }
    }

    function _scoreMembers(
        GroupActionStorage.Layout storage self,
        OriginSubmission memory submission,
        uint256 round,
        uint256[] memory memberIds,
        uint256[] calldata originScores
    ) private returns (uint256 batchTotal) {
        for (uint256 i = 0; i < originScores.length; i++) {
            uint256 score = _scoreMember(self, submission.tokenAddress, round, submission.actionId, memberIds[i], originScores[i]);
            batchTotal += score;
            if (score != 0) {
                _recordProviderScore(self, submission, round, memberIds[i], score);
            }
        }
    }

    function _recordProviderScore(
        GroupActionStorage.Layout storage self,
        OriginSubmission memory submission,
        uint256 round,
        uint256 memberId,
        uint256 score
    ) private {
        uint256 providerId = self.providerAttribution[submission.groupId][memberId].providerId;
        if (providerId == 0) providerId = submission.groupId;
        GroupActionStorage.ProviderScores storage scores =
            self.providerScoresByGroupId[submission.tokenAddress][submission.actionId][round][submission.groupId];
        uint256 previousScore = scores.scoreByProviderId[providerId];
        if (previousScore == 0) {
            if (providerId != submission.groupId) _recordProviderRewardSource(self, submission, round, providerId);
            self.providerIdsByGroupIdByActionId[submission.tokenAddress][round][submission.actionId][submission.groupId]
                .push(providerId);
        }
        scores.scoreByProviderId[providerId] = previousScore + score;
    }

    function _recordProviderRewardSource(
        GroupActionStorage.Layout storage self,
        OriginSubmission memory submission,
        uint256 round,
        uint256 providerId
    ) private {
        uint256[] storage actionIds =
            self.providerActionIdsByGroupIdByProviderId[submission.tokenAddress][round][providerId][submission.groupId];
        if (actionIds.length == 0) {
            self.providerGroupIdsByProviderId[submission.tokenAddress][round][providerId].push(submission.groupId);
        }
        actionIds.push(submission.actionId);
    }

    function _markGroupVerified(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifiedCount,
        uint256 memberCount
    ) internal returns (bool groupVerified) {
        if (verifiedCount != memberCount) {
            return false;
        }
        // Load-bearing: a round only ever becomes verified through this branch, and `isRoundVerified`
        // no longer re-derives it. A missed write leaves the round unsettled forever with no revert.
        uint256 verifiedGroups = ++self.verifiedGroupCountByRound[tokenAddress][actionId][round];
        if (verifiedGroups == self.groupIdsByRound[tokenAddress][actionId].countByRound(round)) {
            self.roundVerified[tokenAddress][actionId][round] = true;
        }
        return true;
    }

    function _scoreMember(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 score
    ) internal returns (uint256 weighted) {
        if (score < GroupActionStorage.MAX_ORIGIN_SCORE) {
            uint256 deduction = GroupActionStorage.MAX_ORIGIN_SCORE - score;
            self.originScoreDeductionByMemberId[tokenAddress][actionId][round][memberId] = deduction;
        }
        return self.memberAmountAt(tokenAddress, round, actionId, memberId) * score;
    }

    function _memberIds(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory memberIds, uint256 total) {
        RoundHistoryUint256Set.Storage storage memberSet = self.memberIdsByGroupId[tokenAddress][actionId][groupId];
        return memberSet.valuesByRound(round, offset, limit, false);
    }

    function _checkElectedVerifier(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId
    ) private view {
        uint256 applicationId = self.electedApplicationId[tokenAddress][actionId][round];
        if (applicationId == 0 || self.applicationVerifierId[tokenAddress][actionId][applicationId] != verifierId) {
            revert IGroupActionVerifyErrors.VerifierNotElected(verifierId, round);
        }
    }


    function _updateElectedVerifier(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 applicationId
    ) private {
        uint256 previousId = self.electedApplicationId[tokenAddress][actionId][round];
        if (previousId == applicationId) return;
        if (self.voteAmountByApplicationId[tokenAddress][actionId][round][applicationId]
            <= self.voteAmountByApplicationId[tokenAddress][actionId][round][previousId]) return;
        if (previousId != 0) self.electedRoundsByApplicationId[tokenAddress][actionId][previousId].pop();
        self.electedApplicationId[tokenAddress][actionId][round] = applicationId;
        self.electedRoundsByApplicationId[tokenAddress][actionId][applicationId].push(round);
    }


    function _applicationVoters(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) private view returns (uint256[] memory voterIds, uint256[] memory voteAmounts, uint256 total) {
        Uint256Set.Storage storage voterSet =
            self.voterIdsByApplicationId[tokenAddress][actionId][round][applicationId];
        (voterIds, total) = voterSet.values(offset, limit, reverse);
        voteAmounts = new uint256[](voterIds.length);
        for (uint256 i = 0; i < voterIds.length; i++) {
            voteAmounts[i] = self.voteAmountByApplicationIdByVoterId[tokenAddress][actionId][round][applicationId][voterIds[i]];
        }
    }

    function _verificationValues(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        bool latest
    ) internal view returns (string[] memory keys, string[] memory values) {
        keys = self.verificationKeysByActionId[tokenAddress][actionId];
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = latest
                ? self.verificationValueHistory[tokenAddress][actionId][memberId][i].latestValue()
                : self.verificationValueHistory[tokenAddress][actionId][memberId][i].value(round);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _submitOriginScores(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        OriginSubmission memory submission,
        uint256[] calldata originScores
    ) private {
        if (originScores.length == 0) {
            revert IGroupActionVerifyErrors.OriginScoresEmpty();
        }
        if (originScores.length > GroupActionStorage.MAX_VERIFICATION_BATCH) {
            revert IGroupActionVerifyErrors.VerificationBatchTooLarge(
                originScores.length, GroupActionStorage.MAX_VERIFICATION_BATCH
            );
        }
        for (uint256 i = 0; i < originScores.length; i++) {
            if (originScores[i] > GroupActionStorage.MAX_ORIGIN_SCORE) {
                revert IGroupActionVerifyErrors.ScoreLimitExceeded(
                    i, originScores[i], GroupActionStorage.MAX_ORIGIN_SCORE
                );
            }
        }

        uint256 round = GroupActionRoundAxis.currentVerifyRound(protocol.phaseAddress);
        bool groupVerified;
        {
            _checkElectedVerifier(self, submission.tokenAddress, round, submission.actionId, submission.verifierId);

            uint256 memberCount = self.memberIdsByGroupId[submission.tokenAddress][submission.actionId][submission.groupId]
                .countByRound(round);
            uint256 verifiedCount =
                self.verifiedMemberCountByGroupId[submission.tokenAddress][submission.actionId][round][submission.groupId];
            if (memberCount != 0 && verifiedCount == memberCount) {
                revert IGroupActionVerifyErrors.GroupVerificationAlreadyComplete(submission.groupId, round);
            }
            if (submission.startIndex != verifiedCount) {
                revert IGroupActionVerifyErrors.StartIndexMismatch(verifiedCount, submission.startIndex);
            }
            if (submission.startIndex + originScores.length > memberCount) {
                revert IGroupActionVerifyErrors.ScoreCountExceeded(
                    submission.startIndex, originScores.length, memberCount
                );
            }

            groupVerified = _scoreBatch(self, submission, round, verifiedCount, memberCount, originScores);
        }

        if (groupVerified && self.roundVerified[submission.tokenAddress][submission.actionId][round]) {
            _recordGeneratedActionReward(self, protocol.actionTargetAddress, submission, round);
        }

        emit IGroupActionVerifyEvents.OriginScoresSubmitted({
            tokenAddress: submission.tokenAddress,
            actionId: submission.actionId,
            groupId: submission.groupId,
            round: round,
            verifierId: submission.verifierId,
            startIndex: submission.startIndex,
            totalActionFinalScore: self.totalActionFinalScore[submission.tokenAddress][submission.actionId][round],
            verifiedGroupCount: self.verifiedGroupCountByRound[submission.tokenAddress][submission.actionId][round],
            roundVerified: self.roundVerified[submission.tokenAddress][submission.actionId][round],
            groupVerified: groupVerified,
            scores: originScores
        });
    }

    function _recordGeneratedActionReward(
        GroupActionStorage.Layout storage self,
        address actionTargetAddress,
        OriginSubmission memory submission,
        uint256 round
    ) private {
        address tokenAddress = submission.tokenAddress;
        uint256 actionId = submission.actionId;
        if (self.totalActionFinalScore[tokenAddress][actionId][round] == 0) return;

        // Load-bearing: Vote totals must be frozen and the proposal pool reserved before this reward is recorded.
        (uint256 reward, ) = IActionTarget(actionTargetAddress).actionReward(tokenAddress, round, actionId);
        if (reward == 0) return;

        self.generatedActionReward[tokenAddress][actionId][round] = reward;
        self.totalGeneratedActionReward[tokenAddress][round] += reward;
        self.totalGeneratedActionRewardByVerifierId[tokenAddress][round][submission.verifierId] += reward;
        self.actionIdsWithGeneratedActionReward[tokenAddress][round].push(actionId);
    }

    function _emitVerifierApplicationSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId,
        uint256 applicationId,
        uint256 previousApplicationId,
        string calldata description
    ) private {
        emit IGroupActionVerifyEvents.VerifierApplicationSubmitted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            verifierId: verifierId,
            round: round,
            applicationId: applicationId,
            previousApplicationId: previousApplicationId,
            hasPreviousApplication: previousApplicationId != 0,
            description: description
        });
    }

    function _emitApplicationVoteRecorded(
        GroupActionStorage.Layout storage self,
        VoteRecord memory record
    ) private {
        uint256 voteAmountTotal =
            self.voteAmountByApplicationId[record.tokenAddress][record.actionId][record.round][record.applicationId];
        emit IGroupActionVerifyEvents.ApplicationVoteRecorded({
            tokenAddress: record.tokenAddress,
            actionId: record.actionId,
            voterId: record.voterId,
            round: record.round,
            applicationId: record.applicationId,
            verifierId: record.verifierId,
            voteAmountAdded: record.voteAmountAdded,
            voteAmountTotal: voteAmountTotal
        });
    }

    function _checkApplicationSubmission(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) private view returns (uint256 round) {
        round = IPhase(protocol.phaseAddress).currentPhase();
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        uint256 descriptionLength = bytes(description).length;
        if (descriptionLength > GroupActionStorage.MAX_DESCRIPTION_BYTES) {
            revert IGroupActionExecutorErrors.DescriptionTooLong(
                descriptionLength, GroupActionStorage.MAX_DESCRIPTION_BYTES
            );
        }
        if (self.createdRoundByActionId[tokenAddress][actionId] == 0) {
            revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        }
        if (IStake(protocol.stakeAddress).govPower(tokenAddress, round, verifierId) == 0) {
            revert IGroupActionVerifyErrors.ZeroVerifierGovPower(tokenAddress, verifierId);
        }
    }
}
