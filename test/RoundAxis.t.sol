// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionRoundAxis} from "../src/GroupActionRoundAxis.sol";
import {LpRoundAxis} from "../src/LpRoundAxis.sol";

contract MockRoundAxisPhase {
    uint256 public currentPhase;

    function setPhase(uint256 phase) external {
        currentPhase = phase;
    }
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

contract LpRoundAxisHarness {
    function joinRound(address phaseAddress) external view returns (uint256) {
        return LpRoundAxis.joinRound(phaseAddress);
    }

    function mintRound(address phaseAddress) external view returns (uint256) {
        return LpRoundAxis.mintRound(phaseAddress);
    }
}

contract RoundAxisTest {
    MockRoundAxisPhase private phase;
    GroupActionRoundAxisHarness private group;
    LpRoundAxisHarness private lp;

    function setUp() public {
        phase = new MockRoundAxisPhase();
        group = new GroupActionRoundAxisHarness();
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
}
