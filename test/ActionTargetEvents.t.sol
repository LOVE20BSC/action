// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionTargetEvents} from "../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract ActionTargetEventsTest is ActionTargetTestBase, IActionTargetEvents {
    function testActionCreatedEvent() external {
        vm.expectEmit(true, true, true, true);
        emit ActionRegistered({
            tokenAddress: address(token),
            actionId: 11,
            round: 1,
            executor: address(executor)
        });
        _createAction(11);
    }

    function testJoinStateRegisteredEvent() external {
        _createAction(11);
        phase.setPhase(2);
        vm.expectEmit(true, true, true, true);
        emit JoinStateRegistered({
            tokenAddress: address(token),
            actionId: 11,
            memberId: 1,
            round: 1
        });
        _join(11, 1);
    }

    function testJoinStateClearedEventOnClear() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared({
            tokenAddress: address(token),
            actionId: 11,
            memberId: 1,
            round: 2,
            forced: false
        });
        _clear(11, 1);
    }

    function testJoinStateClearedEventOnForceClearJoinState() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared({
            tokenAddress: address(token),
            actionId: 11,
            memberId: 1,
            round: 2,
            forced: true
        });
        _forceClearJoinState(11, 1);
    }

    function testActionRewardMintedEvent() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        mint.setMintAmount(777);
        vm.expectEmit(true, true, true, true);
        emit ActionRewardMinted({
            tokenAddress: address(token),
            actionId: 11,
            round: round,
            amount: 777
        });
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

    function testNoEventOnDuplicateClearAndForceClearJoinState() external {
        _createAction(11);
        phase.setPhase(2);
        _join(11, 1);
        _clear(11, 1);
        vm.recordLogs();
        _clear(11, 1);
        _forceClearJoinState(11, 1);
        require(vm.getRecordedLogs().length == 0, "no-op exits emit nothing");
    }

    function testEventsCarryJoinRoundNotVoteRound() external {
        _createAction(11);
        phase.setPhase(3);
        vm.expectEmit(true, true, true, true);
        emit JoinStateRegistered({
            tokenAddress: address(token),
            actionId: 11,
            memberId: 1,
            round: 2
        });
        _join(11, 1);
        phase.setPhase(4);
        vm.expectEmit(true, true, true, true);
        emit JoinStateCleared({
            tokenAddress: address(token),
            actionId: 11,
            memberId: 1,
            round: 3,
            forced: false
        });
        _clear(11, 1);
    }

    function testCreationEventRoundIsVoteRound() external {
        phase.setPhase(7);
        vm.expectEmit(true, true, true, true);
        emit ActionRegistered({
            tokenAddress: address(token),
            actionId: 11,
            round: 7,
            executor: address(executor)
        });
        _createAction(11);
    }
}
