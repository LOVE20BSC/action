// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IGroupVerifyEvents {
    event SubmitOriginScores(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 startIndex,
        uint256 count,
        bool isComplete
    );
    event SetGroupDelegate(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        uint256 indexed groupId,
        address delegate
    );
    event DistrustVote(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        address indexed groupOwner,
        address voter,
        uint256 amount,
        string reason
    );
}

interface IGroupVerifyErrors {
    error OriginScoresEmpty();
    error NotVerifier();
    error ScoreExceedsMax();
    error AlreadyVerified();
    error InvalidStartIndex();
    error ScoresExceedAccountCount();
    error VerifyVotesZero();
    error DistrustVoteExceedsVerifyVotes();
    error InvalidReason();
    error DistrustVoteZeroAmount();
    error OnlyGroupOwner();
    error NotRegisteredExtensionInFactory();
    error ExtensionNotInitialized();
}

interface IGroupVerify is IGroupVerifyEvents, IGroupVerifyErrors {
    /// @notice Maximum origin score for verification (100 = full score)
    function MAX_ORIGIN_SCORE() external pure returns (uint256);

    /// @notice Precision constant for ratio calculations (1e18)
    function PRECISION() external pure returns (uint256);

    function initialize(address factory_) external;

    function FACTORY_ADDRESS() external view returns (address);

    function submitOriginScores(
        address extension,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external;

    function setGroupDelegate(
        address extension,
        uint256 groupId,
        address delegate
    ) external;

    function distrustVote(
        address extension,
        address groupOwner,
        uint256 amount,
        string calldata reason
    ) external;

    function originScoreByAccount(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256);

    function accountScore(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256);

    function totalAccountScore(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function groupScore(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function totalGroupScore(
        address extension,
        uint256 round
    ) external view returns (uint256);

    function delegateByGroupId(
        address extension,
        uint256 groupId
    ) external view returns (address);

    function canVerify(
        address extension,
        address account,
        uint256 groupId
    ) external view returns (bool);

    function verifiedAccountCount(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function isVerified(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (bool);

    function verifiers(
        address extension,
        uint256 round
    ) external view returns (address[] memory);

    function verifiersCount(
        address extension,
        uint256 round
    ) external view returns (uint256);

    function verifiersAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (address);

    function verifierByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address);

    function submitterByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address);

    function groupIdsByVerifier(
        address extension,
        uint256 round,
        address verifier
    ) external view returns (uint256[] memory);

    function groupIdsByVerifierCount(
        address extension,
        uint256 round,
        address verifier
    ) external view returns (uint256);

    function groupIdsByVerifierAtIndex(
        address extension,
        uint256 round,
        address verifier,
        uint256 index
    ) external view returns (uint256);

    function actionIdsByVerifier(
        address tokenAddress,
        uint256 round,
        address verifier
    ) external view returns (uint256[] memory);

    function actionIdsByVerifierCount(
        address tokenAddress,
        uint256 round,
        address verifier
    ) external view returns (uint256);

    function actionIdsByVerifierAtIndex(
        address tokenAddress,
        uint256 round,
        address verifier,
        uint256 index
    ) external view returns (uint256);

    function actionIds(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256[] memory);

    function actionIdsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function actionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (uint256);

    function groupIds(
        address extension,
        uint256 round
    ) external view returns (uint256[] memory);

    function groupIdsCount(
        address extension,
        uint256 round
    ) external view returns (uint256);

    function groupIdsAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (uint256);

    function distrustVotesByGroupOwner(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (uint256);

    function distrustVotesByVoterByGroupOwner(
        address extension,
        uint256 round,
        address voter,
        address groupOwner
    ) external view returns (uint256);

    function distrustReason(
        address extension,
        uint256 round,
        address voter,
        address groupOwner
    ) external view returns (string memory);

    function distrustVotersByGroupOwner(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (address[] memory);

    function distrustVotersByGroupOwnerCount(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (uint256);

    function distrustVotersByGroupOwnerAtIndex(
        address extension,
        uint256 round,
        address groupOwner,
        uint256 index
    ) external view returns (address);

    function distrustGroupOwners(
        address extension,
        uint256 round
    ) external view returns (address[] memory);

    function distrustGroupOwnersCount(
        address extension,
        uint256 round
    ) external view returns (uint256);

    function distrustGroupOwnersAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (address);

    function distrustRateByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);
}
