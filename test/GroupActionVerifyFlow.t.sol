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
        require(executor.votesByApplicationId(address(token), ACTION_ID, 2) == 150e18, "old application keeps votes");
        require(executor.votesByApplicationId(address(token), ACTION_ID, 3) == 0, "new application starts at zero");

        VerifierApplication memory application = executor.verifierApplication(address(token), ACTION_ID, VERIFIER2_ID);
        require(application.applicationId == 3, "current application advanced");
        require(keccak256(bytes(application.description)) == keccak256(bytes("v2b")), "description replaced");

        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        (verifierIds, ) = executor.topVerifiers(address(token), ACTION_ID, 2);
        require(verifierIds.length == 0, "cancelled candidate leaves the rank");

        (VerifierApplication[] memory applications, uint256 total) =
            executor.verifierApplications(address(token), ACTION_ID, 0, 10, false);
        require(total == 1 && applications[0].applicationId == 3, "active applications");
        application = executor.verifierApplication(address(token), ACTION_ID, VERIFIER_ID);
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
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.InvalidCandidate.selector));
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
        bytes[] memory data = new bytes[](6);
        bytes[] memory baseData = _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0);
        for (uint256 i = 0; i < 5; i++) {
            data[i] = baseData[i];
        }
        string[] memory keys = new string[](2);
        keys[0] = "name";
        keys[1] = "city";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "n";
        descriptions[1] = "c";
        data[5] = abi.encode(keys, descriptions);
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
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.InvalidRound.selector, 1));
        executor.onProposalVoted(address(token), 1, ACTION_ID, 0, 1, votedData);

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
        vm.prank(VERIFIER2);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER2_ID, "v2");

        uint256 thirdId = 11;
        address third = address(0x1009);
        memberNFT.setOwner(thirdId, third);
        stake.setValidGovVotes(address(token), thirdId, 100e18);
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

    function _scores(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }
}
