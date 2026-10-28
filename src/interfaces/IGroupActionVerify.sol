// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IVerificationInfo} from "./IVerificationInfo.sol";

struct VerifierApplication {
    uint256 applicationId;
    uint256 verifierId;
    string description;
}

interface IGroupActionVerifyEvents {
    event OriginScoresSubmitted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 round,
        uint256 verifierId,
        uint256 startIndex,
        uint256 totalFinalScore,
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
    event VerifierLocked(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed verifierId,
        uint256 round
    );
    event ApplicationVoteRecorded(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 voterId,
        uint256 round,
        uint256 indexed applicationId,
        uint256 verifierId,
        uint256 votesAdded,
        uint256 totalVotes
    );
}

interface IGroupActionVerifyErrors {
    error OriginScoresEmpty();
    error VerifierNotRanked(uint256 verifierId, uint256 round);
    error VerifierNotOpen(uint256 verifierId, uint256 round);
    error ScoreLimitExceeded(uint256 index, uint256 score, uint256 maxScore);
    error GroupVerificationAlreadyComplete(uint256 groupId, uint256 round);
    error VerificationBatchTooLarge(uint256 count, uint256 maxCount);
    error StartIndexMismatch(uint256 expected, uint256 actual);
    error ScoreCountExceeded(uint256 startIndex, uint256 count, uint256 memberCount);
    error ZeroVerifyVotes(address tokenAddress, uint256 verifierId);
    error NoActiveApplication(uint256 verifierId);
    error VerifierAlreadyLocked(address tokenAddress, uint256 actionId, uint256 round);
}

interface IGroupActionVerify is IVerificationInfo, IGroupActionVerifyEvents, IGroupActionVerifyErrors {
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
        uint256 actionId,
        uint256 round,
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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 score, bool verified);

    function totalFinalScore(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256);

    function verifiedMemberCount(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function isRoundVerified(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (bool);

    function lockedVerifierId(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256);

    function submitVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 verifierId,
        string calldata description
    ) external returns (uint256 applicationId);

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
        uint256 actionId,
        uint256 round,
        uint256 verifierId
    ) external view returns (VerifierApplication memory application);

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
            uint256 total
        );

    function votesByVerifierIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256[] calldata verifierIds
    ) external view returns (uint256[] memory votes);

    function topVerifiers(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory verifierIds, uint256[] memory votes);

    function applicationVoters(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 applicationId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory voterIds,
            uint256[] memory votes,
            uint256 total
        );

    function applicationVotersByVerifierId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 verifierId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory voterIds,
            uint256[] memory votes,
            uint256 total
        );
}
