// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {GroupRewardKey} from "../src/interfaces/IGroupActionVerify.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";

contract GroupServiceShareBudgetRefreshTest is GroupServiceTestBase {
    function testProviderClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 1, PRECISION, 1, 1);
        _atPhase(MINT_PHASE);

        (uint256 quoted, bool isMinted) = executor.providerReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(quoted == 0 && !isMinted, "provider preview rounds to zero");

        vm.prank(MEMBER1);
        require(
            executor.mintProviderReward(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 100,
            "provider is repriced from actual budget"
        );
        (uint256 paid, bool settled) = executor.providerReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(paid == 100 && settled, "provider query records actual payment");
        require(actionTarget.mintRewardCalls() == 1, "service budget minted once");
    }

    function testRecipientClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 1, 0, 0, 0);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        (uint256 quoted, bool isMinted) = executor.recipientReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(quoted == 0 && !isMinted, "recipient preview rounds to zero");

        vm.prank(MEMBER1);
        require(
            executor.mintRecipientReward(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 50,
            "recipient is repriced from actual budget"
        );
        (uint256 paid, bool settled) = executor.recipientReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(paid == 50 && settled, "recipient query records actual payment");
        require(actionTarget.mintRewardCalls() == 1, "service budget minted once");
    }

    function testProviderBatchRepricesFirstZeroPreviewFromActualBudget() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, PRECISION);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(1), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(1), VERIFIER_ID);
        _armServiceReward(200);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 1, false);
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 1, MEMBER1_ID, 1
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 1, MEMBER1_ID, 1
        );
        _atPhase(MINT_PHASE);

        GroupRewardKey[] memory keys = new GroupRewardKey[](2);
        keys[0] = GroupRewardKey(GROUP_ACTION_ID, GROUP_ID);
        keys[1] = GroupRewardKey(GROUP_ACTION_ID_B, GROUP_ID);
        (uint256 firstQuote, bool firstMinted) = executor.providerReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, keys[0].sourceActionId, keys[0].groupId, MEMBER1_ID
        );
        require(firstQuote == 0 && !firstMinted, "first batch item previews as zero");

        vm.prank(MEMBER1);
        uint256[] memory amounts =
            executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, keys);
        require(amounts.length == 2 && amounts[0] == 50 && amounts[1] == 50, "batch reprices every key");
        require(token.balanceOf(MEMBER1) == 100, "batch pays both actual shares");
        require(actionTarget.mintRewardCalls() == 1, "batch mints one service budget");
    }

    function testProviderBatchRollsBackActualBudgetWhenLaterKeyHasNoShare() external {
        _prepareSingleGroup(1, 200, 1, PRECISION, 1, 1);
        _atPhase(MINT_PHASE);

        GroupRewardKey[] memory keys = new GroupRewardKey[](2);
        keys[0] = GroupRewardKey(GROUP_ACTION_ID, GROUP_ID);
        keys[1] = GroupRewardKey(GROUP_ACTION_ID_B, GROUP_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ZeroProviderReward.selector,
                GROUP_ACTION_ID_B,
                GROUP_ID,
                MEMBER1_ID
            )
        );
        vm.prank(MEMBER1);
        executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, keys);

        (uint256 firstAmount, bool firstMinted) = executor.providerReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(firstAmount == 0 && !firstMinted, "failed batch restores first share");
        require(token.balanceOf(MEMBER1) == 0, "failed batch restores first transfer");
        require(actionTarget.mintRewardCalls() == 0, "failed batch restores service budget mint");
    }

    function testGroupOwnerClaimRepricesZeroPreviewUsingActualBudget() external {
        _preparePrimaryOnly(1, 2, VERIFIER_ID);
        (uint256 quoted, bool isMinted) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(quoted == 0 && !isMinted, "owner preview rounds to zero");

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 1,
            "owner claim uses the actual budget"
        );
        require(actionTarget.mintRewardCalls() == 1, "owner claim mints one service budget");
    }

    function testVerifierClaimRepricesZeroPreviewUsingActualBudget() external {
        _preparePrimaryOnly(1, 2, VERIFIER_ID);
        (uint256 quoted, bool isMinted) =
            executor.verifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        require(quoted == 0 && !isMinted, "verifier preview rounds to zero");

        vm.prank(VERIFIER);
        require(
            executor.mintVerifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID) == 1,
            "verifier claim uses the actual budget"
        );
        require(actionTarget.mintRewardCalls() == 1, "verifier claim mints one service budget");
    }

    function testCombinedPrimaryClaimRepricesZeroPreviewUsingActualBudget() external {
        _preparePrimaryOnly(1, 2, GROUP_ID);

        vm.prank(GROUP_OWNER);
        require(
            executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 2,
            "combined owner and verifier claim uses the actual budget"
        );
        require(actionTarget.mintRewardCalls() == 1, "combined claim mints one service budget");
    }

    function testPrimaryClaimRollsBackWhenActualBudgetStillRoundsToZero() external {
        _preparePrimaryOnly(1, 1, GROUP_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardRoundedToZero.selector,
                address(token),
                SERVICE_ROUND,
                GROUP_ID
            )
        );
        vm.prank(GROUP_OWNER);
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(actionTarget.mintRewardCalls() == 0, "zero result rolls back budget mint");
    }

    function testAlreadyMintedZeroProviderShareStillReverts() external {
        _prepareSingleGroup(4, 4, 3, PRECISION, 2, 1);
        _atPhase(MINT_PHASE);
        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 1,
            "owner settlement mints the service budget"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ZeroProviderReward.selector,
                GROUP_ACTION_ID,
                GROUP_ID,
                MEMBER1_ID
            )
        );
        vm.prank(MEMBER1);
        executor.mintProviderReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(actionTarget.mintRewardCalls() == 1, "already-minted budget is not retried");
    }

    function _prepareSingleGroup(
        uint256 previewBudget,
        uint256 actualBudget,
        uint256 groupScore,
        uint256 providerRatio,
        uint256 externalScore,
        uint256 providerScore
    ) private {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, providerRatio);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(groupScore), VERIFIER_ID);
        _armServiceReward(actualBudget);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, previewBudget, false);
        if (providerRatio != 0) {
            groupAction.setMarketScores(
                address(token),
                SERVICE_ROUND,
                GROUP_ACTION_ID,
                GROUP_ID,
                externalScore,
                MEMBER1_ID,
                providerScore
            );
        }
        _atPhase(VERIFY_PHASE);
    }

    function _preparePrimaryOnly(uint256 previewBudget, uint256 actualBudget, uint256 verifierId) private {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(1), verifierId);
        _armServiceReward(actualBudget);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, previewBudget, false);
        _atPhase(MINT_PHASE);
    }
}
