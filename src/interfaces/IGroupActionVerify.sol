// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IVerificationInfo} from "./IVerificationInfo.sol";

struct VerifierApplication {
    uint256 applicationId;
    uint256 memberId;
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
        uint256[] scores
    );
    event VerifierApplicationSubmitted(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 applicationId
    );
    event VerifierApplicationCancelled(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 applicationId
    );
    event VerifierLocked(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed round,
        uint256 memberId
    );
}

interface IGroupActionVerifyErrors {
    error OriginScoresEmpty();
    error InvalidCandidate();
    error ScoreExceedsMax();
    error AlreadyVerified();
    error StartIndexMismatch(uint256 expected, uint256 actual);
    error ScoresExceedAccountCount();
    error VerifyVotesZero();
    error ApplicationNotActive();
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
        uint256 memberId,
        string calldata description
    ) external returns (uint256 applicationId);

    function cancelVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external;

    function verifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
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
}
