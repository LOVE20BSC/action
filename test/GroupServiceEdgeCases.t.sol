// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

/// @dev Boundary behaviors that do not belong to any single happy path: the
///      saturated ratios, the round snapshots around exit and late joins, the
///      parent/child token pairing, empty rewards, unlocked verifiers, batch
///      rollback and the pre-mint projections.
contract GroupServiceEdgeCasesTest is GroupServiceTestBase {
    function testFullVerifierRatioLeavesTheOwnerSideEmpty() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        // The pure owner side floors to zero and there is nothing to burn
        // either, so the mint reverts instead of paying an empty reward.
        (
            uint256 projectedVerifier,
            uint256 projectedOwner,,
            uint256 projectedDistributed,
            uint256 projectedRemaining,
        ) = executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(
            projectedVerifier == 0 && projectedOwner == 0 && projectedDistributed == 0 && projectedRemaining == 0,
            "owner projects nothing at the full verifier ratio"
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);

        (uint256 verifierMint, uint256 verifierBurn) = _settleService(VERIFIER_ID);
        require(verifierMint == SERVICE_REWARD, "verifier takes the whole reward");
        require(verifierBurn == 0, "nothing burned");
        require(token.balanceOf(address(executor)) == 0, "executor drained by the verifier alone");
    }

    function testLateJoinHoldsFromThatRoundButNotTheEarlierOne() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _atPhase(VERIFY_PHASE);

        // A service proposal stays joinable after its creation round: the snapshot starts at the round
        // joined and runs until exit, so this join covers SERVICE_ROUND + 1 onwards.
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        vm.prank(GROUP_OWNER_B);
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID);
        require(
            executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_OWNER_B_ID) == false,
            "late join does not reach back to the creation round"
        );
        require(
            executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND + 1, GROUP_OWNER_B_ID),
            "late join holds from the joined round on"
        );

        _setGroupLedger(
            GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(GROUP_REWARD, GROUP_REWARD), VERIFIER_ID
        );
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        // The timely joiner still earns its share of the enlarged divisor.
        (uint256 ownerMint,) = _settleService(GROUP_ID);
        require(ownerMint == 225e18, "half of the owner half on a divisor of 200");

        (uint256 verifierReward, uint256 ownerReward,, uint256 distributed, uint256 remaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_OWNER_B_ID);
        require(
            verifierReward == 0 && ownerReward == 0 && distributed == 0 && remaining == 0 && !claimed,
            "late joiner projects nothing for the original round"
        );

        vm.prank(GROUP_OWNER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_OWNER_B_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
    }

    function testExitAfterJoinStillSettlesTheJoinedRound() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, 0);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
        _exitService(GROUP_ID);
        _atPhase(MINT_PHASE);

        require(
            executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID),
            "the joined round stays joined after the exit"
        );
        require(
            !executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND + 1, GROUP_ID),
            "the exit clears the later rounds"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD && burnAmount == 0, "exited member settles the joined round");
        require(token.balanceOf(GROUP_OWNER) == SERVICE_REWARD, "reward paid despite the exit");
    }

    function testSetRecipientsBeforeTheVerifyRoundReverts() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);

        // The verify round only opens at phase 3; earlier phases have none.
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, new uint256[](0), new uint256[](0));

        // At the join phase the verify round exists and the call goes through.
        _atPhase(JOIN_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        (uint256[] memory recipientIds, uint256[] memory ratios,) =
            executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, 1);
        require(recipientIds.length == 1 && ratios[0] == PRECISION / 2, "stored at the verify round");
    }

    function testSettlementServesAParentTokenWithAChildAction() external {
        _atPhase(CREATION_PHASE);
        // The service token is the parent of the served action token; every
        // community read must key on the action token, not the service token.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActionsOn(address(childToken), _ids(GROUP_ACTION_ID));
        groupAction.setHasActiveGroups(address(childToken), GROUP_ID, true);
        groupAction.setVerifierApplication(address(childToken), GROUP_ACTION_ID, VERIFIER_ID, 1, 0);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        groupAction.setGroupIds(address(childToken), GROUP_ACTION_ID, SERVICE_ROUND, _ids(GROUP_ID));
        groupAction.setGroupReward(address(childToken), GROUP_ACTION_ID, SERVICE_ROUND, GROUP_ID, GROUP_REWARD);
        groupAction.setLockedVerifierId(address(childToken), GROUP_ACTION_ID, SERVICE_ROUND, VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);

        string[] memory remarks = new string[](1);
        remarks[0] = "";
        vm.prank(GROUP_OWNER);
        executor.setRecipients(
            address(childToken), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER2_ID), _ratios(PRECISION), remarks
        );
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(childToken), SERVICE_ROUND) == GROUP_REWARD,
            "divisor read from the child action token"
        );

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18 && ownerBurn == 0, "owner share computed off the child token");
        require(token.balanceOf(MEMBER2) == 450e18, "recipient paid in the service token");
        require(token.balanceOf(GROUP_OWNER) == 0, "owner redirected everything");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier share computed off the child token");
        require(token.balanceOf(address(executor)) == 0, "executor drained");
    }

    function testZeroServiceRewardRevertsWithoutMinting() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(0);
        _atPhase(MINT_PHASE);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(actionTarget.mintRewardCalls() == 0, "no mint attempted without a reward");


        // The failed attempt is not a one-way door.
        _armServiceReward(SERVICE_REWARD);
        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "settles once a reward exists");
    }

    function testProjectionViewsReturnZerosForUnsettleableRounds() external {
        _standardScenario();

        // The mint round has not opened yet at the verify phase: both projection
        // views stay zero instead of reverting, so integrators can read any
        // round without guarding the phase first.
        _atPhase(VERIFY_PHASE);
        (uint256 verifierReward, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(
            verifierReward == 0 && ownerReward == 0 && ownerDistributed == 0 && ownerRemaining == 0 && !claimed,
            "service reward projection is zero before the mint round"
        );

        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(mintAmount == 0 && burnAmount == 0 && !minted, "base projection is zero before the mint round");

        // A never-created action is not settleable either.
        (
            uint256 strayVerifier,
            uint256 strayOwner,,
            uint256 strayDistributed,
            uint256 strayRemaining,
            bool strayClaimed
        ) = executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID + 99, SERVICE_ROUND, GROUP_ID);
        require(
            strayVerifier == 0 && strayOwner == 0 && strayDistributed == 0 && strayRemaining == 0 && !strayClaimed,
            "uncreated action projects zeros"
        );
        (uint256 strayMint,, bool strayMinted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID + 99, SERVICE_ROUND, GROUP_ID);
        require(strayMint == 0 && !strayMinted, "uncreated action base projection is zero");
    }

    function testMintedZeroAfterARichProjectionReverts() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        // The projection is rich but the mint itself pays nothing: the reward
        // was consumed elsewhere. The recheck after the mint must refuse to
        // settle a zero payout instead of recording an empty reward.
        _armServiceReward(SERVICE_REWARD);
        actionTarget.setMintReturnAmount(0);
        _atPhase(MINT_PHASE);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);

        // The revert rolled the whole call back: nothing is recorded and the
        // projection still derives the same reward, so the member can retry
        // once the mint can actually pay.
        (, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(!claimed, "nothing recorded for the failed mint");
        require(ownerReward == SERVICE_REWARD / 2, "projection unchanged after the failed mint");
        require(ownerDistributed == 0 && ownerRemaining == ownerReward, "no split recorded either");
        require(token.balanceOf(address(executor)) == SERVICE_REWARD, "failed mint moves no assets");
        require(token.burnedTotal() == 0, "failed mint burns nothing");
    }

    function testUnlockedActionCountsTowardTheDivisorOnly() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        // Action B locked no verifier: its reward feeds the divisor, but no
        // member earns a verifier weight from it. Its zero-reward group earns
        // no owner weight either.
        groupAction.setGroupIds(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, _ids(GROUP_ID, GROUP_OWNER_B_ID));
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, GROUP_ID, 40e18);
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, GROUP_OWNER_B_ID, 0);
        groupAction.setLockedVerifierId(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, 0);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18,
            "unlocked action still counts toward the divisor"
        );

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18 && ownerBurn == 0, "owner share on the full divisor");

        (uint256 verifierMint, uint256 verifierBurn) = _settleService(VERIFIER_ID);
        require(verifierMint == 270e18, "verifier earns only from the locked action");
        require(verifierBurn == 0, "verifiers never burn");

        vm.prank(GROUP_OWNER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_OWNER_B_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
    }

    function testBatchRollsBackWhenOneActionWasAlreadyMinted() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, 0);
        _createServiceAction(SERVICE_ACTION_ID + 1, 0, 0);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        vm.prank(GROUP_OWNER);
        executor.join(address(token), SERVICE_ACTION_ID + 1, GROUP_ID);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        actionTarget.setActionReward(address(token), SERVICE_ACTION_ID + 1, SERVICE_ROUND, SERVICE_REWARD, false);
        token.mint(address(executor), SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        _settleService(GROUP_ID);
        uint256 callsAfterFirst = actionTarget.mintRewardCalls();

        // The already-minted action poisons the whole batch.
        uint256[] memory actionIds = _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 1);
        uint256[] memory rounds = _ids(SERVICE_ROUND, SERVICE_ROUND);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberRewards(address(token), actionIds, GROUP_ID, rounds);
        require(actionTarget.mintRewardCalls() == callsAfterFirst, "no mint from the failed batch");

        // The untouched action still settles on its own afterwards.
        vm.prank(GROUP_OWNER);
        (uint256[] memory mintAmounts,) =
            executor.mintMemberRewards(address(token), _ids(SERVICE_ACTION_ID + 1), GROUP_ID, _ids(SERVICE_ROUND));
        require(mintAmounts[0] == SERVICE_REWARD, "the rolled back action settles afterwards");
    }

    function testProjectedRewardsMatchTheSettlementBeforeMinting() external {
        _standardScenario();

        (
            uint256 ownerVerifier,
            uint256 ownerReward,
            uint256 ownerBurned,
            uint256 ownerDistributed,
            uint256 ownerRemaining,
            bool ownerClaimed
        ) = executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(!ownerClaimed, "not claimed before the mint");
        require(ownerVerifier == 0 && ownerReward == 450e18, "owner projection");
        require(
            ownerBurned == 0 && ownerDistributed == 0 && ownerRemaining == 450e18,
            "owner keeps it all without recipients"
        );

        (
            uint256 verifierVerifier,
            uint256 verifierOwner,,
            uint256 verifierDistributed,
            uint256 verifierRemaining,
            bool verifierClaimed
        ) = executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, VERIFIER_ID);
        require(!verifierClaimed && verifierVerifier == 450e18, "verifier projection");
        require(verifierOwner == 0 && verifierDistributed == 0 && verifierRemaining == 0, "verifier has no owner side");

        (uint256 projectedMint, uint256 projectedBurn, bool projectedMinted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(!projectedMinted && projectedMint == 450e18 && projectedBurn == 0, "ledger projection");

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == projectedMint && burnAmount == projectedBurn, "projection matched the payout exactly");
    }

    function _setVotedGroupActionsOn(address actionTokenAddress, uint256[] memory actionIds) internal {
        address[] memory executors = new address[](actionIds.length);
        for (uint256 i = 0; i < actionIds.length; i++) {
            executors[i] = address(groupAction);
        }
        actionTarget.setVotedActions(actionTokenAddress, SERVICE_ROUND, actionIds, executors);
    }
}
