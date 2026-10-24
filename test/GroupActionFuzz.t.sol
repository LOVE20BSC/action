// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionFuzzTest is GroupActionExecutorTestBase {
    uint256 internal constant ACTION_2 = 22;

    function testFuzzVerifierStakeRoundTrip(uint96 stakeSeed) external {
        uint256 stake = uint256(stakeSeed);
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, stake));
        token.mint(VERIFIER, stake);

        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "v");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == stake, "stake recorded");
        require(token.balanceOf(VERIFIER) == before - stake, "stake pulled");
        require(token.balanceOf(address(executor)) == stake, "executor holds the stake");

        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "v2");
        require(token.balanceOf(VERIFIER) == before - stake, "replace does not stake twice");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_2, VERIFIER_ID);
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == 0, "stake cleared");
        require(token.balanceOf(VERIFIER) == before, "stake refunded");
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
    }
    function testFuzzJoinAppendAndWithdrawConserveAmounts(uint96 seed1, uint96 seed2) external {
        _openJoinPhase();
        uint256 amount1 = uint256(seed1) % 100e18 + 1e18;
        uint256 amount2 = uint256(seed2) % 50e18 + 1e18;
        _fundJoinTokenFor(MEMBER1, amount1 + amount2);

        _join(MEMBER1_ID, amount1, 0);
        _join(MEMBER1_ID, amount2, 0);

        (uint256 joinedRound, uint256 amount, , uint256 ownAmount, ) =
            executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(joinedRound == 2 && amount == amount1 + amount2 && ownAmount == amount1 + amount2, "appends");

        _withdraw(MEMBER1_ID, amount2 + 1);
        (, amount, , ownAmount, ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(amount == amount1 + amount2 - amount2 - 1 && ownAmount == amount, "partial withdraw");
        require(
            executor.totalJoinedAmountByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == amount,
            "group total tracks"
        );
        require(joinToken.balanceOf(address(executor)) == amount, "balance conserved");
    }

    function testFuzzScoreDecodingAndAccumulation(uint8 scoreSeed) external {
        uint256 score = uint256(scoreSeed) % 101;
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(score));

        (uint256 decoded, bool verified) = executor.originScore(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(verified && decoded == score, "origin decode");
        (uint256 finalScore, bool finalVerified) = executor.finalScore(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(finalVerified && finalScore == 100e18 * score, "final score");
        require(executor.totalFinalScore(address(token), ACTION_ID, 2) == 100e18 * score, "total accumulates");
    }

    function testFuzzSettleSplitsMatchFinalScore(uint8 score1Seed, uint8 score2Seed) external {
        uint256 score1 = uint256(score1Seed) % 101;
        uint256 score2 = uint256(score2Seed) % 101;
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(score1, score2));

        uint256 final1 = 100e18 * score1;
        uint256 final2 = PROVIDER_QUOTA * score2;
        uint256 total = final1 + final2;

        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        if (total == 0) {
            vm.prank(MEMBER1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                    address(token),
                    ACTION_ID,
                    MEMBER1_ID,
                    2
                )
            );
            executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
            return;
        }

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, final1, total);
        uint256 expected2 = Math.mulDiv(PROPOSAL_REWARD, final2, total);

        uint256 mint1;
        if (expected1 == 0) {
            vm.prank(MEMBER1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                    address(token),
                    ACTION_ID,
                    MEMBER1_ID,
                    2
                )
            );
            executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        } else {
            (mint1,) = _settle(MEMBER1_ID, 2);
        }

        uint256 mint2;
        if (expected2 == 0) {
            vm.prank(MEMBER2);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                    address(token),
                    ACTION_ID,
                    MEMBER2_ID,
                    2
                )
            );
            executor.mintMemberReward(address(token), ACTION_ID, MEMBER2_ID, 2);
        } else {
            (mint2,) = _settle(MEMBER2_ID, 2);
        }
        require(mint1 == expected1 && mint2 == expected2, "split formula");
        require(mint1 + mint2 <= PROPOSAL_REWARD, "budget bound");
        require(token.balanceOf(MEMBER1) == expected1 && token.balanceOf(MEMBER2) == expected2, "paid out");
    }

    function testFuzzProviderQuotaUseAndRefund(uint96 grantSeed, uint96 useSeed) external {
        _openJoinPhase();
        uint256 grant = uint256(grantSeed) % 200e18 + 1e18;
        _fundJoinTokenFor(PROVIDER, grant);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, grant);

        // Joins respect the group's 1e18 minimum, so the fuzzed usage stays at or above it.
        uint256 use = uint256(useSeed) % (grant - 1e18 + 1) + 1e18;
        _join(MEMBER2_ID, use, PROVIDER_ID);
        uint256 remaining = grant - use;

        (uint256[] memory memberIds, uint256[] memory amounts, , uint256 total) =
            executor.providerQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        if (remaining == 0) {
            require(total == 0, "exhausted quota leaves the set");
        } else {
            require(total == 1 && memberIds[0] == MEMBER2_ID && amounts[0] == remaining, "remainder reflected");
        }

        uint256 providerBefore = joinToken.balanceOf(PROVIDER);
        if (remaining != 0) {
            _quotaRemove(PROVIDER_ID, MEMBER2_ID);
            require(joinToken.balanceOf(PROVIDER) - providerBefore == remaining, "unused refunded");
        }
        require(joinToken.balanceOf(address(executor)) == use, "used part stays");
    }

    function testFuzzSetPageBounds(uint8 offsetSeed, uint8 limitSeed) external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 1e18);
        _fundJoinTokenFor(MEMBER2, 1e18);
        _fundJoinTokenFor(PROVIDER, 1e18);
        _join(MEMBER1_ID, 1e18, 0);
        _join(MEMBER2_ID, 1e18, 0);
        _join(PROVIDER_ID, 1e18, 0);

        uint256 offset = uint256(offsetSeed) % 6;
        uint256 limit = uint256(limitSeed) % 6;
        uint256 expected;
        if (limit != 0 && offset < 3) {
            expected = limit < 3 - offset ? limit : 3 - offset;
        }

        (uint256[] memory page, uint256 total) =
            executor.gMemberIdsByGroupId(GROUP_ID, offset, limit, false);
        require(total == 3 && page.length == expected, "page bounds");
        (page, ) = executor.gMemberIdsByGroupId(GROUP_ID, offset, limit, true);
        require(page.length == expected, "reverse page bounds");
    }

    function testFuzzJoinedAmountRoundGuard(uint96 amountSeed, uint8 aheadSeed) external {
        _openJoinPhase();
        uint256 amount = uint256(amountSeed) % 100e18 + 1e18;
        _fundJoinTokenFor(MEMBER1, amount);
        _join(MEMBER1_ID, amount, 0);

        require(executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER1_ID) == amount, "current");
        uint256 ahead = uint256(aheadSeed) % 10 + 3;
        require(executor.joinedAmountByMemberId(address(token), ACTION_ID, ahead, MEMBER1_ID) == 0, "future zero");
        require(executor.joinedAmount(address(token), ACTION_ID, ahead) == 0, "future total zero");
    }

    function _scores(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _scores(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }
}
