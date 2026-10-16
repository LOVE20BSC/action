// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IActionTargetEvents} from "../src/interfaces/IActionTarget.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceSettlementTest is GroupServiceTestBase {
    function testSettlementSplitsBetweenVerifierAndOwner() external {
        _standardScenario();

        // The owner settles first: the mint happened, the denominator is frozen.
        uint256 ownerBefore = token.balanceOf(GROUP_OWNER);
        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18, "owner half of the service reward");
        require(ownerBurn == 0, "cap off, nothing burned");
        require(token.balanceOf(GROUP_OWNER) - ownerBefore == 450e18, "owner paid out");
        require(actionTarget.mintRewardCalls() == 1, "reward minted once");
        require(executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18, "denominator cached");

        // The verifier settles second: reads the already minted reward.
        (uint256 verifierMint, uint256 verifierBurn) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier half of the service reward");
        require(verifierBurn == 0, "verifier side never burns");
        require(token.balanceOf(VERIFIER) == 450e18, "verifier paid out");
        require(actionTarget.mintRewardCalls() == 1, "no second mint");

        // Conservation: everything minted plus burned never exceeds the reward.
        require(
            token.balanceOf(GROUP_OWNER) - ownerBefore + token.balanceOf(VERIFIER) + token.burnedTotal()
                == SERVICE_REWARD,
            "transfers sum to the service reward"
        );
        require(token.balanceOf(address(executor)) == 0, "executor keeps no reward");
    }

    function testSettlementDualRoleMemberEarnsBothShares() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        // The same member owns the only group and is its locked verifier.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), GROUP_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        uint256 before = token.balanceOf(GROUP_OWNER);
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD, "both roles paid from the same reward");
        require(burnAmount == 0, "nothing burned");
        require(token.balanceOf(GROUP_OWNER) - before == SERVICE_REWARD, "member received both halves");
    }

    function testSettlementBurnsOwnerOverflowUnderGovCap() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setGlobalGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 10e18);
        _atPhase(MINT_PHASE);

        // govRatio = 0.1e18, cap = 0.1e18, cap * D = 10e36 < W = 50e36 -> capped.
        uint256 ownerBefore = token.balanceOf(GROUP_OWNER);
        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 90e18, "owner capped at the gov ratio");
        require(ownerBurn == 360e18, "overflow burned, not redistributed");
        require(token.balanceOf(GROUP_OWNER) - ownerBefore == 90e18, "capped amount paid");
        require(token.burnedTotal() == 360e18, "burned from the executor balance");

        // The verifier share is untouched by the owner cap.
        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier unaffected by the owner cap");
        require(token.balanceOf(VERIFIER) == 450e18, "verifier paid in full");
        require(
            token.balanceOf(GROUP_OWNER) - ownerBefore + token.balanceOf(VERIFIER) + token.burnedTotal()
                == SERVICE_REWARD,
            "minted plus burned equals the reward"
        );

        (,, uint256 ownerBurned,,,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(ownerBurned == 360e18, "burn recorded per member");
    }

    function testSettlementCapBoundaryKeepsTheTheoreticalReward() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // govRatio = 0.5e18, cap = 0.5e18, cap * D = 50e36 == W = 50e36: the
        // cross-multiplied comparison keeps the boundary on the uncapped side.
        stake.setGlobalGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 50e18);
        _atPhase(MINT_PHASE);

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18 && ownerBurn == 0, "equality keeps the theoretical reward");
        require(token.burnedTotal() == 0, "no dust burn at the boundary");
    }

    function testSettlementCapsEachOwnerByTheirOwnGovVotes() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        // Two groups earn different rewards in the same action, so the owners'
        // weights differ while the divisor stays shared.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(60e18, 40e18), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // Owner A holds 10% of the global votes, owner B 40%.
        stake.setGlobalGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 10e18);
        stake.setValidGovVotes(address(token), GROUP_OWNER_B_ID, 40e18);
        _atPhase(MINT_PHASE);

        // Owner A: cap = 0.1e18, cap * D = 10e36 < W = 30e36 -> capped at 90e18.
        (uint256 ownerAMint, uint256 ownerABurn) = _settleService(GROUP_ID);
        require(ownerAMint == 90e18 && ownerABurn == 180e18, "owner A capped by their own votes");

        // Owner B: cap = 0.4e18, cap * D = 40e36 >= W = 20e36 -> uncapped.
        (uint256 ownerBMint, uint256 ownerBBurn) = _settleService(GROUP_OWNER_B_ID);
        require(ownerBMint == 180e18 && ownerBBurn == 0, "owner B uncapped at their own votes");

        (,, uint256 burnedA,,,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        (,, uint256 burnedB,,,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_OWNER_B_ID);
        require(burnedA == 180e18 && burnedB == 0, "burns recorded per owner");
        require(token.burnedTotal() == 180e18, "only the capped owner burned");
    }

    function testSettlementCapNotTriggeredLeavesNoDust() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // cap = 1e18, cap * D = 100e36 >= W = 50e36 -> the cap never binds.
        stake.setGlobalGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 100e18);
        _atPhase(MINT_PHASE);

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "full theoretical owner reward");
        require(burnAmount == 0, "no rounding dust burn");
        require(token.burnedTotal() == 0, "nothing burned");
    }

    function testSettlementBurnsOwnerRewardWithoutGovVotes() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // The cap is on but the community has no governance votes at all.
        stake.setGlobalGovVotes(address(token), 0);
        _atPhase(MINT_PHASE);

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 0, "owner reward fully capped away");
        require(burnAmount == 450e18, "theoretical owner reward burned");
        require(token.burnedTotal() == 450e18, "burn executed");
    }

    function testSettlementSumsVerifierWeightAcrossActions() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18,
            "denominator aggregates every served action"
        );

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18, "owner weight spans both actions");
        require(ownerBurn == 0, "cap off");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier weight spans both locked actions");
    }

    function testSettlementIgnoresNonGroupActionsAndEmptyGroups() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        // A non-group executor action and an unverified action add nothing.
        actionTarget.setVotedActions(
            address(token),
            SERVICE_ROUND,
            _ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B),
            _addresses(address(groupAction), address(0xE0))
        );
        groupAction.setGroupIds(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, new uint256[](0));
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD,
            "only group actions with rewards count"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "owner paid on the filtered denominator");
        require(burnAmount == 0, "nothing burned");
    }

    function testSettlementEmptyGroupIdsContributeNothing() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        // Both actions are served by the group executor, but the second one
        // verified no group at all: the divisor read walks its empty list.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        groupAction.setGroupIds(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, new uint256[](0));
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD,
            "empty groups add nothing to the divisor"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18 && burnAmount == 0, "owner paid on the filtered denominator");
    }

    function testSettlementCachesDenominatorAndActionTotals() external {
        _standardScenario();

        // First settlement freezes the round divisor and each action total.
        _settleService(VERIFIER_ID);
        require(executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD, "divisor cached");

        // The served ledger moves afterwards: a new group joins action 21.
        groupAction.setGroupIds(address(token), GROUP_ACTION_ID, SERVICE_ROUND, _ids(GROUP_ID, GROUP_OWNER_B_ID));
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID, SERVICE_ROUND, GROUP_OWNER_B_ID, 400e18);

        // The owner settles on the cached numbers, not the live book.
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "owner reward uses the frozen divisor");
        require(burnAmount == 0, "nothing burned");
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD, "view reads the cache too"
        );
        require(actionTarget.mintRewardCalls() == 1, "still a single mint");
    }

    function testSettlementKeepsZeroDenominatorUncached() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        // No voted group actions: the denominator is 0 and the mint reverts.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);

        // The zero divisor is not cached: it is recomputed on every read.
        require(executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 0, "zero denominator");
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD,
            "recomputed after the ledger gains an action"
        );

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "settlement succeeds once the denominator exists");
    }

    function testSettlementRevertsWithoutJoinOrWeights() external {
        _standardScenario();

        // Joined through the candidate branch but neither owner nor verifier.
        _qualifyCandidate(MEMBER1_ID);
        vm.prank(MEMBER1);
        executor.join(address(token), SERVICE_ACTION_ID, MEMBER1_ID);

        (uint256 verifierReward, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, MEMBER1_ID);
        require(
            verifierReward == 0 && ownerReward == 0 && ownerDistributed == 0 && ownerRemaining == 0 && !claimed,
            "projected zeros without weights"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, MEMBER1_ID, SERVICE_ROUND);

        // A member who never joined the service at all earns nothing either.
        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, MEMBER2_ID, SERVICE_ROUND);
        require(mintAmount == 0 && burnAmount == 0 && !minted, "outsider sees zeros");

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, MEMBER2_ID, SERVICE_ROUND);
    }

    function testZeroDenominatorBlocksSettlement() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        // No group action produced a reward, so the divisor is zero and nothing can be paid out.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);

        // Once a group action yields a reward the divisor exists and the round settles normally.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        (uint256 ownerMint,) = _settleService(GROUP_ID);
        require(ownerMint > 0, "settles once the divisor exists");
    }

    function testSettlementRoundWindow() external {
        _atPhase(CREATION_PHASE);
        // Ratio 0: the whole reward belongs to the owner side.
        _createServiceAction(SERVICE_ACTION_ID, 0, 0);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);

        _atPhase(VERIFY_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.InvalidRound.selector, SERVICE_ROUND));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);

        _atPhase(MINT_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND - 1);

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD, "full reward goes to the owner at ratio 0");
    }

    function testBatchSettlementPairsArraysAndRollsBack() external {
        _atPhase(CREATION_PHASE);
        // Ratio 0: the whole reward belongs to the owner side.
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

        uint256[] memory actionIds = _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 1);
        uint256[] memory rounds = _ids(SERVICE_ROUND, SERVICE_ROUND);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        executor.mintMemberRewards(address(token), actionIds, GROUP_ID, _ids(SERVICE_ROUND));

        // One element that was never created rolls the whole batch back.
        actionIds = _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 2);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.mintMemberRewards(address(token), actionIds, GROUP_ID, rounds);
        require(actionTarget.mintRewardCalls() == 0, "no action settled from the failed batch");

        vm.prank(GROUP_OWNER);
        (uint256[] memory mintAmounts, uint256[] memory burnAmounts) =
            executor.mintMemberRewards(address(token), _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 1), GROUP_ID, rounds);
        require(mintAmounts.length == 2 && burnAmounts.length == 2, "pairwise results");
        require(mintAmounts[0] == SERVICE_REWARD && mintAmounts[1] == SERVICE_REWARD, "both actions paid");
        require(burnAmounts[0] == 0 && burnAmounts[1] == 0, "nothing burned");
    }

    function testSettlementCannotMintTwice() external {
        _standardScenario();
        _settleService(GROUP_ID);

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
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
    }

    function testSettlementReadsRecordedResultAfterMinting() external {
        _standardScenario();
        _settleService(GROUP_ID);

        (
            uint256 verifierReward,
            uint256 ownerReward,
            uint256 ownerBurned,
            uint256 ownerDistributed,
            uint256 ownerRemaining,
            bool claimed
        ) = executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(claimed, "claimed flag");
        require(verifierReward == 0 && ownerReward == 450e18, "roles recorded");
        require(ownerBurned == 0, "no burn recorded");
        require(ownerDistributed == 0 && ownerRemaining == 450e18, "owner kept everything without recipients");

        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(minted && mintAmount == 450e18 && burnAmount == 0, "base ledger recorded");
    }

    function testSettledQueriesIgnoreLaterGovVotes() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setGlobalGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 10e18);
        _atPhase(MINT_PHASE);

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 90e18 && ownerBurn == 360e18, "capped settlement recorded");

        // The votes move underneath a settled round.
        stake.setValidGovVotes(address(token), GROUP_ID, 0);
        stake.setGlobalGovVotes(address(token), 1e18);

        // The recorded result survives: no recompute, no re-burn.
        (,, uint256 ownerBurned,,, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(claimed && ownerBurned == 360e18, "recorded burn ignores later votes");
        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(minted && mintAmount == 90e18 && burnAmount == 360e18, "base ledger ignores later votes");
    }

    function testSettlementTinyAmountsWithFullRedistribution() external {
        // Legacy minimal reproduction: S = 3, T = 3, G = 2, g = 2 with a 100%
        // recipient configuration. The old double floor underflowed here.
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        // Two groups in the action: this group earns 2 of the 3 total.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(2, 1), VERIFIER_ID);
        _armServiceReward(3);
        _atPhase(VERIFY_PHASE);

        // 100% of the owner slice goes to one recipient.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));

        _atPhase(MINT_PHASE);
        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 1 && ownerBurn == 0, "owner theoretical reward floors to 1");
        require(token.balanceOf(MEMBER1) == 1, "recipient paid the full slice");
        require(token.balanceOf(GROUP_OWNER) == 0, "owner kept nothing");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 1, "verifier theoretical reward floors to 1");
        require(
            token.balanceOf(MEMBER1) + token.balanceOf(GROUP_OWNER) + token.balanceOf(VERIFIER)
                    + token.balanceOf(address(executor)) + token.burnedTotal() == 3,
            "all three wei accounted for"
        );
    }

    function _addresses(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }
}
