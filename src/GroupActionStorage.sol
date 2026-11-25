// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupConfig} from "./interfaces/IGroupActionManager.sol";
import {AddressSet} from "@libs/AddressSet.sol";
import {RoundHistoryString} from "@libs/RoundHistoryString.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library GroupActionStorage {
    using AddressSet for AddressSet.Storage;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using Uint256Set for Uint256Set.Storage;

    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_ORIGIN_SCORE = 100;
    uint256 constant MAX_VERIFICATION_BATCH = 100;
    uint256 constant MAX_DESCRIPTION_BYTES = 1024;
    uint256 constant MAX_VERIFICATION_ENTRIES = 16;
    uint256 constant MAX_VERIFICATION_TEXT_BYTES = 1024;

    struct GroupState {
        GroupConfig config;
        bool active;
        uint256 activatedRound;
        uint256 deactivatedRound;
    }

    struct Protocol {
        address actionTargetAddress;
        address stakeAddress;
        address memberNFTAddress;
        address phaseAddress;
        address voteAddress;
    }

    struct ProviderAttribution {
        uint256 providerId;
        uint256 joinedBlock;
    }

    struct ProviderScores {
        mapping(uint256 => uint256) scoreByProviderId;
    }

    struct Layout {
        // tokenAddress => actionId => join token address
        mapping(address => mapping(uint256 => address)) joinTokenAddressByActionId;
        // tokenAddress => actionId => fixed activation stake required per group
        mapping(address => mapping(uint256 => uint256)) requiredActivationStakeByActionId;
        // tokenAddress => actionId => max join amount ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) maxJoinAmountRatioByActionId;
        // tokenAddress => actionId => activation min gov ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) activationMinGovRatioByActionId;
        // tokenAddress => actionId => fixed verifier stake required to apply
        mapping(address => mapping(uint256 => uint256)) requiredVerifierStakeByActionId;
        // tokenAddress => actionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRoundByActionId;
        // tokenAddress => actionId => verification schema keys
        mapping(address => mapping(uint256 => string[])) verificationKeysByActionId;
        // tokenAddress => actionId => verification schema descriptions
        mapping(address => mapping(uint256 => string[])) verificationDescriptionsByActionId;

        // tokenAddress => actionId => groupId => group info
        mapping(address => mapping(uint256 => mapping(uint256 => GroupState))) groupState;
        // tokenAddress => actionId => active group ids
        mapping(address => mapping(uint256 => Uint256Set.Storage)) activeGroupIdsByActionId;
        // tokenAddress => actionId => groupId => description history by round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryString.History))) descriptionHistoryByGroupId;
        // tokenAddress => actionId => total activation stake of active groups in the action
        mapping(address => mapping(uint256 => uint256)) activationStakeByActionId;
        // tokenAddress => total activation stake across actions
        mapping(address => uint256) totalActivationStake;
        // tokenAddress => groupId => total activation stake across actions
        mapping(address => mapping(uint256 => uint256)) activationStakeByGroupId;
        // groupId => token addresses with active groups of the group
        mapping(uint256 => AddressSet.Storage) tokenAddressesByGroupId;
        // tokenAddress => groupId => action ids with active groups of the group
        mapping(address => mapping(uint256 => Uint256Set.Storage)) actionIdsByGroupId;
        // tokenAddress => action ids with any active group
        mapping(address => Uint256Set.Storage) activeActionIds;

        // tokenAddress => actionId => memberId => joined round history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) joinedRoundHistoryByMemberId;
        // tokenAddress => actionId => memberId => group id history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) groupHistoryByMemberId;
        // tokenAddress => actionId => memberId => own amount history (providerId 0)
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) ownAmountHistoryByMemberId;
        // tokenAddress => actionId => memberId => aggregate provider amount history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) providerAmountHistoryByMemberId;
        // tokenAddress => actionId => memberId => provider ids with balance, per round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Set.Storage))) providerIdsByMemberId;
        // tokenAddress => actionId => memberId => providerId => provider amount history
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History)))) providerAmountByMemberIdByProviderId;
        // tokenAddress => actionId => groupId => member ids per round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Set.Storage))) memberIdsByGroupId;
        // tokenAddress => actionId => group ids per round
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) groupIdsByRound;
        // tokenAddress => actionId => groupId => total joined amount history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) joinedAmountByGroupId;
        // tokenAddress => actionId => total joined amount history
        mapping(address => mapping(uint256 => RoundHistoryUint256.History)) joinedAmountByActionId;

        // tokenAddress => actionId => groupId => providerId => member ids with an outstanding grant
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => Uint256Set.Storage)))) quotaMemberIdsByGroupIdByProviderId;
        // tokenAddress => actionId => groupId => providerId => memberId => granted quota amount
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))))) quotaAmountByGroupIdByProviderIdByMemberId;

        // groupId => memberId => count of actions the member currently joins in the group
        mapping(uint256 => mapping(uint256 => uint256)) membershipCountByGroupIdByMemberId;
        // groupId => memberId => tokenAddress => count of actions of the token the member currently joins in the group
        mapping(uint256 => mapping(uint256 => mapping(address => uint256))) membershipCountByTokenAddress;
        // groupId => memberId => token addresses of current membership
        mapping(uint256 => mapping(uint256 => AddressSet.Storage)) joinedTokenAddressesByGroupIdByMemberId;
        Uint256Set.Storage joinedGroupIds;
        // memberId => group ids the member currently belongs to
        mapping(uint256 => Uint256Set.Storage) joinedGroupIdsByMemberId;
        Uint256Set.Storage joinedMemberIds;
        // groupId => member ids currently in the group
        mapping(uint256 => Uint256Set.Storage) joinedMemberIdsByGroupId;

        // Load-bearing: verified-ness is positional — scored members are exactly the first
        // `verifiedMemberCount` slots of the round's member set. The set is written only at the current
        // join round (phase - 1) while verification runs for `phase - 2`; a later write to that round
        // would shift the prefix and silently misreport scores.
        // tokenAddress => actionId => round => memberId => origin score deduction (0 = full score or unverified)
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) originScoreDeductionByMemberId;
        // tokenAddress => actionId => round => groupId => verified member count
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) verifiedMemberCountByGroupId;
        // Load-bearing: the count only reaches the group count because a completed group cannot submit
        // again (`GroupVerificationAlreadyComplete`) and `groupIdsByRound[round]` never holds a zero-member group;
        // otherwise the round stays unverified forever with no revert.
        // tokenAddress => actionId => round => number of groups whose cursor reached its member count
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) verifiedGroupCountByRound;
        // tokenAddress => actionId => round => every group in the round is fully verified
        mapping(address => mapping(uint256 => mapping(uint256 => bool))) roundVerified;
        // tokenAddress => actionId => round => groupId => accumulated final score
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) finalScoreByGroupId;
        // tokenAddress => actionId => round => total final score across groups
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) totalActionFinalScore;
        // tokenAddress => actionId => latest application id
        mapping(address => mapping(uint256 => uint256)) applicationIdCount;
        // tokenAddress => actionId => applicationId => the verifier holding it
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) applicationVerifierId;
        // tokenAddress => actionId => applicationId => description history; edits take effect next round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryString.History))) applicationDescription;
        // tokenAddress => actionId => verifierId => application id history by round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) applicationIdHistory;
        // tokenAddress => actionId => round => applicationId => votes cast in that round
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) voteAmountByApplicationId;
        // tokenAddress => actionId => verifierId => current application id (0 = none)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) currentApplicationId;
        // tokenAddress => actionId => unwithdrawn application ids history by round
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) activeApplicationIds;
        // tokenAddress => actionId => round => leading application id; final after voting closes
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) electedApplicationId;
        // tokenAddress => actionId => applicationId => ordered elected rounds; current-round entry is provisional
        mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) electedRoundsByApplicationId;
        // tokenAddress => actionId => applicationId => round in which accepting votes stopped (0 = accepting)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) applicationStoppedRound;
        // tokenAddress => actionId => applicationId => withdrawal round (0 = not withdrawn)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) applicationWithdrawnRound;
        // tokenAddress => actionId => round => applications with votes withdrawn during that round
        mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) withdrawnVotedApplicationIds;
        // tokenAddress => actionId => verifierId => collateral of the current unwithdrawn application
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) verifierStakeByVerifierId;

        // tokenAddress => total activation stake history by round
        mapping(address => RoundHistoryUint256.History) totalActivationStakeHistory;
        // tokenAddress => groupId => activation stake history across actions, by round
        mapping(address => mapping(uint256 => RoundHistoryUint256.History)) activationStakeHistoryByGroupId;

        // tokenAddress => actionId => memberId => schema key index => value history
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => RoundHistoryString.History)))) verificationValueHistory;

        // tokenAddress => actionId => round => memberId => reward already settled
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) memberMinted;
        // tokenAddress => actionId => round => memberId => minted amount
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) memberMintedReward;

        // Load-bearing: append-only, never removed — a round's tally stops growing when its vote
        // phase closes — so `reverse` is exactly the reverse of first-vote order (no swap-and-pop).
        // tokenAddress => actionId => round => applicationId => voter ids, in first-vote order
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => Uint256Set.Storage))))
            voterIdsByApplicationId;
        // tokenAddress => actionId => round => applicationId => voterId => votes that voter cast
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))))
            voteAmountByApplicationIdByVoterId;
        // tokenAddress => actionId => fixed verifier punishment ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) verifierPunishmentRatioByActionId;

        // tokenAddress => groupId => actions with members in the group, by join round
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) joinedActionIdsByGroupId;
        // tokenAddress => verifierId => actions with an application that has not been withdrawn
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) applicationActionIdsByVerifierId;
        // tokenAddress => verifierId => round => applications withdrawn and not replaced in that round
        mapping(address => mapping(uint256 => mapping(uint256 => Uint256Set.Storage))) withdrawnApplicationActionIds;
        // tokenAddress => round => sum of rewards from fully verified actions
        mapping(address => mapping(uint256 => uint256)) totalGeneratedActionReward;
        // tokenAddress => round => verifierId => rewards from the actions verified by that verifier
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) totalGeneratedActionRewardByVerifierId;
        // tokenAddress => round => fully verified actions with positive rewards, in completion order
        mapping(address => mapping(uint256 => uint256[])) actionIdsWithGeneratedActionReward;
        // tokenAddress => actionId => round => proposal reward recorded at verification completion
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) generatedActionReward;
        // groupId => memberId => permanent first-join attribution across actions and tokens
        mapping(uint256 => mapping(uint256 => ProviderAttribution)) providerAttribution;
        // tokenAddress => actionId => round => groupId => Provider scores
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => ProviderScores)))) providerScoresByGroupId;
        // tokenAddress => round => groupId => actions for which the group finished verification with a positive score
        mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) verifiedActionIdsByGroupId;
        // tokenAddress => round => providerId => other groups with positive Provider scores
        mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) providerGroupIdsByProviderId;
        // tokenAddress => round => providerId => groupId => actions with positive external Provider scores
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[]))))
            providerActionIdsByGroupIdByProviderId;
        // tokenAddress => round => actionId => groupId => positive-score provider ids
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[]))))
            providerIdsByGroupIdByActionId;
        // tokenAddress => providerId => group ids with outstanding quota grants
        mapping(address => mapping(uint256 => Uint256Set.Storage)) quotaGroupIdsByProviderId;
        // tokenAddress => providerId => groupId => action ids with outstanding quota grants
        mapping(address => mapping(uint256 => mapping(uint256 => Uint256Set.Storage)))
            quotaActionIdsByProviderIdByGroupId;
    }

    function generatedActionRewardByGroupId(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) internal view returns (uint256) {
        uint256 groupFinalScore = self.finalScoreByGroupId[tokenAddress][actionId][round][groupId];
        if (groupFinalScore == 0) return 0;

        uint256 proposalReward = self.generatedActionReward[tokenAddress][actionId][round];
        if (proposalReward == 0) return 0;

        return Math.mulDiv(proposalReward, groupFinalScore, self.totalActionFinalScore[tokenAddress][actionId][round]);
    }

    function generatedActionRewardByGroupIdByProviderId(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId
    ) internal view returns (uint256) {
        uint256 actionReward = self.generatedActionReward[tokenAddress][actionId][round];
        if (actionReward == 0) return 0;
        uint256 providerScore = self.providerScoresByGroupId[tokenAddress][actionId][round][groupId]
            .scoreByProviderId[providerId];
        return Math.mulDiv(actionReward, providerScore, self.totalActionFinalScore[tokenAddress][actionId][round]);
    }

    function totalGeneratedActionRewardByGroupIdByProviderId(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256[] storage actionIds
    ) internal view returns (uint256 attributedRewardAmount) {
        for (uint256 i = 0; i < actionIds.length; ++i) {
            attributedRewardAmount += generatedActionRewardByGroupIdByProviderId(
                self, tokenAddress, round, actionIds[i], groupId, providerId
            );
        }
    }

    function memberAmountAt(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal view returns (uint256) {
        return self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].value(round)
            + self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
    }

    // forge-lint: disable-next-item(boolean-cst)
    function originScoreAt(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal view returns (uint256 score, bool verified) {
        uint256 groupId = self.groupHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
        if (groupId == 0) {
            return (0, false);
        }
        uint256 verifiedCount = self.verifiedMemberCountByGroupId[tokenAddress][actionId][round][groupId];
        if (verifiedCount == 0) {
            return (0, false);
        }
        RoundHistoryUint256Set.Storage storage memberSet = self.memberIdsByGroupId[tokenAddress][actionId][groupId];
        uint256 indexPlusOne = memberSet.indexPlusOneHistory[memberId].value(round);
        if (
            indexPlusOne == 0 || indexPlusOne - 1 >= verifiedCount
                || memberSet.slotHistory[indexPlusOne - 1].value(round) != memberId
        ) {
            return (0, false);
        }
        uint256 deduction = self.originScoreDeductionByMemberId[tokenAddress][actionId][round][memberId];
        return (MAX_ORIGIN_SCORE - deduction, true);
    }

    function finalScoreAt(
        Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal view returns (uint256 score, bool verified) {
        (score, verified) = originScoreAt(self, tokenAddress, round, actionId, memberId);
        if (!verified) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, false);
        }
        uint256 amount = memberAmountAt(self, tokenAddress, round, actionId, memberId);
        // forge-lint: disable-next-line(boolean-cst)
        return (amount * score, true);
    }
}
