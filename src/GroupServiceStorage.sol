// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";

library GroupServiceStorage {
    uint256 constant PRECISION = 1e18;
    uint256 constant DEFAULT_MAX_RECIPIENTS = 10;
    uint256 constant MAX_REMARK_BYTES = 256;

    struct Protocol {
        address memberNFTAddress;
        address groupActionExecutorAddress;
    }

    struct Layout {
        // serviceTokenAddress => serviceActionId => action token address
        mapping(address => mapping(uint256 => address)) actionTokenAddressByActionId;
        // serviceTokenAddress => serviceActionId => gov ratio multiplier for the group owner (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) govRatioMultiplierByActionId;
        // serviceTokenAddress => serviceActionId => ratio for the public verifier (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) publicVerifierRatioByActionId;
        // serviceTokenAddress => serviceActionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRoundByActionId;
        // actionTokenAddress => round => cached divisor (0 = not cached)
        mapping(address => mapping(uint256 => uint256)) totalGroupActionRewardByRound;

        // serviceTokenAddress => serviceActionId => round => memberId => settlement record
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) memberMinted;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) verifierRewardByMemberId;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerBurnedByMemberId;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerDistributedByMemberId;
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerRemainingByMemberId;

        // sourceTokenAddress => sourceActionId => groupId => round => recipient ids
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))) recipientIdsHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => ratios
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))) ratiosHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => remarks
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryStringArray.History))) remarksHistory;
        // sourceTokenAddress => groupId => round => source action ids with recipients
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) actionIdsWithRecipients;
    }

    function cachedDenominator(
        Layout storage self,
        address actionTokenAddress,
        uint256 round
    ) internal view returns (uint256) {
        return self.totalGroupActionRewardByRound[actionTokenAddress][round];
    }

    function cacheDenominator(
        Layout storage self,
        address actionTokenAddress,
        uint256 round,
        uint256 value
    ) internal {
        self.totalGroupActionRewardByRound[actionTokenAddress][round] = value;
    }

    // Load-bearing: the divisor cached by the executor may only be paired with weights from the same
    // final ledger. The cache is written only when the action token's round is prepared and the mint
    // window is open (verification closed); caching earlier pairs a frozen divisor with live weights
    // and pays a member twice without reverting.
    function groupReward(
        address groupActionExecutorAddress,
        address actionTokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        return IGroupActionExecutor(groupActionExecutorAddress).generatedActionRewardByGroupId(
            actionTokenAddress, actionId, round, groupId
        );
    }
}
