// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {LpExecutorTestBase} from "./LpExecutorTestBase.sol";

contract LpExecutorFuzzTest is LpExecutorTestBase {
    function testFuzzJoinDeductionFormula(uint96 amount, uint16 elapsed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == joinAmount * joinElapsed / PHASE_BLOCKS, "deduction formula");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == deduction, "total deduction");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == joinAmount,
            "balance recorded"
        );
    }

    function testFuzzJoinDeductionCapsAtAmount(uint96 amount, uint16 elapsed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = PHASE_BLOCKS + (uint256(elapsed) % PHASE_BLOCKS);
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == joinAmount, "deduction capped at the amount");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == joinAmount, "total capped");
    }

    function testFuzzWithdrawScalesDeduction(uint96 amount, uint16 elapsed, uint96 withdrawSeed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);
        uint256 deductionBefore = lpExecutor.deductionByRound(address(token), 2, ACTION_ID);
        uint256 withdrawAmount = uint256(withdrawSeed) % joinAmount + 1;

        _withdraw(1, withdrawAmount);

        if (withdrawAmount == joinAmount) {
            require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "full withdraw takes all");
            require(
                lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 0,
                "balance cleared"
            );
        } else {
            uint256 reduction = deductionBefore * withdrawAmount / joinAmount;
            require(
                lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == joinAmount - withdrawAmount,
                "balance reduced"
            );
            require(
                lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == deductionBefore - reduction,
                "deduction reduced proportionally"
            );
        }
    }

    function testFuzzRewardSplitMatchesReference(
        uint96 rewardSeed,
        uint96 validSeed,
        uint96 totalGovPowerSeed,
        uint96 multiplierSeed
    ) external {
        uint256 reward = uint256(rewardSeed) % 1e27 + 1;
        uint256 memberGovPower = uint256(validSeed) % 1e24;
        uint256 totalGovPower = uint256(totalGovPowerSeed) % 1e24;
        uint256 multiplier = uint256(multiplierSeed) % 3e18;

        _createActionWithConfig(SECOND_ACTION_ID, multiplier, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        stake.setGovPower(address(token), 2, 1, memberGovPower);
        stake.setTotalGovPower(address(token), 2, totalGovPower);
        _atPhase(4);
        _setActionReward(2, SECOND_ACTION_ID, reward, true);
        _fundExecutor(reward);

        (uint256 expectedMint, uint256 expectedBurn) =
            _referenceReward(reward, memberGovPower, totalGovPower, multiplier);
        _assertPendingSplit(expectedMint, expectedBurn);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, SECOND_ACTION_ID, 1);
        require(mintAmount == expectedMint && burnAmount == expectedBurn, "split matches the reference");
        require(mintAmount + burnAmount == reward, "reward is conserved");
    }

    function testFuzzWithdrawClearsJoinedAmount(uint96 amount, uint16 elapsed, bool fullWithdraw) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        if (fullWithdraw) {
            _withdraw(1, joinAmount);
            require(
                lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 0, "joined amount cleared to zero"
            );
            require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "round deduction cleared to zero");
            require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "join state cleared");
        } else {
            require(
                lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == joinAmount,
                "joined amount untouched without a withdrawal"
            );
            require(actionTarget.isJoined(address(token), ACTION_ID, 1), "join state kept without a withdrawal");
        }
    }

    function testFuzzGovRatioFloor(uint96 validSeed, uint96 totalGovPowerSeed) external {
        uint256 totalGovPower = uint256(totalGovPowerSeed) % 1e24 + 1;
        uint256 memberGovPower = uint256(validSeed) % 1e24;
        stake.setTotalGovPower(address(token), 2, totalGovPower);
        stake.setGovPower(address(token), 2, 1, memberGovPower);

        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(minted == false && ratio == memberGovPower * 1e18 / totalGovPower, "floor division");
    }

    function test_ZeroBoundaries(uint256 effectiveAmount, uint256 totalGovPowerInput, uint256 multiplier) external {
        _atPhase(4);
        _setActionReward(2, ACTION_ID, PROPOSAL_REWARD, true);
        (uint256 idleMint, uint256 alreadyPaid, MemberRewardStatus idleStatus) =
            lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        require(idleStatus == MemberRewardStatus.Unavailable && idleMint == 0 && alreadyPaid == 0, "zero total effective amount");

        uint256 memberAmount = effectiveAmount % 1e24 + 1e18;
        uint256 totalGovPower = totalGovPowerInput % 1e24;
        uint256 govRatioMultiplier = multiplier % 3e18;
        uint256 memberGovPower = totalGovPower == 0 ? 0 : totalGovPower / 2;

        _createActionWithConfig(SECOND_ACTION_ID, govRatioMultiplier, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, memberAmount);
        _join(SECOND_ACTION_ID, 2, 1e18);
        stake.setGovPower(address(token), 2, 1, memberGovPower);
        stake.setTotalGovPower(address(token), 2, totalGovPower);
        _atPhase(4);
        _setActionReward(2, SECOND_ACTION_ID, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        uint256 totalEffectiveAmount = memberAmount + 1e18;
        uint256 effectiveLpRatio = memberAmount * PRECISION / totalEffectiveAmount;
        uint256 theoreticalReward = PROPOSAL_REWARD * memberAmount / totalEffectiveAmount;

        uint256 expectedMint;
        uint256 expectedBurn;
        if (govRatioMultiplier == 0) {
            expectedMint = theoreticalReward;
        } else if (totalGovPower == 0) {
            expectedBurn = theoreticalReward;
        } else {
            uint256 govRatio = memberGovPower * PRECISION / totalGovPower;
            uint256 govRatioCap = govRatio * govRatioMultiplier / PRECISION;
            uint256 cappedRatio = govRatioCap < effectiveLpRatio ? govRatioCap : effectiveLpRatio;
            expectedMint =
                cappedRatio == effectiveLpRatio ? theoreticalReward : PROPOSAL_REWARD * cappedRatio / PRECISION;
            expectedBurn = theoreticalReward - expectedMint;
        }

        _assertPendingSplit(expectedMint, expectedBurn);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, SECOND_ACTION_ID, 1);
        require(mintAmount == expectedMint && burnAmount == expectedBurn, "zero boundary split");
        require(mintAmount + burnAmount == theoreticalReward, "reward is conserved");
    }

    function testFuzzBatchLengthMismatch(uint8 actionLength, uint8 roundLength) external {
        uint256 actionIdsLength = uint256(actionLength) % 5;
        uint256 roundsLength = uint256(roundLength) % 5;
        vm.assume(actionIdsLength != roundsLength);

        uint256[] memory actionIds = new uint256[](actionIdsLength);
        uint256[] memory rounds = new uint256[](roundsLength);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.BatchLengthMismatch.selector, actionIdsLength, roundsLength
            )
        );
        lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);
    }

    function _assertPendingSplit(uint256 expectedMint, uint256 expectedBurn) private view {
        (uint256 pendingMint, uint256 pendingBurn, MemberRewardStatus status) =
            lpExecutor.rewardDetail(address(token), 2, SECOND_ACTION_ID, 1);
        require(status == MemberRewardStatus.Pending, "reward awaits settlement");
        require(pendingMint == expectedMint && pendingBurn == expectedBurn, "pending matches the reference");
    }

    function _referenceReward(
        uint256 reward,
        uint256 memberGovPower,
        uint256 totalGovPower,
        uint256 multiplier
    ) internal pure returns (uint256 mintAmount, uint256 burnAmount) {
        // The member joined at the phase start as the only participant, so effectiveLpRatio is 1e18.
        uint256 theoreticalReward = reward;
        if (multiplier == 0) {
            return (theoreticalReward, 0);
        }
        if (totalGovPower == 0) {
            return (0, theoreticalReward);
        }
        uint256 govRatio = memberGovPower * 1e18 / totalGovPower;
        uint256 govRatioCap = govRatio * multiplier / 1e18;
        uint256 cappedRatio = govRatioCap < 1e18 ? govRatioCap : 1e18;
        mintAmount = reward * cappedRatio / 1e18;
        burnAmount = theoreticalReward - mintAmount;
    }
}
