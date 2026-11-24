// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";

contract GroupServiceProviderRewardPagesTest is GroupServiceTestBase {
    function testProviderPagesGroupThenActionsAndRemainStableAfterMint() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(
            GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID),
            _amounts(100, 100),
            VERIFIER_ID
        );
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(900);

        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_OWNER_B_ID, 100, MEMBER1_ID, 100
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 100, MEMBER1_ID, 100
        );
        _atPhase(MINT_PHASE);

        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithProviderRewardByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, false
        );
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_ID, "first group page");
        (groupIds, total) = executor.groupIdsWithProviderRewardByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 1, 1, false
        );
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_OWNER_B_ID, "second group page");
        (groupIds, total) = executor.groupIdsWithProviderRewardByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, true
        );
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_OWNER_B_ID, "reverse group page");

        (uint256[] memory actionIds, uint256 actionCount) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 1, false
        );
        require(actionCount == 2 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID, "first action page");
        _assertReward(actionIds[0], GROUP_ID, 75, false);
        (actionIds, total) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 1, 1, false
        );
        require(total == 2 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID_B, "second action page");
        _assertReward(actionIds[0], GROUP_ID, 75, false);
        (actionIds, total) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 1, true
        );
        require(total == 2 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID_B, "reverse action page");
        (actionIds, total) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 2, 1, false
        );
        require(total == 2 && actionIds.length == 0, "exhausted action page");

        vm.prank(MEMBER1);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 75,
            "selected provider reward paid"
        );
        (actionIds, total) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 2, false
        );
        require(total == 2 && actionIds.length == 2, "page remains stable after mint");
        _assertReward(actionIds[0], GROUP_ID, 75, true);
    }

    function testRecipientPagesGroupThenActions() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _setRecipients(GROUP_OWNER_B_ID, GROUP_ACTION_ID_B, _ids(MEMBER1_ID), _ratios(0.5e18));

        (uint256[] memory groupIds, uint256 total) = executor.groupIdsWithRecipientRewardByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, false
        );
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_ID, "first recipient group");
        (groupIds, total) = executor.groupIdsWithRecipientRewardByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 1, 1, false
        );
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_OWNER_B_ID, "second recipient group");
        (uint256[] memory actionIds, uint256 actionCount) = executor.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 2, false
        );
        require(actionCount == 1 && actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID, "recipient action page");
    }

    function testRoleMintsPayOnlyRemainingSharesAcrossGroups() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(100, 100), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(600);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 50, MEMBER1_ID, 50);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_OWNER_B_ID, 50, MEMBER1_ID, 50);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 50, MEMBER1_ID, 50);

        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _setRecipients(GROUP_OWNER_B_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        vm.prank(MEMBER1);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 25,
            "one provider source paid"
        );
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 37, "one recipient source paid");
        _assertRoleRewards(50, 25, 74, 37, MemberRewardStatus.Pending);

        vm.prank(GROUP_OWNER_B);
        require(executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_OWNER_B_ID) == 38);
        vm.prank(MEMBER1);
        require(executor.mintRecipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 74);
        vm.prank(MEMBER1);
        require(executor.mintProviderReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 50);
        _assertRoleRewards(0, 75, 0, 111, MemberRewardStatus.Settled);
        require(token.balanceOf(MEMBER1) == 186, "balance matches all paid sources");
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 76 && minted == 0 && status == MemberRewardStatus.Pending, "source owner can claim independently");

        vm.expectRevert(abi.encodeWithSelector(
            IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), SERVICE_ACTION_ID, MEMBER1_ID, SERVICE_ROUND
        ));
        vm.prank(MEMBER1);
        executor.mintProviderReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
    }

    function _assertRoleRewards(
        uint256 providerPending,
        uint256 providerMinted,
        uint256 recipientPending,
        uint256 recipientMinted,
        MemberRewardStatus expectedStatus
    ) private view {
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.providerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(pending == providerPending && minted == providerMinted && status == expectedStatus, "provider totals");
        (pending, minted, status) = executor.recipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(pending == recipientPending && minted == recipientMinted && status == expectedStatus, "recipient totals");
    }

    function _assertReward(uint256 sourceActionId, uint256 groupId, uint256 expectedAmount, bool expectedMinted)
        private
        view
    {
        (uint256 amount, bool isMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, sourceActionId, groupId, MEMBER1_ID
        );
        require(amount == expectedAmount && isMinted == expectedMinted, "page quote matches single reward");
    }
}
