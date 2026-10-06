// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupVerify} from "./interface/IGroupVerify.sol";
import {IGroupJoin} from "./interface/IGroupJoin.sol";
import {
    IExtensionGroupActionFactory
} from "./interface/IExtensionGroupActionFactory.sol";
import {
    IGroupManager,
    IGroupManagerErrors
} from "./interface/IGroupManager.sol";
import {ILOVE20Verify} from "@core/interfaces/ILOVE20Verify.sol";
import {ILOVE20Vote} from "@core/interfaces/ILOVE20Vote.sol";
import {IExtension} from "@extension/src/interface/IExtension.sol";
import {IExtensionCenter} from "@extension/src/interface/IExtensionCenter.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract GroupVerify is IGroupVerify {
    using EnumerableSet for EnumerableSet.UintSet;
    uint256 public constant MAX_ORIGIN_SCORE = 100;
    uint256 public constant PRECISION = 1e18;

    IExtensionGroupActionFactory internal _factory;
    IExtensionCenter internal _center;
    IGroupManager internal _groupManager;
    IERC721Enumerable internal _group;
    ILOVE20Verify internal _verify;
    ILOVE20Vote internal _vote;
    IGroupJoin internal _groupJoin;

    address public FACTORY_ADDRESS;
    bool internal _initialized;

    // extension => groupOwner => groupId => delegate
    mapping(address => mapping(address => mapping(uint256 => address)))
        internal _delegateByGroupId;
    // extension => round => account => score deduction (0 means full score 100, >0 means deduction from 100)
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        internal _originScoreDeductionByAccount;
    // extension => round => groupId => verified account count
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _verifiedAccountCount;
    // extension => round => groupId => accumulated total score
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _batchTotalScore;
    // extension => round => groupId => total score of all accounts in group
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _totalAccountScore;
    // extension => round => groupId => group score (with distrust applied)
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        internal _groupScore;
    // extension => round => total score of all verified groups
    mapping(address => mapping(uint256 => uint256)) internal _totalGroupScore;
    // extension => round => groupId => whether verification is complete
    mapping(address => mapping(uint256 => mapping(uint256 => bool)))
        internal _isVerified;
    // extension => round => list of verified group ids
    mapping(address => mapping(uint256 => uint256[])) internal _groupIds;
    // extension => round => groupId => verifier address
    mapping(address => mapping(uint256 => mapping(uint256 => address)))
        internal _verifierByGroupId;
    // extension => round => groupId => submitter address who submitted the original scores
    mapping(address => mapping(uint256 => mapping(uint256 => address)))
        internal _submitterByGroupId;
    // extension => round => verifier => list of verified group ids
    mapping(address => mapping(uint256 => mapping(address => uint256[])))
        internal _groupIdsByVerifier;
    // extension => round => list of verifiers
    mapping(address => mapping(uint256 => address[])) internal _verifiers;
    // tokenAddress => round => verifier => set of actionIds
    mapping(address => mapping(uint256 => mapping(address => EnumerableSet.UintSet)))
        internal _actionIdsByVerifier;
    // tokenAddress => round => set of actionIds with at least one verified group
    mapping(address => mapping(uint256 => EnumerableSet.UintSet))
        internal _actionIds;

    // extension => round => groupOwner => total distrust votes
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        internal _distrustVotesByGroupOwner;
    // extension => round => voter => groupOwner => distrust votes
    mapping(address => mapping(uint256 => mapping(address => mapping(address => uint256))))
        internal _distrustVotesByVoterByGroupOwner;

    // extension => round => groupOwner => list of voters
    mapping(address => mapping(uint256 => mapping(address => address[])))
        internal _distrustVotersByGroupOwner;
    // extension => round => list of groupOwners
    mapping(address => mapping(uint256 => address[]))
        internal _distrustGroupOwners;

    // extension => round => voter => groupOwner => reason
    mapping(address => mapping(uint256 => mapping(address => mapping(address => string))))
        internal _distrustReason;

    function initialize(address factory_) external {
        require(_initialized == false, "Already initialized");
        require(factory_ != address(0), "Invalid factory");

        FACTORY_ADDRESS = factory_;
        _factory = IExtensionGroupActionFactory(factory_);
        _center = IExtensionCenter(_factory.CENTER_ADDRESS());
        _groupManager = IGroupManager(_factory.GROUP_MANAGER_ADDRESS());
        _group = IERC721Enumerable(_factory.GROUP_ADDRESS());
        _verify = ILOVE20Verify(_center.verifyAddress());
        _vote = ILOVE20Vote(_center.voteAddress());
        _groupJoin = IGroupJoin(_factory.GROUP_JOIN_ADDRESS());

        _initialized = true;
    }

    modifier onlyValidExtension(address extension) {
        if (!_factory.exists(extension)) {
            revert NotRegisteredExtensionInFactory();
        }
        if (!IExtension(extension).initialized()) {
            revert ExtensionNotInitialized();
        }
        _;
    }

    modifier onlyGroupOwner(uint256 groupId) {
        if (_group.ownerOf(groupId) != msg.sender) revert OnlyGroupOwner();
        _;
    }

    function setGroupDelegate(
        address extension,
        uint256 groupId,
        address delegate
    ) external onlyValidExtension(extension) onlyGroupOwner(groupId) {
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        _delegateByGroupId[extension][msg.sender][groupId] = delegate;
        emit SetGroupDelegate({
            tokenAddress: tokenAddress,
            round: _verify.currentRound(),
            actionId: actionId,
            groupId: groupId,
            delegate: delegate
        });
    }

    function submitOriginScores(
        address extension,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) external onlyValidExtension(extension) {
        uint256 currentRound = _verify.currentRound();
        _validateSubmitOriginScores(
            extension,
            groupId,
            startIndex,
            originScores,
            currentRound
        );
        bool isComplete = _updateBatchState(
            extension,
            currentRound,
            groupId,
            startIndex,
            originScores
        );
        if (isComplete) {
            _finalizeVerification(extension, currentRound, groupId, msg.sender);
        }
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        _emitSubmitOriginScores(
            tokenAddress,
            actionId,
            currentRound,
            groupId,
            startIndex,
            originScores.length,
            isComplete
        );
    }

    function _validateSubmitOriginScores(
        address extension,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores,
        uint256 currentRound
    ) internal view {
        if (!canVerify(extension, msg.sender, groupId)) {
            revert NotVerifier();
        }
        if (!_groupManager.isGroupActive(extension, groupId)) {
            revert IGroupManagerErrors.GroupNotActive();
        }
        if (originScores.length == 0) {
            revert OriginScoresEmpty();
        }
        if (_isVerified[extension][currentRound][groupId]) {
            revert AlreadyVerified();
        }

        if (
            startIndex !=
            _verifiedAccountCount[extension][currentRound][groupId]
        ) {
            revert InvalidStartIndex();
        }

        uint256 accountCount = _groupJoin.accountsByGroupIdCount(
            extension,
            currentRound,
            groupId
        );
        if (startIndex + originScores.length > accountCount) {
            revert ScoresExceedAccountCount();
        }
    }

    function _updateBatchState(
        address extension,
        uint256 currentRound,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) internal returns (bool isComplete) {
        _batchTotalScore[extension][currentRound][
            groupId
        ] += _storeOriginScores(
            extension,
            currentRound,
            groupId,
            startIndex,
            originScores
        );

        _verifiedAccountCount[extension][currentRound][groupId] += originScores
            .length;

        isComplete =
            _verifiedAccountCount[extension][currentRound][groupId] ==
            _groupJoin.accountsByGroupIdCount(extension, currentRound, groupId);
    }

    function _finalizeVerification(
        address extension,
        uint256 currentRound,
        uint256 groupId,
        address submitter
    ) internal {
        // 0. Update verification state
        _isVerified[extension][currentRound][groupId] = true;

        // 1. Prepare data
        address groupOwner = _group.ownerOf(groupId);

        // 2. Record verifier information
        _verifierByGroupId[extension][currentRound][groupId] = groupOwner;
        _submitterByGroupId[extension][currentRound][groupId] = submitter;
        if (
            _groupIdsByVerifier[extension][currentRound][groupOwner].length == 0
        ) {
            _verifiers[extension][currentRound].push(groupOwner);
        }

        // 3. Record total account score by groupId
        _totalAccountScore[extension][currentRound][groupId] = _batchTotalScore[
            extension
        ][currentRound][groupId];

        // 4. Calculate and update group score
        uint256 calculatedGroupScore = _calculateGroupScore(
            extension,
            currentRound,
            groupId
        );
        _groupScore[extension][currentRound][groupId] = calculatedGroupScore;
        _totalGroupScore[extension][currentRound] += calculatedGroupScore;

        // 5. Update group lists
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        if (_groupIds[extension][currentRound].length == 0) {
            _actionIds[tokenAddress][currentRound].add(actionId);
        }
        _groupIdsByVerifier[extension][currentRound][groupOwner].push(groupId);
        _groupIds[extension][currentRound].push(groupId);

        // 6. Record actionId for verifier (with deduplication)
        _actionIdsByVerifier[tokenAddress][currentRound][groupOwner].add(
            actionId
        );
    }

    function _emitSubmitOriginScores(
        address tokenAddress,
        uint256 actionId,
        uint256 currentRound,
        uint256 groupId,
        uint256 startIndex,
        uint256 count,
        bool isComplete
    ) internal {
        emit SubmitOriginScores({
            tokenAddress: tokenAddress,
            round: currentRound,
            actionId: actionId,
            groupId: groupId,
            startIndex: startIndex,
            count: count,
            isComplete: isComplete
        });
    }

    function distrustVote(
        address extension,
        address groupOwner,
        uint256 amount,
        string calldata reason
    ) external onlyValidExtension(extension) {
        address voter = msg.sender;
        uint256 currentRound = _verify.currentRound();

        _validateDistrustVote(
            extension,
            currentRound,
            voter,
            groupOwner,
            amount,
            reason
        );
        _updateDistrustVoteState(
            extension,
            currentRound,
            voter,
            groupOwner,
            amount,
            reason
        );

        _updateGroupScoresForVerifier(extension, currentRound, groupOwner);

        emit DistrustVote({
            tokenAddress: IExtension(extension).TOKEN_ADDRESS(),
            round: currentRound,
            actionId: IExtension(extension).actionId(),
            groupOwner: groupOwner,
            voter: voter,
            amount: amount,
            reason: reason
        });
    }

    function _validateDistrustVote(
        address extension,
        uint256 currentRound,
        address voter,
        address groupOwner,
        uint256 amount,
        string calldata reason
    ) internal view {
        if (amount == 0) revert DistrustVoteZeroAmount();
        if (bytes(reason).length == 0) revert InvalidReason();

        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        uint256 verifyVotes = _verify.scoreByVerifierByActionIdByAccount(
            tokenAddress,
            currentRound,
            voter,
            actionId,
            extension
        );
        if (verifyVotes == 0) revert VerifyVotesZero();

        uint256 preVotes = _distrustVotesByVoterByGroupOwner[extension][
            currentRound
        ][voter][groupOwner];
        if (preVotes + amount > verifyVotes)
            revert DistrustVoteExceedsVerifyVotes();
    }

    function _updateDistrustVoteState(
        address extension,
        uint256 currentRound,
        address voter,
        address groupOwner,
        uint256 amount,
        string calldata reason
    ) internal {
        _distrustReason[extension][currentRound][voter][groupOwner] = reason;

        uint256 preVotes = _distrustVotesByVoterByGroupOwner[extension][
            currentRound
        ][voter][groupOwner];
        if (preVotes == 0) {
            _distrustVotersByGroupOwner[extension][currentRound][groupOwner]
                .push(voter);
        }

        if (
            _distrustVotesByGroupOwner[extension][currentRound][groupOwner] == 0
        ) {
            _distrustGroupOwners[extension][currentRound].push(groupOwner);
        }

        _distrustVotesByVoterByGroupOwner[extension][currentRound][voter][
            groupOwner
        ] += amount;
        _distrustVotesByGroupOwner[extension][currentRound][
            groupOwner
        ] += amount;
    }

    function originScoreByAccount(
        address extension,
        uint256 round,
        address account
    ) public view returns (uint256) {
        uint256 groupId = _groupJoin.groupIdByAccount(
            extension,
            round,
            account
        );

        // If account is not in any group, return 0
        if (groupId == 0) {
            return 0;
        }

        // if group is verified, return the deduction value
        if (_isVerified[extension][round][groupId]) {
            return
                MAX_ORIGIN_SCORE -
                _originScoreDeductionByAccount[extension][round][account];
        }

        uint256 verifiedCount = _verifiedAccountCount[extension][round][
            groupId
        ];

        // If group is not verified, return 0
        if (verifiedCount == 0) {
            return 0;
        }

        (bool found, uint256 index) = _groupJoin.accountIndexByGroupId(
            extension,
            groupId,
            account,
            round
        );
        if (!found || index >= verifiedCount) {
            return 0;
        }

        uint256 deduction = _originScoreDeductionByAccount[extension][round][
            account
        ];
        return MAX_ORIGIN_SCORE - deduction;
    }

    function totalAccountScore(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _totalAccountScore[extension][round][groupId];
    }
    function accountScore(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256) {
        uint256 originScoreVal = originScoreByAccount(
            extension,
            round,
            account
        );
        if (originScoreVal == 0) return 0;

        uint256 amount = _groupJoin.joinedAmountByAccount(
            extension,
            round,
            account
        );
        return originScoreVal * amount;
    }

    function groupScore(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _groupScore[extension][round][groupId];
    }

    function distrustRateByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _distrustRateByGroupId(extension, round, groupId);
    }

    function _distrustRateByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        // Prefer verifier (recorded at verification time)
        address groupOwner = _verifierByGroupId[extension][round][groupId];
        // Only fallback to current owner for current round (not yet verified)
        if (groupOwner == address(0) && round == _verify.currentRound()) {
            groupOwner = _group.ownerOf(groupId);
        }
        return _calculateDistrustRate(extension, round, groupOwner);
    }

    function _calculateDistrustRate(
        address extension,
        uint256 round,
        address groupOwner
    ) internal view returns (uint256) {
        if (groupOwner == address(0)) {
            return 0; // No group owner means no distrust
        }

        uint256 distrustVotes = _distrustVotesByGroupOwner[extension][round][
            groupOwner
        ];
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        uint256 totalVotes = _vote.votesNumByActionId(
            tokenAddress,
            round,
            actionId
        );

        if (totalVotes == 0) {
            return 0; // No votes means no distrust
        }

        return (distrustVotes * PRECISION) / totalVotes;
    }

    function totalGroupScore(
        address extension,
        uint256 round
    ) external view returns (uint256) {
        return _totalGroupScore[extension][round];
    }

    function delegateByGroupId(
        address extension,
        uint256 groupId
    ) external view returns (address) {
        address groupOwner = _group.ownerOf(groupId);
        return _delegateByGroupId[extension][groupOwner][groupId];
    }

    function canVerify(
        address extension,
        address account,
        uint256 groupId
    ) public view returns (bool) {
        address groupOwner = _group.ownerOf(groupId);
        bool isValidDelegate = account ==
            _delegateByGroupId[extension][groupOwner][groupId];
        return account == groupOwner || isValidDelegate;
    }

    function verifiedAccountCount(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _verifiedAccountCount[extension][round][groupId];
    }

    function isVerified(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (bool) {
        return _isVerified[extension][round][groupId];
    }

    function verifiers(
        address extension,
        uint256 round
    ) external view returns (address[] memory) {
        return _verifiers[extension][round];
    }

    function verifiersCount(
        address extension,
        uint256 round
    ) external view returns (uint256) {
        return _verifiers[extension][round].length;
    }

    function verifiersAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (address) {
        return _verifiers[extension][round][index];
    }

    function verifierByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address) {
        return _verifierByGroupId[extension][round][groupId];
    }

    function submitterByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address) {
        return _submitterByGroupId[extension][round][groupId];
    }

    function groupIdsByVerifier(
        address extension,
        uint256 round,
        address verifier
    ) external view returns (uint256[] memory) {
        return _groupIdsByVerifier[extension][round][verifier];
    }

    function groupIdsByVerifierCount(
        address extension,
        uint256 round,
        address verifier
    ) external view returns (uint256) {
        return _groupIdsByVerifier[extension][round][verifier].length;
    }

    function groupIdsByVerifierAtIndex(
        address extension,
        uint256 round,
        address verifier,
        uint256 index
    ) external view returns (uint256) {
        return _groupIdsByVerifier[extension][round][verifier][index];
    }

    function actionIdsByVerifier(
        address tokenAddress,
        uint256 round,
        address verifier
    ) external view returns (uint256[] memory) {
        return _actionIdsByVerifier[tokenAddress][round][verifier].values();
    }

    function actionIdsByVerifierCount(
        address tokenAddress,
        uint256 round,
        address verifier
    ) external view returns (uint256) {
        return _actionIdsByVerifier[tokenAddress][round][verifier].length();
    }

    function actionIdsByVerifierAtIndex(
        address tokenAddress,
        uint256 round,
        address verifier,
        uint256 index
    ) external view returns (uint256) {
        return _actionIdsByVerifier[tokenAddress][round][verifier].at(index);
    }

    function actionIds(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256[] memory) {
        return _actionIds[tokenAddress][round].values();
    }

    function actionIdsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256) {
        return _actionIds[tokenAddress][round].length();
    }

    function actionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (uint256) {
        return _actionIds[tokenAddress][round].at(index);
    }

    function groupIds(
        address extension,
        uint256 round
    ) external view returns (uint256[] memory) {
        return _groupIds[extension][round];
    }

    function groupIdsCount(
        address extension,
        uint256 round
    ) external view returns (uint256) {
        return _groupIds[extension][round].length;
    }

    function groupIdsAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (uint256) {
        return _groupIds[extension][round][index];
    }

    function distrustVotesByGroupOwner(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (uint256) {
        return _distrustVotesByGroupOwner[extension][round][groupOwner];
    }

    function distrustVotesByVoterByGroupOwner(
        address extension,
        uint256 round,
        address voter,
        address groupOwner
    ) external view returns (uint256) {
        return
            _distrustVotesByVoterByGroupOwner[extension][round][voter][
                groupOwner
            ];
    }

    function distrustReason(
        address extension,
        uint256 round,
        address voter,
        address groupOwner
    ) external view returns (string memory) {
        return _distrustReason[extension][round][voter][groupOwner];
    }

    function distrustVotersByGroupOwner(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (address[] memory) {
        return _distrustVotersByGroupOwner[extension][round][groupOwner];
    }

    function distrustVotersByGroupOwnerCount(
        address extension,
        uint256 round,
        address groupOwner
    ) external view returns (uint256) {
        return _distrustVotersByGroupOwner[extension][round][groupOwner].length;
    }

    function distrustVotersByGroupOwnerAtIndex(
        address extension,
        uint256 round,
        address groupOwner,
        uint256 index
    ) external view returns (address) {
        return _distrustVotersByGroupOwner[extension][round][groupOwner][index];
    }

    function distrustGroupOwners(
        address extension,
        uint256 round
    ) external view returns (address[] memory) {
        return _distrustGroupOwners[extension][round];
    }

    function distrustGroupOwnersCount(
        address extension,
        uint256 round
    ) external view returns (uint256) {
        return _distrustGroupOwners[extension][round].length;
    }

    function distrustGroupOwnersAtIndex(
        address extension,
        uint256 round,
        uint256 index
    ) external view returns (address) {
        return _distrustGroupOwners[extension][round][index];
    }

    function _storeOriginScores(
        address extension,
        uint256 currentRound,
        uint256 groupId,
        uint256 startIndex,
        uint256[] calldata originScores
    ) internal returns (uint256 totalScore) {
        uint256 length = originScores.length;
        for (uint256 i = 0; i < length; i++) {
            if (originScores[i] > MAX_ORIGIN_SCORE) revert ScoreExceedsMax();
            address account = _groupJoin.accountsByGroupIdAtIndex(
                extension,
                currentRound,
                groupId,
                startIndex + i
            );

            // Store deduction instead of original score to save gas
            // If score is 100, don't store (remains 0)
            // If score < 100, store MAX_ORIGIN_SCORE - originScore
            if (originScores[i] < MAX_ORIGIN_SCORE) {
                _originScoreDeductionByAccount[extension][currentRound][
                    account
                ] = MAX_ORIGIN_SCORE - originScores[i];
            }

            totalScore +=
                originScores[i] *
                _groupJoin.joinedAmountByAccount(
                    extension,
                    currentRound,
                    account
                );
        }
        return totalScore;
    }

    function _computeGroupScore(
        uint256 groupAmount,
        uint256 distrustRate_
    ) internal pure returns (uint256) {
        uint256 oneMinusDistrust = PRECISION - distrustRate_;
        return (groupAmount * oneMinusDistrust) / PRECISION;
    }

    function _calculateGroupScore(
        address extension,
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        uint256 groupAmount = _groupJoin.totalJoinedAmountByGroupId(
            extension,
            round,
            groupId
        );
        uint256 distrustRate_ = _distrustRateByGroupId(
            extension,
            round,
            groupId
        );

        return _computeGroupScore(groupAmount, distrustRate_);
    }

    /// @notice Updates group scores for all groups owned by a verifier when distrust votes change
    /// @dev Recalculates each group's score with the new distrust rate and updates totalGroupScore
    /// @param extension The extension address
    /// @param round The round number
    /// @param verifier The verifier whose groups need score updates
    function _updateGroupScoresForVerifier(
        address extension,
        uint256 round,
        address verifier
    ) internal {
        uint256[] storage groupIds_ = _groupIdsByVerifier[extension][round][
            verifier
        ];
        uint256 totalGroupScore_ = _totalGroupScore[extension][round];
        mapping(uint256 => uint256) storage scoreMap = _groupScore[extension][
            round
        ];

        for (uint256 i = 0; i < groupIds_.length; i++) {
            uint256 groupId = groupIds_[i];
            uint256 oldScore = scoreMap[groupId];
            uint256 newScore = _calculateGroupScore(extension, round, groupId);
            scoreMap[groupId] = newScore;
            totalGroupScore_ = totalGroupScore_ - oldScore + newScore;
        }

        _totalGroupScore[extension][round] = totalGroupScore_;
    }
}
