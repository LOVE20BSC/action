// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {ILpExecutorEvents} from "../src/interfaces/ILpExecutor.sol";
import {LpExecutorTestBase, LpExecutorVm} from "./LpExecutorTestBase.sol";

contract LpExecutorEventsTest is LpExecutorTestBase, ILpExecutorEvents, IActionExecutorEvents {
    function testJoinedEvent() external {
        _atPhaseBlock(3, 3300);
        vm.expectEmit(true, true, true, true);
        emit Joined(address(token), ACTION_ID, 1, 2, 100e18);
        _join(1, 100e18);
    }

    function testJoinedEventStructure() external {
        _atPhaseBlock(3, 3300);
        vm.recordLogs();
        _join(1, 100e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(logs[0].emitter == address(lpExecutor), "emitter is the executor");
        require(logs[0].topics.length == 4, "three indexed fields");
        require(
            logs[0].topics[0] == keccak256("Joined(address,uint256,uint256,uint256,uint256)"),
            "event signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(ACTION_ID), "action topic");
        require(logs[0].topics[3] == bytes32(uint256(1)), "member topic");
        require(logs[0].data.length == 64, "round and amount are data");
        (uint256 round, uint256 amount) = abi.decode(logs[0].data, (uint256, uint256));
        require(round == 2 && amount == 100e18, "data values");
    }

    function testWithdrawnEvent() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(address(token), ACTION_ID, 1, 2, 40e18);
        _withdraw(1, 40e18);
    }

    function testWithdrawnEventOnFullWithdraw() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(address(token), ACTION_ID, 1, 2, 100e18);
        _withdraw(1, 100e18);
    }

    function testExitedEvent() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.expectEmit(true, true, true, true);
        emit Exited(address(token), ACTION_ID, 1, 2);
        _exit(1);
    }

    function testMemberRewardMintedEventWithBurn() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        vm.expectEmit(true, true, true, true);
        emit MemberRewardMinted(address(token), ACTION_ID, 1, 2, 200e18, 800e18);
        vm.prank(MEMBER1);
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
    }

    function testMemberRewardMintedEventOnZeroSettlement() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _withdraw(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);

        vm.expectEmit(true, true, true, true);
        emit MemberRewardMinted(address(token), ACTION_ID, 1, 2, 0, 0);
        vm.prank(MEMBER1);
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
    }

    function testWithdrawEmitsOnlyWithdrawn() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.recordLogs();
        _withdraw(1, 40e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(
            logs[0].topics[0] == keccak256("Withdrawn(address,uint256,uint256,uint256,uint256)"),
            "withdrawn signature"
        );
    }

    function testMintEmitsOnlyMemberRewardMinted() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        vm.recordLogs();
        vm.prank(MEMBER1);
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(
            logs[0].topics[0]
                == keccak256("MemberRewardMinted(address,uint256,uint256,uint256,uint256,uint256)"),
            "member reward signature"
        );
    }
}
