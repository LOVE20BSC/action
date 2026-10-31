// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionRoundAxis} from "../src/GroupActionRoundAxis.sol";
import {GroupActionManager} from "../src/GroupActionManager.sol";
import {GroupActionVerify} from "../src/GroupActionVerify.sol";
import {LpRoundAxis} from "../src/LpRoundAxis.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";

contract MockRoundAxisPhase {
    uint256 public currentPhase;

    function setPhase(uint256 phase) external {
        currentPhase = phase;
    }
}

interface RoundAxisVm {
    function expectRevert(bytes calldata data) external;
}

contract GroupActionRoundAxisHarness {
    function joinRound(address phaseAddress) external view returns (uint256) {
        return GroupActionRoundAxis.joinRound(phaseAddress);
    }

    function verifyRound(address phaseAddress) external view returns (uint256) {
        return GroupActionRoundAxis.verifyRound(phaseAddress);
    }

    function mintRound(address phaseAddress) external view returns (uint256) {
        return GroupActionRoundAxis.mintRound(phaseAddress);
    }
}

contract GroupActionManagerGuardHarness {
    function currentJoinRound(address phaseAddress) external view returns (uint256) {
        return GroupActionManager.currentJoinRound(phaseAddress);
    }
}

contract GroupActionVerifyGuardHarness {
    function currentVerifyRound(address phaseAddress) external view returns (uint256) {
        return GroupActionVerify.currentVerifyRound(phaseAddress);
    }
}

contract LpRoundAxisHarness {
    function joinRound(address phaseAddress) external view returns (uint256) {
        return LpRoundAxis.joinRound(phaseAddress);
    }

    function mintRound(address phaseAddress) external view returns (uint256) {
        return LpRoundAxis.mintRound(phaseAddress);
    }
}

contract RoundAxisTest {
    RoundAxisVm internal constant vm = RoundAxisVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockRoundAxisPhase private phase;
    GroupActionRoundAxisHarness private group;
    GroupActionManagerGuardHarness private manager;
    GroupActionVerifyGuardHarness private verify;
    LpRoundAxisHarness private lp;

    function setUp() public {
        phase = new MockRoundAxisPhase();
        group = new GroupActionRoundAxisHarness();
        manager = new GroupActionManagerGuardHarness();
        verify = new GroupActionVerifyGuardHarness();
        lp = new LpRoundAxisHarness();
    }

    function testGroupActionAxis() external {
        require(group.joinRound(address(phase)) == 0);
        phase.setPhase(1);
        require(group.joinRound(address(phase)) == 0);
        phase.setPhase(2);
        require(group.joinRound(address(phase)) == 1);
        require(group.verifyRound(address(phase)) == 0);
        phase.setPhase(3);
        require(group.joinRound(address(phase)) == 2);
        require(group.verifyRound(address(phase)) == 1);
        require(group.mintRound(address(phase)) == 0);
        phase.setPhase(4);
        require(group.verifyRound(address(phase)) == 2);
        require(group.mintRound(address(phase)) == 1);
    }

    function testLpAxis() external {
        require(lp.joinRound(address(phase)) == 0);
        require(lp.mintRound(address(phase)) == 0);
        phase.setPhase(2);
        require(lp.joinRound(address(phase)) == 1);
        require(lp.mintRound(address(phase)) == 0);
        phase.setPhase(3);
        require(lp.mintRound(address(phase)) == 1);
    }

    function testGroupStepsStayOrdered() external {
        for (uint256 p = 4; p < 40; p++) {
            phase.setPhase(p);
            require(group.joinRound(address(phase)) == group.verifyRound(address(phase)) + 1);
            require(group.verifyRound(address(phase)) == group.mintRound(address(phase)) + 1);
        }
    }

    function testLpMintsOnePhaseEarlierThanGroup() external {
        for (uint256 p = 4; p < 40; p++) {
            phase.setPhase(p);
            require(lp.joinRound(address(phase)) == group.joinRound(address(phase)));
            require(lp.mintRound(address(phase)) == group.mintRound(address(phase)) + 1);
        }
    }

    function testJoinGuard() external {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        manager.currentJoinRound(address(phase));
        phase.setPhase(1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        manager.currentJoinRound(address(phase));
        phase.setPhase(2);
        require(manager.currentJoinRound(address(phase)) == 1, "join guard opens at phase 2");
        phase.setPhase(5);
        require(manager.currentJoinRound(address(phase)) == 4, "join guard follows phase");
    }

    function testVerifyGuard() external {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        verify.currentVerifyRound(address(phase));
        phase.setPhase(1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        verify.currentVerifyRound(address(phase));
        phase.setPhase(2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        verify.currentVerifyRound(address(phase));
        phase.setPhase(3);
        require(verify.currentVerifyRound(address(phase)) == 1, "verify guard opens at phase 3");
        phase.setPhase(5);
        require(verify.currentVerifyRound(address(phase)) == 3, "verify guard follows phase");
    }
}
