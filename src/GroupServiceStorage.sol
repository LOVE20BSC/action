// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";

library GroupServiceStorage {
    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_RECIPIENTS_PER_ACTION = 8;
    uint256 constant MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP = 16;
    uint256 constant MAX_REMARK_BYTES = 256;

    enum SettlementCause {
        RoundedToZero,
        NoEligibleWeight,
        PoolEmpty
    }

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
        // serviceTokenAddress => serviceActionId => round => memberId => whether the member reward is settled
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) memberMinted;
        // serviceTokenAddress => serviceActionId => round => memberId => settled verifier reward
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) verifierRewardByMemberId;
        // serviceTokenAddress => serviceActionId => round => memberId => owner reward burned at settlement
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerBurnedByMemberId;
        // serviceTokenAddress => serviceActionId => round => memberId => owner reward paid to recipients
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerDistributedByMemberId;
        // serviceTokenAddress => serviceActionId => round => memberId => owner reward retained by the member
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
