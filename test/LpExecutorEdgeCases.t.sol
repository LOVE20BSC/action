// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {ILpExecutorErrors} from "../src/interfaces/ILpExecutor.sol";
import {MockERC20} from "./mocks/LpExecutorMocks.sol";
import {MockUniswapV2Pair} from "./mocks/UniswapV2Mocks.sol";
import {LpExecutorTestBase} from "./LpExecutorTestBase.sol";

contract LpExecutorEdgeCasesTest is LpExecutorTestBase {
    function testCurrentRoundsAtPhaseBoundaries() external {
        _atPhase(0);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentVoteRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentJoinRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentMintRound();

        _atPhase(1);
        require(lpExecutor.currentVoteRound() == 1, "vote round 1");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentJoinRound();

        _atPhase(2);
        require(lpExecutor.currentJoinRound() == 1, "join round 1");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentMintRound();

        _atPhase(3);
        require(lpExecutor.currentVoteRound() == 3, "vote round 3");
        require(lpExecutor.currentJoinRound() == 2, "join round 2");
        require(lpExecutor.currentMintRound() == 1, "mint round 1");

        _atPhase(9);
        require(lpExecutor.currentMintRound() == 7, "mint round tracks the phase");
    }

    function testJoinedAmountQueriesAtUint256Max() external {
        _join(1, 100e18);
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, type(uint256).max) == 0, "total query");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, type(uint256).max, 1) == 0,
            "member query"
        );
    }

    function testJoinExitSameBlockLeavesNoEffectiveAmount() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        _exit(1);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "total cleared");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction cleared");    }

    function testJoinMinimumAmount() external {
        _atPhaseBlock(3, 3300);
        _join(1, 1);
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 1, "one wei joined");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "floor rounds to zero");
    }

    function testMemberLedgersAreIndependent() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(3, 3300);
        _join(2, 200e18);
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 60e18, "aggregated deduction");

        _withdraw(1, 50e18);
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 50e18,
            "member 1 reduced"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 2) == 200e18,
            "member 2 untouched"
        );
        (uint256 deduction1,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        (uint256 deduction2,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 2);
        require(deduction1 == 0 && deduction2 == 60e18, "deductions independent");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 250e18, "total joined");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 60e18, "total deduction");
    }

    function testExitOneMemberKeepsOthers() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(3, 3300);
        _join(2, 200e18);
        _exit(1);

        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 0,
            "member 1 cleared"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 2) == 200e18,
            "member 2 retained"
        );
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 200e18, "total retained");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 60e18, "deduction retained");    }

    function testAllMembersExitClearsEffectiveAmount() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _join(2, 200e18);
        _exit(1);
        _exit(2);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "total cleared");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction cleared");    }

    function testGovRatioFloorRounding() external {
        stake.setTotalValidGovVotes(address(token), 3);
        stake.setValidGovVotes(address(token), 1, 1);
        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(minted == false && ratio == 333333333333333333, "one third floors");
    }

    function testJoinAfterExternalClearReRegisters() external {
        _join(1, 10e18);
        actionTarget.setJoined(address(token), ACTION_ID, 1, false);
        _join(1, 10e18);
        require(actionTarget.registerCalls() == 2, "re-registered after the target state was cleared");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 20e18, "balance accumulates");
    }

    function testActionStateIsScopedByTokenAddress() external {
        MockERC20 secondToken = new MockERC20();
        MockUniswapV2Pair secondJoinToken =
            MockUniswapV2Pair(factory.createPair(address(secondToken), address(lpBaseToken)));
        bytes[] memory targetData =
            _targetDataWithConfig(GOV_RATIO_MULTIPLIER, MIN_GOV_RATIO, address(secondJoinToken));
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(address(secondToken), ACTION_ID, targetData);
        stake.setTotalValidGovVotes(address(secondToken), 1000e18);
        stake.setValidGovVotes(address(secondToken), 1, 100e18);
        secondJoinToken.mintTo(MEMBER1, 100e18);
        vm.prank(MEMBER1);
        secondJoinToken.approve(address(lpExecutor), type(uint256).max);

        _atPhaseBlock(3, 3300);
        _join(1, 10e18);
        vm.prank(MEMBER1);
        lpExecutor.join(address(secondToken), ACTION_ID, 1, 5e18);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 10e18, "first token ledger");
        require(lpExecutor.joinedAmount(address(secondToken), ACTION_ID, 2) == 5e18, "second token ledger");
        require(
            lpExecutor.joinedAmountTokenAddress(address(secondToken), ACTION_ID) == address(secondJoinToken),
            "second join token"
        );
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), ACTION_ID) == address(joinToken),
            "first join token intact"
        );
    }

    function testCapDisabledTakesPrecedenceOverZeroTotalValidGovVotes() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        stake.setTotalValidGovVotes(address(token), 0);
        _atPhase(4);
        _setActionReward(SECOND_ACTION_ID, 2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(SECOND_ACTION_ID, 1, 2);
        require(mintAmount == PROPOSAL_REWARD && burnAmount == 0, "cap disabled skips the zero vote burn");
    }

    function testMintAtCreationRoundLowerBound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(mintAmount == 200e18 && burnAmount == 800e18, "creation round is mintable");
    }

    function testMemberRewardAfterMintIgnoresConfigChanges() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);
        _mintMemberReward(1, 2);

        _setActionReward(2, 999e18, true);
        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(minted && mintAmount == 200e18 && burnAmount == 800e18, "recorded settlement is stable");
    }

    function testJoinSecondActionRequiresOwnMinRatio() external {
        bytes[] memory targetData = _targetDataWithConfig(GOV_RATIO_MULTIPLIER, PRECISION, address(joinToken));
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, PRECISION, 1e17));
        lpExecutor.join(address(token), SECOND_ACTION_ID, 1, 1e18);

        _join(ACTION_ID, 1, 1e18);
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 1e18,
            "default action remains joinable"
        );
    }
}
