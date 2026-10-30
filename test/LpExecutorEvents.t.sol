// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors, IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {ILpExecutorEvents} from "../src/interfaces/ILpExecutor.sol";
import {LpExecutorTestBase, LpExecutorVm} from "./LpExecutorTestBase.sol";

contract LpExecutorEventsTest is LpExecutorTestBase, ILpExecutorEvents, IActionExecutorEvents {
    function testLpActionCreatedEvent() external {
        _atPhase(CREATION_PHASE);
        vm.expectEmit(true, true, true, true);
        emit LpActionCreated({
            tokenAddress: address(token),
            actionId: SECOND_ACTION_ID,
            joinTokenAddress: address(joinToken),
            govRatioMultiplier: GOV_RATIO_MULTIPLIER,
            minGovRatio: MIN_GOV_RATIO
        });
        _createAction(SECOND_ACTION_ID);
    }

    function testLpActionCreatedEmitsFromTheExecutor() external {
        _atPhase(CREATION_PHASE);
        vm.recordLogs();
        _createAction(SECOND_ACTION_ID);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single creation event");
        require(logs[0].emitter == address(lpExecutor), "emitter is the executor");
        require(
            logs[0].topics[0]
                == keccak256("LpActionCreated(address,uint256,address,uint256,uint256)"),
            "creation signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(SECOND_ACTION_ID), "action topic");
        (address joinTokenAddress, uint256 govRatioMultiplier, uint256 minGovRatio) =
            abi.decode(logs[0].data, (address, uint256, uint256));
        require(joinTokenAddress == address(joinToken), "join token");
        require(govRatioMultiplier == GOV_RATIO_MULTIPLIER, "gov ratio multiplier");
        require(minGovRatio == MIN_GOV_RATIO, "min gov ratio");
    }

    function testLpJoinedEvent() external {
        _atPhaseBlock(3, 3300);
        vm.expectEmit(true, true, true, true);
        emit LpJoined({
            tokenAddress: address(token),
            actionId: ACTION_ID,
            memberId: 1,
            round: 2,
            amount: 100e18
        });
        _join(1, 100e18);
    }

    function testLpJoinedEventStructure() external {
        _atPhaseBlock(3, 3300);
        vm.recordLogs();
        _join(1, 100e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(logs[0].emitter == address(lpExecutor), "emitter is the executor");
        require(logs[0].topics.length == 4, "three indexed fields");
        require(
            logs[0].topics[0] == keccak256("LpJoined(address,uint256,uint256,uint256,uint256)"),
            "event signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(ACTION_ID), "action topic");
        require(logs[0].topics[3] == bytes32(uint256(1)), "member topic");
        require(logs[0].data.length == 64, "round and amount are data");
        (uint256 round, uint256 amount) = abi.decode(logs[0].data, (uint256, uint256));
        require(round == 2 && amount == 100e18, "data values");
    }

    function testLpWithdrawnEvent() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.expectEmit(true, true, true, true);
        emit LpWithdrawn({
            tokenAddress: address(token),
            actionId: ACTION_ID,
            memberId: 1,
            round: 2,
            amount: 40e18
        });
        _withdraw(1, 40e18);
    }

    function testFullWithdrawEmitsWithdrawnThenExited() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.recordLogs();
        _withdraw(1, 100e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 2, "withdrawn and exited");
        require(
            logs[0].topics[0] == keccak256("LpWithdrawn(address,uint256,uint256,uint256,uint256)"),
            "withdrawn signature"
        );
        (uint256 round, uint256 amount) = abi.decode(logs[0].data, (uint256, uint256));
        require(round == 2 && amount == 100e18, "withdrawn payload");
        require(
            logs[1].topics[0] == keccak256("LpExited(address,uint256,uint256,uint256)"),
            "exited signature"
        );
        require(logs[1].topics[2] == bytes32(ACTION_ID), "exit action topic");
        require(logs[1].topics[3] == bytes32(uint256(1)), "exit member topic");
        round = abi.decode(logs[1].data, (uint256));
        require(round == 2, "exit round");
    }

    function testExitEmitsWithdrawnThenExited() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.recordLogs();
        _exit(1);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 2, "withdrawn and exited");
        require(
            logs[0].topics[0] == keccak256("LpWithdrawn(address,uint256,uint256,uint256,uint256)"),
            "withdrawn signature"
        );
        (uint256 round, uint256 amount) = abi.decode(logs[0].data, (uint256, uint256));
        require(round == 2 && amount == 100e18, "withdrawn payload");
        require(
            logs[1].topics[0] == keccak256("LpExited(address,uint256,uint256,uint256)"),
            "exited signature"
        );
        require(logs[1].topics[2] == bytes32(ACTION_ID), "exit action topic");
        require(logs[1].topics[3] == bytes32(uint256(1)), "exit member topic");
        round = abi.decode(logs[1].data, (uint256));
        require(round == 2, "exit round");
    }

    function testFullWithdrawClearsRegistryAfterRefund() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        actionTarget.setEmitClearEvent(true);

        vm.recordLogs();
        _withdraw(1, 100e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 3, "withdrawn, registry clear, exited");
        require(
            logs[0].topics[0] == keccak256("LpWithdrawn(address,uint256,uint256,uint256,uint256)"),
            "withdrawn first"
        );
        require(logs[1].emitter == address(actionTarget), "clear event from ActionTarget");
        require(logs[1].topics.length == 4, "clear has three indexed fields");
        require(
            logs[1].topics[0] == keccak256("JoinStateCleared(address,uint256,uint256,uint256,bool)"),
            "clear after withdrawn"
        );
        require(
            logs[2].topics[0] == keccak256("LpExited(address,uint256,uint256,uint256)"),
            "exited last"
        );
    }

    function testExitClearsRegistryAfterRefund() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        actionTarget.setEmitClearEvent(true);

        vm.recordLogs();
        _exit(1);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 3, "withdrawn, registry clear, exited");
        require(
            logs[0].topics[0] == keccak256("LpWithdrawn(address,uint256,uint256,uint256,uint256)"),
            "withdrawn first"
        );
        require(logs[1].emitter == address(actionTarget), "clear event from ActionTarget");
        require(logs[1].topics.length == 4, "clear has three indexed fields");
        require(
            logs[1].topics[0] == keccak256("JoinStateCleared(address,uint256,uint256,uint256,bool)"),
            "clear after withdrawn"
        );
        require(
            logs[2].topics[0] == keccak256("LpExited(address,uint256,uint256,uint256)"),
            "exited last"
        );
    }

    function testMemberRewardMintedEventWithBurn() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        vm.expectEmit(true, true, true, true);
        emit MemberRewardMinted({
            tokenAddress: address(token),
            actionId: ACTION_ID,
            memberId: 1,
            round: 2,
            mintAmount: 200e18,
            burnAmount: 800e18
        });
        vm.prank(MEMBER1);
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 2, 1);
    }

    function testMintMemberRewardRevertsOnZeroSettlement() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _withdraw(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 2, 1);
    }

    function testPartialWithdrawEmitsOnlyWithdrawn() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        vm.recordLogs();
        _withdraw(1, 40e18);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(
            logs[0].topics[0] == keccak256("LpWithdrawn(address,uint256,uint256,uint256,uint256)"),
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
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 2, 1);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single event");
        require(
            logs[0].topics[0]
                == keccak256("MemberRewardMinted(address,uint256,uint256,uint256,uint256,uint256)"),
            "member reward signature"
        );
    }

    /// E2：`mintActionReward` 的返回值与预计算不同，事件必须报告实际返回值。
    function testMemberRewardReportsTheMintedReturnNotThePrecomputedAmount() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD / 2);
        _fundExecutor(PROPOSAL_REWARD);

        vm.recordLogs();
        vm.prank(MEMBER1);
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 2, 1);
        LpExecutorVm.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 1, "single event");
        (uint256 round, uint256 mintAmount, uint256 burnAmount) =
            abi.decode(logs[0].data, (uint256, uint256, uint256));
        require(round == 2, "round");
        require(mintAmount == 100e18, "mint follows the returned amount");
        require(burnAmount == 400e18, "burn follows the returned amount");
    }
}
