// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupConfig} from "./interfaces/IGroupActionManager.sol";
import {AddressSet} from "libs/AddressSet.sol";
import {RoundHistoryString} from "libs/RoundHistoryString.sol";
import {RoundHistoryUint256} from "libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "libs/Uint256Set.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";

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

    struct GroupInfo {
        GroupConfig config;
        bool active;
        uint256 activatedRound;
        uint256 deactivatedRound;
    }

    struct Layout {
        address actionTarget;
        address stakeAddress;
        address memberNFTAddress;
        address phaseAddress;
        address voteAddress;
        uint256[] splits;
        bool initialized;

        // tokenAddress => actionId => join token address
        mapping(address => mapping(uint256 => address)) joinTokenAddress;
        // tokenAddress => actionId => activation stake amount
        mapping(address => mapping(uint256 => uint256)) activationStakeAmount;
        // tokenAddress => actionId => max join amount ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) maxJoinAmountRatio;
        // tokenAddress => actionId => activation min gov ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) activationMinGovRatio;
        // tokenAddress => actionId => verifier stake amount required to apply
        mapping(address => mapping(uint256 => uint256)) verifierStakeAmount;
        // tokenAddress => actionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRound;
        // tokenAddress => actionId => verification schema keys
        mapping(address => mapping(uint256 => string[])) verificationKeys;
        // tokenAddress => actionId => verification schema descriptions
        mapping(address => mapping(uint256 => string[])) verificationDescriptions;

        // tokenAddress => actionId => groupId => group info
        mapping(address => mapping(uint256 => mapping(uint256 => GroupInfo))) groupInfo;
        // tokenAddress => actionId => active group ids
        mapping(address => mapping(uint256 => Uint256Set.Storage)) activeGroupIds;
        // tokenAddress => actionId => groupId => description history by round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryString.History))) descriptionHistory;
        // tokenAddress => actionId => staked amount of active groups
        mapping(address => mapping(uint256 => uint256)) staked;
        // tokenAddress => total staked across actions
        mapping(address => uint256) totalStaked;
        // tokenAddress => group owner memberId => total staked of the member's active groups
        mapping(address => mapping(uint256 => uint256)) totalStakedByMemberId;
        // groupId => token addresses with active groups of the group
        mapping(uint256 => AddressSet.Storage) tokenAddressesByGroupId;
        // tokenAddress => groupId => action ids with active groups of the group
        mapping(address => mapping(uint256 => Uint256Set.Storage)) actionIdsByGroupId;
        // tokenAddress => action ids with any active group
        mapping(address => Uint256Set.Storage) actionIds;

        // tokenAddress => actionId => memberId => joined round history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) joinedRoundHistory;
        // tokenAddress => actionId => memberId => group id history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) groupHistory;
        // tokenAddress => actionId => memberId => own amount history (providerId 0)
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) ownAmountHistory;
        // tokenAddress => actionId => memberId => aggregate provider amount history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) providerAmountHistory;
        // tokenAddress => actionId => memberId => provider ids with balance, per round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Set.Storage))) providerIdsByMemberId;
        // tokenAddress => actionId => memberId => providerId => provider amount history
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History)))) providerAmountByProviderId;
        // tokenAddress => actionId => groupId => member ids per round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Set.Storage))) memberIdsByGroupId;
        // tokenAddress => actionId => group ids per round
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) groupIdsByRound;
        // tokenAddress => actionId => groupId => total joined amount history
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) totalJoinedAmountByGroupId;
        // tokenAddress => actionId => total joined amount history
        mapping(address => mapping(uint256 => RoundHistoryUint256.History)) totalJoinedAmount;

        // tokenAddress => actionId => groupId => providerId => member ids with quota
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => Uint256Set.Storage)))) quotaMemberIds;
        // tokenAddress => actionId => groupId => providerId => memberId => quota amount
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))))) quotaAmount;
        // tokenAddress => actionId => groupId => providerId => memberId => block number of the latest quota add
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))))) quotaBlockNumber;

        // groupId => memberId => count of actions the member currently joins in the group
        mapping(uint256 => mapping(uint256 => uint256)) membershipCountByGroupIdByMemberId;
        // groupId => memberId => tokenAddress => count of actions of the token the member currently joins in the group
        mapping(uint256 => mapping(uint256 => mapping(address => uint256))) membershipCountByToken;
        // groupId => memberId => token addresses of current membership
        mapping(uint256 => mapping(uint256 => AddressSet.Storage)) gTokenAddressesByGroupIdByMemberId;
        // group ids with members
        Uint256Set.Storage gGroupIds;
        // memberId => group ids the member currently belongs to
        mapping(uint256 => Uint256Set.Storage) gGroupIdsByMemberId;
        // member ids with membership
        Uint256Set.Storage gMemberIds;
        // groupId => member ids currently in the group
        mapping(uint256 => Uint256Set.Storage) gMemberIdsByGroupId;

        // tokenAddress => actionId => round => memberId => origin score deduction from MAX_ORIGIN_SCORE
        // (0 = full score or unverified).
        // Load-bearing: verified-ness is positional — scored members are exactly the first
        // `verifiedMemberCount` slots of the round's member set. The set is written only at the current
        // join round (phase - 1) while verification runs for `phase - 2`; a later write to that round
        // would shift the prefix and silently misreport scores.
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) originScoreDeduction;
        // tokenAddress => actionId => round => groupId => verified member count
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) verifiedMemberCount;
        // tokenAddress => actionId => round => number of groups whose cursor reached its member count
        // Load-bearing: the count only reaches the group count because a completed group cannot submit
        // again (`GroupVerificationComplete`) and `groupIdsByRound[round]` never holds a zero-member group;
        // otherwise the round stays unverified forever with no revert.
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) verifiedGroupCount;
        // tokenAddress => actionId => round => every group in the round is fully verified
        mapping(address => mapping(uint256 => mapping(uint256 => bool))) roundVerified;
        // tokenAddress => actionId => round => groupId => accumulated final score
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) finalScoreByGroupId;
        // tokenAddress => actionId => round => total final score across groups
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) totalFinalScore;
        // tokenAddress => actionId => round => locked verifier member id (0 = none)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) lockedVerifierId;
        // tokenAddress => actionId => latest application id
        mapping(address => mapping(uint256 => uint256)) applicationIdCounter;
        // tokenAddress => actionId => applicationId => applicant member id
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) applicationMemberId;
        // tokenAddress => actionId => applicationId => application description
        mapping(address => mapping(uint256 => mapping(uint256 => string))) applicationDescription;
        // tokenAddress => actionId => memberId => round => application the member stood with
        // Load-bearing: every per-round lookup resolves through this history, because a round's rank
        // holds that round's application id. Reading `currentApplicationId` instead answers a later
        // round's application and silently rejects whoever replaced or cancelled after the vote round.
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History))) applicationIdHistory;
        // tokenAddress => actionId => round => applicationId => votes cast in that round
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) votesByApplicationId;
        // tokenAddress => actionId => memberId => current application id (0 = none)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) currentApplicationId;
        // tokenAddress => actionId => active application ids
        mapping(address => mapping(uint256 => Uint256Set.Storage)) activeApplicationIds;
        // tokenAddress => actionId => round => ranked application ids (votes desc, applicationId asc)
        mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) rankedApplicationIds;

        // tokenAddress => actionId => memberId => schema key index => value history
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => RoundHistoryString.History)))) verificationValueHistory;

        // tokenAddress => actionId => round => memberId => reward already settled
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) memberMinted;
        // tokenAddress => actionId => round => memberId => minted amount
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) memberMintedReward;
        // tokenAddress => actionId => round => memberId => burned amount
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) memberBurnedReward;
    }

    function joinRound(Layout storage s) internal view returns (uint256) {
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        return phase < 2 ? 0 : phase - 1;
    }

    function currentJoinRound(Layout storage s) internal view returns (uint256) {
        uint256 round = joinRound(s);
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted();
        }
        return round;
    }

    function memberAmountAt(
        Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (uint256) {
        return s.ownAmountHistory[tokenAddress][actionId][memberId].value(round)
            + s.providerAmountHistory[tokenAddress][actionId][memberId].value(round);
    }
}
