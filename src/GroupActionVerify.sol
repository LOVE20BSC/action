// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {
    VerifierApplication,
    IGroupActionVerifyEvents,
    IGroupActionVerifyErrors
} from "./interfaces/IGroupActionVerify.sol";
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
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

library GroupActionVerify {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using SafeERC20 for IERC20;
    using Uint256Set for Uint256Set.Storage;

    struct OriginSubmission {
        address tokenAddress;
        uint256 actionId;
        uint256 groupId;
        uint256 verifierId;
        uint256 startIndex;
    }

    modifier onlyMemberOwner(
        GroupActionStorage.Layout storage s,
        uint256 memberId
    ) {
        if (IMemberNFT(s.memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    function submitOriginScores(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external onlyMemberOwner(s, verifierId) {
        _submitOriginScores(
            s,
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
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        return _originScoreOf(s, tokenAddress, actionId, round, memberId);
    }

    function finalScore(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        (score, verified) = _originScoreOf(s, tokenAddress, actionId, round, memberId);
        if (!verified) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, false);
        }
        uint256 amount = s.memberAmountAt(tokenAddress, actionId, round, memberId);
        // forge-lint: disable-next-line(boolean-cst)
        return (amount * score, true);
    }

    function totalFinalScore(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256) {
        return s.totalFinalScore[tokenAddress][actionId][round];
    }

    function verifiedMemberCount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return s.verifiedMemberCount[tokenAddress][actionId][round][groupId];
    }

    function isRoundVerified(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (bool) {
        return s.roundVerified[tokenAddress][actionId][round];
    }

    function lockedVerifierId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256) {
        return s.lockedVerifierId[tokenAddress][actionId][round];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function submitVerifierApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata description
    ) external onlyMemberOwner(s, memberId) returns (uint256 applicationId) {
        uint256 round = IPhase(s.phaseAddress).currentPhase();
        if (IStake(s.stakeAddress).validGovVotes(tokenAddress, round, memberId) == 0) {
            revert IGroupActionVerifyErrors.ZeroVerifyVotes(tokenAddress, memberId);
        }
        uint256 descriptionLength = bytes(description).length;
        if (descriptionLength > GroupActionStorage.MAX_DESCRIPTION_BYTES) {
            revert IGroupActionExecutorErrors.DescriptionTooLong(
                descriptionLength, GroupActionStorage.MAX_DESCRIPTION_BYTES
            );
        }
        if (s.createdRound[tokenAddress][actionId] == 0) {
            revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        }

        uint256 previousApplicationId = s.currentApplicationId[tokenAddress][actionId][memberId];
        applicationId = _replaceApplication(s, tokenAddress, actionId, memberId, round);
        s.applicationMemberId[tokenAddress][actionId][applicationId] = memberId;
        s.applicationDescription[tokenAddress][actionId][applicationId] = description;

        uint256 stakeAmount = previousApplicationId == 0 ? s.verifierStakeAmount[tokenAddress][actionId] : 0;
        if (stakeAmount != 0) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), stakeAmount);
            emit IGroupActionVerifyEvents.VerifierStakeDeposited({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                amount: stakeAmount
            });
        }

        _emitVerifierApplicationSubmitted(
            tokenAddress, actionId, memberId, round, applicationId, previousApplicationId, description
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function cancelVerifierApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyMemberOwner(s, memberId) {
        uint256 round = IPhase(s.phaseAddress).currentPhase();
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][memberId];
        if (applicationId == 0) {
            revert IGroupActionVerifyErrors.NoActiveApplication(memberId);
        }

        s.activeApplicationIds[tokenAddress][actionId].remove(applicationId);
        _removeFromRank(s, tokenAddress, actionId, round, applicationId);
        s.currentApplicationId[tokenAddress][actionId][memberId] = 0;
        s.applicationIdHistory[tokenAddress][actionId][memberId].record(round, 0);

        // Load-bearing: staked is equivalent to holding a current application.
        uint256 stakeAmount = s.verifierStakeAmount[tokenAddress][actionId];
        if (stakeAmount != 0) {
            IERC20(tokenAddress).safeTransfer(IMemberNFT(s.memberNFTAddress).ownerOf(memberId), stakeAmount);
            emit IGroupActionVerifyEvents.VerifierStakeRefunded({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                amount: stakeAmount
            });
        }

        emit IGroupActionVerifyEvents.VerifierApplicationCancelled({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            applicationId: applicationId
        });
    }

    function verifierStake(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256) {
        if (s.currentApplicationId[tokenAddress][actionId][memberId] == 0) {
            return 0;
        }
        return s.verifierStakeAmount[tokenAddress][actionId];
    }

    function verifierApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (VerifierApplication memory application) {
        uint256 applicationId = s.applicationIdHistory[tokenAddress][actionId][memberId].value(round);
        if (applicationId == 0) {
            return VerifierApplication({applicationId: 0, memberId: 0, description: ""});
        }
        return VerifierApplication({
            applicationId: applicationId,
            memberId: s.applicationMemberId[tokenAddress][actionId][applicationId],
            description: s.applicationDescription[tokenAddress][actionId][applicationId]
        });
    }

    function verifierApplications(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256 total) {
        uint256[] memory applicationIds;
        (applicationIds, total) = s.activeApplicationIds[tokenAddress][actionId].values(offset, limit, reverse);
        applications = new VerifierApplication[](applicationIds.length);
        for (uint256 i = 0; i < applicationIds.length; i++) {
            uint256 applicationId = applicationIds[i];
            applications[i] = VerifierApplication({
                applicationId: applicationId,
                memberId: s.applicationMemberId[tokenAddress][actionId][applicationId],
                description: s.applicationDescription[tokenAddress][actionId][applicationId]
            });
        }
    }

    function votesByVerifierIds(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory votes) {
        votes = new uint256[](verifierIds.length);
        for (uint256 i = 0; i < verifierIds.length; i++) {
            uint256 applicationId = s.applicationIdHistory[tokenAddress][actionId][verifierIds[i]].value(round);
            if (applicationId != 0) {
                votes[i] = s.votesByApplicationId[tokenAddress][actionId][round][applicationId];
            }
        }
    }

    function topVerifiers(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory verifierIds, uint256[] memory votes) {
        uint256[] storage rankedApplicationIds = s.rankedApplicationIds[tokenAddress][actionId][round];
        verifierIds = new uint256[](rankedApplicationIds.length);
        votes = new uint256[](rankedApplicationIds.length);
        for (uint256 i = 0; i < rankedApplicationIds.length; i++) {
            uint256 applicationId = rankedApplicationIds[i];
            verifierIds[i] = s.applicationMemberId[tokenAddress][actionId][applicationId];
            votes[i] = s.votesByApplicationId[tokenAddress][actionId][round][applicationId];
        }
    }

    function verificationSchema(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId
    ) external view returns (string[] memory keys, string[] memory descriptions) {
        return (s.verificationKeys[tokenAddress][actionId], s.verificationDescriptions[tokenAddress][actionId]);
    }

    function verificationValue(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata key
    ) external view returns (string memory value) {
        string[] storage keys = s.verificationKeys[tokenAddress][actionId];
        for (uint256 i = 0; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(key))) {
                return s.verificationValueHistory[tokenAddress][actionId][memberId][i].latestValue();
            }
        }
        return "";
    }

    function verificationInfos(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values) {
        return _verificationValues(s, tokenAddress, actionId, memberId, true, 0);
    }

    function verificationInfosByRound(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (string[] memory keys, string[] memory values) {
        return _verificationValues(s, tokenAddress, actionId, memberId, false, round);
    }

    function onProposalVoted(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        bytes[] calldata targetData,
        uint256 votes
    ) external {
        if (targetData.length == 0 || targetData.length == 1) {
            return;
        }
        if (targetData.length > 2) {
            revert IGroupActionExecutorErrors.TargetDataLengthMismatch(2, targetData.length);
        }
        if (targetData[1].length != 32) {
            revert IGroupActionExecutorErrors.InvalidTargetDataShape(1, targetData[1].length);
        }

        uint256 candidateMemberId = abi.decode(targetData[1], (uint256));
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][candidateMemberId];
        if (applicationId == 0) {
            revert IGroupActionVerifyErrors.NoActiveApplication(candidateMemberId);
        }

        if (votes == 0) {
            return;
        }
        s.votesByApplicationId[tokenAddress][actionId][round][applicationId] += votes;
        _upsertRank(s, tokenAddress, actionId, round, applicationId);

        _emitApplicationVoteRecorded(s, tokenAddress, actionId, applicationId, round, candidateMemberId, votes);
    }

    function _scoreBatch(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 verifiedCount,
        uint256 memberCount,
        uint256[] calldata originScores
    ) internal returns (bool groupVerified) {
        (uint256[] memory memberIds, ) =
            _pageMembers(s, tokenAddress, actionId, round, groupId, verifiedCount, originScores.length);
        uint256 groupFinal = s.finalScoreByGroupId[tokenAddress][actionId][round][groupId];
        uint256 totalFinal = s.totalFinalScore[tokenAddress][actionId][round];
        for (uint256 i = 0; i < originScores.length; i++) {
            uint256 weighted = _scoreMember(s, tokenAddress, actionId, round, memberIds[i], originScores[i]);
            groupFinal += weighted;
            totalFinal += weighted;
        }
        s.finalScoreByGroupId[tokenAddress][actionId][round][groupId] = groupFinal;
        s.totalFinalScore[tokenAddress][actionId][round] = totalFinal;
        uint256 newVerifiedCount = verifiedCount + originScores.length;
        s.verifiedMemberCount[tokenAddress][actionId][round][groupId] = newVerifiedCount;
        return _markGroupVerified(s, tokenAddress, actionId, round, newVerifiedCount, memberCount);
    }

    function _markGroupVerified(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifiedCount,
        uint256 memberCount
    ) internal returns (bool groupVerified) {
        if (verifiedCount != memberCount) {
            return false;
        }
        // Load-bearing: a round only ever becomes verified through this branch, and `isRoundVerified`
        // no longer re-derives it. A missed write leaves the round unsettled forever with no revert.
        uint256 verifiedGroups = ++s.verifiedGroupCount[tokenAddress][actionId][round];
        if (verifiedGroups == s.groupIdsByRound[tokenAddress][actionId].countByRound(round)) {
            s.roundVerified[tokenAddress][actionId][round] = true;
        }
        return true;
    }

    function _scoreMember(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 score
    ) internal returns (uint256 weighted) {
        if (score < GroupActionStorage.MAX_ORIGIN_SCORE) {
            uint256 deduction = GroupActionStorage.MAX_ORIGIN_SCORE - score;
            s.originScoreDeduction[tokenAddress][actionId][round][memberId] = deduction;
        }
        return s.memberAmountAt(tokenAddress, actionId, round, memberId) * score;
    }

    // forge-lint: disable-next-item(boolean-cst)
    function _originScoreOf(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (uint256 score, bool verified) {
        uint256 groupId = s.groupHistory[tokenAddress][actionId][memberId].value(round);
        if (groupId == 0) {
            return (0, false);
        }
        uint256 verifiedCount = s.verifiedMemberCount[tokenAddress][actionId][round][groupId];
        if (verifiedCount == 0) {
            return (0, false);
        }
        RoundHistoryUint256Set.Storage storage memberSet = s.memberIdsByGroupId[tokenAddress][actionId][groupId];
        uint256 indexPlusOne = memberSet.indexPlusOneHistory[memberId].value(round);
        if (
            indexPlusOne == 0 || indexPlusOne - 1 >= verifiedCount
                || memberSet.slotHistory[indexPlusOne - 1].value(round) != memberId
        ) {
            return (0, false);
        }
        uint256 deduction = s.originScoreDeduction[tokenAddress][actionId][round][memberId];
        return (GroupActionStorage.MAX_ORIGIN_SCORE - deduction, true);
    }

    function _pageMembers(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory memberIds, uint256 total) {
        RoundHistoryUint256Set.Storage storage memberSet = s.memberIdsByGroupId[tokenAddress][actionId][groupId];
        return memberSet.valuesByRound(round, offset, limit, false);
    }

    function _currentVerifyRound(GroupActionStorage.Layout storage s) internal view returns (uint256) {
        uint256 round = GroupActionRoundAxis.verifyRound(s.phaseAddress);
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    function _requireOpenCandidate(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId
    ) internal view {
        uint256 applicationId = s.applicationIdHistory[tokenAddress][actionId][verifierId].value(round);
        if (applicationId == 0) {
            revert IGroupActionVerifyErrors.NoActiveApplication(verifierId);
        }
        uint256[] storage rankedApplicationIds = s.rankedApplicationIds[tokenAddress][actionId][round];
        uint256 rank = 0;
        for (; rank < rankedApplicationIds.length; rank++) {
            if (rankedApplicationIds[rank] == applicationId) {
                break;
            }
        }
        if (rank == rankedApplicationIds.length) {
            revert IGroupActionVerifyErrors.CandidateNotRanked(verifierId, round);
        }
        if (rank == 0) {
            return;
        }
        uint256 splitIndex = rank - 1;
        (uint256 startBlock, uint256 phaseBlocks) = IPhase(s.phaseAddress).phaseInfo(round + 2);
        uint256 openOffset =
            Math.mulDiv(phaseBlocks, s.splits[splitIndex], GroupActionStorage.PRECISION, Math.Rounding.Ceil);
        if (block.number < startBlock + openOffset) {
            revert IGroupActionVerifyErrors.CandidateNotOpen(verifierId, round);
        }
    }

    function _replaceApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) internal returns (uint256 applicationId) {
        uint256 previousApplicationId = s.currentApplicationId[tokenAddress][actionId][memberId];
        if (previousApplicationId != 0) {
            s.activeApplicationIds[tokenAddress][actionId].remove(previousApplicationId);
            _removeFromRank(s, tokenAddress, actionId, round, previousApplicationId);
        }

        applicationId = ++s.applicationIdCounter[tokenAddress][actionId];
        s.currentApplicationId[tokenAddress][actionId][memberId] = applicationId;
        s.activeApplicationIds[tokenAddress][actionId].add(applicationId);
        s.applicationIdHistory[tokenAddress][actionId][memberId].record(round, applicationId);
    }

    function _upsertRank(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 applicationId
    ) internal {
        uint256[] storage rankedApplicationIds = s.rankedApplicationIds[tokenAddress][actionId][round];
        uint256 capacity = s.splits.length + 1;

        _removeFromRank(s, tokenAddress, actionId, round, applicationId);

        uint256 length = rankedApplicationIds.length;
        if (length >= capacity) {
            uint256 lastApplicationId = rankedApplicationIds[length - 1];
            uint256 lastVotes = s.votesByApplicationId[tokenAddress][actionId][round][lastApplicationId];
            uint256 applicationVotes = s.votesByApplicationId[tokenAddress][actionId][round][applicationId];
            if (applicationVotes <= lastVotes) {
                return;
            }
            rankedApplicationIds.pop();
        }

        uint256 insertIndex = rankedApplicationIds.length;
        for (uint256 i = 0; i < rankedApplicationIds.length; i++) {
            uint256 rankedApplicationId = rankedApplicationIds[i];
            uint256 rankedVotes = s.votesByApplicationId[tokenAddress][actionId][round][rankedApplicationId];
            uint256 applicationVotes = s.votesByApplicationId[tokenAddress][actionId][round][applicationId];
            if (rankedVotes < applicationVotes || (rankedVotes == applicationVotes && rankedApplicationId > applicationId)) {
                insertIndex = i;
                break;
            }
        }
        rankedApplicationIds.push(applicationId);
        for (uint256 i = rankedApplicationIds.length - 1; i > insertIndex; i--) {
            rankedApplicationIds[i] = rankedApplicationIds[i - 1];
        }
        if (insertIndex != rankedApplicationIds.length - 1) {
            rankedApplicationIds[insertIndex] = applicationId;
        }
    }

    function _removeFromRank(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 applicationId
    ) internal {
        uint256[] storage rankedApplicationIds = s.rankedApplicationIds[tokenAddress][actionId][round];
        uint256 length = rankedApplicationIds.length;
        uint256 removeIndex = length;
        for (uint256 i = 0; i < length; i++) {
            if (rankedApplicationIds[i] == applicationId) {
                removeIndex = i;
                break;
            }
        }
        if (removeIndex == length) {
            return;
        }
        for (uint256 i = removeIndex; i < length - 1; i++) {
            rankedApplicationIds[i] = rankedApplicationIds[i + 1];
        }
        rankedApplicationIds.pop();
    }

    function _verificationValues(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        bool latest,
        uint256 round
    ) internal view returns (string[] memory keys, string[] memory values) {
        keys = s.verificationKeys[tokenAddress][actionId];
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = latest
                ? s.verificationValueHistory[tokenAddress][actionId][memberId][i].latestValue()
                : s.verificationValueHistory[tokenAddress][actionId][memberId][i].value(round);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _submitOriginScores(
        GroupActionStorage.Layout storage s,
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

        uint256 round = _currentVerifyRound(s);
        bool groupVerified;
        {
            uint256 lockedVerifier = s.lockedVerifierId[submission.tokenAddress][submission.actionId][round];
            if (lockedVerifier != 0) {
                if (lockedVerifier != submission.verifierId) {
                    revert IGroupActionVerifyErrors.VerifierAlreadyLocked(
                        submission.tokenAddress, submission.actionId, round
                    );
                }
            } else {
                _requireOpenCandidate(s, submission.tokenAddress, submission.actionId, round, submission.verifierId);
            }

            uint256 memberCount = s.memberIdsByGroupId[submission.tokenAddress][submission.actionId][submission.groupId]
                .countByRound(round);
            uint256 verifiedCount =
                s.verifiedMemberCount[submission.tokenAddress][submission.actionId][round][submission.groupId];
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
            for (uint256 i = 0; i < originScores.length; i++) {
                if (originScores[i] > GroupActionStorage.MAX_ORIGIN_SCORE) {
                    revert IGroupActionVerifyErrors.ScoreLimitExceeded(
                        i, originScores[i], GroupActionStorage.MAX_ORIGIN_SCORE
                    );
                }
            }

            if (lockedVerifier == 0) {
                s.lockedVerifierId[submission.tokenAddress][submission.actionId][round] = submission.verifierId;
                emit IGroupActionVerifyEvents.VerifierLocked({
                    tokenAddress: submission.tokenAddress,
                    actionId: submission.actionId,
                    memberId: submission.verifierId,
                    round: round
                });
            }

            groupVerified = _scoreBatch(
                s,
                submission.tokenAddress,
                submission.actionId,
                round,
                submission.groupId,
                verifiedCount,
                memberCount,
                originScores
            );
        }

        emit IGroupActionVerifyEvents.OriginScoresSubmitted({
            tokenAddress: submission.tokenAddress,
            actionId: submission.actionId,
            groupId: submission.groupId,
            round: round,
            verifierId: submission.verifierId,
            startIndex: submission.startIndex,
            totalFinalScore: s.totalFinalScore[submission.tokenAddress][submission.actionId][round],
            verifiedGroupCount: s.verifiedGroupCount[submission.tokenAddress][submission.actionId][round],
            roundVerified: s.roundVerified[submission.tokenAddress][submission.actionId][round],
            groupVerified: groupVerified,
            scores: originScores
        });
    }

    function _emitVerifierApplicationSubmitted(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round,
        uint256 applicationId,
        uint256 previousApplicationId,
        string calldata description
    ) private {
        emit IGroupActionVerifyEvents.VerifierApplicationSubmitted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            applicationId: applicationId,
            previousApplicationId: previousApplicationId,
            hasPreviousApplication: previousApplicationId != 0,
            description: description
        });
    }

    function _emitApplicationVoteRecorded(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 applicationId,
        uint256 round,
        uint256 candidateMemberId,
        uint256 votesAdded
    ) private {
        emit IGroupActionVerifyEvents.ApplicationVoteRecorded({
            tokenAddress: tokenAddress,
            actionId: actionId,
            applicationId: applicationId,
            round: round,
            candidateMemberId: candidateMemberId,
            votesAdded: votesAdded,
            totalVotes: s.votesByApplicationId[tokenAddress][actionId][round][applicationId]
        });
    }
}
