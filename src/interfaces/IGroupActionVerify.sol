// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IVerificationInfo} from "./IVerificationInfo.sol";

struct VerifierApplication {
    uint256 applicationId;
    uint256 verifierId;
    string description;
    uint256 stoppedRound;
    uint256 withdrawnRound;
    uint256 pendingRound;
    uint256 punishmentAmount;
    uint256[] failedRounds;
}

interface IGroupActionVerifyEvents {
    event VerifierApplicationPunished(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed applicationId,
        uint256 verifierId,
        uint256[] failedRounds,
        uint256 burnedAmount
    );
    event VerifierApplicationStopped(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 applicationId,
        uint256 round
    );
    event VerifierApplicationDescriptionUpdated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed applicationId,
        uint256 effectiveRound,
        string description
    );
    event OriginScoresSubmitted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 round,
        uint256 verifierId,
        uint256 startIndex,
        uint256 totalActionFinalScore,
        uint256 verifiedGroupCount,
        bool roundVerified,
        bool groupVerified,
        uint256[] scores
    );
    event VerifierApplicationSubmitted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 round,
        uint256 applicationId,
        uint256 previousApplicationId,
        bool hasPreviousApplication,
        string description
    );
    event VerifierApplicationCancelled(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 round,
        uint256 applicationId
    );
    event VerifierStakeDeposited(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 round,
        uint256 amount
    );
    event VerifierStakeRefunded(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 round,
        uint256 amount
    );
    event ApplicationVoteRecorded(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 voterId,
        uint256 round,
        uint256 indexed applicationId,
        uint256 verifierId,
        uint256 voteAmountAdded,
        uint256 voteAmountTotal
    );
}

interface IGroupActionVerifyErrors {
    error ApplicationOverdue(
        uint256 applicationId,
        uint256 round
    );
    error ApplicationStopped(uint256 applicationId);
    error ReapplicationInStoppedRound(uint256 round);
    error ApplicationStillResponsible(
        uint256 applicationId,
        uint256 round
    );
    error OriginScoresEmpty();
    error VerifierNotElected(
        uint256 verifierId,
        uint256 round
    );
    error ScoreLimitExceeded(
        uint256 index,
        uint256 score,
        uint256 maxScore
    );
    error GroupVerificationAlreadyComplete(
        uint256 groupId,
        uint256 round
    );
    error VerificationBatchTooLarge(
        uint256 count,
        uint256 maxCount
    );
    error StartIndexMismatch(
        uint256 expected,
        uint256 actual
    );
    error ScoreCountExceeded(
        uint256 startIndex,
        uint256 count,
        uint256 maxCount
    );
    error ZeroVerifyVotes(
        address tokenAddress,
        uint256 verifierId
    );
    error NoActiveApplication(uint256 verifierId);
}

interface IGroupActionVerify is IVerificationInfo, IGroupActionVerifyEvents, IGroupActionVerifyErrors {
    function providerScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 score, uint256 groupFinalScore);

    function groupIdsWithProviderRewardByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount);

    function actionIdsWithProviderRewardByGroupIdByProviderId(
        address tokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount);

    function submitOriginScores(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external;

    function originScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 score,
            bool verified
        );

    function finalScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 score, bool verified);

    function totalActionFinalScore(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256);

    function verifiedMemberCount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256);

    function isRoundVerified(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool);

    function verifier(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 verifierId, uint256 applicationId, uint256 voteAmount);

    function verifierElectedRounds(
        address tokenAddress,
        uint256 actionId,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory rounds, uint256 totalCount);

    function submitVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) external returns (uint256 applicationId);

    function stopVerifierApplication(address tokenAddress, uint256 actionId, uint256 verifierId) external;

    function cancelVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external;

    function verifierStake(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (uint256);

    function verifierApplication(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application);

    function hasVerifierApplicationByRound(
        address tokenAddress,
        uint256 round,
        uint256 verifierId
    ) external view returns (bool);

    function verifierApplications(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            VerifierApplication[] memory applications,
            uint256 totalCount
        );

    function verifierApplicationsByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (VerifierApplication[] memory applications, uint256[] memory voteAmounts, uint256 totalCount);

    function voteAmountsByVerifierIds(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory voteAmounts);

    function applicationVoters(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory voterIds,
            uint256[] memory voteAmounts,
            uint256 totalCount
        );

    function applicationVotersByVerifierId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory voterIds,
            uint256[] memory voteAmounts,
            uint256 totalCount
        );
}
