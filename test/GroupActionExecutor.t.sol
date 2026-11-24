// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutor} from "../src/GroupActionExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
import {IMemberRewardExecutor, MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionExecutorTest is GroupActionExecutorTestBase {
    function testConstructorDerivesDependenciesAndValidates() external {
        require(executor.ACTION_TARGET_ADDRESS() == address(actionTarget), "action target");
        require(executor.joinTokenAddress(address(token), ACTION_ID) == address(joinToken), "join token stored");
        require(executor.requiredActivationStake(address(token), ACTION_ID) == ACTIVATION_STAKE, "stake stored");
        require(executor.maxJoinAmountRatio(address(token), ACTION_ID) == PRECISION, "ratio stored");
        require(executor.activationMinGovRatio(address(token), ACTION_ID) == 0, "min gov ratio stored");
        require(executor.requiredVerifierStake(address(token), ACTION_ID) == VERIFIER_STAKE, "verifier stake stored");

        _atPhase(3);
        require(executor.currentJoinRound() == 2, "join round derived from stake phase");
        require(executor.currentVerifyRound() == 1, "verify round derived from stake phase");
    }

    function testFullRoundSettleMatchesFinalScore() external {
        _prepareRound();

        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        _submitScores(_scores(100, 60));

        require(executor.isRoundVerified(address(token), 2, ACTION_ID), "round verified");
        (uint256 verifierId,,) = executor.verifier(address(token), 2, ACTION_ID);
        require(verifierId == VERIFIER_ID, "elected verifier");
        require(executor.verifiedMemberCount(address(token), 2, ACTION_ID, GROUP_ID) == 2, "cursor complete");

        uint256 memberFinal1 = 100e18 * 100;
        uint256 memberFinal2 = PROVIDER_QUOTA * 60;
        uint256 totalFinal = memberFinal1 + memberFinal2;
        require(executor.totalActionFinalScore(address(token), 2, ACTION_ID) == totalFinal, "total final score");
        require(
            executor.joinedAmountByMemberId(address(token), 2, ACTION_ID, MEMBER2_ID) == PROVIDER_QUOTA,
            "provider quota counted as join amount"
        );

        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, memberFinal1, totalFinal);
        uint256 expected2 = Math.mulDiv(PROPOSAL_REWARD, memberFinal2, totalFinal);
        require(expected1 + expected2 == PROPOSAL_REWARD - 1, "dust sanity");

        IMemberRewardExecutor rewards = IMemberRewardExecutor(address(executor));
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            rewards.memberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
        require(pending == expected1 && minted == 0 && status == MemberRewardStatus.Pending, "member reward preview");

        require(
            executor.generatedActionRewardByGroupId(address(token), 2, ACTION_ID, GROUP_ID) == PROPOSAL_REWARD,
            "group reward"
        );

        uint256 balanceBefore = token.balanceOf(MEMBER1);
        uint256 mint1 = _settle(2, MEMBER1_ID);
        require(mint1 == expected1, "member 1 minted");
        require(token.balanceOf(MEMBER1) - balanceBefore == expected1, "member 1 paid");

        balanceBefore = token.balanceOf(MEMBER2);
        uint256 mint2 = _settle(2, MEMBER2_ID);
        require(mint2 == expected2, "member 2 minted");
        require(token.balanceOf(MEMBER2) - balanceBefore == expected2, "member 2 paid");

        require(actionTarget.mintRewardCalls() == 1, "single reward pull");
        require(actionTarget.registerCalls() == 2, "join state registered");
        (pending, minted, status) = rewards.memberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
        require(pending == 0 && minted == expected1 && status == MemberRewardStatus.Settled, "settlement recorded");
    }

    function testUnverifiedRoundBlocksSettle() external {
        _prepareRound();

        _atPhase(5);
        require(
            executor.generatedActionRewardByGroupId(address(token), 2, ACTION_ID, GROUP_ID) == 0,
            "no group reward"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector,
                address(token),
                2
            )
        );
        executor.mintMemberReward(address(token), 2, ACTION_ID, MEMBER1_ID);

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            IMemberRewardExecutor(address(executor)).memberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
        require(pending == 0 && minted == 0 && status == MemberRewardStatus.Unavailable, "unverified reward unavailable");
    }

    function testPartialVerificationBlocksSettle() external {
        _prepareRound();

        _atPhase(4);
        _submitScores(_scores(100));

        require(
            executor.totalActionFinalScore(address(token), 2, ACTION_ID) == 100e18 * 100,
            "scored member counted"
        );
        require(!executor.isRoundVerified(address(token), 2, ACTION_ID), "round not complete");

        _atPhase(5);
        require(
            executor.generatedActionRewardByGroupId(address(token), 2, ACTION_ID, GROUP_ID) == 0,
            "partial batches unlock nothing"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector,
                address(token),
                2
            )
        );
        executor.mintMemberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
    }

    function testBatchMintMemberRewards() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(100, 60));
        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, 100e18 * 100, 100e18 * 100 + PROVIDER_QUOTA * 60);

        uint256[] memory actionIds = new uint256[](1);
        actionIds[0] = ACTION_ID;
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = 2;
        vm.prank(MEMBER1);
        uint256[] memory mintAmounts = IMemberRewardExecutor(address(executor))
            .mintMemberRewards(address(token), rounds, actionIds, MEMBER1_ID);
        require(mintAmounts.length == 1 && mintAmounts[0] == expected1, "batch mint amount");
        require(token.balanceOf(MEMBER1) == expected1, "batch mint paid");

        uint256[] memory mismatched = new uint256[](2);
        mismatched[0] = ACTION_ID;
        mismatched[1] = ACTION_ID;
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        executor.mintMemberRewards(address(token), rounds, mismatched, MEMBER1_ID);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.mintMemberRewards(address(token), rounds, mismatched, MEMBER1_ID);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, MEMBER1_ID, 2
            )
        );
        executor.mintMemberRewards(address(token), rounds, actionIds, MEMBER1_ID);
    }

    function testBatchSettlementLocalizesTheFailingElement() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(100, 60));
        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID + 1;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 2;

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_ID + 1)
        );
        executor.mintMemberRewards(address(token), rounds, actionIds, MEMBER1_ID);

        (,, MemberRewardStatus status) =
            IMemberRewardExecutor(address(executor)).memberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
        require(status == MemberRewardStatus.Pending, "earlier element rolled back");
        require(actionTarget.mintRewardCalls() == 0, "no action reward pulled");
    }

    function testBatchSettlementPaysTwoVerifiedActionsAtomically() external {
        uint256 secondActionId = ACTION_ID + 1;
        _createAction(secondActionId);
        _fundTokenFor(VERIFIER, VERIFIER_STAKE);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), secondActionId, VERIFIER_ID, "verifier");
        vote.setVotesNumByProposalId(address(token), CREATION_PHASE, secondActionId, 1000e18);
        _castVotesForActionAt(secondActionId, MEMBER1_ID, VERIFIER_ID, 100e18, CREATION_PHASE);

        _prepareRound();
        _activateGroupOn(address(token), secondActionId, GROUP_ID);
        _fundJoinTokenFor(MEMBER1, 100e18);
        _joinOn(address(token), secondActionId, GROUP_ID, MEMBER1_ID, 100e18);

        _atPhase(4);
        _submitScores(_scores(100, 60));
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), secondActionId, VERIFIER_ID, GROUP_ID, 0, _scores(100));
        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD * 2);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        actionTarget.setActionReward(address(token), 2, secondActionId, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = secondActionId;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 2;
        uint256 expectedFirst = Math.mulDiv(
            PROPOSAL_REWARD, 100e18 * 100, 100e18 * 100 + PROVIDER_QUOTA * 60
        );
        uint256 expectedSecond = PROPOSAL_REWARD;

        vm.prank(MEMBER1);
        uint256[] memory amounts = executor.mintMemberRewards(address(token), rounds, actionIds, MEMBER1_ID);
        require(amounts.length == 2, "one result per action");
        require(amounts[0] == expectedFirst && amounts[1] == expectedSecond, "results follow input order");
        require(token.balanceOf(MEMBER1) == expectedFirst + expectedSecond, "both rewards are paid");
        require(actionTarget.mintRewardCalls() == 2, "each action budget is minted once");
    }

    function testJoinedAmountQueryGuards() external {
        _prepareRound();

        require(executor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 100e18 + PROVIDER_QUOTA, "round total");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 3, 2));
        executor.joinedAmountByActionId(address(token), 3, ACTION_ID);
        require(
            executor.joinedAmountByMemberId(address(token), 2, ACTION_ID, MEMBER1_ID) == 100e18,
            "member round amount"
        );
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 3, 2));
        executor.joinedAmountByMemberId(address(token), 3, ACTION_ID, MEMBER1_ID);
        require(executor.joinTokenAddress(address(token), ACTION_ID) == address(joinToken), "join token");
        require(executor.currentJoinRound() == 2, "join round getter");
        require(executor.currentVoteRound() == 3, "vote round getter");
    }

    function testProviderQuotaAndAmountsConsistency() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 250e18);

        uint256 secondProviderId = 11;
        address secondProvider = address(0x1008);
        memberNFT.setOwner(secondProviderId, secondProvider);
        _fundJoinTokenFor(secondProvider, 100e18);

        _grantQuota(PROVIDER_ID, MEMBER2_ID, 200e18);
        uint256[] memory ids = _ids(MEMBER2_ID);
        vm.prank(secondProvider);
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, secondProviderId, ids, _ids(100e18));
        _grantQuota(PROVIDER_ID, MEMBER1_ID, 50e18);

        vm.prank(MEMBER2);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 120e18, PROVIDER_ID, new string[](0));
        vm.prank(MEMBER2);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 80e18, secondProviderId, new string[](0));
        _join(MEMBER1_ID, 50e18, PROVIDER_ID);

        (uint256[] memory providerIds, uint256[] memory amounts, uint256 total) =
            executor.providerAmountsByMemberId(address(token), 2, ACTION_ID, MEMBER2_ID, 0, 10, false);
        require(total == 2, "two sources");
        require(providerIds[0] == PROVIDER_ID && amounts[0] == 120e18, "first source");
        require(providerIds[1] == secondProviderId && amounts[1] == 80e18, "second source");
        require(
            amounts[0] + amounts[1] == executor.joinedAmountByMemberId(address(token), 2, ACTION_ID, MEMBER2_ID),
            "sources sum to join amount"
        );

        (uint256[] memory memberIds, uint256[] memory quotaAmounts, uint256[] memory used, uint256 quotaTotal) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(quotaTotal == 2, "fully used grant stays listed");
        require(memberIds[0] == MEMBER2_ID && quotaAmounts[0] == 200e18 && used[0] == 120e18, "partially used row");
        require(memberIds[1] == MEMBER1_ID && quotaAmounts[1] == 50e18 && used[1] == 50e18, "fully used row");
        (memberIds, quotaAmounts, used, quotaTotal) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, secondProviderId, 0, 10, false);
        require(quotaTotal == 1 && memberIds[0] == MEMBER2_ID, "second quota table");
        require(quotaAmounts[0] == 100e18 && used[0] == 80e18, "second grant tracked");
    }

    function testRoundGettersAndGuards() external {
        require(executor.currentVoteRound() == 2, "vote round at creation");
        require(executor.currentJoinRound() == 1, "join round at creation");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.currentMintRound();

        GroupActionExecutor fresh;
        {
            fresh = new GroupActionExecutor(address(actionTarget));
        }

        phase.setCurrentPhase(0);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentVoteRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentJoinRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentMintRound();

        phase.setCurrentPhase(1);
        require(fresh.currentVoteRound() == 1, "vote at phase 1");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentJoinRound();

        phase.setCurrentPhase(2);
        require(fresh.currentJoinRound() == 1, "join at phase 2");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentVerifyRound();

        phase.setCurrentPhase(3);
        require(fresh.currentVerifyRound() == 1, "verify at phase 3");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        fresh.currentMintRound();

        phase.setCurrentPhase(4);
        require(fresh.currentMintRound() == 1, "mint at phase 4");
    }

    function testZeroTotalScoreBlocksSettle() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(0, 0));

        require(executor.isRoundVerified(address(token), 2, ACTION_ID), "verified");
        require(executor.totalActionFinalScore(address(token), 2, ACTION_ID) == 0, "zero total");

        _atPhase(5);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector,
                address(token),
                2
            )
        );
        executor.mintMemberReward(address(token), 2, ACTION_ID, MEMBER1_ID);
    }

    function testMintRejectsAnUncreatedAction() external {
        _atPhase(4);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_ID + 1)
        );
        executor.mintMemberReward(address(token), 2, ACTION_ID + 1, MEMBER1_ID);
    }

    function testMintChecksOwnerBeforeActionExistence() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.mintMemberReward(address(token), 2, ACTION_ID + 1, MEMBER1_ID);
    }

    function testMintRoundGuards() external {
        _prepareRound();
        _atPhase(5);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, 1, 2)
        );
        executor.mintMemberReward(address(token), 1, ACTION_ID, MEMBER1_ID);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 3, 2));
        executor.mintMemberReward(address(token), 3, ACTION_ID, MEMBER1_ID);
    }

    /// @dev The action is reusable: a later round re-submits it, the community votes again, members
    ///      join, a verifier is locked from that round's own ranking, and the round settles on its
    ///      own weights. No state from the creation round leaks into the reused one.
    function testCrossRoundReuseRunsTheWholePipeline() external {
        _submitApplication();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();

        // Round 5: the proposal is submitted again and the ranking is built from round 5 votes only.
        // The application submitted in the creation round still stands, so nobody has to re-apply.
        _atPhase(5);
        vote.setVotesNum(address(token), 5, 1000e18);
        vote.setVotesNumByProposalId(address(token), 5, ACTION_ID, 1000e18);
        require(
            executor.verifierApplication(address(token), 5, ACTION_ID, VERIFIER_ID).applicationId
                == executor.verifierApplication(address(token), CREATION_PHASE, ACTION_ID, VERIFIER_ID).applicationId,
            "the creation-round application still stands"
        );
        _castVotesForAt(VERIFIER_ID, 100e18, 5);

        (uint256 round5Verifier,, uint256 round5Votes) = executor.verifier(address(token), 5, ACTION_ID);
        require(round5Verifier == VERIFIER_ID && round5Votes == 100e18, "round 5 election");
        (uint256 creationVerifier,,) = executor.verifier(address(token), CREATION_PHASE, ACTION_ID);
        require(creationVerifier == 0, "creation round has no votes");

        _atPhase(6);
        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 100e18, 0);
        require(
            executor.joinedAmountByMemberId(address(token), 5, ACTION_ID, MEMBER1_ID) == 100e18,
            "round 5 participation"
        );

        _atPhase(7);
        _submitScores(_scores(100));
        require(executor.isRoundVerified(address(token), 5, ACTION_ID), "round 5 verified");
        (uint256 verifierId,,) = executor.verifier(address(token), 5, ACTION_ID);
        require(verifierId == VERIFIER_ID, "round 5 verifier");

        _atPhase(8);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), 5, ACTION_ID, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        uint256 mintAmount = _settle(5, MEMBER1_ID);
        require(mintAmount == PROPOSAL_REWARD, "round 5 settles on its own weights");
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
