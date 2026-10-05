// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../src/ActionTarget.sol";
import {IActionTargetErrors} from "../src/interfaces/IActionTarget.sol";
import {MockExecutor, MockMint} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract ActionTargetTest is ActionTargetTestBase {
    function _joinNotOpenData(uint256 actionId, uint256 currentRound, uint256 createdRound)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IActionTargetErrors.JoinNotOpen.selector, address(token), actionId, currentRound, createdRound
        );
    }

    function _unauthorizedExecutorData(uint256 actionId) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IActionTargetErrors.UnauthorizedExecutor.selector, address(token), actionId);
    }

    function testInitBindsDependenciesAndDerivesPhase() external view {
        require(actionTarget.initialized(), "initialized");
        require(actionTarget.memberNFTAddress() == address(memberNFT), "memberNFT bound");
        require(actionTarget.submitAddress() == submitAddress, "submit bound");
        require(actionTarget.voteAddress() == address(vote), "vote bound");
        require(actionTarget.mintAddress() == address(mint), "mint bound");
        require(actionTarget.phaseAddress() == address(phase), "phase derived from vote");
    }

    function testInitIsPermissionless() external {
        ActionTarget fresh = new ActionTarget();
        vm.prank(OUTSIDER);
        fresh.init(address(memberNFT), SUBMIT_ADDRESS, address(vote), address(mint));
        require(fresh.initialized(), "outsider init succeeds");
        require(fresh.phaseAddress() == address(phase), "phase derived");
    }

    function testInitRejectsSecondCall() external {
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.AlreadyInitialized.selector));
        actionTarget.init(address(memberNFT), SUBMIT_ADDRESS, address(vote), address(mint));
        require(actionTarget.memberNFTAddress() == address(memberNFT), "state unchanged");
    }

    function testInitRejectsZeroDependencyAddresses() external {
        ActionTarget fresh = new ActionTarget();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidAddress.selector));
        fresh.init(address(0), SUBMIT_ADDRESS, address(vote), address(mint));

        fresh = new ActionTarget();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidAddress.selector));
        fresh.init(address(memberNFT), address(0), address(vote), address(mint));

        fresh = new ActionTarget();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidAddress.selector));
        fresh.init(address(memberNFT), SUBMIT_ADDRESS, address(0), address(mint));

        fresh = new ActionTarget();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidAddress.selector));
        fresh.init(address(memberNFT), SUBMIT_ADDRESS, address(vote), address(0));
    }

    function testInitRejectsVoteWithoutPhase() external {
        vote.setPhaseAddress(address(0));
        ActionTarget fresh = new ActionTarget();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidAddress.selector));
        fresh.init(address(memberNFT), SUBMIT_ADDRESS, address(vote), address(mint));
    }

    function testCreateBindsExecutorAndIndexes() external {
        _createAction(11);
        require(actionTarget.executor(address(token), 11) == address(executor), "executor bound");
        (uint256[] memory actionIds,, uint256 total) = actionTarget.actions(address(token), 0, 10, false);
        require(total == 1 && actionIds.length == 1 && actionIds[0] == 11, "actions index");
        (uint256[] memory byExecutor, uint256 executorTotal) =
            actionTarget.actionIdsByExecutor(address(token), address(executor), 0, 10, false);
        require(executorTotal == 1 && byExecutor.length == 1 && byExecutor[0] == 11, "executor index");
        require(executor.createdCalls() == 1, "executor notified");
        require(
            executor.lastCreatedTargetDataHash() == keccak256(abi.encode(_targetData(address(executor)))),
            "full target data forwarded"
        );
    }

    function testCreateForwardsFullTargetData() external {
        bytes[] memory targetData = _targetDataWithBusiness(address(executor), 777);
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(token), 12, targetData);
        require(executor.lastCreatedTargetDataHash() == keccak256(abi.encode(targetData)), "business items forwarded");
        require(actionTarget.executor(address(token), 12) == address(executor), "bound");
    }

    function testCreateRejectsNonSubmitCaller() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.UnauthorizedCallback.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(executor)));
    }

    function testCreateRejectsInvalidExecutor() external {
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, new bytes[](0));

        bytes[] memory malformed = new bytes[](1);
        malformed[0] = new bytes(31);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, malformed);

        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(0)));

        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(0xdead)));
    }

    function testCreateRejectsExecutorWithoutSelfAcknowledgment() external {
        MockExecutor mismatched = new MockExecutor(OUTSIDER);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(mismatched)));

        executor.setRevertActionTarget(true);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(executor)));
    }

    function testCreateRejectsDuplicateBinding() external {
        MockExecutor second = new MockExecutor(address(actionTarget));
        _createAction(11);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.AlreadyCreated.selector, address(token), 11));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(second)));
        require(actionTarget.executor(address(token), 11) == address(executor), "first binding retained");
        (uint256[] memory actionIds,, uint256 total) = actionTarget.actions(address(token), 0, 10, false);
        require(total == 1 && actionIds.length == 1, "index not duplicated");
        (uint256[] memory secondIds, uint256 secondTotal) =
            actionTarget.actionIdsByExecutor(address(token), address(second), 0, 10, false);
        require(secondTotal == 0 && secondIds.length == 0, "second executor index untouched");
    }

    function testCreateCallbackRevertRollsBackBinding() external {
        executor.setRevertCreated(true);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.CreatedCallbackReverted.selector));
        actionTarget.onProposalCreated(address(token), 11, _targetData(address(executor)));
        require(actionTarget.executor(address(token), 11) == address(0), "binding rolled back");
        (uint256[] memory actionIds,, uint256 total) = actionTarget.actions(address(token), 0, 0, false);
        require(total == 0 && actionIds.length == 0, "index rolled back");
    }

    function testSubmittedForwardsContext() external {
        _createAction(11);
        bytes[] memory targetData = _targetDataWithBusiness(address(executor), 7);
        vm.prank(submitAddress);
        actionTarget.onProposalSubmitted(address(token), 11, 7, targetData);
        require(executor.submittedCalls() == 1, "executor notified");
        require(executor.lastCallbackTokenAddress() == address(token), "token forwarded");
        require(executor.lastSubmittedProposalId() == 11, "proposalId forwarded");
        require(executor.lastSubmittedSubmitterId() == 7, "submitterId forwarded");
        require(executor.lastSubmittedTargetDataHash() == keccak256(abi.encode(targetData)), "target data forwarded");
    }

    function testSubmittedRejectsNonSubmitCaller() external {
        _createAction(11);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.UnauthorizedCallback.selector));
        actionTarget.onProposalSubmitted(address(token), 11, 7, _targetData(address(executor)));
    }

    function testSubmittedRejectsUnboundProposal() external {
        bytes[] memory targetData = _targetData(address(executor));
        vm.prank(submitAddress);
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.UnboundProposal.selector, address(token), 99)
        );
        actionTarget.onProposalSubmitted(address(token), 99, 7, targetData);
    }

    function testSubmittedRejectsMismatchedTargetData() external {
        _createAction(11);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalSubmitted(address(token), 11, 7, new bytes[](0));

        bytes[] memory malformed = new bytes[](1);
        malformed[0] = new bytes(33);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalSubmitted(address(token), 11, 7, malformed);

        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalSubmitted(address(token), 11, 7, _targetData(OUTSIDER));
    }

    function testSubmittedCallbackRevertBubbles() external {
        _createAction(11);
        executor.setRevertSubmitted(true);
        vm.prank(submitAddress);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.SubmittedCallbackReverted.selector));
        actionTarget.onProposalSubmitted(address(token), 11, 7, _targetData(address(executor)));
    }

    function testVotedForwardsContextWithEmptyData() external {
        _createAction(11);
        vm.prank(voteAddress);
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, new bytes[](0));
        require(executor.votedCalls() == 1, "executor notified");
        require(executor.lastCallbackTokenAddress() == address(token), "token forwarded");
        require(executor.lastVotedRound() == 3, "round forwarded");
        require(executor.lastVotedProposalId() == 11, "proposalId forwarded");
        require(executor.lastVotedVoterId() == 5, "voterId forwarded");
        require(executor.lastVotedVotes() == 250, "votes forwarded");
        require(
            executor.lastVotedTargetDataHash() == keccak256(abi.encode(new bytes[](0))), "empty data forwarded"
        );
    }

    function testVotedForwardsBusinessTargetData() external {
        _createAction(11);
        bytes[] memory targetData = new bytes[](2);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(uint256(88));
        vm.prank(voteAddress);
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, targetData);
        require(executor.lastVotedTargetDataHash() == keccak256(abi.encode(targetData)), "business items forwarded");
    }

    function testVotedRejectsNonVoteCaller() external {
        _createAction(11);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.UnauthorizedCallback.selector));
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, new bytes[](0));
    }

    function testVotedRejectsUnboundProposal() external {
        vm.prank(voteAddress);
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.UnboundProposal.selector, address(token), 99)
        );
        actionTarget.onProposalVoted(address(token), 3, 99, 5, 250, new bytes[](0));
    }

    function testVotedRejectsMismatchedTargetData() external {
        _createAction(11);
        bytes[] memory malformed = new bytes[](1);
        malformed[0] = new bytes(20);
        vm.prank(voteAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, malformed);

        bytes[] memory mismatched = new bytes[](1);
        mismatched[0] = abi.encode(OUTSIDER);
        vm.prank(voteAddress);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, mismatched);
    }

    function testVotedCallbackRevertBubbles() external {
        _createAction(11);
        executor.setRevertVoted(true);
        vm.prank(voteAddress);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.VotedCallbackReverted.selector));
        actionTarget.onProposalVoted(address(token), 3, 11, 5, 250, new bytes[](0));
    }

    function testRegisterJoinStateRecordsJoinRound() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "joined");
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 1 && memberIds.length == 1 && memberIds[0] == 1, "snapshot at join round");
        (uint256[] memory actionIds, uint256 actionTotal) =
            actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, false);
        require(actionTotal == 1 && actionIds.length == 1 && actionIds[0] == 11, "member mirror");
    }

    function testRegisterJoinStateRejectsNonBoundExecutor() external {
        _createAction(11);
        phase.setPhase(2);
        vm.prank(OUTSIDER);
        vm.expectRevert(_unauthorizedExecutorData(11));
        actionTarget.registerJoinState(address(token), 11, 1);

        require(actionTarget.isJoined(address(token), 11, 1) == false, "not joined");
    }

    function testRegisterJoinStateRejectsUnboundAction() external {
        phase.setPhase(2);
        vm.prank(address(executor));
        vm.expectRevert(_unauthorizedExecutorData(99));
        actionTarget.registerJoinState(address(token), 99, 1);
    }

    function testRegisterJoinStateRejectsBeforeJoinOpens() external {
        phase.setPhase(1);
        _createAction(11);
        vm.prank(address(executor));
        vm.expectRevert(_joinNotOpenData(11, 1, 1));
        actionTarget.registerJoinState(address(token), 11, 1);

        phase.setPhase(0);
        vm.prank(address(executor));
        vm.expectRevert(_joinNotOpenData(11, 0, 1));
        actionTarget.registerJoinState(address(token), 11, 1);

        phase.setPhase(2);
        _join(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "opens one round after creation");
    }

    function testRegisterJoinStateIsIdempotent() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _join(11, 1);
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 1 && memberIds.length == 1, "single membership");
    }

    function testClearJoinStateRemovesMembership() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        _clear(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "membership cleared");
        (uint256[] memory actionIds, uint256 actionTotal) =
            actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, false);
        require(actionTotal == 0 && actionIds.length == 0, "mirror cleared");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 1), "round 1 snapshot retained");
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 1 && memberIds.length == 1, "round 1 member list retained");
    }

    function testClearJoinStateRejectsNonBoundExecutor() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        vm.prank(OUTSIDER);
        vm.expectRevert(_unauthorizedExecutorData(11));
        actionTarget.clearJoinState(address(token), 11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "membership retained");
    }

    function testClearJoinStateIsIdempotent() external {
        _createAction(11);
        phase.setPhase(2);
        _clear(11, 1);
        _clear(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "no-op stays cleared");
    }

    function testExitPathsNeedNoJoinWindow() external {
        phase.setPhase(2);
        _createAction(11);
        _clear(11, 1);
        _forceExit(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "exit paths stay no-ops");
    }

    function testForceExitClearsOnlyTargetState() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        executor.setRevertCreated(true);
        executor.setRevertSubmitted(true);
        executor.setRevertVoted(true);
        executor.setRevertNeedBurn(true);
        _forceExit(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "membership cleared");
        (uint256[] memory actionIds, uint256 actionTotal) =
            actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, false);
        require(actionTotal == 0 && actionIds.length == 0, "mirror cleared");
        require(executor.createdCalls() == 1, "executor untouched after creation");
        require(token.transferCalls() == 0, "no token movement");
    }

    function testForceExitThenClearJoinStateIsIdempotent() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        _forceExit(11, 1);
        _clear(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "still cleared");
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 2, 0, 10, false);
        require(total == 0 && memberIds.length == 0, "round 2 snapshot stays empty");
    }

    function testForceExitRequiresCurrentOwner() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.NotMemberOwner.selector, 1));
        actionTarget.forceExit(address(token), 11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "membership retained");
    }

    function testForceExitTracksCurrentOwnerAfterTransfer() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        memberNFT.setOwner(1, MEMBER2);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.NotMemberOwner.selector, 1));
        actionTarget.forceExit(address(token), 11, 1);
        vm.prank(MEMBER2);
        actionTarget.forceExit(address(token), 11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "current owner can force exit");
    }

    function testForceExitIsIdempotent() external {
        _createAction(11);
        phase.setPhase(2);
        _forceExit(11, 1);
        _forceExit(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "no-op stays cleared");
    }

    function testIsJoinedByRoundTracksSnapshots() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        _clear(11, 1);
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 1), "joined as of round 1");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 2) == false, "cleared as of round 2");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 0) == false, "not joined before round 1");
        phase.setPhase(4);
        _join(11, 1);
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 3), "rejoined as of round 3");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 4) == false, "future round is not started");
        require(actionTarget.isJoined(address(token), 11, 1), "currently joined");
    }

    function testMemberIdsByActionIdRoundBounds() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(4);
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 5, 0, 10, false);
        require(total == 0 && memberIds.length == 0, "future round is empty");
        (memberIds, total) = actionTarget.memberIdsByActionId(address(token), 11, 3, 0, 10, false);
        require(total == 1 && memberIds[0] == 1, "nearest snapshot at round 3");
        (memberIds, total) = actionTarget.memberIdsByActionId(address(token), 11, 0, 0, 10, false);
        require(total == 0 && memberIds.length == 0, "before first join is empty");
    }

    function testActionIdsByMemberIdPagination() external {
        phase.setPhase(1);
        _createAction(11);
        _createAction(12);
        _createAction(13);
        phase.setPhase(2);
        _join(11, 1);
        _join(12, 1);
        _join(13, 1);

        (uint256[] memory page, uint256 total) = actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, false);
        require(total == 3 && page.length == 3 && page[0] == 11 && page[1] == 12 && page[2] == 13, "forward page");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 1, 2, false);
        require(total == 3 && page.length == 2 && page[0] == 12 && page[1] == 13, "offset and limit");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 0, 0, false);
        require(total == 3 && page.length == 0, "limit zero returns total only");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 3, 10, false);
        require(total == 3 && page.length == 0, "out of range offset");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, true);
        require(total == 3 && page.length == 3 && page[0] == 13 && page[1] == 12 && page[2] == 11, "reverse page");

        _clear(11, 1);
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, false);
        require(total == 2 && page.length == 2 && page[0] == 13 && page[1] == 12, "swap-and-pop changes same offset");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 0, 10, true);
        require(total == 2 && page[0] == 12 && page[1] == 13, "reverse walks current storage order");
    }

    function testMemberIdsByActionIdPagination() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _join(11, 2);
        _join(11, 3);

        (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 3 && page.length == 3 && page[0] == 1 && page[1] == 2 && page[2] == 3, "forward page");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 1, 1, false);
        require(total == 3 && page.length == 1 && page[0] == 2, "offset and limit");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 0, false);
        require(total == 3 && page.length == 0, "limit zero returns total only");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 9, 10, false);
        require(total == 3 && page.length == 0, "out of range offset");

        _clear(11, 1);
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 2 && page[0] == 3 && page[1] == 2, "swap-and-pop changes same offset");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, true);
        require(total == 2 && page[0] == 2 && page[1] == 3, "reverse walks current storage order");
    }

    function testActionsPaginationIsAppendOnlyCreationOrder() external {
        _createAction(21);
        _createAction(22);
        _createAction(23);

        (uint256[] memory actionIds, address[] memory executors, uint256 total) =
            actionTarget.actions(address(token), 0, 10, false);
        require(total == 3 && actionIds.length == 3, "totals");
        require(actionIds[0] == 21 && actionIds[1] == 22 && actionIds[2] == 23, "creation order");
        require(
            executors[0] == address(executor) && executors[1] == address(executor)
                && executors[2] == address(executor),
            "executors aligned"
        );
        (actionIds, executors, total) = actionTarget.actions(address(token), 1, 5, true);
        require(total == 3 && actionIds.length == 2 && actionIds[0] == 22 && actionIds[1] == 21, "reverse order");
        require(executors.length == 2, "executors paged");
        (actionIds, executors, total) = actionTarget.actions(address(token), 0, 0, false);
        require(total == 3 && actionIds.length == 0 && executors.length == 0, "limit zero returns total only");
    }

    function testActionIdsByExecutorPagination() external {
        MockExecutor second = new MockExecutor(address(actionTarget));
        _createAction(31);
        _createAction(32, second);
        _createAction(33);

        (uint256[] memory page, uint256 total) =
            actionTarget.actionIdsByExecutor(address(token), address(executor), 0, 10, false);
        require(total == 2 && page.length == 2 && page[0] == 31 && page[1] == 33, "first executor");
        (page, total) = actionTarget.actionIdsByExecutor(address(token), address(second), 0, 10, false);
        require(total == 1 && page.length == 1 && page[0] == 32, "second executor");
        (page, total) = actionTarget.actionIdsByExecutor(address(token), OUTSIDER, 0, 10, false);
        require(total == 0 && page.length == 0, "unknown executor");
        (page, total) = actionTarget.actionIdsByExecutor(address(token), address(executor), 0, 10, true);
        require(total == 2 && page[0] == 33 && page[1] == 31, "reverse order");
    }

    function testVotedActionsFiltersUnboundAndPaginates() external {
        MockExecutor second = new MockExecutor(address(actionTarget));
        _createAction(41);
        _createAction(42, second);
        _createAction(43);

        uint256 round = 2;
        uint256[] memory votedIds = new uint256[](3);
        votedIds[0] = 41;
        votedIds[1] = 999;
        votedIds[2] = 42;
        vote.setVotedProposalIds(address(token), round, votedIds);

        (uint256[] memory actionIds, address[] memory executors, uint256 total) =
            actionTarget.votedActions(address(token), round, 0, 10, false);
        require(total == 2 && actionIds.length == 2, "unbound filtered out");
        require(actionIds[0] == 41 && actionIds[1] == 42, "voted order retained");
        require(executors[0] == address(executor) && executors[1] == address(second), "executors aligned");
        (actionIds, executors, total) = actionTarget.votedActions(address(token), round, 1, 10, false);
        require(total == 2 && actionIds.length == 1 && actionIds[0] == 42, "offset within filtered list");
        (actionIds,, total) = actionTarget.votedActions(address(token), round, 0, 10, true);
        require(total == 2 && actionIds[0] == 42 && actionIds[1] == 41, "reverse order");
        (actionIds,, total) = actionTarget.votedActions(address(token), round + 1, 0, 10, false);
        require(total == 0 && actionIds.length == 0, "empty round");
    }

    function testVotedActionsReadsFullRoundListBeforeFiltering() external {
        _createAction(2);
        _createAction(4);
        uint256 round = 3;
        uint256[] memory votedIds = new uint256[](4);
        votedIds[0] = 1;
        votedIds[1] = 2;
        votedIds[2] = 3;
        votedIds[3] = 4;
        vote.setVotedProposalIds(address(token), round, votedIds);

        (uint256[] memory actionIds,, uint256 total) = actionTarget.votedActions(address(token), round, 0, 2, false);
        require(total == 2 && actionIds.length == 2, "filtered total");
        require(actionIds[0] == 2 && actionIds[1] == 4, "filtering precedes the caller window");
    }

    function testMintActionRewardMintsOnceAndTransfers() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);

        vm.prank(address(executor));
        uint256 amount = actionTarget.mintActionReward(address(token), 11, round);
        require(amount == MINT_AMOUNT, "amount returned");
        require(mint.mintCalls() == 1, "mint called once");
        require(mint.lastMintCaller() == address(actionTarget), "action target is the caller");
        require(mint.lastMintTokenAddress() == address(token), "token forwarded");
        require(mint.lastMintRound() == round, "round forwarded");
        require(mint.lastMintProposalId() == 11, "actionId forwarded");
        require(token.transferCalls() == 1, "single transfer");
        require(token.lastTransferTo() == address(executor), "reward forwarded to executor");
        require(token.lastTransferAmount() == MINT_AMOUNT, "full amount forwarded");
        (uint256 recorded, bool minted) = actionTarget.actionReward(address(token), 11, round);
        require(recorded == MINT_AMOUNT && minted, "reward query");
    }

    function testMintActionRewardRejectsNonBoundExecutor() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        vm.prank(OUTSIDER);
        vm.expectRevert(_unauthorizedExecutorData(11));
        actionTarget.mintActionReward(address(token), 11, round);

        vm.prank(address(executor));
        vm.expectRevert(_unauthorizedExecutorData(99));
        actionTarget.mintActionReward(address(token), 99, round);
    }

    function testMintActionRewardRejectsRepeat() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, round);

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.AlreadyMinted.selector, address(token), 11, round)
        );
        actionTarget.mintActionReward(address(token), 11, round);
        require(mint.mintCalls() == 1, "mint not repeated");
        require(token.transferCalls() == 1, "transfer not repeated");
    }

    function testMintActionRewardRejectsUnvotedProposal() external {
        _createAction(11);
        uint256 round = 5;
        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.ProposalNotVoted.selector, address(token), 11));
        actionTarget.mintActionReward(address(token), 11, round);
        require(mint.mintCalls() == 0, "mint not attempted");
    }

    function testMintActionRewardRoundIsIndependent() external {
        _createAction(11);
        vote.setProposalVoted(address(token), 5, 11, true);
        vote.setProposalVoted(address(token), 6, 11, true);
        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, 5);
        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, 6);
        (uint256 amount5, bool minted5) = actionTarget.actionReward(address(token), 11, 5);
        (uint256 amount6, bool minted6) = actionTarget.actionReward(address(token), 11, 6);
        require(amount5 == MINT_AMOUNT && minted5 && amount6 == MINT_AMOUNT && minted6, "per-round dedup");
        require(mint.mintCalls() == 2, "one mint per round");
    }

    function testMintActionRewardRollsBackOnTransferFailure() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        token.setTransferResult(false);
        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.TransferFailed.selector, address(token), address(executor), MINT_AMOUNT
            )
        );
        actionTarget.mintActionReward(address(token), 11, round);
        (uint256 amount, bool minted) = actionTarget.actionReward(address(token), 11, round);
        require(amount == 0 && minted == false, "ledger rolled back");
        require(mint.mintCalls() == 0, "mock mint call rolled back");
    }

    function testMintActionRewardPropagatesMintRevert() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        mint.setRevertOnMint(true);
        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(MockMint.MintProposalRewardReverted.selector));
        actionTarget.mintActionReward(address(token), 11, round);
        (uint256 amount, bool minted) = actionTarget.actionReward(address(token), 11, round);
        require(amount == 0 && minted == false, "ledger untouched");
    }

    function testRewardQueriesDefaultForUnboundRounds() external view {
        (uint256 amount, bool minted) = actionTarget.actionReward(address(token), 11, 5);
        require(amount == 0 && minted == false, "unbound action defaults");
        (amount, minted) = actionTarget.actionReward(address(token), 11, 0);
        require(amount == 0 && minted == false, "round zero defaults");
        (uint256 burnedAmount, bool burned) = actionTarget.burnInfo(address(token), 99, 5);
        require(burnedAmount == 0 && burned == false, "burn defaults");
    }

    function testBurnRewardIfNeededIsPermissionless() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        vote.setRoundEnded(round, true);
        executor.setNeedBurn(true);

        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 1, "burn called once");
        require(mint.lastBurnCaller() == address(actionTarget), "action target is the caller");
        require(mint.lastBurnTokenAddress() == address(token), "token forwarded");
        require(mint.lastBurnRound() == round, "round forwarded");
        require(mint.lastBurnProposalId() == 11, "actionId forwarded");
        require(token.transferCalls() == 0, "no token movement");
        (uint256 recorded, bool burned) = actionTarget.burnInfo(address(token), 11, round);
        require(recorded == BURN_AMOUNT && burned, "burn ledger");
    }

    function testBurnRewardIfNeededNoOps() external {
        uint256 round = 5;
        executor.setNeedBurn(true);

        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 99, round);
        require(mint.burnCalls() == 0, "unbound action no-op even before round end");

        vote.setRoundEnded(round, true);
        _createAction(11);
        mint.setProposalReward(address(token), round, 11, 0, false);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "zero amount no-op");

        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, true);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "already minted no-op");

        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        executor.setNeedBurn(false);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "judgment false no-op");

        (uint256 recorded, bool burned) = actionTarget.burnInfo(address(token), 11, round);
        require(recorded == 0 && burned == false, "ledger untouched");
    }

    function testBurnRewardIfNeededRejectsOpenRound() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        vote.setRoundEnded(round, false);
        executor.setNeedBurn(true);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidRound.selector, round));
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "no burn on open round");
    }

    function testBurnRewardIfNeededSkipsJudgmentWhenAlreadyMinted() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, true);
        vote.setRoundEnded(round, true);
        executor.setRevertNeedBurn(true);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "no burn when minted");
    }

    function testBurnRewardIfNeededSkipsJudgmentWhenAmountZero() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, 0, false);
        vote.setRoundEnded(round, true);
        executor.setRevertNeedBurn(true);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 0, "no burn when the amount is zero");
    }

    function testBurnRewardIfNeededPropagatesJudgmentRevert() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        vote.setRoundEnded(round, true);
        executor.setRevertNeedBurn(true);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NeedBurnRewardReverted.selector));
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
    }

    function testBurnRewardIfNeededPropagatesBurnRevert() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        vote.setRoundEnded(round, true);
        executor.setNeedBurn(true);
        mint.setRevertOnBurn(true);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(MockMint.BurnUnmintedProposalRewardReverted.selector));
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        (uint256 recorded, bool burned) = actionTarget.burnInfo(address(token), 11, round);
        require(recorded == 0 && burned == false, "ledger rolled back");
    }

    function testBurnRewardIfNeededIsIdempotent() external {
        _createAction(11);
        uint256 round = 5;
        mint.setProposalReward(address(token), round, 11, BURN_AMOUNT, false);
        vote.setRoundEnded(round, true);
        executor.setNeedBurn(true);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        vm.prank(OUTSIDER);
        actionTarget.burnRewardIfNeeded(address(token), 11, round);
        require(mint.burnCalls() == 1, "repeat is a no-op");
    }

    function testExecutorGetterReturnsZeroForUnboundAction() external {
        require(actionTarget.executor(address(token), 99) == address(0), "unbound executor");
        _createAction(11);
        require(actionTarget.executor(address(token), 11) == address(executor), "bound executor");
    }
}
