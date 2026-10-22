// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
import {IGroupActionVerifyErrors} from "../src/interfaces/IGroupActionVerify.sol";
import {VerifierApplication} from "../src/interfaces/IGroupActionVerify.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionVerifyFlowTest is GroupActionExecutorTestBase {
    uint256 internal constant ACTION_2 = 22;
    uint256 internal constant VERIFIER2_ID = 10;

    address internal constant VERIFIER2 = address(0x1007);

    function testVerifierApplicationLifecycle() external {
        _submitApplication();
        _castVotesFor(VERIFIER_ID, 100e18);
        (uint256[] memory verifierIds, uint256[] memory votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 1 && verifierIds[0] == VERIFIER_ID && votes[0] == 100e18, "single candidate");

        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setValidGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        _castVotesFor(VERIFIER2_ID, 150e18);

        (verifierIds, votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 2, "two candidates");
        require(verifierIds[0] == VERIFIER2_ID && verifierIds[1] == VERIFIER_ID, "votes descending");
        require(votes[0] == 150e18 && votes[1] == 100e18, "ranked votes");

        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2b");
        (verifierIds, votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 1 && verifierIds[0] == VERIFIER_ID, "replaced candidate leaves the rank");
        uint256[] memory replacedIds = new uint256[](1);
        replacedIds[0] = VERIFIER2_ID;
        uint256[] memory replacedVotes = executor.votesByVerifierIds(address(token), ACTION_ID, 2, replacedIds);
        require(replacedVotes[0] == 0, "the replacement starts at zero in this round");

        VerifierApplication memory application =
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER2_ID);
        require(application.applicationId == 3, "current application advanced");
        require(keccak256(bytes(application.description)) == keccak256(bytes("v2b")), "description replaced");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        (verifierIds, ) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 0, "cancelled candidate leaves the rank");

        (VerifierApplication[] memory applications, uint256 total) =
            executor.verifierApplications(address(token), ACTION_ID, 0, 10, false);
        require(total == 1 && applications[0].applicationId == 3, "active applications");
        application = executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID);
        require(application.applicationId == 0, "cancelled member has no application");

        uint256[] memory ids = new uint256[](2);
        ids[0] = VERIFIER_ID;
        ids[1] = VERIFIER2_ID;
        uint256[] memory currentVotes = executor.votesByVerifierIds(address(token), ACTION_ID, 2, ids);
        require(currentVotes[0] == 0 && currentVotes[1] == 0, "no votes on current applications");
    }

    function testOpenBlockGatingByRank() external {
        _submitApplication();
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setValidGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        _castVotesFor(VERIFIER_ID, 100e18);
        _castVotesFor(VERIFIER2_ID, 200e18);

        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();
        _fundJoinTokenFor(MEMBER1, 1e18);
        _join(MEMBER1_ID, 1e18, 0);

        _atPhase(4);
        // splits = [5e17] => the second rank opens 500 blocks into the verify phase.
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.InvalidCandidate.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _scores(100));

        vm.roll(4 * PHASE_BLOCKS + 499);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.InvalidCandidate.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _scores(100));

        vm.roll(4 * PHASE_BLOCKS + 500);
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _scores(100));
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "rank 2 verified");
    }

    function testOriginScoreSubmissionReverts() external {
        _prepareRound();
        _atPhase(4);

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.OriginScoresEmpty.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, new uint256[](0));

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.VerificationBatchTooLarge.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, new uint256[](101));

        uint256[] memory overMax = new uint256[](1);
        overMax[0] = 101;
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreExceedsMax.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, overMax);

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.StartIndexMismatch.selector, 0, 1));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _scores(100));

        uint256[] memory tooMany = new uint256[](3);
        tooMany[0] = 100;
        tooMany[1] = 90;
        tooMany[2] = 80;
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoresExceedAccountCount.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, tooMany);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, VERIFIER_ID));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _scores(100));

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationNotActive.selector));
        executor.submitOriginScores(address(token), ACTION_ID, MEMBER2_ID, GROUP_ID, 0, _scores(100));

        _submitScores(_scores(100));
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "locked after first batch");

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionVerifyErrors.VerifierAlreadyLocked.selector, address(token), ACTION_ID, 2
            )
        );
        executor.submitOriginScores(address(token), ACTION_ID, MEMBER2_ID, GROUP_ID, 1, _scores(90));

        uint256[] memory secondBatch = new uint256[](1);
        secondBatch[0] = 90;
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, secondBatch);
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "round verified");

        uint256[] memory again = new uint256[](1);
        again[0] = 50;
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.AlreadyVerified.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 2, again);
    }

    function testSchemaAndVerificationInfoFlow() external {
        bytes[] memory data = new bytes[](7);
        bytes[] memory baseData = _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, VERIFIER_STAKE);
        for (uint256 i = 0; i < 6; i++) {
            data[i] = baseData[i];
        }
        string[] memory keys = new string[](2);
        keys[0] = "name";
        keys[1] = "city";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "n";
        descriptions[1] = "c";
        data[6] = abi.encode(keys, descriptions);
        _createActionWith(ACTION_2, data);

        (string[] memory schemaKeys, string[] memory schemaDescriptions) =
            executor.verificationSchema(address(token), ACTION_2);
        require(schemaKeys.length == 2 && schemaDescriptions.length == 2, "schema stored");
        require(keccak256(bytes(schemaKeys[0])) == keccak256(bytes("name")), "schema key");

        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        vote.setVotesNumByProposalId(address(token), 2, ACTION_2, 1000e18);
        _activateGroupOn(address(token), ACTION_2, GROUP_ID);
        _fundJoinTokenFor(MEMBER1, 10e18);

        string[] memory shortInfos = new string[](1);
        shortInfos[0] = "alice";
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.VerificationInfoLengthMismatch.selector));
        executor.join(address(token), ACTION_2, GROUP_ID, MEMBER1_ID, 1e18, 0, shortInfos);

        string[] memory infos = new string[](2);
        infos[0] = "alice";
        infos[1] = "sh";
        vm.prank(MEMBER1);
        executor.join(address(token), ACTION_2, GROUP_ID, MEMBER1_ID, 1e18, 0, infos);

        require(
            keccak256(bytes(executor.verificationValue(address(token), ACTION_2, MEMBER1_ID, "name")))
                == keccak256(bytes("alice")),
            "value by key"
        );
        (string[] memory valueKeys, string[] memory values) =
            executor.verificationInfos(address(token), ACTION_2, MEMBER1_ID);
        require(valueKeys.length == 2 && keccak256(bytes(values[1])) == keccak256(bytes("sh")), "infos latest");
        (valueKeys, values) = executor.verificationInfosByRound(address(token), ACTION_2, MEMBER1_ID, 2);
        require(values.length == 2 && keccak256(bytes(values[0])) == keccak256(bytes("alice")), "infos by round");
        require(
            bytes(executor.verificationValue(address(token), ACTION_2, MEMBER1_ID, "missing")).length == 0,
            "unknown key empty"
        );

        vm.prank(MEMBER1);
        executor.join(address(token), ACTION_2, GROUP_ID, MEMBER1_ID, 1e18, 0, new string[](0));
        require(
            keccak256(bytes(executor.verificationValue(address(token), ACTION_2, MEMBER1_ID, "name")))
                == keccak256(bytes("alice")),
            "values kept on append"
        );
    }

    function testCallbackGuards() external {
        bytes[] memory votedData = new bytes[](2);
        votedData[0] = abi.encode(address(executor));
        votedData[1] = abi.encode(VERIFIER_ID);

        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.UnauthorizedCallback.selector));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 1, votedData);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.UnauthorizedCallback.selector));
        executor.onProposalSubmitted(address(token), ACTION_ID, 0, votedData);

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationNotActive.selector));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 1, votedData);

        _submitApplication();
        // An application stands for its creation round and every round after it, so a vote for a later
        // round is accepted; a vote for a round before it existed is not reachable in practice, and the
        // missing-candidate guard above already covers the only real rejection.
        bytes[] memory zeroCandidate = new bytes[](2);
        zeroCandidate[0] = votedData[0];
        zeroCandidate[1] = abi.encode(uint256(0));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.InvalidCandidate.selector));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 1, zeroCandidate);

        bytes[] memory three = new bytes[](3);
        three[0] = votedData[0];
        three[1] = votedData[1];
        three[2] = votedData[1];
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataLength.selector));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 1, three);

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 1, new bytes[](0));

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), 2, ACTION_ID, 0, 0, votedData);
        (uint256[] memory verifierIds, ) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 0, "zero votes rank nothing");

        _castVotesFor(VERIFIER_ID, 5e18);
        (verifierIds, ) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 1 && verifierIds[0] == VERIFIER_ID, "vote ranks the candidate");
    }

    function testRankCapacityAndReplacement() external {
        // Board capacity is SPLITS().length + 1 = 2 with splits = [5e17].
        _submitApplication();
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setValidGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");

        uint256 thirdId = 11;
        address third = address(0x1009);
        memberNFT.setOwner(thirdId, third);
        stake.setValidGovVotes(address(token), thirdId, 100e18);
        _fundVerifierStakeFor(third);
        vm.prank(third);
        executor.submitVerifierApplication(address(token), ACTION_ID, thirdId, "v3");

        _castVotesFor(VERIFIER_ID, 100e18);
        _castVotesFor(VERIFIER2_ID, 200e18);
        _castVotesFor(thirdId, 150e18);
        (uint256[] memory verifierIds, uint256[] memory votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 2 && verifierIds[1] == thirdId, "third candidate replaces the last");
        require(votes[0] == 200e18 && votes[1] == 150e18, "replacement votes");

        _castVotesFor(VERIFIER_ID, 50e18);
        (verifierIds, votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 2 && verifierIds[1] == thirdId, "equal votes do not replace");

        _castVotesFor(VERIFIER_ID, 1);
        (verifierIds, votes) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds[0] == VERIFIER2_ID && verifierIds[1] == VERIFIER_ID, "strictly above replaces");
        require(votes[1] == 150e18 + 1, "replacing votes accumulate");
    }

    function testVerifierStakeLifecycle() external {
        require(executor.VERIFIER_STAKE_AMOUNT(address(token), ACTION_ID) == VERIFIER_STAKE, "stake configured");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == 0, "no stake before applying");

        uint256 verifierBefore = token.balanceOf(VERIFIER);
        _submitApplication();
        require(token.balanceOf(VERIFIER) == verifierBefore - VERIFIER_STAKE, "stake pulled on application");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE, "executor holds the stake");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "stake recorded");

        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "replaced");
        require(token.balanceOf(VERIFIER) == verifierBefore - VERIFIER_STAKE, "replace does not stake twice");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "stake unchanged");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == verifierBefore, "stake refunded");
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == 0, "stake cleared");

        _submitApplication();
        require(token.balanceOf(VERIFIER) == verifierBefore - VERIFIER_STAKE, "re-application stakes again");
    }

    function testVerifierStakeZeroConfigNeedsNoTransfer() external {
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, 0));
        require(executor.VERIFIER_STAKE_AMOUNT(address(token), ACTION_2) == 0, "stake disabled");

        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "v");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == 0, "nothing recorded");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_2, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == before, "no transfer in either direction");
    }

    function testVerifierApplicationHistorySurvivesALaterModification() external {
        _atPhase(3);
        _submitApplication();
        uint256 round3ApplicationId =
            executor.verifierApplication(address(token), ACTION_ID, 3, VERIFIER_ID).applicationId;

        _atPhase(5);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "round 5");
        uint256 round5ApplicationId =
            executor.verifierApplication(address(token), ACTION_ID, 5, VERIFIER_ID).applicationId;
        require(round5ApplicationId != round3ApplicationId, "a modification is a fresh application");

        // Round 4 falls between the two applications and must answer with the round-3 one.
        VerifierApplication memory application =
            executor.verifierApplication(address(token), ACTION_ID, 4, VERIFIER_ID);
        require(application.applicationId == round3ApplicationId, "round 4 keeps the round-3 application");
        require(
            keccak256(bytes(application.description)) == keccak256(bytes("verifier")),
            "round 4 keeps the round-3 description"
        );
        require(
            executor.verifierApplication(address(token), ACTION_ID, 6, VERIFIER_ID).applicationId
                == round5ApplicationId,
            "the replacement stands for later rounds"
        );
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID).applicationId == 0, "no backfill"
        );
    }

    function testVerifierApplicationStandsAcrossRounds() external {
        _submitApplication();
        uint256 applicationId = executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID).applicationId;
        require(applicationId != 0, "applied in the creation round");

        _atPhase(3);
        // One application stands from its creation round onwards: round 3 is answered by round 2's.
        require(
            executor.verifierApplication(address(token), ACTION_ID, 3, VERIFIER_ID).applicationId == applicationId,
            "later rounds reuse the same application"
        );
        // A round before the application existed is never answered by it.
        require(
            executor.verifierApplication(address(token), ACTION_ID, 1, VERIFIER_ID).applicationId == 0, "no backfill"
        );

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == 0, "stake refunded");
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 3, VERIFIER_ID).applicationId == 0, "cancelled"
        );
        // The termination point is the cancellation round: earlier rounds keep their own answer.
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID).applicationId == applicationId,
            "the cancellation never rewrites earlier rounds"
        );
    }

    function testReplacingAfterTheVoteRoundKeepsTheVerificationRight() external {
        _prepareRound();
        // The round-2 votes are already in the rank; a fresh application in round 3 only changes what
        // later rounds answer, so the elected verifier still owns the round-2 verification.
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "replaced");

        _atPhase(4);
        _submitScores(_scores(100));
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "round 2 still verifiable");
    }

    function testCancellingAfterTheVoteRoundKeepsTheVerificationRight() external {
        _prepareRound();
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == 0, "bond returned");

        _atPhase(4);
        _submitScores(_scores(100));
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "round 2 still verifiable");
    }

    function testLockedVerifierKeepsVerifyingAfterCancelling() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(100));
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "locked");

        // The bond covers holding an application, not the verification duty: cancelling refunds it and
        // leaves the lock on the member.
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == VERIFIER_STAKE, "bond returned");

        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _scores(100));
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "the locked verifier finishes the round");
    }

    function testVerifierApplicationReplacementKeepsTheBond() external {
        _submitApplication();
        uint256 firstApplicationId =
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID).applicationId;
        uint256 afterFirst = token.balanceOf(VERIFIER);

        _atPhase(3);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "round 3");

        uint256 secondApplicationId =
            executor.verifierApplication(address(token), ACTION_ID, 3, VERIFIER_ID).applicationId;
        require(secondApplicationId != firstApplicationId, "a modification is a fresh application");
        require(token.balanceOf(VERIFIER) == afterFirst, "a replacement neither refunds nor charges");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "still one bond");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER_ID).applicationId == firstApplicationId,
            "the round that saw the first application still answers with it"
        );
        require(
            executor.verifierApplication(address(token), ACTION_ID, 4, VERIFIER_ID).applicationId
                == secondApplicationId,
            "the replacement stands for every later round"
        );

        // Cancelling the only application returns the whole bond.
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == afterFirst + VERIFIER_STAKE, "bond returned on cancel");
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
    }

    function testVerifierStakeNeedsBalanceAndAllowance() external {
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setValidGovVotes(address(token), VERIFIER2_ID, 100e18);

        vm.prank(VERIFIER2);
        vm.expectRevert();
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER2_ID) == 0, "nothing recorded");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER2_ID).applicationId == 0,
            "no application"
        );

        token.mint(VERIFIER2, VERIFIER_STAKE);
        vm.prank(VERIFIER2);
        vm.expectRevert();
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER2_ID).applicationId == 0,
            "no application"
        );

        vm.prank(VERIFIER2);
        token.approve(address(executor), VERIFIER_STAKE);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        require(
            executor.verifierStake(address(token), ACTION_ID, VERIFIER2_ID) == VERIFIER_STAKE, "staked after approval"
        );
    }

    function testVerifierStakeRefundFollowsTheMemberNFT() external {
        _submitApplication();

        address nextHolder = address(0x2001);
        memberNFT.setOwner(VERIFIER_ID, nextHolder);
        uint256 before = token.balanceOf(nextHolder);
        vm.prank(nextHolder);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(nextHolder) - before == VERIFIER_STAKE, "refund to the current holder");
    }

    function testVerifierApplicationGuardsDoNotCharge() external {
        uint256 before = token.balanceOf(VERIFIER);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, VERIFIER_ID));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "v");

        stake.setValidGovVotes(address(token), VERIFIER_ID, 0);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.VerifyVotesZero.selector));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "v");
        stake.setValidGovVotes(address(token), VERIFIER_ID, 100e18);

        bytes memory longDescription = new bytes(1025);
        for (uint256 i = 0; i < longDescription.length; i++) {
            longDescription[i] = 0x61;
        }
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, string(longDescription));

        // An action that was never created cannot host an application, and the rejection charges nothing.
        _atPhase(3);
        vm.prank(VERIFIER);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_2)
        );
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "v");

        require(token.balanceOf(VERIFIER) == before, "no charge on rejected applications");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == 0, "nothing staked");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 3, VERIFIER_ID).applicationId == 0, "no application"
        );
    }

    function testVerifierApplicationDescriptionLimit() external {
        bytes memory longDescription = new bytes(1025);
        for (uint256 i = 0; i < longDescription.length; i++) {
            longDescription[i] = 0x61;
        }
        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, string(longDescription));
        require(token.balanceOf(VERIFIER) == before, "no charge above the limit");

        bytes memory limitDescription = new bytes(1024);
        for (uint256 i = 0; i < limitDescription.length; i++) {
            limitDescription[i] = 0x61;
        }
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, string(limitDescription));
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "staked at limit");
        require(token.balanceOf(VERIFIER) == before - VERIFIER_STAKE, "charged at limit");
    }

    function testVerifierStakeCancelWithoutApplicationReverts() external {
        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationNotActive.selector));
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == before, "no refund without an application");
    }

    function testVerifierStakeIsPerMember() external {
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setValidGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);

        _submitApplication();
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE * 2, "both stakes held");

        vm.prank(VERIFIER2);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID);
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE, "only the cancelling member is refunded");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "other stake intact");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER2_ID) == 0, "cancelled stake cleared");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(address(executor)) == 0, "executor emptied after both cancel");
    }

    function testVerifierStakeIsPerAction() external {
        _createActionWith(
            ACTION_2, _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, VERIFIER_STAKE * 2)
        );
        _fundTokenFor(VERIFIER, VERIFIER_STAKE * 2);

        _submitApplication();
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "v");
        require(executor.VERIFIER_STAKE_AMOUNT(address(token), ACTION_2) == VERIFIER_STAKE * 2, "second action config");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "action 1 stake");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == VERIFIER_STAKE * 2, "action 2 stake");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE * 3, "both action stakes held");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_2, VERIFIER_ID);
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "action 1 intact");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == 0, "action 2 cleared");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE, "only action 2 refunded");
    }

    function _scores(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }
}
