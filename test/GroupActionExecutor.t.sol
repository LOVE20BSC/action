// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutor} from "../src/GroupActionExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionExecutorTest is GroupActionExecutorTestBase {
    function testInitDerivesDependenciesAndValidates() external {
        require(executor.initialized(), "initialized");
        require(executor.actionTarget() == address(actionTarget), "action target");
        require(executor.JOIN_TOKEN_ADDRESS(address(token), ACTION_ID) == address(joinToken), "join token stored");
        require(executor.ACTIVATION_STAKE_AMOUNT(address(token), ACTION_ID) == ACTIVATION_STAKE, "stake stored");
        require(executor.MAX_JOIN_AMOUNT_RATIO(address(token), ACTION_ID) == PRECISION, "ratio stored");
        require(executor.ACTIVATION_MIN_GOV_RATIO(address(token), ACTION_ID) == 0, "min gov ratio stored");
        require(executor.VERIFIER_STAKE_AMOUNT(address(token), ACTION_ID) == VERIFIER_STAKE, "verifier stake stored");
        uint256[] memory splits = executor.SPLITS();
        require(splits.length == 1 && splits[0] == 5e17, "splits stored");

        _atPhase(3);
        require(executor.currentJoinRound() == 2, "join round derived from stake phase");
        require(executor.currentVerifyRound() == 1, "verify round derived from stake phase");

        uint256[] memory again = new uint256[](1);
        again[0] = 5e17;
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.AlreadyInitialized.selector));
        executor.init(address(actionTarget), address(stake), again);

        GroupActionExecutor fresh = new GroupActionExecutor();
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidAddress.selector));
        fresh.init(address(0), address(stake), again);

        GroupActionExecutor badSplits = new GroupActionExecutor();
        uint256[] memory zeroSplits = new uint256[](1);
        zeroSplits[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidSplits.selector));
        badSplits.init(address(actionTarget), address(stake), zeroSplits);
    }

    function testFullRoundSettleMatchesFinalScore() external {
        _prepareRound();

        _atPhase(4);
        _submitScores(_scores(100, 60));

        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "round verified");
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "verifier locked");
        require(executor.verifiedMemberCount(address(token), ACTION_ID, 2, GROUP_ID) == 2, "cursor complete");

        uint256 memberFinal1 = 100e18 * 100;
        uint256 memberFinal2 = PROVIDER_QUOTA * 60;
        uint256 totalFinal = memberFinal1 + memberFinal2;
        require(executor.totalFinalScore(address(token), ACTION_ID, 2) == totalFinal, "total final score");
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID) == PROVIDER_QUOTA,
            "provider quota counted as join amount"
        );

        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, memberFinal1, totalFinal);
        uint256 expected2 = Math.mulDiv(PROPOSAL_REWARD, memberFinal2, totalFinal);
        require(expected1 + expected2 == PROPOSAL_REWARD - 1, "dust sanity");

        (uint256 viewAmount, uint256 viewBurn, bool viewMinted) =
            executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == expected1 && viewBurn == 0 && !viewMinted, "member reward preview");

        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == PROPOSAL_REWARD,
            "group reward"
        );

        uint256 balanceBefore = token.balanceOf(MEMBER1);
        (uint256 mint1, uint256 burn1) = _settle(MEMBER1_ID, 2);
        require(mint1 == expected1 && burn1 == 0, "member 1 minted");
        require(token.balanceOf(MEMBER1) - balanceBefore == expected1, "member 1 paid");

        balanceBefore = token.balanceOf(MEMBER2);
        (uint256 mint2, uint256 burn2) = _settle(MEMBER2_ID, 2);
        require(mint2 == expected2 && burn2 == 0, "member 2 minted");
        require(token.balanceOf(MEMBER2) - balanceBefore == expected2, "member 2 paid");

        require(actionTarget.mintRewardCalls() == 1, "single reward pull");
        require(actionTarget.registerCalls() == 2, "join state registered");
        (viewAmount, viewBurn, viewMinted) = executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == expected1 && viewBurn == 0 && viewMinted, "minted flag recorded");
    }

    function testUnverifiedRoundBlocksSettle() external {
        _prepareRound();

        _atPhase(5);
        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 0,
            "no group reward"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);

        (uint256 viewAmount, uint256 viewBurn, bool viewMinted) =
            executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == 0 && viewBurn == 0 && !viewMinted, "unsettled round stays pending");
    }

    function testPartialVerificationBlocksSettle() external {
        _prepareRound();

        _atPhase(4);
        _submitScores(_scores(100));

        require(
            executor.totalFinalScore(address(token), ACTION_ID, 2) == 100e18 * 100,
            "scored member counted"
        );
        require(!executor.isRoundVerified(address(token), ACTION_ID, 2), "round not complete");

        _atPhase(5);
        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 0,
            "partial batches unlock nothing"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
    }

    function testBatchMintMemberRewards() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(100, 60));
        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, 100e18 * 100, 100e18 * 100 + PROVIDER_QUOTA * 60);

        uint256[] memory actionIds = new uint256[](1);
        actionIds[0] = ACTION_ID;
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = 2;
        vm.prank(MEMBER1);
        (uint256[] memory mintAmounts, uint256[] memory burnAmounts) =
            executor.mintMemberRewards(address(token), actionIds, MEMBER1_ID, rounds);
        require(mintAmounts[0] == expected1 && burnAmounts[0] == 0, "batch mint amount");
        require(token.balanceOf(MEMBER1) == expected1, "batch mint paid");

        uint256[] memory mismatched = new uint256[](2);
        mismatched[0] = ACTION_ID;
        mismatched[1] = ACTION_ID;
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        executor.mintMemberRewards(address(token), mismatched, MEMBER1_ID, rounds);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.mintMemberRewards(address(token), mismatched, MEMBER1_ID, rounds);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, MEMBER1_ID, 2
            )
        );
        executor.mintMemberRewards(address(token), actionIds, MEMBER1_ID, rounds);
    }

    function testJoinedAmountQueryGuards() external {
        _prepareRound();

        require(executor.joinedAmount(address(token), ACTION_ID, 2) == 100e18 + PROVIDER_QUOTA, "round total");
        require(executor.joinedAmount(address(token), ACTION_ID, 3) == 0, "future round zero");
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER1_ID) == 100e18,
            "member round amount"
        );
        require(executor.joinedAmountByMemberId(address(token), ACTION_ID, 3, MEMBER1_ID) == 0, "member future zero");
        require(executor.joinedAmountTokenAddress(address(token), ACTION_ID) == address(joinToken), "join token");
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
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, secondProviderId, ids, _ids(100e18));
        _grantQuota(PROVIDER_ID, MEMBER1_ID, 50e18);

        vm.prank(MEMBER2);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 120e18, PROVIDER_ID, new string[](0));
        vm.prank(MEMBER2);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 80e18, secondProviderId, new string[](0));
        _join(MEMBER1_ID, 50e18, PROVIDER_ID);

        (uint256[] memory providerIds, uint256[] memory amounts, uint256 total) =
            executor.providerAmountsByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID, 0, 10, false);
        require(total == 2, "two sources");
        require(providerIds[0] == PROVIDER_ID && amounts[0] == 120e18, "first source");
        require(providerIds[1] == secondProviderId && amounts[1] == 80e18, "second source");
        require(
            amounts[0] + amounts[1] == executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID),
            "sources sum to join amount"
        );

        (uint256[] memory memberIds, uint256[] memory quotaAmounts, , uint256 quotaTotal) =
            executor.providerQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(quotaTotal == 1 && memberIds[0] == MEMBER2_ID && quotaAmounts[0] == 80e18, "quota table");
        (memberIds, quotaAmounts, , quotaTotal) =
            executor.providerQuota(address(token), ACTION_ID, GROUP_ID, secondProviderId, 0, 10, false);
        require(quotaTotal == 1 && memberIds[0] == MEMBER2_ID && quotaAmounts[0] == 20e18, "second quota table");
    }

    function testRoundGettersAndGuards() external {
        require(executor.currentVoteRound() == 2, "vote round at creation");
        require(executor.currentJoinRound() == 1, "join round at creation");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.currentMintRound();

        GroupActionExecutor fresh = new GroupActionExecutor();
        uint256[] memory splits = new uint256[](1);
        splits[0] = 5e17;
        fresh.init(address(actionTarget), address(stake), splits);

        phase.setCurrentPhase(0);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentVoteRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentJoinRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentMintRound();

        phase.setCurrentPhase(1);
        require(fresh.currentVoteRound() == 1, "vote at phase 1");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentJoinRound();

        phase.setCurrentPhase(2);
        require(fresh.currentJoinRound() == 1, "join at phase 2");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentVerifyRound();

        phase.setCurrentPhase(3);
        require(fresh.currentVerifyRound() == 1, "verify at phase 3");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        fresh.currentMintRound();

        phase.setCurrentPhase(4);
        require(fresh.currentMintRound() == 1, "mint at phase 4");
    }

    function testZeroTotalScoreBlocksSettle() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(0, 0));

        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "verified");
        require(executor.totalFinalScore(address(token), ACTION_ID, 2) == 0, "zero total");

        _atPhase(5);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
    }

    function testMintRejectsAnUncreatedAction() external {
        _atPhase(4);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_ID + 1)
        );
        executor.mintMemberReward(address(token), ACTION_ID + 1, MEMBER1_ID, 2);
    }

    function testMintChecksOwnerBeforeActionExistence() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.mintMemberReward(address(token), ACTION_ID + 1, MEMBER1_ID, 2);
    }

    function testMintRoundGuards() external {
        _prepareRound();
        _atPhase(5);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.InvalidRound.selector, 3));
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 3);
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
            executor.verifierApplication(address(token), ACTION_ID, 5, VERIFIER_ID).applicationId
                == executor.verifierApplication(address(token), ACTION_ID, CREATION_PHASE, VERIFIER_ID).applicationId,
            "the creation-round application still stands"
        );
        _castVotesForAt(VERIFIER_ID, 100e18, 5);

        (uint256[] memory rankedIds, uint256[] memory rankedVotes) =
            executor.topVerifiers(address(token), ACTION_ID, 5);
        require(rankedIds.length == 1 && rankedIds[0] == VERIFIER_ID, "round 5 ranking");
        require(rankedVotes[0] == 100e18, "round 5 tally");
        (uint256[] memory creationIds, ) = executor.topVerifiers(address(token), ACTION_ID, CREATION_PHASE);
        require(creationIds.length == 0, "the creation round keeps its own ranking");

        _atPhase(6);
        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 100e18, 0);
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 5, MEMBER1_ID) == 100e18,
            "round 5 participation"
        );

        _atPhase(7);
        _submitScores(_scores(100));
        require(executor.isRoundVerified(address(token), ACTION_ID, 5), "round 5 verified");
        require(executor.lockedVerifierId(address(token), ACTION_ID, 5) == VERIFIER_ID, "round 5 verifier");

        _atPhase(8);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 5, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        (uint256 mintAmount, uint256 burnAmount) = _settle(MEMBER1_ID, 5);
        require(mintAmount == PROPOSAL_REWARD && burnAmount == 0, "round 5 settles on its own weights");
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
