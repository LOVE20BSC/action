// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceExecutor} from "../src/GroupServiceExecutor.sol";
import {
    MockGroupServicePhase,
    MockGroupServiceMemberNFT,
    MockGroupServiceStake,
    MockGroupServiceLaunch,
    MockGroupServiceActionTarget,
    MockGroupServiceMint,
    MockGroupServiceGroupActionExecutor,
    MockGroupServiceToken
} from "./mocks/GroupServiceMocks.sol";

interface GroupServiceVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

/// @dev Executor-level suite: deploys the real GroupServiceExecutor with thin
///      mocks for the ActionTarget / Stake / GroupActionExecutor / Launch
///      periphery. The phase model follows the spec: the service action is
///      created at vote round R (SERVICE_ROUND), joins at R+1, configures
///      recipients at R+2 (verify round) and settles at R+3 (mint round), while
///      the served GroupAction round R has already been verified at R+2.
abstract contract GroupServiceTestBase {
    GroupServiceVm internal constant vm = GroupServiceVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant DEFAULT_MAX_RECIPIENTS = 10;

    uint256 internal constant CREATION_PHASE = 2;
    uint256 internal constant JOIN_PHASE = 3;
    uint256 internal constant VERIFY_PHASE = 4;
    uint256 internal constant MINT_PHASE = 5;
    /// @dev The round being settled: the service action's creation/vote round.
    uint256 internal constant SERVICE_ROUND = CREATION_PHASE;

    uint256 internal constant SERVICE_ACTION_ID = 31;
    uint256 internal constant SERVICE_ACTION_ID_B = 32;
    uint256 internal constant GROUP_ACTION_ID = 21;
    uint256 internal constant GROUP_ACTION_ID_B = 22;

    uint256 internal constant MEMBER1_ID = 1;
    uint256 internal constant MEMBER2_ID = 2;
    uint256 internal constant GROUP_ID = 5;
    uint256 internal constant VERIFIER_ID = 6;
    uint256 internal constant GROUP_OWNER_B_ID = 7;

    address internal constant MEMBER1 = address(0x1001);
    address internal constant MEMBER2 = address(0x1002);
    address internal constant GROUP_OWNER = address(0x1005);
    address internal constant VERIFIER = address(0x1006);
    address internal constant GROUP_OWNER_B = address(0x1007);

    uint256 internal constant GROUP_REWARD = 100e18;
    uint256 internal constant SERVICE_REWARD = 900e18;

    GroupServiceExecutor internal executor;
    MockGroupServicePhase internal phase;
    uint256 internal _currentPhase;
    MockGroupServiceMemberNFT internal memberNFT;
    MockGroupServiceStake internal stake;
    MockGroupServiceLaunch internal launch;
    MockGroupServiceActionTarget internal actionTarget;
    MockGroupServiceMint internal mint;
    MockGroupServiceGroupActionExecutor internal groupAction;
    MockGroupServiceToken internal token;
    MockGroupServiceToken internal childToken;
    MockGroupServiceToken internal grandChildToken;

    function setUp() public virtual {
        phase = new MockGroupServicePhase();
        memberNFT = new MockGroupServiceMemberNFT();
        stake = new MockGroupServiceStake();
        launch = new MockGroupServiceLaunch();
        actionTarget = new MockGroupServiceActionTarget();
        mint = new MockGroupServiceMint();
        groupAction = new MockGroupServiceGroupActionExecutor();
        token = new MockGroupServiceToken();
        childToken = new MockGroupServiceToken();
        grandChildToken = new MockGroupServiceToken();

        memberNFT.setOwner(MEMBER1_ID, MEMBER1);
        memberNFT.setOwner(MEMBER2_ID, MEMBER2);
        memberNFT.setOwner(GROUP_ID, GROUP_OWNER);
        memberNFT.setOwner(VERIFIER_ID, VERIFIER);
        memberNFT.setOwner(GROUP_OWNER_B_ID, GROUP_OWNER_B);

        stake.setMemberNFTAddress(address(memberNFT));
        stake.setPhaseAddress(address(phase));
        stake.setLaunchAddress(address(launch));
        actionTarget.setPhaseAddress(address(phase));
        actionTarget.setMintAddress(address(mint));

        launch.setParentToken(address(childToken), address(token));
        launch.setParentToken(address(grandChildToken), address(childToken));

        // The source GroupAction actions exist in the mock's eyes; `setRecipients` now refuses
        // configurations keyed to actions this executor never created.
        groupAction.setJoinTokenAddress(address(token), GROUP_ACTION_ID, address(token));
        groupAction.setJoinTokenAddress(address(token), GROUP_ACTION_ID_B, address(token));
        groupAction.setJoinTokenAddress(address(childToken), GROUP_ACTION_ID, address(childToken));

        executor = _deployExecutor();
        _atPhase(CREATION_PHASE);
    }

    function _deployExecutor() internal returns (GroupServiceExecutor) {
        GroupServiceExecutor deployed = new GroupServiceExecutor();
        deployed.init(address(actionTarget), address(stake), address(groupAction));
        return deployed;
    }


    function _atPhase(uint256 currentPhase) internal {
        _currentPhase = currentPhase;
        phase.setCurrentPhase(currentPhase);
    }

    function _memberAddress(uint256 memberId) internal pure returns (address) {
        if (memberId == MEMBER1_ID) return MEMBER1;
        if (memberId == MEMBER2_ID) return MEMBER2;
        if (memberId == GROUP_ID) return GROUP_OWNER;
        if (memberId == VERIFIER_ID) return VERIFIER;
        if (memberId == GROUP_OWNER_B_ID) return GROUP_OWNER_B;
        revert("unknown member");
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ratios(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _ratios(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ratios(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _serviceTargetData(address actionTokenAddress, uint256 govRatioMultiplier, uint256 ratioForPublicVerifier)
        internal
        view
        returns (bytes[] memory targetData)
    {
        targetData = new bytes[](4);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(actionTokenAddress);
        targetData[2] = abi.encode(govRatioMultiplier);
        targetData[3] = abi.encode(ratioForPublicVerifier);
    }

    /// @dev Creates the service proposal through the ActionTarget callback. The
    ///      executor itself records `createdRound = currentPhase`, matching the
    ///      real creation flow; the mock additionally keeps the creation round
    ///      for its `JoinNotOpen` replication.
    function _createServiceActionOn(
        address serviceTokenAddress,
        address actionTokenAddress,
        uint256 actionId,
        uint256 govRatioMultiplier,
        uint256 ratioForPublicVerifier
    ) internal {
        vm.prank(address(actionTarget));
        executor.onProposalCreated(
            serviceTokenAddress,
            actionId,
            _serviceTargetData(actionTokenAddress, govRatioMultiplier, ratioForPublicVerifier)
        );
        actionTarget.setCreatedRound(serviceTokenAddress, actionId, _currentPhase);
    }

    function _createServiceAction(uint256 actionId, uint256 govRatioMultiplier, uint256 ratioForPublicVerifier)
        internal
    {
        _createServiceActionOn(address(token), address(token), actionId, govRatioMultiplier, ratioForPublicVerifier);
    }

    function _joinService(uint256 memberId) internal {
        _joinServiceOn(SERVICE_ACTION_ID, memberId);
    }

    function _joinServiceOn(uint256 actionId, uint256 memberId) internal {
        vm.prank(_memberAddress(memberId));
        executor.join(address(token), actionId, memberId);
    }

    function _exitService(uint256 memberId) internal {
        vm.prank(_memberAddress(memberId));
        executor.exit(address(token), SERVICE_ACTION_ID, memberId);
    }

    function _qualifyGroupOwner(uint256 memberId) internal {
        groupAction.setHasActiveGroups(address(token), memberId, true);
    }

    function _qualifyCandidate(uint256 memberId) internal {
        groupAction.setVerifierApplication(address(token), GROUP_ACTION_ID, memberId, 1, 0);
    }

    function _setVotedGroupActions(uint256[] memory actionIds) internal {
        address[] memory executors = new address[](actionIds.length);
        for (uint256 i = 0; i < actionIds.length; i++) {
            executors[i] = address(groupAction);
        }
        actionTarget.setVotedActions(address(token), SERVICE_ROUND, actionIds, executors);
    }

    function _setGroupLedger(uint256 actionId, uint256[] memory groupIds, uint256[] memory rewards, uint256 verifierId)
        internal
    {
        groupAction.setGroupIds(address(token), actionId, SERVICE_ROUND, groupIds);
        for (uint256 i = 0; i < groupIds.length; i++) {
            groupAction.setGroupReward(address(token), actionId, SERVICE_ROUND, groupIds[i], rewards[i]);
        }
        groupAction.setLockedVerifierId(address(token), actionId, SERVICE_ROUND, verifierId);
    }

    /// @dev Funds the executor with the service reward the way ActionTarget's
    ///      mint transfer does, and programs the mock to pay it out once.
    function _armServiceReward(uint256 amount) internal {
        _armServiceRewardOn(SERVICE_ACTION_ID, amount);
    }

    function _armServiceRewardOn(uint256 actionId, uint256 amount) internal {
        actionTarget.setActionReward(address(token), actionId, SERVICE_ROUND, amount, false);
        actionTarget.setMintReturnAmount(amount);
        token.mint(address(executor), amount);
    }

    function _settleService(uint256 memberId) internal returns (uint256 mintAmount, uint256 burnAmount) {
        return _settleServiceOn(SERVICE_ACTION_ID, memberId);
    }

    function _settleServiceOn(uint256 actionId, uint256 memberId)
        internal
        returns (uint256 mintAmount, uint256 burnAmount)
    {
        vm.prank(_memberAddress(memberId));
        return executor.mintMemberReward(address(token), actionId, memberId, SERVICE_ROUND);
    }

    function _setRecipients(
        uint256 groupId,
        uint256 sourceActionId,
        uint256[] memory recipientIds,
        uint256[] memory ratios
    ) internal {
        string[] memory remarks = new string[](recipientIds.length);
        for (uint256 i = 0; i < recipientIds.length; i++) {
            remarks[i] = "";
        }
        vm.prank(_memberAddress(groupId));
        executor.setRecipients(address(token), sourceActionId, groupId, recipientIds, ratios, remarks);
    }

    /// @dev The standard scenario: one community group action with a single
    ///      group, owner and public verifier both joined through their own
    ///      qualification branch, cap off, half of the service reward reserved
    ///      for public verifiers. Ends at the mint phase.
    function _standardScenario() internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        // The community action set exists before the joins: the candidate
        // qualification reads it inside the join.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);
    }
}
