// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

import {VerifierApplication} from "../../src/interfaces/IGroupActionVerify.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Phase mock: GroupService only reads `currentPhase`.
contract MockGroupServicePhase {
    uint256 internal _currentPhase;

    function setCurrentPhase(uint256 currentPhase_) external {
        _currentPhase = currentPhase_;
    }

    function currentPhase() external view returns (uint256) {
        return _currentPhase;
    }
}

/// @notice MemberNFT mock: reverts on nonexistent ids, like the real one.
contract MockGroupServiceMemberNFT {
    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 memberId, address owner) external {
        _owners[memberId] = owner;
    }

    function ownerOf(uint256 memberId) external view returns (address) {
        address owner = _owners[memberId];
        if (owner == address(0)) {
            revert IERC721Errors.ERC721NonexistentToken(memberId);
        }
        return owner;
    }
}

/// @notice Stake mock: exposes the three addresses GroupService derives plus the
///         governance vote reads used by the owner cap.
contract MockGroupServiceStake {
    address public memberNFTAddress;
    address public phaseAddress;
    address public launchAddress;

    // tokenAddress => total valid gov votes
    mapping(address => uint256) internal _totalValidGovVotes;
    // tokenAddress => memberId => valid gov votes
    mapping(address => mapping(uint256 => uint256)) internal _validGovVotes;

    function setMemberNFTAddress(address memberNFTAddress_) external {
        memberNFTAddress = memberNFTAddress_;
    }

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setLaunchAddress(address launchAddress_) external {
        launchAddress = launchAddress_;
    }

    function setTotalValidGovVotes(address tokenAddress, uint256 votes) external {
        _totalValidGovVotes[tokenAddress] = votes;
    }

    function setValidGovVotes(address tokenAddress, uint256 memberId, uint256 votes) external {
        _validGovVotes[tokenAddress][memberId] = votes;
    }

    // The real `Stake` is round-keyed; this double answers only the phase's current round (zero otherwise).
    function totalValidGovVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        if (round != IPhase(phaseAddress).currentPhase()) return 0;
        return _totalValidGovVotes[tokenAddress];
    }

    function validGovVotes(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256) {
        if (round != IPhase(phaseAddress).currentPhase()) return 0;
        return _validGovVotes[tokenAddress][memberId];
    }
}

/// @notice Launch mock: only the direct-parent relation is programmable.
contract MockGroupServiceLaunch {
    mapping(address => address) internal _parentTokenOf;

    function setParentToken(address tokenAddress, address parentTokenAddress) external {
        _parentTokenOf[tokenAddress] = parentTokenAddress;
    }

    function parentTokenOf(address tokenAddress) external view returns (address) {
        return _parentTokenOf[tokenAddress];
    }
}

/// @notice Mint mock: only the round-preparation flag the service executor reads.
contract MockGroupServiceMint {
    mapping(address => mapping(uint256 => bool)) internal _prepared;

    function setRewardPrepared(address tokenAddress, uint256 round, bool prepared) external {
        _prepared[tokenAddress][round] = prepared;
    }

    function isRewardPrepared(address tokenAddress, uint256 round) external view returns (bool) {
        return _prepared[tokenAddress][round];
    }
}

/// @notice ActionTarget mock. Replicates the behaviors GroupService leans on: the
///         join round is `currentPhase - 1` with a `JoinNotOpen` window
///         (`currentRound > createdRound`), round snapshots keep history —
///         clearing only removes the current join round, never past rounds.
contract MockGroupServiceActionTarget {
    error JoinNotOpen(address tokenAddress, uint256 actionId, uint256 currentRound, uint256 createdRound);

    address public phaseAddress;
    address public mintAddress;

    // tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRound;
    // tokenAddress => actionId => memberId => currently joined
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _joined;
    // tokenAddress => actionId => memberId => round => joined as of that round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) internal _joinedByRound;
    // key => recorded rounds (ascending), key = keccak256(token, actionId, memberId)
    mapping(bytes32 => uint256[]) internal _recordedRounds;

    // tokenAddress => round => voted action ids / executors
    mapping(address => mapping(uint256 => uint256[])) internal _votedActionIds;
    mapping(address => mapping(uint256 => address[])) internal _votedExecutors;

    // tokenAddress => actionId => round => reward amount / minted flag
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _actionReward;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _actionMinted;

    // tokenAddress => actionId => the bound executor
    mapping(address => mapping(uint256 => address)) internal _executorByActionId;

    uint256 public mintReturnAmount;
    uint256 public mintRewardCalls;
    address public lastMintTokenAddress;
    uint256 public lastMintActionId;
    uint256 public lastMintRound;

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setMintAddress(address mintAddress_) external {
        mintAddress = mintAddress_;
    }

    function setBoundExecutor(address tokenAddress, uint256 actionId, address executor_) external {
        _executorByActionId[tokenAddress][actionId] = executor_;
    }

    function setCreatedRound(address tokenAddress, uint256 actionId, uint256 createdRound) external {
        _createdRound[tokenAddress][actionId] = createdRound;
    }

    function setVotedActions(
        address tokenAddress,
        uint256 round,
        uint256[] calldata actionIds,
        address[] calldata executors
    ) external {
        require(actionIds.length == executors.length, "parallel arrays");
        _votedActionIds[tokenAddress][round] = actionIds;
        _votedExecutors[tokenAddress][round] = executors;
    }

    function setActionReward(address tokenAddress, uint256 actionId, uint256 round, uint256 amount, bool minted)
        external
    {
        _actionReward[tokenAddress][actionId][round] = amount;
        _actionMinted[tokenAddress][actionId][round] = minted;
    }

    function setMintReturnAmount(uint256 mintReturnAmount_) external {
        mintReturnAmount = mintReturnAmount_;
    }

    function registerJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        uint256 currentRound = MockGroupServicePhase(phaseAddress).currentPhase();
        uint256 createdRound = _createdRound[tokenAddress][actionId];
        if (currentRound <= createdRound) {
            revert JoinNotOpen(tokenAddress, actionId, currentRound, createdRound);
        }
        _recordMembership(tokenAddress, actionId, memberId, currentRound - 1, true);
    }

    function clearJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        _recordMembership(tokenAddress, actionId, memberId, _joinRound(), false);
    }

    function isJoined(address tokenAddress, uint256 actionId, uint256 memberId) external view returns (bool) {
        return _joined[tokenAddress][actionId][memberId];
    }

    function isJoinedByRound(address tokenAddress, uint256 actionId, uint256 memberId, uint256 round)
        external
        view
        returns (bool)
    {
        if (round > _joinRound()) {
            return false;
        }
        return _containsByRound(tokenAddress, actionId, memberId, round);
    }

    function actionReward(address tokenAddress, uint256 actionId, uint256 round)
        external
        view
        returns (uint256 amount, bool minted)
    {
        amount = _actionReward[tokenAddress][actionId][round];
        minted = _actionMinted[tokenAddress][actionId][round];
    }

    function mintActionReward(address tokenAddress, uint256 actionId, uint256 round) external returns (uint256) {
        mintRewardCalls++;
        lastMintTokenAddress = tokenAddress;
        lastMintActionId = actionId;
        lastMintRound = round;
        _actionReward[tokenAddress][actionId][round] = mintReturnAmount;
        _actionMinted[tokenAddress][actionId][round] = true;
        return mintReturnAmount;
    }

    function votedActions(address tokenAddress, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory actionIds, address[] memory executors, uint256 total)
    {
        uint256[] storage ids = _votedActionIds[tokenAddress][round];
        address[] storage exes = _votedExecutors[tokenAddress][round];
        total = ids.length;
        if (offset >= total) {
            return (new uint256[](0), new address[](0), total);
        }
        uint256 remaining = total - offset;
        uint256 size = limit < remaining ? limit : remaining;
        actionIds = new uint256[](size);
        executors = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 index = reverse ? total - 1 - offset - i : offset + i;
            actionIds[i] = ids[index];
            executors[i] = exes[index];
        }
    }

    function _joinRound() internal view returns (uint256) {
        uint256 currentRound = MockGroupServicePhase(phaseAddress).currentPhase();
        return currentRound == 0 ? 0 : currentRound - 1;
    }

    function _recordMembership(address tokenAddress, uint256 actionId, uint256 memberId, uint256 round, bool present)
        internal
    {
        bytes32 key = keccak256(abi.encode(tokenAddress, actionId, memberId));
        uint256[] storage rounds = _recordedRounds[key];
        if (rounds.length == 0 || rounds[rounds.length - 1] != round) {
            rounds.push(round);
        }
        _joinedByRound[tokenAddress][actionId][memberId][round] = present;
        _joined[tokenAddress][actionId][memberId] = present;
    }

    function _containsByRound(address tokenAddress, uint256 actionId, uint256 memberId, uint256 round)
        internal
        view
        returns (bool)
    {
        uint256[] storage rounds = _recordedRounds[keccak256(abi.encode(tokenAddress, actionId, memberId))];
        for (uint256 i = rounds.length; i > 0; i--) {
            if (rounds[i - 1] <= round) {
                return _joinedByRound[tokenAddress][actionId][memberId][rounds[i - 1]];
            }
        }
        return false;
    }
}

/// @notice GroupActionExecutor mock: programmable per-round group ledger — the
///         served community data GroupService aggregates.
contract MockGroupServiceGroupActionExecutor {
    // tokenAddress => memberId => the member owns an active group
    mapping(address => mapping(uint256 => bool)) internal _activeGroups;
    // tokenAddress => actionId => memberId => applicationId (0 = no application)
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _applicationId;
    // first round in which the application stands
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _applicationSinceRound;
    // tokenAddress => actionId => round => group ids
    mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) internal _groupIds;
    bool internal _rewardReadsBlocked;
    bool internal _groupSliceReadsBlocked;
    // tokenAddress => actionId => round => groupId => group score
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _groupReward;
    // tokenAddress => actionId => round => the action's own reward; zero means "equal to the group
    // scores it is split by", which keeps the default ledger self-consistent
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _actionReward;
    // tokenAddress => actionId => round => locked verifier memberId
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _lockedVerifierId;
    // tokenAddress => total staked
    mapping(address => uint256) internal _totalStaked;
    // tokenAddress => memberId => total staked
    mapping(address => mapping(uint256 => uint256)) internal _totalStakedByMemberId;

    // tokenAddress => actionId => join token address (zero = action never created)
    mapping(address => mapping(uint256 => address)) internal _joinTokenAddress;

    function setHasActiveGroups(address tokenAddress, uint256 memberId, bool active) external {
        _activeGroups[tokenAddress][memberId] = active;
    }

    function setJoinTokenAddress(address tokenAddress, uint256 actionId, address joinTokenAddress) external {
        _joinTokenAddress[tokenAddress][actionId] = joinTokenAddress;
    }

    function JOIN_TOKEN_ADDRESS(address tokenAddress, uint256 actionId) external view returns (address) {
        return _joinTokenAddress[tokenAddress][actionId];
    }

    /// @dev Test device: `sinceRound = 0` marks an application that stands in every round.
    function setVerifierApplication(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 applicationId,
        uint256 sinceRound
    ) external {
        _applicationId[tokenAddress][actionId][memberId] = applicationId;
        _applicationSinceRound[tokenAddress][actionId][memberId] = sinceRound;
    }

    function setGroupIds(address tokenAddress, uint256 actionId, uint256 round, uint256[] calldata newGroupIds)
        external
    {
        _groupIds[tokenAddress][actionId][round] = newGroupIds;
    }

    function setGroupReward(address tokenAddress, uint256 actionId, uint256 round, uint256 groupId, uint256 reward)
        external
    {
        _groupReward[tokenAddress][actionId][round][groupId] = reward;
    }

    function setActionReward(address tokenAddress, uint256 actionId, uint256 round, uint256 reward) external {
        _actionReward[tokenAddress][actionId][round] = reward;
    }

    /// @dev Test device: makes every live reward read revert, so a caller that is supposed to answer
    ///      from its own cache is proven not to walk the ledger again.
    function setRewardReadsBlocked(bool blocked) external {
        _rewardReadsBlocked = blocked;
    }

    /// @dev Test device: blocks only the per-group slice read, so a divisor that walks groups reverts
    ///      while the action-level read keeps working.
    function setGroupSliceReadsBlocked(bool blocked) external {
        _groupSliceReadsBlocked = blocked;
    }

    function setLockedVerifierId(address tokenAddress, uint256 actionId, uint256 round, uint256 verifierId) external {
        _lockedVerifierId[tokenAddress][actionId][round] = verifierId;
    }

    function setTotalStaked(address tokenAddress, uint256 amount) external {
        _totalStaked[tokenAddress] = amount;
    }

    function setTotalStakedByMemberId(address tokenAddress, uint256 memberId, uint256 amount) external {
        _totalStakedByMemberId[tokenAddress][memberId] = amount;
    }

    function hasActiveGroups(address tokenAddress, uint256 memberId) external view returns (bool) {
        return _activeGroups[tokenAddress][memberId];
    }

    function verifierApplication(address tokenAddress, uint256 actionId, uint256 round, uint256 memberId)
        external
        view
        returns (VerifierApplication memory application)
    {
        uint256 applicationId = _applicationId[tokenAddress][actionId][memberId];
        if (round < _applicationSinceRound[tokenAddress][actionId][memberId]) {
            applicationId = 0;
        }
        application = VerifierApplication({
            applicationId: applicationId, verifierId: applicationId == 0 ? 0 : memberId, description: ""
        });
    }

    function groupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory page, uint256 total) {
        uint256[] storage ids = _groupIds[tokenAddress][actionId][round];
        total = ids.length;
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        uint256 remaining = total - offset;
        uint256 size = limit < remaining ? limit : remaining;
        page = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 index = reverse ? total - 1 - offset - i : offset + i;
            page[i] = ids[index];
        }
    }

    function generatedActionRewardByGroupId(address tokenAddress, uint256 actionId, uint256 round, uint256 groupId)
        external
        view
        returns (uint256)
    {
        require(!_rewardReadsBlocked && !_groupSliceReadsBlocked, "live group read");
        return _sliceReward(tokenAddress, actionId, round, groupId, _liveActionReward(tokenAddress, actionId, round));
    }

    function generatedActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256) {
        require(!_rewardReadsBlocked, "live reward read");
        return _liveActionReward(tokenAddress, actionId, round);
    }

    function _liveActionReward(address tokenAddress, uint256 actionId, uint256 round) private view returns (uint256) {
        uint256 pinned = _actionReward[tokenAddress][actionId][round];
        if (pinned != 0) {
            return pinned;
        }
        return _scoreTotal(tokenAddress, actionId, round);
    }

    function _scoreTotal(address tokenAddress, uint256 actionId, uint256 round) private view returns (uint256 total) {
        uint256[] storage ids = _groupIds[tokenAddress][actionId][round];
        for (uint256 i = 0; i < ids.length; i++) {
            total += _groupReward[tokenAddress][actionId][round][ids[i]];
        }
    }

    function _sliceReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 actionReward
    ) private view returns (uint256) {
        uint256 totalScore = _scoreTotal(tokenAddress, actionId, round);
        uint256 score = _groupReward[tokenAddress][actionId][round][groupId];
        if (totalScore == 0 || score == 0) {
            return 0;
        }
        return Math.mulDiv(actionReward, score, totalScore);
    }

    function lockedVerifierId(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return _lockedVerifierId[tokenAddress][actionId][round];
    }

    function totalStaked(address tokenAddress) external view returns (uint256) {
        return _totalStaked[tokenAddress];
    }

    function totalStakedByMemberId(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _totalStakedByMemberId[tokenAddress][memberId];
    }
}

/// @notice Service token mock: ERC20 surface plus the LOVE20 `burn` the executor
///         calls on the owner overflow. `burn` always burns the caller's balance,
///         matching `LOVE20Token.burn`.
contract MockGroupServiceToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TokenBurned(address indexed from, uint256 amount);

    uint256 internal _totalSupply;
    uint256 public burnedTotal;
    mapping(address => uint256) internal _balanceOf;

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        _balanceOf[msg.sender] -= amount;
        _totalSupply -= amount;
        burnedTotal += amount;
        emit TokenBurned(msg.sender, amount);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balanceOf[msg.sender] -= amount;
        _balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
