// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryStringArray} from "libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";

library GroupServiceStorage {
    uint256 constant PRECISION = 1e18;
    uint256 constant DEFAULT_MAX_RECIPIENTS = 10;

    struct Layout {
        address actionTarget;
        address stakeAddress;
        address groupActionExecutorAddress;
        address memberNFTAddress;
        address phaseAddress;
        address launchAddress;
        bool initialized;

        // serviceTokenAddress => serviceActionId => action token address
        mapping(address => mapping(uint256 => address)) actionTokenAddress;
        // serviceTokenAddress => serviceActionId => gov ratio multiplier for the group owner (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) govRatioMultiplier;
        // serviceTokenAddress => serviceActionId => ratio for the public verifier (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) ratioForPublicVerifier;
        // serviceTokenAddress => serviceActionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRound;
        // actionTokenAddress => round => cached total group action reward denominator
        mapping(address => mapping(uint256 => uint256)) totalGroupActionRewardByRound;
        // actionTokenAddress => round => actionId => cached action reward total
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) actionRewardByRound;

        // serviceTokenAddress => serviceActionId => round => memberId => settlement record
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) memberMinted;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) verifierRewardByMember;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerBurnedByMember;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerDistributedByMember;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerRemainingByMember;

        // sourceTokenAddress => sourceActionId => groupId => round => recipient ids
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))) recipientIdsHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => ratios
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))) ratiosHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => remarks
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryStringArray.History))) remarksHistory;
        // sourceTokenAddress => groupId => round => source action ids with recipients
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) actionIdsWithRecipients;

        // actionTokenAddress => round => actionId => groupId => frozen generated reward
        // Load-bearing: the owner weight and the verifier weight are read per group, so the frozen
        // divisor alone is not enough. Freezing each group's slice too is what keeps every member of
        // a round dividing by, and being divided into, the same reward book.
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) groupRewardByRound;
        // actionTokenAddress => round => whether the reward book above has been frozen
        mapping(address => mapping(uint256 => bool)) rewardBookFrozen;
    }

    // Load-bearing: this must stay equal to ActionTarget's own join round (phase - 1). ActionTarget
    // keys the join snapshot it writes by that round, and every `isJoinedByRound` / `joinedAmount`
    // argument here is read in the same round space; if the two drift, the reported round and the
    // recorded snapshot disagree without any revert.
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

    // Load-bearing: every weight in a round must come from the same book the divisor came from.
    // Before the first settlement the book is the served GroupAction's live ledger; afterwards it is
    // the frozen snapshot taken by `GroupServiceExecutor._cacheActionRewards`. Reading live after the
    // freeze is what lets a later ledger move hand one member a second helping of the same reward.
    function groupReward(
        Layout storage s,
        address actionTokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        if (s.rewardBookFrozen[actionTokenAddress][round]) {
            return s.groupRewardByRound[actionTokenAddress][round][actionId][groupId];
        }
        return IGroupActionExecutor(s.groupActionExecutorAddress).generatedActionRewardByGroupId(
            actionTokenAddress, actionId, round, groupId
        );
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function requireMemberOwner(Layout storage s, uint256 memberId) internal view {
        if (IMemberNFT(s.memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
    }
}
