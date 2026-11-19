// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";

import {IPhase} from "@core/interfaces/IPhase.sol";

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
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    address public memberNFTAddress;
    address public phaseAddress;
    address public launchAddress;

    // tokenAddress => total valid gov votes
    mapping(address => RoundHistoryUint256.History) internal _totalGovVotes;
    // tokenAddress => memberId => valid gov votes
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _govVotes;

    function setMemberNFTAddress(address memberNFTAddress_) external {
        memberNFTAddress = memberNFTAddress_;
    }

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setLaunchAddress(address launchAddress_) external {
        launchAddress = launchAddress_;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }

    function LAUNCH_ADDRESS() external view returns (address) {
        return launchAddress;
    }

    function setTotalGovVotes(address tokenAddress, uint256 votes) external {
        _totalGovVotes[tokenAddress].record(IPhase(phaseAddress).currentPhase(), votes);
    }

    function setGovVotes(address tokenAddress, uint256 memberId, uint256 votes) external {
        _govVotes[tokenAddress][memberId].record(IPhase(phaseAddress).currentPhase(), votes);
    }

    function setTotalGovVotes(address tokenAddress, uint256 round, uint256 votes) external {
        _totalGovVotes[tokenAddress].record(round, votes);
    }

    function setGovVotes(address tokenAddress, uint256 round, uint256 memberId, uint256 votes) external {
        _govVotes[tokenAddress][memberId].record(round, votes);
    }

    function totalGovVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        return _totalGovVotes[tokenAddress].value(round);
    }

    function govVotes(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256) {
        return _govVotes[tokenAddress][memberId].value(round);
    }
}

/// @notice Launch mock: only the direct-parent relation is programmable.
contract MockGroupServiceLaunch {
    mapping(address => address) internal _parentTokenByTokenAddress;

    function setParentToken(address tokenAddress, address parentTokenAddress) external {
        _parentTokenByTokenAddress[tokenAddress] = parentTokenAddress;
    }

    function parentToken(address tokenAddress) external view returns (address) {
        return _parentTokenByTokenAddress[tokenAddress];
    }
}

/// @notice ActionTarget mock. Replicates the behaviors GroupService leans on: the
///         join round is `currentPhase - 1` with a `JoinNotOpen` window
///         (`currentRound > createdRound`), round snapshots keep history —
///         clearing only removes the current join round, never past rounds.
contract MockGroupServiceActionTarget {
    error JoinNotOpen(
        address tokenAddress,
        uint256 actionId,
        uint256 currentRound,
        uint256 createdRound
    );

    address public PHASE_ADDRESS;
    address public MINT_ADDRESS;
    address public VOTE_ADDRESS;

    // tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRound;
    // tokenAddress => actionId => memberId => currently joined
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _joined;
    // tokenAddress => actionId => memberId => round => joined as of that round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) internal _joinedByRound;
    // key => recorded rounds (ascending), key = keccak256(token, actionId, memberId)
    mapping(bytes32 => uint256[]) internal _recordedRounds;

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

    function setPhaseAddress(address phaseAddress) external {
        PHASE_ADDRESS = phaseAddress;
    }

    function setMintAddress(address mintAddress) external {
        MINT_ADDRESS = mintAddress;
    }

    function setVoteAddress(address voteAddress) external {
        VOTE_ADDRESS = voteAddress;
    }

    function setBoundExecutor(address tokenAddress, uint256 actionId, address executor_) external {
        _executorByActionId[tokenAddress][actionId] = executor_;
    }

    function setCreatedRound(address tokenAddress, uint256 actionId, uint256 createdRound) external {
        _createdRound[tokenAddress][actionId] = createdRound;
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
        uint256 currentRound = MockGroupServicePhase(PHASE_ADDRESS).currentPhase();
        uint256 createdRound = _createdRound[tokenAddress][actionId];
        if (currentRound <= createdRound) {
            revert JoinNotOpen(tokenAddress, actionId, currentRound, createdRound);
        }
        _recordMembership(tokenAddress, actionId, currentRound - 1, memberId, true);
    }

    function clearJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        _recordMembership(tokenAddress, actionId, _joinRound(), memberId, false);
    }

    function isJoined(address tokenAddress, uint256 actionId, uint256 memberId) external view returns (bool) {
        return _joined[tokenAddress][actionId][memberId];
    }

    function isJoinedByRound(address tokenAddress, uint256 actionId, uint256 round, uint256 memberId)
        external
        view
        returns (bool)
    {
        if (round > _joinRound()) {
            return false;
        }
        return _containsByRound(tokenAddress, actionId, round, memberId);
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

    function votedActionIdsByExecutors(
        address,
        uint256,
        address[] calldata
    ) external pure returns (uint256[] memory, address[] memory) {
        revert("unexpected round action scan");
    }

    function _joinRound() internal view returns (uint256) {
        uint256 currentRound = MockGroupServicePhase(PHASE_ADDRESS).currentPhase();
        return currentRound == 0 ? 0 : currentRound - 1;
    }

    function _recordMembership(address tokenAddress, uint256 actionId, uint256 round, uint256 memberId, bool present)
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

    function _containsByRound(address tokenAddress, uint256 actionId, uint256 round, uint256 memberId)
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
    using Uint256Set for Uint256Set.Storage;

    struct VerifiedAction {
        uint256 reward;
        uint256 totalScore;
        uint256 verifierId;
        uint256[] groupIds;
        mapping(uint256 => uint256) scoreByGroupId;
    }

    address public ACTION_TARGET_ADDRESS;

    // tokenAddress => memberId => the member owns an active group
    mapping(address => mapping(uint256 => bool)) internal _activeGroups;
    // first round in which the application stands
    mapping(address => mapping(uint256 => uint256)) internal _applicationSinceRound;
    mapping(address => mapping(uint256 => mapping(uint256 => VerifiedAction))) internal _verifiedAction;
    mapping(address => mapping(uint256 => uint256)) internal _roundReward;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _verifierWeight;
    mapping(address => mapping(uint256 => mapping(uint256 => Uint256Set.Storage))) internal _joinedActions;
    mapping(address => mapping(uint256 => Uint256Set.Storage)) internal _generatedActions;
    bool internal _groupSliceReadsBlocked;
    // tokenAddress => total staked
    mapping(address => mapping(uint256 => uint256)) internal _totalStaked;
    // tokenAddress => memberId => total staked
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _stakedByMemberId;

    // tokenAddress => actionId => join token address (zero = action never created)
    mapping(address => mapping(uint256 => address)) internal _joinTokenAddress;

    function setHasActiveGroups(address tokenAddress, uint256 memberId, bool active) external {
        _activeGroups[tokenAddress][memberId] = active;
    }

    function setActionTargetAddress(address actionTargetAddress) external {
        ACTION_TARGET_ADDRESS = actionTargetAddress;
    }

    function setJoinTokenAddress(address tokenAddress, uint256 actionId, address joinTokenAddressValue) external {
        _joinTokenAddress[tokenAddress][actionId] = joinTokenAddressValue;
    }

    function joinTokenAddress(address tokenAddress, uint256 actionId) external view returns (address) {
        return _joinTokenAddress[tokenAddress][actionId];
    }

    function setVerifierApplication(
        address tokenAddress,
        uint256 verifierId,
        uint256 sinceRound
    ) external {
        _applicationSinceRound[tokenAddress][verifierId] = sinceRound;
    }

    function setGroupLedger(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256[] calldata groupIds,
        uint256[] calldata scores,
        uint256 verifierId
    ) external {
        VerifiedAction storage action = _verifiedAction[tokenAddress][actionId][round];
        for (uint256 i = 0; i < action.groupIds.length; i++) {
            uint256 groupId = action.groupIds[i];
            delete action.scoreByGroupId[groupId];
            _joinedActions[tokenAddress][round][groupId].remove(actionId);
        }
        action.groupIds = groupIds;
        uint256 totalScore;
        for (uint256 i = 0; i < groupIds.length; i++) {
            uint256 groupId = groupIds[i];
            _joinedActions[tokenAddress][round][groupId].add(actionId);
            action.scoreByGroupId[groupId] = scores[i];
            totalScore += scores[i];
        }
        action.totalScore = totalScore;
        _setActionReward(action, tokenAddress, actionId, round, totalScore, verifierId);
    }

    function setActionReward(address tokenAddress, uint256 actionId, uint256 round, uint256 reward) external {
        VerifiedAction storage action = _verifiedAction[tokenAddress][actionId][round];
        _setActionReward(action, tokenAddress, actionId, round, reward, action.verifierId);
    }

    function _setActionReward(
        VerifiedAction storage action,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 reward,
        uint256 verifierId
    ) private {
        _roundReward[tokenAddress][round] = _roundReward[tokenAddress][round] - action.reward + reward;
        _verifierWeight[tokenAddress][round][action.verifierId] -= action.reward;
        _verifierWeight[tokenAddress][round][verifierId] += reward;
        action.reward = reward;
        action.verifierId = verifierId;
        if (reward != 0) {
            _generatedActions[tokenAddress][round].add(actionId);
        } else {
            _generatedActions[tokenAddress][round].remove(actionId);
        }
    }

    function setGroupSliceReadsBlocked(bool blocked) external {
        _groupSliceReadsBlocked = blocked;
    }

    function setTotalStaked(address tokenAddress, uint256 round, uint256 amount) external {
        _totalStaked[tokenAddress][round] = amount;
    }

    function setStakedByMemberId(address tokenAddress, uint256 round, uint256 memberId, uint256 amount) external {
        _stakedByMemberId[tokenAddress][round][memberId] = amount;
    }

    function hasActiveGroups(address tokenAddress, uint256 memberId) external view returns (bool) {
        return _activeGroups[tokenAddress][memberId];
    }

    function hasVerifierApplicationByRound(address tokenAddress, uint256 round, uint256 verifierId)
        external view returns (bool)
    {
        uint256 sinceRound = _applicationSinceRound[tokenAddress][verifierId];
        return sinceRound != 0 && round >= sinceRound;
    }

    function generatedActionRewardByGroupId(address tokenAddress, uint256 actionId, uint256 round, uint256 groupId)
        public
        view
        returns (uint256)
    {
        require(!_groupSliceReadsBlocked, "unexpected group slice read");
        VerifiedAction storage action = _verifiedAction[tokenAddress][actionId][round];
        uint256 score = action.scoreByGroupId[groupId];
        return score == 0 ? 0 : Math.mulDiv(action.reward, score, action.totalScore);
    }

    function totalGeneratedActionRewardByGroupId(address tokenAddress, uint256 round, uint256 groupId)
        external
        view
        returns (uint256 weight)
    {
        if (_joinedActions[tokenAddress][round][groupId].count() == 0) return 0;
        (uint256[] memory actionIds,) = _generatedActions[tokenAddress][round].values(0, type(uint256).max, false);
        for (uint256 i = 0; i < actionIds.length; ++i) {
            weight += generatedActionRewardByGroupId(tokenAddress, actionIds[i], round, groupId);
        }
    }

    function totalGeneratedActionReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256) {
        return _roundReward[tokenAddress][round];
    }

    function verifierRewardWeight(address tokenAddress, uint256 round, uint256 verifierId)
        external view returns (uint256)
    {
        return _verifierWeight[tokenAddress][round][verifierId];
    }

    function totalActivationStakeByRound(address tokenAddress, uint256 round) external view returns (uint256) {
        return _totalStaked[tokenAddress][round];
    }

    function activationStakeByGroupIdByRound(address tokenAddress, uint256 round, uint256 groupId) external view returns (uint256) {
        return _stakedByMemberId[tokenAddress][round][groupId];
    }
}

/// @notice Service token mock: ERC20 surface plus the LOVE20 `burn` the executor
///         calls on the owner overflow. `burn` always burns the caller's balance,
///         matching `LOVE20Token.burn`.
contract MockGroupServiceToken {
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );
    event TokenBurned(
        address indexed from,
        uint256 amount
    );

    uint256 internal _totalSupply;
    uint256 public burnedTotal;
    mapping(address => uint256) internal _balanceOf;

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balanceOf[to] += amount;
        emit Transfer({
            from: address(0),
            to: to,
            value: amount
        });
    }

    function burn(uint256 amount) external {
        _balanceOf[msg.sender] -= amount;
        _totalSupply -= amount;
        burnedTotal += amount;
        emit TokenBurned({
            from: msg.sender,
            amount: amount
        });
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
        emit Transfer({
            from: msg.sender,
            to: to,
            value: amount
        });
        return true;
    }
}
