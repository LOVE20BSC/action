// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "../src/GroupActionStorage.sol";
import {GroupActionVerify} from "../src/GroupActionVerify.sol";
import {IGroupActionVerifyErrors, IGroupActionVerifyEvents} from "../src/interfaces/IGroupActionVerify.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {MockGroupActionMemberNFT, MockGroupActionPhase} from "./mocks/GroupActionMocks.sol";

interface GroupActionVerifyVm {
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
}

/// @dev Library-level suite: seeds the shared Layout directly and drives
///      GroupActionVerify through the real submission path with the verifier
///      pre-locked, bypassing only the election flow.
contract GroupActionVerifyTest is IGroupActionVerifyEvents {
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

    GroupActionStorage.Layout internal _layout;
    MockGroupActionPhase internal phase;
    MockGroupActionMemberNFT internal memberNFT;

    constructor() {
        phase = new MockGroupActionPhase();
        phase.setCurrentPhase(3);
        memberNFT = new MockGroupActionMemberNFT();

        _layout.MEMBER_NFT_ADDRESS = address(memberNFT);
        _layout.PHASE_ADDRESS = address(phase);
        _layout.lockedVerifierId[TOKEN][ACTION_ID][ROUND] = VERIFIER_ID;

        _seedMember(1, GROUP_A, MEMBER_AMOUNT_A);
        _seedMember(2, GROUP_A, MEMBER_AMOUNT_B);
        _seedMember(3, GROUP_A, MEMBER_AMOUNT_C);
        _seedMember(4, GROUP_B, 40e18);
        _layout.groupIdsByRound[TOKEN][ACTION_ID].add(ROUND, GROUP_A);
        _layout.groupIdsByRound[TOKEN][ACTION_ID].add(ROUND, GROUP_B);
    }

    function test_RevertIfOriginScoreAboveMax() external {
        _bindVerifier();
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreLimitExceeded.selector, 1, 101, 100));
        _submit(GROUP_A, 0, _scores(99, 101));
    }

    function test_RevertIfOriginScoreAtTypeMax() external {
        _bindVerifier();
        uint256[] memory scores = new uint256[](1);
        scores[0] = type(uint256).max;
        vm.expectRevert(abi.encodeWithSelector(IGroupActionVerifyErrors.ScoreLimitExceeded.selector, 0, type(uint256).max, 100));
        _submit(GROUP_A, 0, scores);
    }

    function test_AcceptsScoreAtMaxBoundary() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(score == 100 && verified, "origin score at max");
        (uint256 finalScore, bool finalVerified) = GroupActionVerify.finalScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(finalScore == MEMBER_AMOUNT_A * 100 && finalVerified, "final score at max");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND) == MEMBER_AMOUNT_A * 100,
            "total accumulated"
        );
        require(GroupActionVerify.verifiedMemberCount(_layout, TOKEN, ACTION_ID, ROUND, GROUP_A) == 1, "cursor advanced");
    }

    function test_ScoreZeroVerifiesWithZeroContribution() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(0));

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(score == 0 && verified, "zero score is verified");
        (uint256 finalScore, ) = GroupActionVerify.finalScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(finalScore == 0, "zero final score");
        require(GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND) == 0, "zero total");
        require(GroupActionVerify.verifiedMemberCount(_layout, TOKEN, ACTION_ID, ROUND, GROUP_A) == 1, "cursor advanced");
    }

    function test_ContinuousBatchesFollowSetOrder() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 90));
        _submit(GROUP_A, 2, _scores(80));

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        (uint256 score3, bool verified3) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 3);
        require(score1 == 100 && verified1, "member 1 first");
        require(score2 == 90 && verified2, "member 2 second");
        require(score3 == 80 && verified3, "member 3 third");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 90 + MEMBER_AMOUNT_C * 80,
            "total accumulated across batches"
        );
    }

    function test_RoundCompletesOnlyWhenAllGroupsVerified() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 90));
        _submit(GROUP_A, 2, _scores(80));
        require(!GroupActionVerify.isRoundVerified(_layout, TOKEN, ACTION_ID, ROUND), "group B still pending");

        _submit(GROUP_B, 0, _scores(50));
        require(GroupActionVerify.isRoundVerified(_layout, TOKEN, ACTION_ID, ROUND), "round complete");
    }

    function test_FullScoreWritesNoDeductionSlot() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60));

        require(_layout.originScoreDeductionByMemberId[TOKEN][ACTION_ID][ROUND][1] == 0, "full score writes no slot");
        require(_layout.originScoreDeductionByMemberId[TOKEN][ACTION_ID][ROUND][2] == 40, "deduction stored");
        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        require(score1 == 100 && verified1, "full score decodes");
        require(score2 == 60 && verified2, "deduction decodes");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 60,
            "totals unchanged"
        );
    }

    function test_UnverifiedMemberBeyondCursorReturnsZero() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        require(score == 0 && !verified, "beyond cursor unverified");
        (uint256 finalScore, bool finalVerified) = GroupActionVerify.finalScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        require(finalScore == 0 && !finalVerified, "beyond cursor final zero");
    }

    function test_MemberOutsideMemberSetReturnsZero() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));
        _layout.groupHistoryByMemberId[TOKEN][ACTION_ID][9].record(ROUND, GROUP_A);

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 9);
        require(score == 0 && !verified, "absent from member set is unverified");
    }

    function test_UnscoredGroupReturnsZero() external {
        _bindVerifier();

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 4);
        require(score == 0 && !verified, "unscored group unverified");
    }

    function test_ScoredRoundSurvivesLaterRoundSetChurn() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60, 30));
        _submit(GROUP_B, 0, _scores(50));

        // Round 2: member 2 leaves, swap-and-pop displaces member 3 within the round-2 order.
        _layout.memberIdsByGroupId[TOKEN][ACTION_ID][GROUP_A].remove(ROUND + 1, 2);

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        (uint256 score3, bool verified3) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 3);
        require(score1 == 100 && verified1, "member 1 keeps round score");
        require(score2 == 60 && verified2, "departing member keeps round score");
        require(score3 == 30 && verified3, "displaced member keeps round score");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 60 + MEMBER_AMOUNT_C * 30 + 40e18 * 50,
            "totals frozen across later rounds"
        );
        require(GroupActionVerify.isRoundVerified(_layout, TOKEN, ACTION_ID, ROUND), "round stays verified");
    }

    function test_RoundVerifiedTracksTheGroupCounter() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60, 30));
        require(!GroupActionVerify.isRoundVerified(_layout, TOKEN, ACTION_ID, ROUND), "partial round");
        require(_layout.verifiedGroupCountByRound[TOKEN][ACTION_ID][ROUND] == 1, "one group counted");

        _submit(GROUP_B, 0, _scores(50));
        require(GroupActionVerify.isRoundVerified(_layout, TOKEN, ACTION_ID, ROUND), "verified");
        require(
            _layout.verifiedGroupCountByRound[TOKEN][ACTION_ID][ROUND]
                == _layout.groupIdsByRound[TOKEN][ACTION_ID].countByRound(ROUND),
            "counter reaches the group count"
        );
    }

    /// 群游标与整轮游标必须分别报值：GROUP_A 收尾时本群完成但整轮仍开（`groupVerified = true`、
    /// `roundVerified = false`），GROUP_B 收尾时两者都为 true，两个布尔写反即失败。
    function test_OriginScoresSubmittedSeparatesGroupAndRoundVerified() external {
        _bindVerifier();
        vm.expectEmit(true, true, true, true);
        emit OriginScoresSubmitted({
            tokenAddress: TOKEN,
            actionId: ACTION_ID,
            groupId: GROUP_A,
            round: ROUND,
            verifierId: VERIFIER_ID,
            startIndex: 0,
            totalFinalScore: MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 90 + MEMBER_AMOUNT_C * 80,
            verifiedGroupCount: 1,
            roundVerified: false,
            groupVerified: true,
            scores: _scores(100, 90, 80)
        });
        _submit(GROUP_A, 0, _scores(100, 90, 80));

        vm.expectEmit(true, true, true, true);
        emit OriginScoresSubmitted({
            tokenAddress: TOKEN,
            actionId: ACTION_ID,
            groupId: GROUP_B,
            round: ROUND,
            verifierId: VERIFIER_ID,
            startIndex: 0,
            totalFinalScore: MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_B * 90 + MEMBER_AMOUNT_C * 80 + 40e18 * 50,
            verifiedGroupCount: 2,
            roundVerified: true,
            groupVerified: true,
            scores: _scores(50)
        });
        _submit(GROUP_B, 0, _scores(50));
    }

    function test_SameRoundChurnKeepsFinalOrderVerifiable() external {
        _bindVerifier();
        // Member 2 leaves and re-joins within the round: the round keeps the final arrangement [1, 3, 2].
        _layout.memberIdsByGroupId[TOKEN][ACTION_ID][GROUP_A].remove(ROUND, 2);
        _layout.groupHistoryByMemberId[TOKEN][ACTION_ID][2].record(ROUND, 0);
        _layout.memberIdsByGroupId[TOKEN][ACTION_ID][GROUP_A].add(ROUND, 2);
        _layout.groupHistoryByMemberId[TOKEN][ACTION_ID][2].record(ROUND, GROUP_A);

        _submit(GROUP_A, 0, _scores(100, 90, 80));

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        (uint256 score3, bool verified3) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 3);
        require(score1 == 100 && verified1, "slot 0 scored first");
        require(score3 == 90 && verified3, "displaced member scored in new slot");
        require(score2 == 80 && verified2, "re-added member scored last");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND)
                == MEMBER_AMOUNT_A * 100 + MEMBER_AMOUNT_C * 90 + MEMBER_AMOUNT_B * 80,
            "totals follow the final arrangement"
        );
        require(_layout.originScoreDeductionByMemberId[TOKEN][ACTION_ID][ROUND][3] == 10, "deduction follows member 3");
    }

    function test_PartialBatchRemainderStaysUnverified() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100));
        _submit(GROUP_A, 1, _scores(90));

        (uint256 score3, bool verified3) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 3);
        require(score3 == 0 && !verified3, "remainder stays unverified");
        require(
            GroupActionVerify.verifiedMemberCount(_layout, TOKEN, ACTION_ID, ROUND, GROUP_A) == 2,
            "cursor at batch boundary"
        );

        _submit(GROUP_A, 2, _scores(80));
        (score3, verified3) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 3);
        require(score3 == 80 && verified3, "remainder verified by final batch");
        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(score1 == 100 && verified1, "first batch untouched");
    }

    function test_SlotMismatchIsRejectedAsUnverified() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60));

        // Corrupt the slot lookup only: the member index still points at slot 0.
        _layout.memberIdsByGroupId[TOKEN][ACTION_ID][GROUP_A].slotHistory[0].record(ROUND, 99);

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(score1 == 0 && !verified1, "slot mismatch rejected");
        (uint256 final1, bool finalVerified1) = GroupActionVerify.finalScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        require(final1 == 0 && !finalVerified1, "slot mismatch final zero");
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 2);
        require(score2 == 60 && verified2, "unrelated member unchanged");
    }

    function test_DeductionsIsolatedAcrossRounds() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(60));

        phase.setCurrentPhase(4);
        _layout.lockedVerifierId[TOKEN][ACTION_ID][ROUND + 1] = VERIFIER_ID;
        _submit(GROUP_A, 0, _scores(100));

        (uint256 score1, bool verified1) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 1);
        (uint256 score2, bool verified2) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND + 1, 1);
        require(score1 == 60 && verified1, "round 1 deduction intact");
        require(score2 == 100 && verified2, "round 2 full score decodes from empty slot");
        require(_layout.originScoreDeductionByMemberId[TOKEN][ACTION_ID][ROUND][1] == 40, "round 1 slot");
        require(_layout.originScoreDeductionByMemberId[TOKEN][ACTION_ID][ROUND + 1][1] == 0, "round 2 no slot");
        require(
            GroupActionVerify.totalFinalScore(_layout, TOKEN, ACTION_ID, ROUND + 1) == MEMBER_AMOUNT_A * 100,
            "round 2 totals"
        );
    }

    function test_MemberWithoutGroupReturnsZero() external {
        _bindVerifier();
        _submit(GROUP_A, 0, _scores(100, 60, 30));

        (uint256 score, bool verified) = GroupActionVerify.originScore(_layout, TOKEN, ACTION_ID, ROUND, 99);
        require(score == 0 && !verified, "no group attribution is unverified");
    }

    function _seedMember(uint256 memberId, uint256 groupId, uint256 amount) internal {
        _layout.memberIdsByGroupId[TOKEN][ACTION_ID][groupId].add(ROUND, memberId);
        _layout.groupHistoryByMemberId[TOKEN][ACTION_ID][memberId].record(ROUND, groupId);
        _layout.ownAmountHistoryByMemberId[TOKEN][ACTION_ID][memberId].record(ROUND, amount);
    }

    function _bindVerifier() internal {
        // The library runs via delegatecall and inherits this frame's msg.sender, and the
        // cheatcode prank does not reach delegatecalls, so bind the owner at call time.
        memberNFT.setOwner(VERIFIER_ID, msg.sender);
    }

    function _submit(uint256 groupId, uint256 startIndex, uint256[] memory scores) internal {
        GroupActionVerify.submitOriginScores(_layout, TOKEN, ACTION_ID, VERIFIER_ID, groupId, startIndex, scores);
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

    function _scores(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }
}
