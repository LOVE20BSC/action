// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "../src/GroupActionStorage.sol";
import {GroupActionVerify} from "../src/GroupActionVerify.sol";
import {IGroupActionVerifyErrors} from "../src/interfaces/IGroupActionVerify.sol";
import {RoundHistoryUint256} from "libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {MockGroupActionMemberNFT, MockGroupActionPhase} from "./mocks/GroupActionMocks.sol";

interface GroupActionVerifyVm {
    function expectRevert(bytes calldata revertData) external;
}

/// @dev Library-level suite: seeds the shared Layout directly and drives
///      GroupActionVerify through the real submission path with the verifier
///      pre-locked, bypassing only the election flow.
contract GroupActionVerifyTest {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;

    GroupActionVerifyVm internal constant vm =
        GroupActionVerifyVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant TOKEN = address(0x3001);
    uint256 internal constant ACTION_ID = 21;
    uint256 internal constant GROUP_A = 5;
    uint256 internal constant GROUP_B = 6;
    uint256 internal constant VERIFIER_ID = 1001;
    uint256 internal constant ROUND = 1;
    uint256 internal constant MEMBER_AMOUNT_A = 10e18;
    uint256 internal constant MEMBER_AMOUNT_B = 20e18;
    uint256 internal constant MEMBER_AMOUNT_C = 30e18;

    GroupActionStorage.Layout internal s;
    MockGroupActionPhase internal phase;
    MockGroupActionMemberNFT internal memberNFT;

    constructor() {
        phase = new MockGroupActionPhase();
        phase.setCurrentPhase(3);
        memberNFT = new MockGroupActionMemberNFT();

        s.memberNFTAddress = address(memberNFT);
        s.phaseAddress = address(phase);
        s.lockedVerifierId[TOKEN][ACTION_ID][ROUND] = VERIFIER_ID;

        _seedMember(1, GROUP_A, MEMBER_AMOUNT_A);
        _seedMember(2, GROUP_A, MEMBER_AMOUNT_B);
        _seedMember(3, GROUP_A, MEMBER_AMOUNT_C);
        _seedMember(4, GROUP_B, 40e18);
        s.groupIdsByRound[TOKEN][ACTION_ID].add(ROUND, GROUP_A);
        s.groupIdsByRound[TOKEN][ACTION_ID].add(ROUND, GROUP_B);
    }

    function test_RevertIfOriginScoreAboveMax() external {
        _bindVerifier();
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreExceedsMax.selector));
        _submit(GROUP_A, 0, _scores(99, 101));
    }

    function test_RevertIfOriginScoreAtTypeMax() external {
        _bindVerifier();
        uint256[] memory scores = new uint256[](1);
        scores[0] = type(uint256).max;
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreExceedsMax.selector));
        _submit(GROUP_A, 0, scores);
    }

    function test_AcceptsScoreAtMaxBoundary() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));

        (uint256 score, bool verified) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 1);
        require(score == 100 && verified, "origin score at max");
        (uint256 finalScore, bool finalVerified) = GroupActionVerify.finalScore(s, TOKEN, ACTION_ID, ROUND, 1);
        require(finalScore == MEMBER_AMOUNT_A * 100 && finalVerified, "final score at max");
        require(
            GroupActionVerify.totalFinalScore(s, TOKEN, ACTION_ID, ROUND) == MEMBER_AMOUNT_A * 100,
            "total accumulated"
        );
        require(GroupActionVerify.verifiedMemberCount(s, TOKEN, ACTION_ID, ROUND, GROUP_A) == 1, "cursor advanced");
    }

    function test_ScoreZeroVerifiesWithZeroContribution() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(0));

        (uint256 score, bool verified) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 1);
        require(score == 0 && verified, "zero score is verified");
        (uint256 finalScore, ) = GroupActionVerify.finalScore(s, TOKEN, ACTION_ID, ROUND, 1);
        require(finalScore == 0, "zero final score");
        require(GroupActionVerify.totalFinalScore(s, TOKEN, ACTION_ID, ROUND) == 0, "zero total");
        require(GroupActionVerify.verifiedMemberCount(s, TOKEN, ACTION_ID, ROUND, GROUP_A) == 1, "cursor advanced");
    }

    function test_ContinuousBatchesFollowSetOrder() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 90));
        _submit(GROUP_A, 2, _scores(80));

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 2);
        (uint256 score3, bool verified3) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 3);
        require(score1 == 100 && verified1, "member 1 first");
        require(score2 == 90 && verified2, "member 2 second");
        require(score3 == 80 && verified3, "member 3 third");
        require(
            GroupActionVerify.totalFinalScore(s, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 90 + MEMBER_AMOUNT_C * 80,
            "total accumulated across batches"
        );
    }

    function test_RoundCompletesOnlyWhenAllGroupsVerified() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 90));
        _submit(GROUP_A, 2, _scores(80));
        require(!GroupActionVerify.isRoundVerified(s, TOKEN, ACTION_ID, ROUND), "group B still pending");

        _submit(GROUP_B, 0, _scores(50));
        require(GroupActionVerify.isRoundVerified(s, TOKEN, ACTION_ID, ROUND), "round complete");
    }

    function test_FullScoreWritesNoDeductionSlot() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60));

        require(s.originScoreDeduction[TOKEN][ACTION_ID][ROUND][1] == 0, "full score writes no slot");
        require(s.originScoreDeduction[TOKEN][ACTION_ID][ROUND][2] == 40, "deduction stored");
        (uint256 score1, bool verified1) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 2);
        require(score1 == 100 && verified1, "full score decodes");
        require(score2 == 60 && verified2, "deduction decodes");
        require(
            GroupActionVerify.totalFinalScore(s, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 60,
            "totals unchanged"
        );
    }

    function test_UnverifiedMemberBeyondCursorReturnsZero() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));

        (uint256 score, bool verified) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 2);
        require(score == 0 && !verified, "beyond cursor unverified");
        (uint256 finalScore, bool finalVerified) = GroupActionVerify.finalScore(s, TOKEN, ACTION_ID, ROUND, 2);
        require(finalScore == 0 && !finalVerified, "beyond cursor final zero");
    }

    function test_MemberOutsideMemberSetReturnsZero() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));
        s.groupHistory[TOKEN][ACTION_ID][9].record(ROUND, GROUP_A);

        (uint256 score, bool verified) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 9);
        require(score == 0 && !verified, "absent from member set is unverified");
    }

    function test_UnscoredGroupReturnsZero() external {
        _bindVerifier();

        (uint256 score, bool verified) = GroupActionVerify.originScore(s, TOKEN, ACTION_ID, ROUND, 4);
        require(score == 0 && !verified, "unscored group unverified");
    }

    function _seedMember(uint256 memberId, uint256 groupId, uint256 amount) internal {
        s.memberIdsByGroupId[TOKEN][ACTION_ID][groupId].add(ROUND, memberId);
        s.groupHistory[TOKEN][ACTION_ID][memberId].record(ROUND, groupId);
        s.ownAmountHistory[TOKEN][ACTION_ID][memberId].record(ROUND, amount);
    }

    function _bindVerifier() internal {
        // The library runs via delegatecall and inherits this frame's msg.sender, and the
        // cheatcode prank does not reach delegatecalls, so bind the owner at call time.
        memberNFT.setOwner(VERIFIER_ID, msg.sender);
    }

    function _submit(uint256 groupId, uint256 startIndex, uint256[] memory scores) internal {
        GroupActionVerify.submitOriginScores(s, TOKEN, ACTION_ID, VERIFIER_ID, groupId, startIndex, scores);
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
