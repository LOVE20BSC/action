// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase, TestServiceRewardDetails} from "./GroupServiceTestBase.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {IGroupServiceExecutorErrors, MemberRewardSummary} from "../src/interfaces/IGroupServiceExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutor} from "../src/interfaces/IGroupActionExecutor.sol";

contract GroupServiceProviderIncentivesTest is GroupServiceTestBase {
    uint256 private constant MAX_REWARDS_PER_BATCH = 32;

    function testRewardBatchRejectsMismatchedArrayLengths() external {
        uint256[] memory sourceActionIds = _ids(GROUP_ACTION_ID, GROUP_ACTION_ID + 1);
        uint256[] memory groupIds = _ids(GROUP_ID);
        bytes memory errorData = abi.encodeWithSelector(
            IGroupServiceExecutorErrors.RewardArraysLengthMismatch.selector,
            sourceActionIds.length,
            groupIds.length
        );

        vm.expectRevert(errorData);
        vm.prank(MEMBER1);
        executor.mintProviderRewards(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds
        );

        vm.expectRevert(errorData);
        vm.prank(MEMBER1);
        executor.mintRecipientRewards(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds
        );
    }

    function testRewardBatchLimitRejectsMoreThanThirtyTwoKeys() external {
        uint256[] memory sourceActionIds = new uint256[](MAX_REWARDS_PER_BATCH + 1);
        uint256[] memory groupIds = new uint256[](MAX_REWARDS_PER_BATCH + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.TooManyRewards.selector,
                MAX_REWARDS_PER_BATCH + 1,
                MAX_REWARDS_PER_BATCH
            )
        );
        vm.prank(MEMBER1);
        executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.TooManyRewards.selector,
                MAX_REWARDS_PER_BATCH + 1,
                MAX_REWARDS_PER_BATCH
            )
        );
        vm.prank(MEMBER1);
        executor.mintRecipientRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);
    }

    function testRewardBatchChecksMemberOwnerBeforeSize() external {
        uint256[] memory sourceActionIds = new uint256[](MAX_REWARDS_PER_BATCH + 1);
        uint256[] memory groupIds = new uint256[](MAX_REWARDS_PER_BATCH + 1);
        bytes memory notMemberOwner = abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID);

        vm.expectRevert(notMemberOwner);
        vm.prank(MEMBER2);
        executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);

        vm.expectRevert(notMemberOwner);
        vm.prank(MEMBER2);
        executor.mintRecipientRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);
    }

    function testProviderBatchAtMaximumSizePaysEverySelectedKey() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(100 * MAX_REWARDS_PER_BATCH);
        for (uint256 i; i < MAX_REWARDS_PER_BATCH; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 100, MEMBER1_ID, 100
            );
        }
        _atPhase(MINT_PHASE);

        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithProviderRewardByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, false
        );
        require(total == 1 && groupIds.length == 1 && groupIds[0] == GROUP_ID, "provider group page");
        uint256[] memory sourceActionIds;
        (sourceActionIds, total) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, MAX_REWARDS_PER_BATCH, false
        );
        require(sourceActionIds.length == MAX_REWARDS_PER_BATCH && total == sourceActionIds.length, "maximum action page is batchable");
        uint256[] memory batchGroupIds = new uint256[](sourceActionIds.length);
        for (uint256 i; i < batchGroupIds.length; ++i) batchGroupIds[i] = GROUP_ID;

        vm.expectCall(
            address(groupAction),
            abi.encodeCall(IGroupActionExecutor.totalGeneratedActionRewardByGroupId, (address(token), SERVICE_ROUND, GROUP_ID)),
            1
        );
        uint256 beforeGas = gasleft();
        vm.prank(MEMBER1);
        uint256[] memory amounts =
            executor.mintProviderRewards(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, batchGroupIds
            );
        require(beforeGas - gasleft() < 10_000_000, "maximum Provider batch fits the local gas budget");
        require(amounts.length == MAX_REWARDS_PER_BATCH, "batch return aligns with keys");
        for (uint256 i; i < amounts.length; ++i) {
            require(amounts[i] == 25, "each Provider key receives its exact amount");
        }
        require(token.balanceOf(MEMBER1) == 25 * MAX_REWARDS_PER_BATCH, "batch actual payout matches its rows");
    }

    function testRecipientBatchAtMaximumSizePaysEverySelectedKey() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _armServiceReward(100 * MAX_REWARDS_PER_BATCH);
        _atPhase(VERIFY_PHASE);
        for (uint256 i; i < MAX_REWARDS_PER_BATCH / 2; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            groupAction.setJoinTokenAddress(address(token), sourceActionId, address(token));
            _setGroupLedger(sourceActionId, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(100, 100), VERIFIER_ID);
            _setRecipients(GROUP_ID, sourceActionId, _ids(MEMBER1_ID), _ratios(0.5e18));
            _setRecipients(GROUP_OWNER_B_ID, sourceActionId, _ids(MEMBER1_ID), _ratios(0.5e18));
        }
        _atPhase(MINT_PHASE);

        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithRecipientRewardByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 2, false
        );
        require(groupIds.length == 2 && total == 2, "recipient groups page");
        uint256[] memory sourceActionIds = new uint256[](MAX_REWARDS_PER_BATCH);
        uint256[] memory batchGroupIds = new uint256[](MAX_REWARDS_PER_BATCH);
        for (uint256 i; i < groupIds.length; ++i) {
            (uint256[] memory groupActionIds, uint256 groupActionCount) = executor
                .actionIdsWithRecipientRewardByGroupIdByRecipientId(
                    address(token), SERVICE_ROUND, SERVICE_ACTION_ID, groupIds[i], MEMBER1_ID, 0,
                    MAX_REWARDS_PER_BATCH, false
                );
            require(groupActionCount == MAX_REWARDS_PER_BATCH / 2, "recipient action page");
            for (uint256 j; j < groupActionIds.length; ++j) {
                uint256 index = i * groupActionIds.length + j;
                sourceActionIds[index] = groupActionIds[j];
                batchGroupIds[index] = groupIds[i];
            }
        }

        uint256 beforeGas = gasleft();
        vm.prank(MEMBER1);
        uint256[] memory amounts =
            executor.mintRecipientRewards(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, batchGroupIds
            );
        require(beforeGas - gasleft() < 10_000_000, "maximum recipient batch fits the local gas budget");
        require(amounts.length == MAX_REWARDS_PER_BATCH, "batch return aligns with keys");
        for (uint256 i; i < amounts.length; ++i) {
            require(amounts[i] == 25, "each recipient key receives its exact amount");
        }
        require(token.balanceOf(MEMBER1) == 25 * MAX_REWARDS_PER_BATCH, "batch actual payout matches its rows");
    }

    function testProviderMintWithoutARewardRevertsWithShareKeys() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(200);
        _atPhase(MINT_PHASE);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ZeroProviderReward.selector,
                GROUP_ACTION_ID,
                GROUP_ID,
                MEMBER1_ID
            )
        );
        vm.prank(MEMBER1);
        executor.mintProviderRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
    }

    function testCombinedMintUsesActualBudgetForSharesThatRoundedToZeroInPreview() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(200);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 20, false);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.1e18));
        _atPhase(MINT_PHASE);

        _assertMemberReward(5, 0, MemberRewardStatus.Pending);
        vm.prank(MEMBER1);
        uint256 paid = executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(paid == 55, "actual budget pays both shares");
        _assertMemberReward(0, 55, MemberRewardStatus.Settled);
    }

    function testCombinedMintLeavesPreviouslyPaidProviderShareUntouched() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.2e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(200);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 30, MEMBER1_ID, 30);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.11e18));
        _atPhase(MINT_PHASE);

        _assertMemberReward(16, 0, MemberRewardStatus.Pending);
        vm.prank(MEMBER1);
        require(executor.mintProviderRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID) == 6, "paid provider slice");
        _assertMemberReward(10, 6, MemberRewardStatus.Pending);
        vm.prank(MEMBER1);
        require(executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 10, "only remainder paid");
        _assertMemberReward(0, 16, MemberRewardStatus.Settled);
        require(token.balanceOf(MEMBER1) == 16, "no duplicate payment");
    }

    function testProviderRoleRemainsPendingWhileAnotherSourceShareIsUnminted() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.2e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(400);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 30, MEMBER1_ID, 30);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 50, MEMBER1_ID, 50);
        _atPhase(MINT_PHASE);

        vm.prank(MEMBER1);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 6,
            "first Provider share paid"
        );

        MemberRewardSummary memory provider =
            _serviceRewardDetail(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID).provider;
        require(provider.pendingAmount == 10 && provider.mintedAmount == 6, "Provider role amounts");
        require(provider.status == MemberRewardStatus.Pending, "Provider role has another payable share");
    }

    function _assertMemberReward(uint256 pending, uint256 paid, MemberRewardStatus status) private view {
        (uint256 actualPending, uint256 actualPaid, MemberRewardStatus actualStatus) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(actualPending == pending && actualPaid == paid && actualStatus == status, "member reward summary");
    }

    function testRecipientPageTracksHistoricalConfiguration() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(VERIFY_PHASE + 1);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(0.5e18));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER1_ID), _ratios(0.5e18));
        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithRecipientRewardByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 2, false
        );
        require(total == 1 && groupIds.length == 1 && groupIds[0] == GROUP_ID, "historical group configuration");
        (uint256[] memory actionIds, uint256 actionCount) = executor.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 2, false
        );
        require(actionCount == 1 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID, "historical action configuration");
        (actionIds, actionCount) = executor.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), SERVICE_ROUND + 1, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 2, false
        );
        require(actionCount == 1 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID_B, "current action configuration");
    }

    function testProviderBatchIsAtomicOnDuplicateAndSupportsRetry() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.2e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100e18), VERIFIER_ID);
        _armServiceReward(200e18);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 30e18, MEMBER1_ID, 30e18);
        _atPhase(MINT_PHASE);
        uint256[] memory sourceActionIds = _ids(GROUP_ACTION_ID, GROUP_ACTION_ID);
        uint256[] memory groupIds = _ids(GROUP_ID, GROUP_ID);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSignature("ProviderRewardAlreadyMinted(address,uint256,uint256,uint256,uint256,uint256)",
            address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID));
        executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);
        require(token.balanceOf(MEMBER1) == 0, "atomic batch");
        uint256[] memory retrySourceActionIds = _ids(GROUP_ACTION_ID);
        uint256[] memory retryGroupIds = _ids(GROUP_ID);
        vm.prank(MEMBER1);
        uint256[] memory amounts = executor.mintProviderRewards(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, retrySourceActionIds, retryGroupIds
        );
        require(amounts[0] == 6e18 && token.balanceOf(MEMBER1) == 6e18, "single batch retry paid");
    }

    function testOwnerAndVerifierOfSameIdentityMintIndependently() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100e18), GROUP_ID);
        _armServiceReward(200e18);
        _atPhase(MINT_PHASE);

        vm.prank(GROUP_OWNER);
        require(executor.mintVerifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 100e18, "verifier paid");
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.verifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 100e18 && status == MemberRewardStatus.Settled, "verifier status");
        (pending, minted, status) = executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 100e18 && minted == 0 && status == MemberRewardStatus.Pending, "owner pending");
        vm.prank(GROUP_OWNER);
        require(executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 100e18, "owner paid");
        require(token.balanceOf(GROUP_OWNER) == 200e18, "both roles paid once");
    }

    function testProviderPaidBeforeOwnerAndRecipientFromOneBudget() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.2e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100e18), VERIFIER_ID);
        _armServiceReward(200e18);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 30e18, MEMBER1_ID, 30e18);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        (uint256 amount, bool minted) = executor.providerRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID);
        require(amount == 6e18 && !minted, "provider quote");
        vm.prank(MEMBER1);
        require(executor.mintProviderRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID) == 6e18, "provider paid");
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER2_ID) == 47e18, "recipient paid after reserve");
        (uint256 ownerPaid, ) = _settleService(GROUP_ID);
        require(ownerPaid == 47e18, "owner keeps remainder");
        require(token.balanceOf(MEMBER1) == 6e18 && token.balanceOf(MEMBER2) == 47e18 && token.balanceOf(GROUP_OWNER) == 47e18, "actual payouts");
        (amount, minted) = executor.providerRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID);
        require(amount == 6e18 && minted, "paid quote");
    }

    function testProviderAmountsRoundDownIndependently() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 1e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(3), VERIFIER_ID);
        _armServiceReward(22);
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 2, MEMBER1_ID, 1
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 2, MEMBER2_ID, 1
        );
        _atPhase(MINT_PHASE);

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 3 && minted == 0 && status == MemberRewardStatus.Pending, "the owner's provider amount rounds down");

        (uint256 firstAmount, bool firstMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        (uint256 secondAmount, bool secondMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER2_ID
        );
        require(firstAmount == 3 && secondAmount == 3 && !firstMinted && !secondMinted, "provider shares round independently");

        vm.prank(MEMBER1);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID)
                == 3,
            "first provider receives rounded share"
        );
        vm.prank(MEMBER2);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER2_ID)
                == 3,
            "second provider receives rounded share"
        );
        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 3,
            "owner receives its market share"
        );
        vm.prank(VERIFIER);
        require(
            executor.mintVerifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID) == 11,
            "verifier receives role reward"
        );
        require(token.balanceOf(address(executor)) == 2, "provider rounding remainder stays in service");
    }

    function testOwnerCanQuoteAndMintAcrossSixtyFiveProviderActions() external {
        uint256 secondServiceActionId = SERVICE_ACTION_ID + 1;
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _createServiceAction(secondServiceActionId, 0, 0.5e18, 0.2e18);
        _armServiceReward(2000);
        _armServiceRewardOn(secondServiceActionId, 2000);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 1000, false);

        for (uint256 i = 0; i < 65; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50
            );
        }
        _atPhase(MINT_PHASE);

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(
            pending == 375 && minted == 0 && status == MemberRewardStatus.Pending,
            "owner market share uses the whole quoted budget"
        );
        require(actionTarget.mintRewardCalls() == 0, "quoting leaves the budget unminted");

        vm.prank(GROUP_OWNER);
        uint256 first = executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(first == 750, "combined mint uses the actual budget");
        vm.prank(GROUP_OWNER);
        uint256 second = executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, secondServiceActionId, GROUP_ID);
        require(second == 900, "second service uses its own ratio");
        require(token.balanceOf(GROUP_OWNER) == first + second, "both owner rewards paid");
        require(actionTarget.mintRewardCalls() == 2, "each service budget minted once");
    }

    function testOwnerAsSoleProviderUsesRoundedPartnershipBudgets() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(12);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER1_ID), _ratios(PRECISION));
        _atPhase(MINT_PHASE);

        vm.prank(GROUP_OWNER);
        require(executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 2);
        vm.prank(MEMBER1);
        require(executor.mintRecipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 4);
        require(token.balanceOf(address(executor)) == 6, "only the verifier budget remains");
    }

    function testRoundMarketRoundingLeavesDustAfterOwnerProviderAndRecipientsClaim() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 100, MEMBER1_ID, 100);
        _armServiceReward(12);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(1e18));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(1e18));
        _atPhase(MINT_PHASE);

        (uint256 ownerPaid,) = _settleService(GROUP_ID);
        (uint256 providerPaid,) = _settleService(MEMBER1_ID);
        (uint256 recipientPaid,) = _settleService(MEMBER2_ID);
        (uint256 verifierPaid,) = _settleService(VERIFIER_ID);
        require(ownerPaid == 1 && providerPaid == 2 && recipientPaid == 2 && verifierPaid == 6, "rounded payouts");
        require(token.balanceOf(address(executor)) == 1, "unassigned market remainder");
    }
}
