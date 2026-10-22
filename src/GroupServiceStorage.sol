// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";

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
        address mintAddress;
        bool initialized;

        // serviceTokenAddress => serviceActionId => action token address
        mapping(address => mapping(uint256 => address)) actionTokenAddress;
        // serviceTokenAddress => serviceActionId => gov ratio multiplier for the group owner (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) govRatioMultiplier;
        // serviceTokenAddress => serviceActionId => ratio for the public verifier (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) ratioForPublicVerifier;
        // serviceTokenAddress => serviceActionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRound;
        // actionTokenAddress => round => cached divisor (0 = not cached)
        mapping(address => mapping(uint256 => uint256)) totalGroupActionRewardByRound;

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

    function cachedDenominator(
        Layout storage s,
        address actionTokenAddress,
        uint256 round
    ) internal view returns (uint256) {
        return s.totalGroupActionRewardByRound[actionTokenAddress][round];
    }

    function cacheDenominator(
        Layout storage s,
        address actionTokenAddress,
        uint256 round,
        uint256 value
    ) internal {
        s.totalGroupActionRewardByRound[actionTokenAddress][round] = value;
    }

    // Load-bearing: the divisor cached by the executor may only be paired with weights from the same
    // final ledger. The cache is written only when the action token's round is prepared and the mint
    // window is open (verification closed); caching earlier pairs a frozen divisor with live weights
    // and pays a member twice without reverting.
    function groupReward(
        Layout storage s,
        address actionTokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        return IGroupActionExecutor(s.groupActionExecutorAddress).generatedActionRewardByGroupId(
            actionTokenAddress, actionId, round, groupId
        );
    }
}
