// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase, TestServiceRewardDetails} from "./GroupServiceTestBase.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {MemberRewardSummary} from "../src/interfaces/IGroupServiceExecutor.sol";

contract GroupServiceRewardDetailsTest is GroupServiceTestBase {
    function testZeroProviderRatioKeepsMemberQuoteAndMintWithinGasBudget() external {
        uint256 sourceActionCount = 32;
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0);
        for (uint256 i; i < sourceActionCount; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), MEMBER1_ID);
            groupAction.setMarketScores(address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50);
        }
        _armServiceReward(1000);
        _atPhase(MINT_PHASE);

        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithProviderRewardByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, false
        );
        require(total == 1 && groupIds[0] == GROUP_ID, "Provider group remains discoverable");
        (, uint256 actionCount) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, sourceActionCount, false
        );
        require(actionCount == sourceActionCount, "source Provider candidates remain discoverable");

        uint256 gasBefore = gasleft();
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        uint256 quoteGas = gasBefore - gasleft();
        require(pending == 500 && minted == 0 && status == MemberRewardStatus.Pending, "verifier reward quoted");

        vm.prank(MEMBER1);
        gasBefore = gasleft();
        uint256 paid = executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        uint256 mintGas = gasBefore - gasleft();
        require(paid == 500, "verifier reward paid");
        require(quoteGas < 100_000, "zero-Provider-ratio quote exceeds gas budget");
        require(mintGas < 350_000, "zero-Provider-ratio mint exceeds gas budget");
    }

    function testMemberRewardDetailsTrackAllFourRolesAcrossPartialAndCombinedMint() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.4e18);
        _setGroupLedger(
            GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID),
            _amounts(100, 100),
            GROUP_ID
        );
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_OWNER_B_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(300);

        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_OWNER_B_ID, 100, GROUP_ID, 50
        );
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_OWNER_B_ID, GROUP_ACTION_ID_B, _ids(GROUP_ID), _ratios(0.2e18));
        _atPhase(MINT_PHASE);

        _assertDetails(
            MemberRewardSummary(100, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(50, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(6, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(10, 0, MemberRewardStatus.Pending),
            50
        );

        vm.prank(GROUP_OWNER);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID_B, GROUP_OWNER_B_ID, GROUP_ID
            ) == 10,
            "provider paid first"
        );
        _assertDetails(
            MemberRewardSummary(100, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(50, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(6, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(0, 10, MemberRewardStatus.Settled),
            50
        );

        vm.prank(GROUP_OWNER);
        require(
            executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 156,
            "remaining roles paid together"
        );
        _assertDetails(
            MemberRewardSummary(0, 100, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 50, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 6, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 10, MemberRewardStatus.Settled),
            50
        );
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 166 && status == MemberRewardStatus.Settled, "member total settled");
    }

    function testServiceRewardTracksOwnerBudgetBeforeAndAfterGovCap() external {
        _createServiceAction(SERVICE_ACTION_ID, 1e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(1000);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 800, false);
        stake.setTotalGovPower(address(token), SERVICE_ROUND, 100);
        stake.setGovPower(address(token), SERVICE_ROUND, GROUP_ID, 20);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        TestServiceRewardDetails memory quote =
            _serviceRewardDetail(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(quote.ownerBudgetBeforeCap == 400 && quote.ownerBudget == 160, "quoted budgets");
        _assertSummary(quote.owner, MemberRewardSummary(80, 0, MemberRewardStatus.Pending));
        require(quote.ownerBudgetBeforeCap - quote.ownerBudget == 240, "quoted owner budget difference");
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), quote.owner);

        vm.prank(GROUP_OWNER);
        require(executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 100);

        TestServiceRewardDetails memory actual =
            _serviceRewardDetail(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(actual.ownerBudgetBeforeCap == 500 && actual.ownerBudget == 200, "actual budgets");
        _assertSummary(actual.owner, MemberRewardSummary(0, 100, MemberRewardStatus.Settled));
        require(actual.ownerBudgetBeforeCap - actual.ownerBudget == 300, "actual owner budget difference");
        (pending, minted, status) = executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), actual.owner);
        require(token.balanceOf(GROUP_OWNER) == 100 && token.burnedTotal() == 300, "actual payout and burn");
    }

    function _assertDetails(
        MemberRewardSummary memory verifier,
        MemberRewardSummary memory owner,
        MemberRewardSummary memory recipient,
        MemberRewardSummary memory provider,
        uint256 expectedOwnerBudget
    ) private view {
        TestServiceRewardDetails memory details =
            _serviceRewardDetail(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(details.verifier, verifier);
        _assertSummary(details.owner, owner);
        _assertSummary(details.recipient, recipient);
        _assertSummary(details.provider, provider);
        require(details.ownerBudget == expectedOwnerBudget, "owner budget separated from self reward");
        require(details.ownerBudgetBeforeCap == expectedOwnerBudget, "uncapped budgets agree");

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.verifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), details.verifier);

        (pending, minted, status) = executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), details.owner);

        (pending, minted, status) = executor.recipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), details.recipient);

        (pending, minted, status) = executor.providerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(MemberRewardSummary(pending, minted, status), details.provider);
    }

    function _assertSummary(MemberRewardSummary memory actual, MemberRewardSummary memory expected) private pure {
        require(
            actual.pendingAmount == expected.pendingAmount && actual.mintedAmount == expected.mintedAmount
                && actual.status == expected.status,
            "role summary"
        );
    }
}
