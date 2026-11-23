// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorErrors, IGroupServiceExecutorEvents} from "../src/interfaces/IGroupServiceExecutor.sol";
import {IActionTargetEvents} from "../src/interfaces/IActionTarget.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {GroupServiceTestBase, GroupServiceVm} from "./GroupServiceTestBase.sol";

contract GroupServiceSettlementTest is GroupServiceTestBase {
    function testSettlementSplitsBetweenVerifierAndOwner() external {
        _standardScenario();

        // The owner settles first, using the source round's verification total.
        uint256 ownerBefore = token.balanceOf(GROUP_OWNER);
        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18, "owner half of the service reward");
        require(ownerBurn == 0, "cap off, nothing burned");
        require(token.balanceOf(GROUP_OWNER) - ownerBefore == 450e18, "owner paid out");
        require(actionTarget.mintRewardCalls() == 1, "reward minted once");
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18,
            "denominator uses the source round total"
        );

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
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), GROUP_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        uint256 before = token.balanceOf(GROUP_OWNER);
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD, "both roles paid from the same reward");
        require(burnAmount == 0, "nothing burned");
        require(token.balanceOf(GROUP_OWNER) - before == SERVICE_REWARD, "member received both halves");
    }

    function testOwnerAndVerifierClaimsUseTheActualServiceBudget() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(200);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 20, false);
        _atPhase(MINT_PHASE);

        (uint256 quotedOwnerReward, bool ownerMinted) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(quotedOwnerReward == 10 && !ownerMinted, "view uses the pre-mint quote");

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 100,
            "owner receives the share of the actual budget"
        );
        (uint256 ownerPaid, bool ownerSettled) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(ownerPaid == 100 && ownerSettled, "owner query reports the actual payment");

        (uint256 quotedVerifierReward, bool verifierMinted) =
            executor.verifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        require(quotedVerifierReward == 100 && !verifierMinted, "verifier query reads the minted budget");
        vm.prank(VERIFIER);
        require(
            executor.mintVerifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID) == 100,
            "verifier receives the actual budget share"
        );
        require(actionTarget.mintRewardCalls() == 1, "actual service budget is minted once");
    }

    function testCombinedPrimaryMintUsesTheActualServiceBudget() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), GROUP_ID);
        _armServiceReward(200);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 20, false);
        _atPhase(MINT_PHASE);

        vm.prank(GROUP_OWNER);
        require(
            executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 200,
            "combined claim pays both shares from the actual budget"
        );
        require(token.balanceOf(GROUP_OWNER) == 200, "combined actual payout reaches the identity owner");
        require(actionTarget.mintRewardCalls() == 1, "combined claim mints one service budget");
    }

    function testSettlementBurnsOwnerOverflowUnderGovCap() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 10e18);
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
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(ownerBurned == 360e18, "burn recorded per member");
    }

    function testSettlementCapBoundaryKeepsTheTheoreticalReward() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // govRatio = 0.5e18, cap = 0.5e18, cap * D = 50e36 == W = 50e36: the
        // cross-multiplied comparison keeps the boundary on the uncapped side.
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 50e18);
        _atPhase(MINT_PHASE);

        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 450e18 && ownerBurn == 0, "equality keeps the theoretical reward");
        require(token.burnedTotal() == 0, "no dust burn at the boundary");
    }

    function testSettlementCapsEachOwnerByTheirOwnGovVotes() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        // Two groups earn different rewards in the same action, so the owners'
        // weights differ while the divisor stays shared.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(60e18, 40e18), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // Owner A holds 10% of the global votes, owner B 40%.
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 10e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_OWNER_B_ID, 40e18);
        _atPhase(MINT_PHASE);

        // Owner A: cap = 0.1e18, cap * D = 10e36 < W = 30e36 -> capped at 90e18.
        (uint256 ownerAMint, uint256 ownerABurn) = _settleService(GROUP_ID);
        require(ownerAMint == 90e18 && ownerABurn == 180e18, "owner A capped by their own votes");

        // Owner B: cap = 0.4e18, cap * D = 40e36 >= W = 20e36 -> uncapped.
        (uint256 ownerBMint, uint256 ownerBBurn) = _settleService(GROUP_OWNER_B_ID);
        require(ownerBMint == 180e18 && ownerBBurn == 0, "owner B uncapped at their own votes");

        (,, uint256 burnedA,,,) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        (,, uint256 burnedB,,,) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_OWNER_B_ID);
        require(burnedA == 180e18 && burnedB == 0, "burns recorded per owner");
        require(token.burnedTotal() == 180e18, "only the capped owner burned");
    }

    function testSettlementCapNotTriggeredLeavesNoDust() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        // cap = 1e18, cap * D = 100e36 >= W = 50e36 -> the cap never binds.
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 100e18);
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
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 100e18);
        _atPhase(VERIFY_PHASE);
        stake.setTotalGovVotes(address(token), 0);
        stake.setGovVotes(address(token), GROUP_ID, 0);
        _atPhase(MINT_PHASE);

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 0 && status == MemberRewardStatus.Pending, "owner burn is pending");

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 0, "owner reward fully capped away");
        require(burnAmount == 450e18, "theoretical owner reward burned");
        require(token.burnedTotal() == 450e18, "burn executed");

        (pending, minted, status) = executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 0 && status == MemberRewardStatus.Settled, "owner burn settled");
    }

    function testSettlementSumsVerifierWeightAcrossActions() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
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

    function testVerifierClaimsFromTheRecordedWeightWithoutReadingGroupSlices() external {
        _standardScenario();
        groupAction.setGroupSliceReadsBlocked(true);
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD,
            "divisor read from the source round total"
        );
        (uint256 projected,,) = _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        (uint256 claimed,) = _settleService(VERIFIER_ID);
        require(projected == 450e18 && claimed == projected, "verifier half");
    }

    function testParentServiceReadsRecordedSourceRoundTotalAndWeights() external {
        address serviceTokenAddress = address(token);
        address actionTokenAddress = address(childToken);
        _atPhase(CREATION_PHASE);
        _createServiceActionOn(serviceTokenAddress, actionTokenAddress, SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        groupAction.setHasActiveGroups(actionTokenAddress, GROUP_ID, true);
        groupAction.setVerifierApplication(actionTokenAddress, VERIFIER_ID, CREATION_PHASE);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        groupAction.setGroupLedger(
            actionTokenAddress, SERVICE_ROUND, GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID
        );
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(400e18), GROUP_ID);
        _armServiceRewardOn(SERVICE_ACTION_ID, SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(executor.totalGroupActionReward(actionTokenAddress, SERVICE_ROUND) == GROUP_REWARD, "child total");
        require(executor.totalGroupActionReward(serviceTokenAddress, SERVICE_ROUND) == 400e18, "independent parent total");

        // Cross-token settlement: the two address fields must not be interchangeable.
        vm.recordLogs();
        (uint256 ownerMint,) = _settleService(GROUP_ID);
        require(ownerMint == 450e18, "owner uses the child group weight");
        GroupServiceVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 splitTopic = IGroupServiceExecutorEvents.ServiceRewardsDistributed.selector;
        bool splitSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != splitTopic) continue;
            require(
                logs[i].topics[1] == bytes32(uint256(uint160(serviceTokenAddress))), "split service token topic"
            );
            require(logs[i].topics[2] == bytes32(SERVICE_ACTION_ID), "split action topic");
            require(logs[i].topics[3] == bytes32(uint256(uint160(actionTokenAddress))), "split action token topic");
            splitSeen = true;
        }
        require(splitSeen, "missing ServiceRewardsDistributed");
        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier uses the child verification weight");
    }

    /// @dev The owner weight is the sum of floored per-group slices, so it can stay below the
    ///      action-level divisor. The difference is not redistributed; it stays in the executor.
    function testOwnerFloorResidueStaysInTheExecutor() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(1, 1), VERIFIER_ID);
        // Divisor 3, two slices of floor(3 * 1 / 2) = 1 each: one wei of the action reward is
        // unallocated at the group level, so the owner weights cover 2/3 of the divisor.
        groupAction.setActionReward(address(token), SERVICE_ROUND, GROUP_ACTION_ID, 3);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        (uint256 first,) = _settleService(GROUP_ID);
        (uint256 second,) = _settleService(GROUP_OWNER_B_ID);
        require(first == 150e18 && second == 150e18, "each owner takes a sixth");
        require(
            token.balanceOf(address(executor)) == 600e18,
            "the verifier half and the unallocated third stay in the executor"
        );
    }

    function testSourceRoundTotalIgnoresTheNumberOfGroups() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);

        uint256 groupCount = 101;
        uint256[] memory groupIds = new uint256[](groupCount);
        uint256[] memory rewards = new uint256[](groupCount);
        groupIds[0] = GROUP_ID;
        rewards[0] = GROUP_REWARD;
        for (uint256 i = 1; i < groupCount; i++) {
            groupIds[i] = 1000 + i;
            rewards[i] = GROUP_REWARD;
        }
        _setGroupLedger(GROUP_ACTION_ID, groupIds, rewards, VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        groupAction.setGroupSliceReadsBlocked(true);
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == groupCount * GROUP_REWARD,
            "divisor covers every group without walking them"
        );
        groupAction.setGroupSliceReadsBlocked(false);

        (uint256 ownerMint,) = _settleService(GROUP_ID);
        require(ownerMint > 0, "owner paid on a wide round");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier half on the same divisor");
    }

    function testZeroDenominatorBlocksSettlementUntilTheLedgerPays() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        // No recorded source rewards: the denominator is 0 and the claim reverts.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), SERVICE_ROUND)
        );
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);

        require(executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 0, "zero denominator");
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == GROUP_REWARD,
            "recorded total after the ledger gains an action"
        );

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "settlement succeeds once the denominator exists");
    }

    function testSettlementRevertsWithoutJoinOrWeights() external {
        _standardScenario();

        // Joined through the verifier branch but is neither the group owner nor the locked verifier.
        _atPhase(JOIN_PHASE);
        _qualifyVerifier(MEMBER1_ID);
        vm.prank(MEMBER1);
        executor.join(address(token), SERVICE_ACTION_ID, MEMBER1_ID);
        _atPhase(MINT_PHASE);

        (uint256 verifierReward, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(
            verifierReward == 0 && ownerReward == 0 && ownerDistributed == 0 && ownerRemaining == 0 && !claimed,
            "projected zeros without weights"
        );

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.ZeroRewardWeight.selector,
                address(token),
                SERVICE_ACTION_ID,
                MEMBER1_ID
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);

        // A member who never joined the service at all earns nothing either.
        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER2_ID);
        require(mintAmount == 0 && burnAmount == 0 && !minted, "outsider sees zeros");

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.ZeroRewardWeight.selector,
                address(token),
                SERVICE_ACTION_ID,
                MEMBER2_ID
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER2_ID);
    }

    function testSettlementRoundWindow() external {
        _atPhase(CREATION_PHASE);
        // Ratio 0: the whole reward belongs to the owner side.
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);

        _atPhase(VERIFY_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, SERVICE_ROUND, 1));
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);

        _atPhase(MINT_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, SERVICE_ROUND - 1, 2));
        executor.mintMemberReward(address(token), SERVICE_ROUND - 1, SERVICE_ACTION_ID, GROUP_ID);

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD / 2, "the owner side keeps the non-verifier share");
    }

    function testBatchSettlementPairsArraysAndRollsBack() external {
        _atPhase(CREATION_PHASE);
        // Ratio 0: the whole reward belongs to the owner side.
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _createServiceAction(SERVICE_ACTION_ID + 1, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        vm.prank(GROUP_OWNER);
        executor.join(address(token), SERVICE_ACTION_ID + 1, GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID + 1, SERVICE_REWARD, false);
        token.mint(address(executor), SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        uint256[] memory actionIds = _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 1);
        uint256[] memory rounds = _ids(SERVICE_ROUND, SERVICE_ROUND);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        executor.mintMemberRewards(address(token), _ids(SERVICE_ROUND), actionIds, GROUP_ID);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, GROUP_ID));
        executor.mintMemberRewards(address(token), _ids(SERVICE_ROUND), actionIds, GROUP_ID);

        // One element that was never created rolls the whole batch back.
        actionIds = _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 2);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.ActionNotCreated.selector, address(token), SERVICE_ACTION_ID + 2
            )
        );
        executor.mintMemberRewards(address(token), rounds, actionIds, GROUP_ID);
        require(actionTarget.mintRewardCalls() == 0, "no action settled from the failed batch");

        // Owner check precedes action existence on the single-settlement entry.
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID + 2, MEMBER1_ID);

        vm.prank(GROUP_OWNER);
        uint256[] memory mintAmounts =
            executor.mintMemberRewards(address(token), rounds, _ids(SERVICE_ACTION_ID, SERVICE_ACTION_ID + 1), GROUP_ID);
        require(mintAmounts.length == 2, "pairwise results");
        require(mintAmounts[0] == SERVICE_REWARD / 2 && mintAmounts[1] == SERVICE_REWARD / 2, "both actions paid");
        require(token.burnedTotal() == 0, "nothing burned");
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
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
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
        ) = _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(claimed, "claimed flag");
        require(verifierReward == 0 && ownerReward == 450e18, "roles recorded");
        require(ownerBurned == 0, "no burn recorded");
        require(ownerDistributed == 0 && ownerRemaining == 450e18, "owner kept everything without recipients");

        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(minted && mintAmount == 450e18 && burnAmount == 0, "base ledger recorded");
    }

    function testPendingAndSettledRewardsUseVotesAtTheEndOfVerification() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 5e18);
        _atPhase(VERIFY_PHASE);
        stake.setGovVotes(address(token), GROUP_ID, 10e18);
        _atPhase(MINT_PHASE);

        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(!minted && mintAmount == 90e18 && burnAmount == 360e18, "initial owner cap");
        stake.setTotalGovVotes(address(token), 200e18);
        stake.setGovVotes(address(token), GROUP_ID, 50e18);
        (mintAmount, burnAmount, minted) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(!minted && mintAmount == 90e18 && burnAmount == 360e18, "later votes do not change the cap");
        (, uint256 ownerReward, uint256 pendingBurn,,,) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(ownerReward == 90e18 && pendingBurn == 360e18, "service quote uses the verification snapshot");
        (uint256 ownerMint, uint256 ownerBurn) = _settleService(GROUP_ID);
        require(ownerMint == 90e18 && ownerBurn == 360e18, "settlement uses the same snapshot");

        // The votes move underneath a settled round.
        stake.setGovVotes(address(token), GROUP_ID, 0);
        stake.setTotalGovVotes(address(token), 1e18);

        // The recorded result survives: no recompute, no re-burn.
        (,, uint256 ownerBurned,,, bool claimed) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(claimed && ownerBurned == 360e18, "recorded burn ignores later votes");
        (mintAmount, burnAmount, minted) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(minted && mintAmount == 90e18 && burnAmount == 360e18, "base ledger ignores later votes");
        (uint256 verifierMint, uint256 verifierBurn) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18 && verifierBurn == 0, "verifier reward ignores the owner cap");
    }

    function testSettlementTinyAmountsWithFullRedistribution() external {
        // Legacy minimal reproduction: S = 3, T = 3, G = 2, g = 2 with a 100%
        // recipient configuration. The old double floor underflowed here.
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        // Two groups in the action: this group earns 2 of the 3 total.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(2, 1), VERIFIER_ID);
        _armServiceReward(3);
        _atPhase(VERIFY_PHASE);

        // 100% of the owner slice goes to one recipient.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));

        _atPhase(MINT_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.ZeroOwnerRewardRemaining.selector, GROUP_ID));
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 1, "recipient claims the full slice");
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

}
