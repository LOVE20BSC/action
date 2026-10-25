// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../src/ActionTarget.sol";
import {IActionTargetErrors} from "../src/interfaces/IActionTarget.sol";
import {MockExecutor, MockToken} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract ActionTargetEdgeCasesTest is ActionTargetTestBase {
    function testCreateRejectsMalformedItemLengths() external {
        uint256[] memory lengths = new uint256[](4);
        lengths[0] = 0;
        lengths[1] = 31;
        lengths[2] = 33;
        lengths[3] = 64;
        for (uint256 i = 0; i < lengths.length; i++) {
            bytes[] memory targetData = new bytes[](1);
            targetData[0] = new bytes(lengths[i]);
            vm.prank(submitAddress);
            vm.expectRevert(
                abi.encodeWithSelector(IActionTargetErrors.InvalidTargetDataShape.selector, 0, lengths[i])
            );
            actionTarget.onProposalCreated(address(token), 11, targetData);
        }
        require(actionTarget.executor(address(token), 11) == address(0), "never bound");
    }

    function testCreateAtPhaseZeroRecordsZeroRound() external {
        phase.setPhase(0);
        _createAction(11);
        require(actionTarget.executor(address(token), 11) == address(executor), "bound at phase zero");

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.JoinNotOpen.selector, address(token), 11, 0, 0)
        );
        actionTarget.registerJoinState(address(token), 11, 1);

        phase.setPhase(1);
        _join(11, 1);
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 0), "first snapshot at round zero");
    }

    function testSameRoundJoinAndClearOverwritesSnapshot() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _clear(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1) == false, "current state cleared");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 1) == false, "same round overwritten");
        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 0 && memberIds.length == 0, "same round member list overwritten");
    }

    function testJoinGapsUseNearestSnapshot() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(4);
        _join(11, 2);

        (uint256[] memory memberIds, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 1 && memberIds[0] == 1, "round 1 snapshot");
        (memberIds, total) = actionTarget.memberIdsByActionId(address(token), 11, 2, 0, 10, false);
        require(total == 1 && memberIds[0] == 1, "gap uses nearest snapshot");
        (memberIds, total) = actionTarget.memberIdsByActionId(address(token), 11, 3, 0, 10, false);
        require(total == 2 && memberIds[0] == 1 && memberIds[1] == 2, "round 3 snapshot");
        require(actionTarget.isJoinedByRound(address(token), 11, 2, 2) == false, "member 2 absent in round 2");
        require(actionTarget.isJoinedByRound(address(token), 11, 2, 3), "member 2 present in round 3");
    }

    function testPaginationOffsetAtUint256Max() external {
        phase.setPhase(1);
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);

        (uint256[] memory page, uint256 total) =
            actionTarget.actionIdsByMemberId(address(token), 1, type(uint256).max, 10, false);
        require(total == 1 && page.length == 0, "member offset saturated");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, type(uint256).max, 10, false);
        require(total == 1 && page.length == 0, "action offset saturated");
        (page, total) = actionTarget.actionIdsByExecutor(address(token), address(executor), type(uint256).max, 10, false);
        require(total == 1 && page.length == 0, "executor offset saturated");
        (page, total) = actionTarget.actionIdsByExecutor(address(token), address(executor), 1, 10, false);
        require(total == 1 && page.length == 0, "offset equal to total");
    }

    function testActionStateIsScopedByTokenAddress() external {
        MockToken secondToken = new MockToken();
        _createAction(11);
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(secondToken), 11, _targetData(address(executor)));

        phase.setPhase(2);
        _join(11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "joined under first token");
        require(actionTarget.isJoined(address(secondToken), 11, 1) == false, "second token independent");

        (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(secondToken), 11, 1, 0, 10, false);
        require(total == 0 && page.length == 0, "second token snapshot independent");
        uint256[] memory members = new uint256[](1);
        members[0] = 1;
        uint256[] memory rounds = actionTarget.joinedRounds(address(token), 11, members);
        require(rounds[0] == 1, "first token join round");
        rounds = actionTarget.joinedRounds(address(secondToken), 11, members);
        require(rounds[0] == 0, "second token join round independent");
        (uint256[] memory ids,, uint256 indexTotal) = actionTarget.actions(address(token), 0, 10, false);
        require(indexTotal == 1 && ids[0] == 11, "first token index");
        (ids,, indexTotal) = actionTarget.actions(address(secondToken), 0, 10, false);
        require(indexTotal == 1 && ids[0] == 11, "second token index");
    }

    function testActionIdsByMemberIdUnknownMember() external view {
        (uint256[] memory page, uint256 total) = actionTarget.actionIdsByMemberId(address(token), 42, 0, 10, false);
        require(total == 0 && page.length == 0, "unknown member empty");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 42, 0, 0, true);
        require(total == 0 && page.length == 0, "unknown member reverse empty");
    }

    function testAllMembersLeaveClearsCurrentList() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _join(11, 2);
        _clear(11, 1);
        _clear(11, 2);
        (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 0 && page.length == 0, "current list empty");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 0, false);
        require(total == 0, "total only empty");
    }

    function testVotedActionsExcludesAllUnbound() external {
        vote.setVotedProposalIds(address(token), 3, _singleId(77));
        (uint256[] memory page,, uint256 total) = actionTarget.votedActions(address(token), 3, 0, 10, false);
        require(total == 0 && page.length == 0, "unbound round empty");

        _createAction(77);
        (page,, total) = actionTarget.votedActions(address(token), 3, 0, 10, false);
        require(total == 1 && page[0] == 77, "bound round populated");
    }

    function testMemberIdsRoundBoundaryExactness() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);

        (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, 0, 10, false);
        require(total == 1 && page[0] == 1, "join round readable");
        (page, total) = actionTarget.memberIdsByActionId(address(token), 11, 2, 0, 10, false);
        require(total == 0 && page.length == 0, "next round is not started");
        require(actionTarget.isJoinedByRound(address(token), 11, 1, 2) == false, "flag matches boundary");
    }

    function testCreateAcceptsMultipleBusinessItems() external {
        bytes[] memory targetData = new bytes[](4);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(uint256(1));
        targetData[2] = hex"deadbeef";
        targetData[3] = abi.encode(address(OUTSIDER), uint256(9));
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(token), 11, targetData);
        require(executor.lastCreatedTargetDataHash() == keccak256(abi.encode(targetData)), "all items forwarded");
    }

    function testUnboundActionWritesRejectedEvenAfterBindingsExist() external {
        MockExecutor second = new MockExecutor(address(actionTarget));
        _createAction(11, second);
        phase.setPhase(2);
        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.UnauthorizedExecutor.selector, address(token), 11)
        );
        actionTarget.registerJoinState(address(token), 11, 1);
        vm.prank(address(second));
        actionTarget.registerJoinState(address(token), 11, 1);
        require(actionTarget.isJoined(address(token), 11, 1), "only the bound executor can register");
    }

    function _singleId(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
