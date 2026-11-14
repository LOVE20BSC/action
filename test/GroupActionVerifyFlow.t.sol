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

    function testDescriptionEditsKeepTheIdStakeVotesAndCurrentText() external {
        _submitApplication();
        _castVerifierVotes();
        vm.prank(VERIFIER);
        uint256 id = executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "next text");
        require(id == 1 && executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "one application and deposit");
        require(keccak256(bytes(_application(2).description)) == keccak256("verifier"), "current text frozen");
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "latest next text");
        require(keccak256(bytes(_application(3).description)) == keccak256("latest next text"), "next-round edit can be replaced");
        (, uint256 applicationId, uint256 votes) = executor.verifier(address(token), ACTION_ID, 2);
        require(applicationId == 1 && votes == 100e18, "edits preserve votes");
        _atPhase(3);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "round four");
        require(keccak256(bytes(_application(3).description)) == keccak256("latest next text"), "next edit cannot change current round");
        require(keccak256(bytes(_application(2).description)) == keccak256("verifier"), "historical text frozen");
    }

    function testTiesKeepWhoReachedTheVoteAmountFirst() external {
        _submitApplication();
        _applySecond();
        _castVotesFor(VERIFIER2_ID, 100);
        _castVotesFor(VERIFIER_ID, 100);
        (uint256 electedId,,) = executor.verifier(address(token), ACTION_ID, 2);
        require(electedId == VERIFIER2_ID, "older application does not break a tie");
        _castVotesFor(VERIFIER_ID, 1);
        _castVotesFor(VERIFIER2_ID, 1);
        (electedId,,) = executor.verifier(address(token), ACTION_ID, 2);
        require(electedId == VERIFIER_ID, "incumbent retains tied tally");
        (, uint256 total) = executor.verifierElectedRounds(address(token), ACTION_ID, 1, 0, 10, false);
        require(total == 0, "current leader is not final history");
        _atPhase(3);
        (uint256[] memory rounds, uint256 finalTotal) = executor.verifierElectedRounds(address(token), ACTION_ID, 1, 0, 10, false);
        require(finalTotal == 1 && rounds[0] == 2, "final winner saved without another vote");
        (, total) = executor.verifierElectedRounds(address(token), ACTION_ID, 2, 0, 10, false);
        require(total == 0, "temporary winner owes no duty");
    }

    function testOnlyTheElectedVerifierCanSubmitThroughoutTheWholePeriod() external {
        _submitApplication();
        _applySecond();
        _castVotesFor(VERIFIER_ID, 100);
        _castVotesFor(VERIFIER2_ID, 99);
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);
        _activateGroup();
        _fundJoinTokenFor(MEMBER1, 1e18);
        _join(MEMBER1_ID, 1e18, 0);
        _atPhase(4);
        for (uint256 offset = 0; offset < PHASE_BLOCKS; offset += PHASE_BLOCKS - 1) {
            vm.roll(4 * PHASE_BLOCKS + offset);
            vm.prank(VERIFIER2);
            vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.VerifierNotElected.selector, VERIFIER2_ID, 2));
            executor.submitOriginScores(address(token), ACTION_ID, VERIFIER2_ID, GROUP_ID, 0, _scores(100));
        }
        _submitScores(_scores(100));
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "winner has the entire period");
    }

    function testStoppingKeepsVotesAndOldVerificationRights() external {
        _prepareRound();
        vm.prank(VERIFIER);
        executor.stopVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationStopped.selector, 1));
        _castVotesForAt(VERIFIER_ID, 1, 3);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationStopped.selector, 1));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "cannot restart");
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationStillResponsible.selector, 1, 2));
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        _atPhase(4);
        _submitScores(_scores(0, 0));
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "zero scores still fulfill the duty");
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        vm.prank(VERIFIER);
        uint256 nextId = executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "new application");
        require(nextId == 2, "earlier stop adds no extra wait after a later refund");
        require(_application(2).applicationId == 1 && _application(2).stoppedRound == 3, "history keeps old application");
    }

    function testStopAndRefundCannotReapplyInTheStoppedRound() external {
        _submitApplication();
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ReapplicationInStoppedRound.selector, 2));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "same round");
        _atPhase(3);
        vm.prank(VERIFIER);
        require(executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "next round") == 2, "new deposit and id");
    }

    function testEmptyRosterCannotReleaseCurrentOrJoiningRoundWinner() external {
        _submitApplication();
        _castVerifierVotes();
        vm.prank(VERIFIER);
        executor.stopVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        for (uint256 round = 2; round <= 3; round++) {
            _atPhase(round);
            vm.prank(VERIFIER);
            vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationStillResponsible.selector, 1, 2));
            executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        }
        _atPhase(4);
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == VERIFIER_STAKE, "empty after joining closes is exempt");
        require(_application(2).punishmentAmount == 0 && _application(2).failedRounds.length == 0, "no task no penalty");
    }

    function testWithdrawnNonleaderKeepsHistoricalApplicationsAndVotes() external {
        _submitApplication();
        _applySecond();
        _castVotesFor(VERIFIER_ID, 70);
        _castVotesFor(VERIFIER2_ID, 90);
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        (VerifierApplication[] memory applications, uint256[] memory votes, uint256 total) =
            executor.verifierApplicationsByRound(address(token), ACTION_ID, 2, 0, 10, false);
        require(total == 2 && applications[0].applicationId == 2 && applications[1].applicationId == 1, "withdrawn voted application archived");
        require(votes[0] == 90 && votes[1] == 70 && applications[1].withdrawnRound == 2, "archived votes and lifecycle");
        (applications, votes, total) = executor.verifierApplicationsByRound(address(token), ACTION_ID, 2, 1, 1, false);
        require(total == 2 && applications.length == 1 && votes[0] == 70, "pagination crosses archive boundary");
        (applications, votes, total) = executor.verifierApplicationsByRound(address(token), ACTION_ID, 2, 0, 1, true);
        require(total == 2 && applications[0].applicationId == 1 && votes[0] == 70, "reverse archive page");
        (, , total) = executor.verifierApplicationsByRound(address(token), ACTION_ID, 2, 0, 0, false);
        require(total == 2, "count-only history");
        (applications, votes, total) = executor.verifierApplicationsByRound(address(token), ACTION_ID, 2, 2, 10, false);
        require(total == 2 && applications.length == 0 && votes.length == 0, "empty page preserves total");
        uint256[] memory ids = new uint256[](1);
        ids[0] = VERIFIER_ID;
        require(executor.voteAmountsByVerifierIds(address(token), ACTION_ID, 2, ids)[0] == 70, "member history keeps votes");
        (uint256[] memory voters,,) = executor.applicationVotersByVerifierId(address(token), ACTION_ID, 2, VERIFIER_ID, 0, 10, false);
        require(voters.length == 1 && voters[0] == MEMBER1_ID, "member history keeps voters");
        _atPhase(3);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "fresh");
        require(_application(2).applicationId == 1 && _application(3).applicationId == 3, "new application does not rewrite old rounds");
    }

    function testOverdueApplicationIsBlockedWithoutAnySettlementOrBurn() external {
        _prepareRound();
        _atPhase(10);
        uint256 before = token.balanceOf(address(executor));
        require(_application(2).punishmentAmount == 12e18 && _application(2).failedRounds[0] == 2, "penalty is derived without a transaction");
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationOverdue.selector, 1, 2));
        _castVotesForAt(VERIFIER_ID, 1, 10);
        require(token.balanceOf(address(executor)) == before, "voting does not burn");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "stake intact until withdrawal");
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == 28e18, "one failure is one third of maximum ratio");
        require(token.balanceOf(address(executor)) == before - VERIFIER_STAKE, "burn and refund consume exactly this bond");
        require(_application(2).punishmentAmount == 12e18, "historical punishment remains queryable");
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.NoActiveApplication.selector, VERIFIER_ID));
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
    }

    function testThreePendingWinsBlockAFourthButRemainingWorkStillReducesPenalty() external {
        _prepareRound();
        _castVotesForAt(VERIFIER_ID, 100, 3);
        _atPhase(4);
        _castVotesForAt(VERIFIER_ID, 100, 4);
        _atPhase(5);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationOverdue.selector, 1, 2));
        _castVotesForAt(VERIFIER_ID, 100, 5);
        require(_application(2).failedRounds.length == 1 && _application(2).pendingRound != 0, "one overdue and two pending");
        vm.prank(VERIFIER);
        executor.stopVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        _submitScores(_scores(100, 100));
        _atPhase(6);
        _submitScores(_scores(100, 100));
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == 28e18, "finishing the other duties avoids their two shares");
        (uint256[] memory rounds, uint256 total) = executor.verifierElectedRounds(address(token), ACTION_ID, 1, 0, 10, true);
        require(total == 3 && rounds[0] == 4 && rounds[1] == 3 && rounds[2] == 2, "actual election history");
    }

    function testFuzzPenaltyCountsOnlyFailedDuties(uint8 completedMask) external {
        _prepareRound();
        _castVotesForAt(VERIFIER_ID, 100, 3);
        _atPhase(4);
        _castVotesForAt(VERIFIER_ID, 100, 4);
        vm.prank(VERIFIER);
        executor.stopVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        uint256 failures;
        for (uint256 bit = 0; bit < 3; bit++) {
            _atPhase(4 + bit);
            if ((uint256(completedMask) & (uint256(1) << bit)) != 0) _submitScores(_scores(100, 100));
            else failures++;
        }
        _atPhase(7);
        uint256 amount = 12e18 * failures;
        VerifierApplication memory application = _application(2);
        require(application.failedRounds.length == failures && application.punishmentAmount == amount, "failed duties determine penalty");
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == VERIFIER_STAKE - amount, "linear penalty refunds remainder");
    }

    function testFuzzPenaltyRoundsOnceEvenWhenItBecomesZero(uint96 stakeSeed, uint64 ratioSeed) external {
        uint256 collateral = uint256(stakeSeed);
        uint256 ratio = uint256(ratioSeed) % (PRECISION - 1) + 1;
        bytes[] memory data = _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, collateral);
        data[6] = abi.encode(ratio);
        _createActionWith(ACTION_2, data);
        vote.setVotesNumByProposalId(address(token), 2, ACTION_2, 1000e18);
        _fundTokenFor(VERIFIER, collateral);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_2, VERIFIER_ID, "rounding");
        bytes[] memory voteData = new bytes[](2);
        voteData[0] = abi.encode(address(executor));
        voteData[1] = abi.encode(VERIFIER_ID);
        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), 2, ACTION_2, MEMBER1_ID, 1, voteData);
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_ID, _defaultConfig());
        _fundJoinTokenFor(MEMBER1, 1e18);
        vm.prank(MEMBER1);
        executor.join(address(token), ACTION_2, GROUP_ID, MEMBER1_ID, 1e18, 0, new string[](0));
        _atPhase(5);
        VerifierApplication memory application = executor.verifierApplication(address(token), ACTION_2, 2, VERIFIER_ID);
        uint256 expected = collateral * ratio / (3 * PRECISION);
        require(application.punishmentAmount == expected && application.failedRounds.length == 1, "single final rounding");
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ApplicationOverdue.selector, 1, 2));
        executor.onProposalVoted(address(token), 5, ACTION_2, MEMBER1_ID, 1, voteData);
        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_2, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == before + collateral - expected, "zero penalty still allows only withdrawal");
    }

    function testCompletedApplicationsCanKeepWinningWithoutALifetimeLimit() external {
        _submitApplication();
        for (uint256 round = 2; round < 10; round++) {
            _atPhase(round);
            _castVotesForAt(VERIFIER_ID, 1, round);
        }
        _atPhase(10);
        (uint256[] memory rounds, uint256 total) = executor.verifierElectedRounds(address(token), ACTION_ID, 1, 2, 3, false);
        require(total == 8 && rounds.length == 3 && rounds[0] == 4 && rounds[2] == 6, "paginated final history across empty rounds");
        require(_application(2).failedRounds.length == 0, "empty completed joining periods are not failures");
    }

    function _applySecond() internal {
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "second");
    }

    function _application(uint256 round) internal view returns (VerifierApplication memory) {
        return executor.verifierApplication(address(token), ACTION_ID, round, VERIFIER_ID);
    }

    function testOriginScoreSubmissionReverts() external {
        _prepareRound();
        _atPhase(4);

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.OriginScoresEmpty.selector));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, new uint256[](0));

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.VerificationBatchTooLarge.selector, 101, 100));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, new uint256[](101));

        uint256[] memory overMax = new uint256[](1);
        overMax[0] = 101;
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreLimitExceeded.selector, 0, 101, 100));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, overMax);

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.StartIndexMismatch.selector, 0, 1));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _scores(100));

        uint256[] memory tooMany = new uint256[](3);
        tooMany[0] = 100;
        tooMany[1] = 90;
        tooMany[2] = 80;
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreCountExceeded.selector, 0, 3, 2));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, tooMany);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, VERIFIER_ID));
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _scores(100));

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionVerifyErrors.VerifierNotElected.selector, MEMBER2_ID, 2)
        );
        executor.submitOriginScores(address(token), ACTION_ID, MEMBER2_ID, GROUP_ID, 0, _scores(100));

        _submitScores(_scores(100));

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionVerifyErrors.VerifierNotElected.selector, MEMBER2_ID, 2
            )
        );
        executor.submitOriginScores(address(token), ACTION_ID, MEMBER2_ID, GROUP_ID, 1, _scores(90));

        uint256[] memory overMaxByOther = new uint256[](1);
        overMaxByOther[0] = 101;
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreLimitExceeded.selector, 0, 101, 100));
        executor.submitOriginScores(address(token), ACTION_ID, MEMBER2_ID, GROUP_ID, 0, overMaxByOther);

        uint256[] memory secondBatch = new uint256[](1);
        secondBatch[0] = 90;
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, secondBatch);
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "round verified");

        uint256[] memory again = new uint256[](1);
        again[0] = 50;
        vm.prank(VERIFIER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionVerifyErrors.GroupVerificationAlreadyComplete.selector, GROUP_ID, uint256(2))
        );
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 2, again);
    }

    function testSchemaAndVerificationInfoFlow() external {
        string[] memory keys = new string[](2);
        keys[0] = "name";
        keys[1] = "city";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "n";
        descriptions[1] = "c";
        _createActionWith(ACTION_2, _targetDataWithSchema(keys, descriptions));

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
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.VerificationInfoLengthMismatch.selector, 2, 1));
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
        (valueKeys, values) = executor.verificationInfosByRound(address(token), ACTION_2, 2, MEMBER1_ID);
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

        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(this)));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(this)));
        executor.onProposalSubmitted(address(token), ACTION_ID, 0, votedData);

        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionVerifyErrors.NoActiveApplication.selector, VERIFIER_ID)
        );
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);

        _submitApplication();
        // An application stands for its creation round and every round after it, so a vote for a later
        // round is accepted; a vote for a round before it existed is not reachable in practice, and the
        // missing-verifier guard above already covers the only real rejection.
        bytes[] memory zeroVerifier = new bytes[](2);
        zeroVerifier[0] = votedData[0];
        zeroVerifier[1] = abi.encode(uint256(0));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.NoActiveApplication.selector, uint256(0)));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, zeroVerifier);

        bytes[] memory three = new bytes[](3);
        three[0] = votedData[0];
        three[1] = votedData[1];
        three[2] = votedData[1];
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.TooManyTargetDataItems.selector, 3, 2));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, three);

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, new bytes[](0));

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 0, votedData);
        (uint256 verifierId,,) = executor.verifier(address(token), ACTION_ID, 2);
        require(verifierId == 0, "zero votes elect nobody");
        (, , uint256 rosterTotal) = executor.applicationVoters(address(token), ACTION_ID, 2, 1, 0, 10, false);
        require(rosterTotal == 0, "zero votes name no voter");

        _castVotesFor(VERIFIER_ID, 5e18);
        (verifierId,,) = executor.verifier(address(token), ACTION_ID, 2);
        require(verifierId == VERIFIER_ID, "positive vote elects the verifier");
    }

    function testVerifierIdItemLengthZeroReverts() external {
        bytes[] memory votedData = new bytes[](2);
        votedData[0] = abi.encode(address(executor));
        votedData[1] = new bytes(0);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 1, 0));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);
    }

    function testVerifierIdItemLength31Reverts() external {
        bytes[] memory votedData = new bytes[](2);
        votedData[0] = abi.encode(address(executor));
        votedData[1] = new bytes(31);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 1, 31));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);
    }

    function testVerifierIdItemLength33Reverts() external {
        bytes[] memory votedData = new bytes[](2);
        votedData[0] = abi.encode(address(executor));
        votedData[1] = new bytes(33);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 1, 33));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);
    }

    function testVerifierIdItemLength64Reverts() external {
        bytes[] memory votedData = new bytes[](2);
        votedData[0] = abi.encode(address(executor));
        votedData[1] = new bytes(64);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 1, 64));
        executor.onProposalVoted(address(token), 2, ACTION_ID, MEMBER2_ID, 1, votedData);
    }

    function testVerifierStakeNeedsBalanceAndAllowance() external {
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setGovVotes(address(token), VERIFIER2_ID, 100e18);

        vm.prank(VERIFIER2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER2_ID) == 0, "nothing recorded");
        require(
            executor.verifierApplication(address(token), ACTION_ID, 2, VERIFIER2_ID).applicationId == 0,
            "no application"
        );

        token.mint(VERIFIER2, VERIFIER_STAKE);
        vm.prank(VERIFIER2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
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

        stake.setGovVotes(address(token), VERIFIER_ID, 0);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ZeroVerifyVotes.selector, address(token), VERIFIER_ID));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "v");
        stake.setGovVotes(address(token), VERIFIER_ID, 100e18);

        bytes memory longDescription = new bytes(1025);
        for (uint256 i = 0; i < longDescription.length; i++) {
            longDescription[i] = 0x61;
        }
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector, 1025, 1024));
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
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector, 1025, 1024));
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

    function testApplicationChecksDescriptionBeforeActionExistence() external {
        bytes memory longDescription = new bytes(1025);
        for (uint256 i = 0; i < longDescription.length; i++) {
            longDescription[i] = 0x61;
        }
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector, 1025, 1024));
        executor.submitVerifierApplication(address(token), uint256(99), VERIFIER_ID, string(longDescription));
    }

    function testVerifierStakeCancelWithoutApplicationReverts() external {
        uint256 before = token.balanceOf(VERIFIER);
        vm.prank(VERIFIER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionVerifyErrors.NoActiveApplication.selector, VERIFIER_ID)
        );
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        require(token.balanceOf(VERIFIER) == before, "no refund without an application");
    }

    function testVerifierStakeIsPerMember() external {
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setGovVotes(address(token), VERIFIER2_ID, 100e18);
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
        require(executor.requiredVerifierStake(address(token), ACTION_2) == VERIFIER_STAKE * 2, "second action config");
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "action 1 stake");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == VERIFIER_STAKE * 2, "action 2 stake");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE * 3, "both action stakes held");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_2, VERIFIER_ID);
        require(executor.verifierStake(address(token), ACTION_ID, VERIFIER_ID) == VERIFIER_STAKE, "action 1 intact");
        require(executor.verifierStake(address(token), ACTION_2, VERIFIER_ID) == 0, "action 2 cleared");
        require(token.balanceOf(address(executor)) == VERIFIER_STAKE, "only action 2 refunded");
    }

    function testApplicationVotersKeepOneRowPerVoter() external {
        _submitApplication();
        _castVotesFrom(MEMBER2_ID, VERIFIER_ID, 30e18);
        _castVotesFrom(PROVIDER_ID, VERIFIER_ID, 20e18);
        _castVotesFrom(MEMBER2_ID, VERIFIER_ID, 10e18);

        (uint256[] memory voterIds, uint256[] memory votes, uint256 total) =
            executor.applicationVoters(address(token), ACTION_ID, 2, 1, 0, 10, false);
        require(total == 2, "one row per voter");
        require(voterIds[0] == MEMBER2_ID && voterIds[1] == PROVIDER_ID, "first-vote order");
        require(votes[0] == 40e18 && votes[1] == 20e18, "repeat votes accumulate on the voter row");

        (uint256 electedId,, uint256 electedVotes) = executor.verifier(address(token), ACTION_ID, 2);
        require(electedId == VERIFIER_ID && electedVotes == votes[0] + votes[1], "voter totals match election");

        (voterIds, votes, ) = executor.applicationVoters(address(token), ACTION_ID, 2, 1, 0, 10, true);
        require(voterIds[0] == PROVIDER_ID && voterIds[1] == MEMBER2_ID, "reverse is first-vote reverse");
        require(votes[1] == 40e18, "votes follow their voter");

        (voterIds, votes, total) = executor.applicationVoters(address(token), ACTION_ID, 2, 1, 2, 10, false);
        require(voterIds.length == 0 && votes.length == 0 && total == 2, "out of range returns the true total");

        (, , total) = executor.applicationVoters(address(token), ACTION_ID, 2, 1, 0, 0, false);
        require(total == 2, "limit 0 is the count entry");

        (, , total) = executor.applicationVoters(address(token), ACTION_ID, 2, 99, 0, 10, false);
        require(total == 0, "an unknown application has no roster");
    }

    function testApplicationVotersByVerifierIdFollowTheRound() external {
        _submitApplication();
        _castVotesFrom(MEMBER2_ID, VERIFIER_ID, 100e18);

        _atPhase(4);
        _castVotesFromAt(PROVIDER_ID, VERIFIER_ID, 60e18, 4);

        (uint256[] memory voterIds, uint256[] memory votes, uint256 total) = executor.applicationVotersByVerifierId(
            address(token), ACTION_ID, 2, VERIFIER_ID, 0, 10, false
        );
        require(total == 1 && voterIds[0] == MEMBER2_ID && votes[0] == 100e18, "round 2 keeps its own voters");

        (voterIds, votes, total) = executor.applicationVotersByVerifierId(
            address(token), ACTION_ID, 4, VERIFIER_ID, 0, 10, false
        );
        require(total == 1 && voterIds[0] == PROVIDER_ID && votes[0] == 60e18, "round 4 keeps only round-4 votes");

        _atPhase(7);
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "round 7");
        (voterIds, votes, total) = executor.applicationVotersByVerifierId(
            address(token), ACTION_ID, 7, VERIFIER_ID, 0, 10, false
        );
        require(total == 0 && voterIds.length == 0 && votes.length == 0, "a fresh application starts empty");

        (, , total) = executor.applicationVotersByVerifierId(
            address(token), ACTION_ID, 4, VERIFIER_ID, 0, 10, false
        );
        require(total == 1, "the round that saw the earlier application keeps its roster");

        (, , total) = executor.applicationVotersByVerifierId(
            address(token), ACTION_ID, 2, MEMBER1_ID, 0, 10, false
        );
        require(total == 0, "a member without an application has no roster");
    }

    function testApplicationVoterRostersStayPerVerifier() external {
        _submitApplication();
        memberNFT.setOwner(VERIFIER2_ID, VERIFIER2);
        stake.setGovVotes(address(token), VERIFIER2_ID, 100e18);
        _fundVerifierStakeFor(VERIFIER2);
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");

        _castVotesFrom(MEMBER2_ID, VERIFIER_ID, 70e18);
        _castVotesFrom(MEMBER2_ID, VERIFIER2_ID, 90e18);
        _castVotesFrom(PROVIDER_ID, VERIFIER2_ID, 10e18);

        (uint256[] memory voterIds, uint256[] memory votes, uint256 total) =
            executor.applicationVoters(address(token), ACTION_ID, 2, 1, 0, 10, false);
        require(total == 1 && voterIds[0] == MEMBER2_ID && votes[0] == 70e18, "verifier one keeps its own roster");

        (voterIds, votes, total) = executor.applicationVoters(address(token), ACTION_ID, 2, 2, 0, 10, false);
        require(total == 2 && votes[0] == 90e18 && votes[1] == 10e18, "verifier two keeps both voters");

        (uint256 electedId,, uint256 electedVotes) = executor.verifier(address(token), ACTION_ID, 2);
        require(electedId == VERIFIER2_ID && electedVotes == 100e18, "separate vote totals");
    }

    function _scores(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _scores(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }
}

contract GroupActionVerifyRoundGuardTest is GroupActionExecutorTestBase {
    function testSubmitApplicationRejectsBeforeTheFirstRound() external {
        phase.setCurrentPhase(0);

        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "v");
    }
}
