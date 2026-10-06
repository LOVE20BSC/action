// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {LpExecutorTestBase} from "./LpExecutorTestBase.sol";

contract LpExecutorFuzzTest is LpExecutorTestBase {
    function testFuzzJoinDeductionFormula(uint96 amount, uint16 elapsed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == joinAmount * joinElapsed / PHASE_BLOCKS, "deduction formula");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == deduction, "total deduction");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == joinAmount,
            "balance recorded"
        );
    }

    function testFuzzJoinDeductionCapsAtAmount(uint96 amount, uint16 elapsed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = PHASE_BLOCKS + (uint256(elapsed) % PHASE_BLOCKS);
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == joinAmount, "deduction capped at the amount");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == joinAmount, "total capped");
    }

    function testFuzzWithdrawScalesDeduction(uint96 amount, uint16 elapsed, uint96 withdrawSeed) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);
        uint256 deductionBefore = lpExecutor.totalDeduction(address(token), ACTION_ID, 2);
        uint256 withdrawAmount = uint256(withdrawSeed) % joinAmount + 1;

        _withdraw(1, withdrawAmount);

        if (withdrawAmount == joinAmount) {
            require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "full withdraw takes all");
            require(
                lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 0,
                "balance cleared"
            );
        } else {
            uint256 reduction = deductionBefore * withdrawAmount / joinAmount;
            require(
                lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == joinAmount - withdrawAmount,
                "balance reduced"
            );
            require(
                lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == deductionBefore - reduction,
                "deduction reduced proportionally"
            );
        }
    }

    function testFuzzRewardSplitMatchesReference(
        uint96 rewardSeed,
        uint96 validSeed,
        uint96 globalSeed,
        uint96 multiplierSeed
    ) external {
        uint256 reward = uint256(rewardSeed) % 1e27 + 1;
        uint256 validVotes = uint256(validSeed) % 1e24;
        uint256 globalVotes = uint256(globalSeed) % 1e24;
        uint256 multiplier = uint256(multiplierSeed) % 3e18;

        _createActionWithConfig(SECOND_ACTION_ID, multiplier, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        stake.setValidGovVotes(address(token), 1, validVotes);
        stake.setGlobalGovVotes(address(token), globalVotes);
        _atPhase(4);
        _setActionReward(SECOND_ACTION_ID, 2, reward, true);
        _fundExecutor(reward);

        (uint256 expectedMint, uint256 expectedBurn) =
            _referenceReward(reward, validVotes, globalVotes, multiplier);
        (uint256 pendingMint, uint256 pendingBurn, bool mintedBefore) =
            lpExecutor.memberReward(address(token), SECOND_ACTION_ID, 1, 2);
        require(mintedBefore == false, "not minted yet");
        require(pendingMint == expectedMint && pendingBurn == expectedBurn, "pending matches the reference");

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(SECOND_ACTION_ID, 1, 2);
        require(mintAmount == expectedMint && burnAmount == expectedBurn, "split matches the reference");
        require(mintAmount + burnAmount == reward, "reward is conserved");
    }

    function testFuzzNeedBurnRewardMatchesModel(uint96 amount, uint16 elapsed, bool fullWithdraw) external {
        uint256 joinAmount = uint256(amount) + 1;
        uint256 joinElapsed = uint256(elapsed) % PHASE_BLOCKS;
        _atPhaseBlock(3, 3000 + joinElapsed);
        _join(1, joinAmount);

        if (fullWithdraw) {
            _withdraw(1, joinAmount);
        }
        _atPhase(4);
        require(lpExecutor.needBurnReward(address(token), ACTION_ID, 2) == fullWithdraw, "burn judgement");
    }

    function testFuzzGovRatioFloor(uint96 validSeed, uint96 globalSeed) external {
        uint256 globalVotes = uint256(globalSeed) % 1e24 + 1;
        uint256 validVotes = uint256(validSeed) % 1e24;
        stake.setGlobalGovVotes(address(token), globalVotes);
        stake.setValidGovVotes(address(token), 1, validVotes);

        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(minted == false && ratio == validVotes * 1e18 / globalVotes, "floor division");
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
        lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);
    }

    function _referenceReward(
        uint256 reward,
        uint256 validVotes,
        uint256 globalVotes,
        uint256 multiplier
    ) internal pure returns (uint256 mintAmount, uint256 burnAmount) {
        // The member joined at the phase start as the only participant, so effectiveLpRatio is 1e18.
        uint256 theoreticalReward = reward;
        if (multiplier == 0) {
            return (theoreticalReward, 0);
        }
        if (globalVotes == 0) {
            return (0, theoreticalReward);
        }
        uint256 govRatio = validVotes * 1e18 / globalVotes;
        uint256 govRatioCap = govRatio * multiplier / 1e18;
        uint256 cappedRatio = govRatioCap < 1e18 ? govRatioCap : 1e18;
        mintAmount = reward * cappedRatio / 1e18;
        burnAmount = theoreticalReward - mintAmount;
    }
}
