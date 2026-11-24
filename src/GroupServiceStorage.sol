// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";

library GroupServiceStorage {
    uint256 constant PRECISION = 1e18;
    uint256 constant MAX_RECIPIENTS_PER_ACTION = 8;
    uint256 constant MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP = 16;
    uint256 constant MAX_REMARK_BYTES = 256;
    uint256 constant MAX_REWARDS_PER_BATCH = 32;

    enum SettlementCause {
        RoundedToZero,
        NoEligibleWeight,
        PoolEmpty
    }

    struct Protocol {
        address memberNFTAddress;
        address groupActionExecutorAddress;
        address actionTargetAddress;
        address stakeAddress;
    }

    enum PrimaryRole {
        Owner,
        Verifier,
        Both
    }

    struct Settlement {
        address actionTokenAddress;
        uint256 publicVerifierRatio;
        uint256 providerIncentiveRatio;
        uint256 govRatioMultiplier;
        uint256 verifierWeight;
        uint256 ownerWeight;
        uint256 ownerProviderWeight;
        uint256 denominator;
        uint256 serviceReward;
        bool actionMinted;
        uint256 verifierReward;
        uint256 ownerReward;
        uint256 ownerBurned;
        SettlementCause cause;
    }

    struct MemberRewardKey {
        address tokenAddress;
        uint256 round;
        uint256 actionId;
        uint256 memberId;
    }

    struct PrimaryAmounts {
        uint256 owner;
        uint256 verifier;
        uint256 burn;
    }

    struct Share {
        address tokenAddress;
        uint256 round;
        uint256 serviceActionId;
        uint256 sourceActionId;
        uint256 groupId;
        uint256 memberId;
    }

    struct PaidShare {
        uint256 recipient;
        uint256 provider;
    }

    struct ShareMintResult {
        uint256 mintAmount;
        bool previouslyMinted;
        bool hasEligibleWeight;
    }

    struct Layout {
        // serviceTokenAddress => serviceActionId => action token address
        mapping(address => mapping(uint256 => address)) actionTokenAddressByActionId;
        // serviceTokenAddress => serviceActionId => gov ratio multiplier for the group owner (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) govRatioMultiplierByActionId;
        // serviceTokenAddress => serviceActionId => ratio for the public verifier (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) publicVerifierRatioByActionId;
        // serviceTokenAddress => serviceActionId => fixed Provider ratio (1e18 precision)
        mapping(address => mapping(uint256 => uint256)) providerIncentiveRatioByActionId;
        // serviceTokenAddress => serviceActionId => creation vote round
        mapping(address => mapping(uint256 => uint256)) createdRoundByActionId;
        // serviceTokenAddress => serviceActionId => round => memberId => settled verifier reward
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))))
            verifierRewardByMemberId;
        // serviceTokenAddress => serviceActionId => round => groupId => owner overflow already burned
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) ownerBurnByGroupId;
        // serviceTokenAddress => serviceActionId => round => memberId => owner reward retained by the member
        mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))))
            ownerRemainingByMemberId;

        // sourceTokenAddress => sourceActionId => groupId => round => recipient ids
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History)))
            recipientIdsHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => ratios
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))) ratiosHistory;
        // sourceTokenAddress => sourceActionId => groupId => round => remarks
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryStringArray.History))) remarksHistory;
        // sourceTokenAddress => groupId => round => source action ids with recipients
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) actionIdsWithRecipients;
        // serviceTokenAddress => serviceActionId => round => groupId => sourceActionId => memberId
        mapping(
            address
                => mapping(
                uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => PaidShare))))
            )
        ) paidShares;

        // sourceTokenAddress => recipientId => groups with configured rewards by round
        mapping(address => mapping(uint256 => RoundHistoryUint256Set.Storage)) recipientGroupIdsByRecipientId;
        // sourceTokenAddress => recipientId => groupId => source action ids by round
        mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Set.Storage)))
            recipientActionIdsByGroupIdByRecipientId;
    }
}
