// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionTargetEvents} from "../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract ActionTargetEventsTest is ActionTargetTestBase, IActionTargetEvents {
    function testActionCreatedEvent() external {
        vm.expectEmit(true, true, true, true);
        emit ActionCreated(address(token), 11, address(executor), 1);
        _createAction(11);
    }

    function testJoinStateRegisteredEvent() external {
        _createAction(11);
        phase.setPhase(2);
        vm.expectEmit(true, true, true, true);
        emit JoinStateRegistered(address(token), 11, 1, 1);
        _join(11, 1);
    }

    function testJoinStateClearedEventOnClear() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared(address(token), 11, 1, 2, false);
        _clear(11, 1);
    }

    function testJoinStateClearedEventOnForceExit() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared(address(token), 11, 1, 2, true);
        _forceExit(11, 1);
    }

    function testActionRewardMintedEvent() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        mint.setMintAmount(777);
        vm.expectEmit(true, true, true, true);
        emit ActionRewardMinted(address(token), 11, round, 777);
        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, round);
        (uint256 recorded, bool mintedFlag) = actionTarget.actionReward(address(token), 11, round);
        require(recorded == 777 && mintedFlag, "event amount matches the ledger");
    }

    function testNoEventOnDuplicateJoin() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        vm.recordLogs();
        _join(11, 1);
        require(vm.getRecordedLogs().length == 0, "duplicate join emits nothing");
    }

    function testNoEventOnDuplicateClearAndForceExit() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _clear(11, 1);
        vm.recordLogs();
        _clear(11, 1);
        _forceExit(11, 1);
        require(vm.getRecordedLogs().length == 0, "no-op exits emit nothing");
    }

    function testEventsCarryJoinRoundNotVoteRound() external {
        _createAction(11);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateRegistered(address(token), 11, 1, 2);
        _join(11, 1);
        phase.setPhase(4);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared(address(token), 11, 1, 3, false);
        _clear(11, 1);
    }

    function testCreationEventRoundIsVoteRound() external {
        phase.setPhase(7);
        vm.expectEmit(true, true, true, true);
        emit ActionCreated(address(token), 11, address(executor), 7);
        _createAction(11);
    }
}
