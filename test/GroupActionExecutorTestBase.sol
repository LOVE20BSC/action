// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutor} from "../src/GroupActionExecutor.sol";
import {GroupConfig} from "../src/interfaces/IGroupActionManager.sol";
import {
    MockGroupActionExecutorActionTarget,
    MockGroupActionExecutorStake,
    MockGroupActionToken,
    MockGroupActionVote
} from "./mocks/GroupActionExecutorMocks.sol";
import {MockGroupActionMemberNFT, MockGroupActionPhase} from "./mocks/GroupActionMocks.sol";

interface GroupActionExecutorVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function roll(uint256 blockNumber) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

/// @dev Executor-level suite: deploys the real Executor with thin mocks for the
///      Stake/Vote/ActionTarget periphery, drives the full round chain
///      (create -> apply/vote -> activate -> join -> verify -> settle) through
///      the real entry points and asserts the settle split against finalScore.
abstract contract GroupActionExecutorTestBase {
    GroupActionExecutorVm internal constant vm =
        GroupActionExecutorVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant ACTION_ID = 21;
    uint256 internal constant GROUP_ID = 5;
    uint256 internal constant GROUP_B_ID = 7;
    uint256 internal constant CREATION_PHASE = 2;
    uint256 internal constant PHASE_BLOCKS = 1000;
    uint256 internal constant PROPOSAL_REWARD = 1000e18;
    uint256 internal constant ACTIVATION_STAKE = 100e18;
    uint256 internal constant PROVIDER_QUOTA = 150e18;

    uint256 internal constant MEMBER1_ID = 1;
    uint256 internal constant MEMBER2_ID = 2;
    uint256 internal constant PROVIDER_ID = 4;
    uint256 internal constant GROUP_OWNER_ID = 5;
    uint256 internal constant VERIFIER_ID = 6;

    address internal constant MEMBER1 = address(0x1001);
    address internal constant MEMBER2 = address(0x1002);
    address internal constant PROVIDER = address(0x1004);
    address internal constant GROUP_OWNER = address(0x1005);
    address internal constant VERIFIER = address(0x1006);

    GroupActionExecutor internal executor;
    MockGroupActionPhase internal phase;
    MockGroupActionExecutorStake internal stake;
    MockGroupActionMemberNFT internal memberNFT;
    MockGroupActionVote internal vote;
    MockGroupActionExecutorActionTarget internal actionTarget;
    MockGroupActionToken internal token;
    MockGroupActionToken internal joinToken;

    function setUp() public virtual {
        _deployMocks();
        executor = new GroupActionExecutor();
        uint256[] memory splits = new uint256[](1);
        splits[0] = 5e17;
        executor.init(address(actionTarget), address(stake), splits);
        _configurePhase();
        _createAction(ACTION_ID);
    }

    function _deployMocks() internal {
        phase = new MockGroupActionPhase();
        stake = new MockGroupActionExecutorStake();
        memberNFT = new MockGroupActionMemberNFT();
        vote = new MockGroupActionVote();
        actionTarget = new MockGroupActionExecutorActionTarget();
        token = new MockGroupActionToken();
        joinToken = new MockGroupActionToken();

        memberNFT.setOwner(MEMBER1_ID, MEMBER1);
        memberNFT.setOwner(MEMBER2_ID, MEMBER2);
        memberNFT.setOwner(PROVIDER_ID, PROVIDER);
        memberNFT.setOwner(GROUP_OWNER_ID, GROUP_OWNER);
        memberNFT.setOwner(VERIFIER_ID, VERIFIER);

        stake.setMemberNFTAddress(address(memberNFT));
        stake.setPhaseAddress(address(phase));
        stake.setVoteAddress(address(vote));
        stake.setGlobalGovVotes(address(token), 1000e18);
        stake.setValidGovVotes(address(token), MEMBER1_ID, 100e18);
        stake.setValidGovVotes(address(token), VERIFIER_ID, 100e18);

        vote.setVotesNum(address(token), CREATION_PHASE, 1000e18);
        vote.setVotesNumByProposalId(address(token), CREATION_PHASE, ACTION_ID, 1000e18);
    }

    function _configurePhase() internal {
        for (uint256 i = 1; i <= 12; i++) {
            phase.setPhaseInfo(i, i * PHASE_BLOCKS, PHASE_BLOCKS);
        }
        phase.setCurrentPhase(CREATION_PHASE);
        vm.roll(CREATION_PHASE * PHASE_BLOCKS);
    }

    function _atPhase(uint256 currentPhase) internal {
        phase.setCurrentPhase(currentPhase);
        vm.roll(currentPhase * PHASE_BLOCKS);
    }

    function _targetData() internal view returns (bytes[] memory targetData) {
        return _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0);
    }

    function _targetDataWith(address joinTokenAddress, uint256 stakeAmount, uint256 ratio, uint256 minGovRatio)
        internal
        view
        returns (bytes[] memory targetData)
    {
        targetData = new bytes[](5);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(joinTokenAddress);
        targetData[2] = abi.encode(stakeAmount);
        targetData[3] = abi.encode(ratio);
        targetData[4] = abi.encode(minGovRatio);
    }

    function _createAction(uint256 actionId) internal {
        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), actionId, _targetData());
    }

    function _createActionWith(uint256 actionId, bytes[] memory targetData) internal {
        _createActionOn(address(token), actionId, targetData);
    }

    function _createActionOn(address tokenAddress, uint256 actionId, bytes[] memory targetData) internal {
        vm.prank(address(actionTarget));
        executor.onProposalCreated(tokenAddress, actionId, targetData);
    }

    function _clone(bytes[] memory data) internal pure returns (bytes[] memory copy) {
        copy = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            copy[i] = data[i];
        }
    }

    function _submitApplication() internal {
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "verifier");
    }

    function _castCandidateVotes() internal {
        _castVotesFor(VERIFIER_ID, 100e18);
    }

    function _castVotesFor(uint256 candidateMemberId, uint256 votes) internal {
        bytes[] memory targetData = new bytes[](2);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(candidateMemberId);
        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), CREATION_PHASE, ACTION_ID, 0, votes, targetData);
    }

    function _activateGroup() internal {
        _activateGroupWith(GROUP_ID, _defaultConfig());
    }

    function _activateGroupWith(uint256 groupId, GroupConfig memory config) internal {
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_ID, groupId, config);
    }

    function _defaultConfig() internal pure returns (GroupConfig memory) {
        return GroupConfig({description: "group", maxCapacity: 0, minJoinAmount: 1e18, maxJoinAmount: 0, maxAccounts: 0});
    }

    function _deactivateGroup(uint256 groupId) internal {
        vm.prank(GROUP_OWNER);
        executor.deactivateGroup(address(token), ACTION_ID, groupId);
    }

    function _activateGroupOn(address tokenAddress, uint256 actionId, uint256 groupId) internal {
        vm.prank(GROUP_OWNER);
        executor.activateGroup(tokenAddress, actionId, groupId, _defaultConfig());
    }

    function _joinOn(address tokenAddress, uint256 actionId, uint256 groupId, uint256 memberId, uint256 amount)
        internal
    {
        vm.prank(_memberAddress(memberId));
        executor.join(tokenAddress, actionId, groupId, memberId, amount, 0, new string[](0));
    }

    function _exitOn(address tokenAddress, uint256 actionId, uint256 memberId) internal {
        vm.prank(_memberAddress(memberId));
        executor.exit(tokenAddress, actionId, memberId);
    }

    function _fundTokenFor(address account, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(executor), type(uint256).max);
    }

    function _fundJoinTokenFor(address account, uint256 amount) internal {
        joinToken.mint(account, amount);
        vm.prank(account);
        joinToken.approve(address(executor), type(uint256).max);
    }

    function _grantQuota(uint256 providerId, uint256 memberId, uint256 amount) internal {
        uint256[] memory memberIds = new uint256[](1);
        memberIds[0] = memberId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(_memberAddress(providerId));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, providerId, memberIds, amounts);
    }

    function _join(uint256 memberId, uint256 amount, uint256 providerId) internal {
        _joinAt(GROUP_ID, memberId, amount, providerId);
    }

    function _joinAt(uint256 groupId, uint256 memberId, uint256 amount, uint256 providerId) internal {
        vm.prank(_memberAddress(memberId));
        executor.join(address(token), ACTION_ID, groupId, memberId, amount, providerId, new string[](0));
    }

    function _withdraw(uint256 memberId, uint256 amount) internal {
        vm.prank(_memberAddress(memberId));
        executor.withdraw(address(token), ACTION_ID, memberId, amount);
    }

    function _exit(uint256 memberId) internal {
        vm.prank(_memberAddress(memberId));
        executor.exit(address(token), ACTION_ID, memberId);
    }

    function _quotaRemove(uint256 providerId, uint256 memberId) internal {
        vm.prank(_memberAddress(providerId));
        executor.providerQuotaRemove(address(token), ACTION_ID, GROUP_ID, providerId, _ids(memberId));
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _submitScores(uint256[] memory scores) internal {
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, scores);
    }

    function _settle(uint256 memberId, uint256 round) internal returns (uint256 mintAmount, uint256 burnAmount) {
        vm.prank(_memberAddress(memberId));
        return executor.mintMemberReward(address(token), ACTION_ID, memberId, round);
    }

    function _fundExecutor(uint256 amount) internal {
        token.mint(address(executor), amount);
    }

    /// @dev Drives creation-phase voting plus the join phase up to two members
    ///      (one own-amount join, one provider-quota join); ends at phase 3.
    function _prepareRound() internal {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _fundJoinTokenFor(PROVIDER, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, PROVIDER_QUOTA);
        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, PROVIDER_QUOTA, PROVIDER_ID);
    }

    /// @dev Creation-phase application and votes, then the join phase with the
    ///      group active; ends at phase 3.
    function _openJoinPhase() internal {
        _submitApplication();
        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();
    }

    function _memberAddress(uint256 memberId) internal pure returns (address) {
        if (memberId == MEMBER1_ID) return MEMBER1;
        if (memberId == MEMBER2_ID) return MEMBER2;
        if (memberId == PROVIDER_ID) return PROVIDER;
        if (memberId == GROUP_OWNER_ID) return GROUP_OWNER;
        return VERIFIER;
    }
}
