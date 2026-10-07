// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {
    VerifierApplication,
    IGroupActionVerifyEvents,
    IGroupActionVerifyErrors
} from "./interfaces/IGroupActionVerify.sol";
import {IStake} from "core/src/interfaces/IStake.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RoundHistoryUint256} from "libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {RoundHistoryString} from "libs/RoundHistoryString.sol";
import {Uint256Set} from "libs/Uint256Set.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

library GroupActionVerify {
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using Uint256Set for Uint256Set.Storage;

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function submitOriginScores(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external {
        s.requireMemberOwner(verifierId);
        if (originScores.length == 0) {
            revert IGroupActionVerifyErrors.OriginScoresEmpty();
        }
        if (originScores.length > GroupActionStorage.MAX_VERIFICATION_BATCH) {
            revert IGroupActionVerifyErrors.VerificationBatchTooLarge();
        }

        uint256 round = _currentVerifyRound(s);

        uint256 lockedVerifier = s.lockedVerifierId[tokenAddress][actionId][round];
        if (lockedVerifier != 0) {
            if (lockedVerifier != verifierId) {
                revert IGroupActionVerifyErrors.VerifierAlreadyLocked(tokenAddress, actionId, round);
            }
        } else {
            _requireOpenCandidate(s, tokenAddress, actionId, round, verifierId);
        }

        uint256 memberCount = s.memberIdsByGroupId[tokenAddress][actionId][groupId].countByRound(round);
        uint256 verifiedCount = s.verifiedMemberCount[tokenAddress][actionId][round][groupId];
        if (memberCount != 0 && verifiedCount == memberCount) {
            revert IGroupActionVerifyErrors.AlreadyVerified();
        }
        if (startIndex != verifiedCount) {
            revert IGroupActionVerifyErrors.StartIndexMismatch(verifiedCount, startIndex);
        }
        if (startIndex + originScores.length > memberCount) {
            revert IGroupActionVerifyErrors.ScoresExceedAccountCount();
        }

        if (lockedVerifier == 0) {
            s.lockedVerifierId[tokenAddress][actionId][round] = verifierId;
            emit IGroupActionVerifyEvents.VerifierLocked({
                tokenAddress: tokenAddress,
                actionId: actionId,
                round: round,
                memberId: verifierId
            });
        }

        _scoreBatch(s, tokenAddress, actionId, round, groupId, verifiedCount, originScores);

        emit IGroupActionVerifyEvents.OriginScoresSubmitted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            groupId: groupId,
            round: round,
            verifierId: verifierId,
            startIndex: startIndex,
            scores: originScores
        });
    }

    function originScore(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        uint256 packed = s.originScorePacked[tokenAddress][actionId][round][memberId];
        return (packed & GroupActionStorage.SCORE_MASK, packed >= GroupActionStorage.VERIFIED_FLAG);
    }

    function finalScore(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified) {
        uint256 packed = s.originScorePacked[tokenAddress][actionId][round][memberId];
        verified = packed >= GroupActionStorage.VERIFIED_FLAG;
        if (!verified) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, false);
        }
        uint256 amount = s.memberAmountAt(tokenAddress, actionId, round, memberId);
        // forge-lint: disable-next-line(boolean-cst)
        return (amount * (packed & GroupActionStorage.SCORE_MASK), true);
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
        uint256 groupCount = s.groupIdsByRound[tokenAddress][actionId].countByRound(round);
        if (groupCount == 0) {
            return true;
        }
        (uint256[] memory groupIds, ) =
            s.groupIdsByRound[tokenAddress][actionId].valuesByRound(round, 0, groupCount, false);
        for (uint256 i = 0; i < groupIds.length; i++) {
            uint256 groupId = groupIds[i];
            if (
                s.verifiedMemberCount[tokenAddress][actionId][round][groupId]
                    != s.memberIdsByGroupId[tokenAddress][actionId][groupId].countByRound(round)
            ) {
                return false;
            }
        }
        return true;
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
    ) external returns (uint256 applicationId) {
        s.requireMemberOwner(memberId);
        if (IStake(s.stakeAddress).validGovVotes(tokenAddress, memberId) == 0) {
            revert IGroupActionVerifyErrors.VerifyVotesZero();
        }
        if (bytes(description).length > GroupActionStorage.MAX_DESCRIPTION_BYTES) {
            revert IGroupActionExecutorErrors.DescriptionTooLong();
        }
        uint256 createdRound = s.createdRound[tokenAddress][actionId];
        uint256 currentRound = IPhase(s.phaseAddress).currentPhase();
        if (currentRound != createdRound) {
            revert IActionExecutorErrors.InvalidRound(currentRound);
        }

        applicationId = _replaceApplication(s, tokenAddress, actionId, memberId, createdRound);
        s.applicationMemberId[tokenAddress][actionId][applicationId] = memberId;
        s.applicationDescription[tokenAddress][actionId][applicationId] = description;
        s.applicationCreatedRound[tokenAddress][actionId][applicationId] = createdRound;

        emit IGroupActionVerifyEvents.VerifierApplicationSubmitted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: createdRound,
            applicationId: applicationId
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function cancelVerifierApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external {
        s.requireMemberOwner(memberId);
        uint256 createdRound = s.createdRound[tokenAddress][actionId];
        uint256 currentRound = IPhase(s.phaseAddress).currentPhase();
        if (currentRound != createdRound) {
            revert IActionExecutorErrors.InvalidRound(currentRound);
        }
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][memberId];
        if (applicationId == 0) {
            revert IGroupActionVerifyErrors.ApplicationNotActive();
        }

        s.activeApplicationIds[tokenAddress][actionId].remove(applicationId);
        _removeFromRank(s, tokenAddress, actionId, createdRound, applicationId);
        s.currentApplicationId[tokenAddress][actionId][memberId] = 0;

        emit IGroupActionVerifyEvents.VerifierApplicationCancelled({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: createdRound,
            applicationId: applicationId
        });
    }

    function verifierApplication(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (VerifierApplication memory application) {
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][memberId];
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
            uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][verifierIds[i]];
            if (applicationId != 0 && s.applicationCreatedRound[tokenAddress][actionId][applicationId] == round) {
                votes[i] = s.votesByApplicationId[tokenAddress][actionId][applicationId];
            }
        }
    }

    function votesByApplicationId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 applicationId
    ) external view returns (uint256) {
        return s.votesByApplicationId[tokenAddress][actionId][applicationId];
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
            votes[i] = s.votesByApplicationId[tokenAddress][actionId][applicationId];
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
        if (round != s.createdRound[tokenAddress][actionId]) {
            revert IActionExecutorErrors.InvalidRound(round);
        }
        if (targetData.length == 0 || targetData.length == 1) {
            return;
        }
        if (targetData.length > 2) {
            revert IGroupActionExecutorErrors.InvalidTargetDataLength();
        }
        if (targetData[1].length != 32) {
            revert IGroupActionExecutorErrors.InvalidTargetDataLength();
        }

        uint256 candidateMemberId = abi.decode(targetData[1], (uint256));
        if (candidateMemberId == 0) {
            revert IGroupActionVerifyErrors.InvalidCandidate();
        }
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][candidateMemberId];
        if (applicationId == 0) {
            revert IGroupActionVerifyErrors.ApplicationNotActive();
        }

        if (votes == 0) {
            return;
        }
        s.votesByApplicationId[tokenAddress][actionId][applicationId] += votes;
        _upsertRank(s, tokenAddress, actionId, round, applicationId);
    }

    function _scoreBatch(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 verifiedCount,
        uint256[] calldata originScores
    ) internal {
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
        s.verifiedMemberCount[tokenAddress][actionId][round][groupId] = verifiedCount + originScores.length;
    }

    function _scoreMember(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 score
    ) internal returns (uint256 weighted) {
        s.originScorePacked[tokenAddress][actionId][round][memberId] = score | GroupActionStorage.VERIFIED_FLAG;
        return s.memberAmountAt(tokenAddress, actionId, round, memberId) * score;
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
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        if (phase < 3) {
            revert IActionExecutorErrors.RoundNotStarted();
        }
        return phase - 2;
    }

    function _requireOpenCandidate(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId
    ) internal view {
        uint256 applicationId = s.currentApplicationId[tokenAddress][actionId][verifierId];
        uint256[] storage rankedApplicationIds = s.rankedApplicationIds[tokenAddress][actionId][round];
        uint256 rank = 0;
        for (; rank < rankedApplicationIds.length; rank++) {
            if (rankedApplicationIds[rank] == applicationId) {
                break;
            }
        }
        if (rank == rankedApplicationIds.length || applicationId == 0) {
            revert IGroupActionVerifyErrors.InvalidCandidate();
        }
        if (rank == 0) {
            return;
        }
        uint256 splitIndex = rank - 1;
        if (splitIndex >= s.splits.length) {
            revert IGroupActionVerifyErrors.InvalidCandidate();
        }
        (uint256 startBlock, uint256 phaseBlocks) = IPhase(s.phaseAddress).phaseInfo(round + 2);
        uint256 openOffset =
            Math.mulDiv(phaseBlocks, s.splits[splitIndex], GroupActionStorage.PRECISION, Math.Rounding.Ceil);
        if (block.number < startBlock + openOffset) {
            revert IGroupActionVerifyErrors.InvalidCandidate();
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
            uint256 lastVotes = s.votesByApplicationId[tokenAddress][actionId][lastApplicationId];
            uint256 applicationVotes = s.votesByApplicationId[tokenAddress][actionId][applicationId];
            if (applicationVotes <= lastVotes) {
                return;
            }
            rankedApplicationIds.pop();
        }

        uint256 insertIndex = rankedApplicationIds.length;
        for (uint256 i = 0; i < rankedApplicationIds.length; i++) {
            uint256 rankedApplicationId = rankedApplicationIds[i];
            uint256 rankedVotes = s.votesByApplicationId[tokenAddress][actionId][rankedApplicationId];
            uint256 applicationVotes = s.votesByApplicationId[tokenAddress][actionId][applicationId];
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
}
