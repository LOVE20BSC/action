// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutor} from "../src/interfaces/IGroupActionExecutor.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {IStake} from "@core/interfaces/IStake.sol";

contract GroupServiceShareBudgetRefreshTest is GroupServiceTestBase {
    function testProviderClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 1, PRECISION, 1, 1);
        _atPhase(MINT_PHASE);

        (uint256 quoted, bool isMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(quoted == 0 && !isMinted, "provider preview rounds to zero");

        vm.prank(MEMBER1);
        require(
            executor.mintProviderRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 100,
            "provider is repriced from actual budget"
        );
        (uint256 paid, bool settled) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(paid == 100 && settled, "provider query records actual payment");
        require(actionTarget.mintRewardCalls() == 1, "service budget minted once");
    }

    function testRecipientClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 1, 0, 0, 0);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        (uint256 quoted, bool isMinted) = executor.recipientRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(quoted == 0 && !isMinted, "recipient preview rounds to zero");

        vm.prank(MEMBER1);
        require(
            executor.mintRecipientRewardBySourceActionIdByGroupId(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 50,
            "recipient is repriced from actual budget"
        );
        (uint256 paid, bool settled) = executor.recipientRewardBySourceActionIdByGroupId(
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

        uint256[] memory sourceActionIds = _ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B);
        uint256[] memory groupIds = _ids(GROUP_ID, GROUP_ID);
        (uint256 firstQuote, bool firstMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, sourceActionIds[0], groupIds[0], MEMBER1_ID
        );
        require(firstQuote == 0 && !firstMinted, "first batch item previews as zero");

        vm.prank(MEMBER1);
        uint256[] memory amounts =
            executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);
        require(amounts.length == 2 && amounts[0] == 50 && amounts[1] == 50, "batch reprices every key");
        require(token.balanceOf(MEMBER1) == 100, "batch pays both actual shares");
        require(actionTarget.mintRewardCalls() == 1, "batch mints one service budget");
    }

    function testProviderBatchUsesEachGroupsBudgetWhenGroupsInterleave() external {
        _createServiceAction(SERVICE_ACTION_ID, PRECISION, 0.5e18, PRECISION);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(100, 100), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100);
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_OWNER_B_ID, 100, MEMBER1_ID, 100
        );
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 100, MEMBER1_ID, 100);
        stake.setTotalGovVotes(address(token), VERIFY_PHASE, 100);
        stake.setGovVotes(address(token), VERIFY_PHASE, GROUP_ID, 10);
        stake.setGovVotes(address(token), VERIFY_PHASE, GROUP_OWNER_B_ID, 30);
        _armServiceReward(600);
        _atPhase(MINT_PHASE);

        uint256[] memory sourceActionIds = _ids(GROUP_ACTION_ID, GROUP_ACTION_ID, GROUP_ACTION_ID_B);
        uint256[] memory groupIds = _ids(GROUP_ID, GROUP_OWNER_B_ID, GROUP_ID);
        vm.expectCall(
            address(groupAction),
            abi.encodeCall(IGroupActionExecutor.totalGeneratedActionRewardByGroupId, (address(token), SERVICE_ROUND, GROUP_ID)),
            1
        );
        vm.prank(MEMBER1);
        uint256[] memory amounts =
            executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);
        require(amounts[0] == 30 && amounts[1] == 100 && amounts[2] == 30, "each batch item uses its group's cap");
        require(token.balanceOf(MEMBER1) == 160, "batch pays all three shares");
    }

    function testProviderBatchRollsBackActualBudgetWhenLaterKeyHasNoShare() external {
        _prepareSingleGroup(1, 200, 1, PRECISION, 1, 1);
        _atPhase(MINT_PHASE);

        uint256[] memory sourceActionIds = _ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B);
        uint256[] memory groupIds = _ids(GROUP_ID, GROUP_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ZeroProviderReward.selector,
                GROUP_ACTION_ID_B,
                GROUP_ID,
                MEMBER1_ID
            )
        );
        vm.prank(MEMBER1);
        executor.mintProviderRewards(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, sourceActionIds, groupIds);

        vm.expectCall(
            address(groupAction),
            abi.encodeCall(IGroupActionExecutor.totalGeneratedActionRewardByGroupId, (address(token), SERVICE_ROUND, GROUP_ID)),
            1
        );
        (uint256 firstAmount, bool firstMinted) = executor.providerRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(firstAmount == 0 && !firstMinted, "failed batch restores first share");
        require(token.balanceOf(MEMBER1) == 0, "failed batch restores first transfer");
        require(actionTarget.mintRewardCalls() == 0, "failed batch restores service budget mint");
    }

    function testProviderFirstClaimCachesSourceAcrossProposals() external {
        uint256 childServiceActionId = SERVICE_ACTION_ID_B + 1;
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _createServiceAction(SERVICE_ACTION_ID_B, 0, 0.25e18);
        _createServiceActionOn(address(token), address(childToken), childServiceActionId, 0, 0.25e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(100, 300), VERIFIER_ID);
        groupAction.setGroupLedger(
            address(childToken), SERVICE_ROUND, GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(300, 100), VERIFIER_ID
        );
        groupAction.setGroupLedger(
            address(token), SERVICE_ROUND + 1, GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(200, 200), VERIFIER_ID
        );
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100);
        _armServiceReward(400);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, 400, false);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, childServiceActionId, 400, false);
        actionTarget.setActionReward(address(token), SERVICE_ROUND + 1, SERVICE_ACTION_ID_B, 400, false);
        _atPhase(MINT_PHASE);

        vm.prank(MEMBER1);
        uint256 paid = executor.mintProviderRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(paid == 25, "provider settles before owner");

        vm.mockCallRevert(
            address(groupAction),
            abi.encodeCall(IGroupActionExecutor.totalGeneratedActionRewardByGroupId, (address(token), SERVICE_ROUND, GROUP_ID)),
            abi.encodeWithSignature("Error(string)", "unexpected repeat of source aggregation")
        );
        (uint256 ownerBudget,) = executor.groupOwnerRewardBudget(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, GROUP_ID);
        require(ownerBudget == 75, "another proposal reuses the source total with its own ratios");
        (ownerBudget,) = executor.groupOwnerRewardBudget(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, GROUP_OWNER_B_ID);
        require(ownerBudget == 225, "different group uses its own total");
        (ownerBudget,) = executor.groupOwnerRewardBudget(address(token), SERVICE_ROUND, childServiceActionId, GROUP_ID);
        require(ownerBudget == 225, "different source token uses its own total");
        _atPhase(MINT_PHASE + 1);
        (ownerBudget,) = executor.groupOwnerRewardBudget(address(token), SERVICE_ROUND + 1, SERVICE_ACTION_ID_B, GROUP_ID);
        require(ownerBudget == 150, "different round uses its own total");
    }

    function testCombinedRecipientAndProviderReuseActualCappedBudget() external {
        _createServiceAction(SERVICE_ACTION_ID, PRECISION, 0.5e18, 0.4e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        groupAction.setMarketScores(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 50, MEMBER1_ID, 50);
        stake.setTotalGovVotes(address(token), VERIFY_PHASE, 100);
        stake.setGovVotes(address(token), VERIFY_PHASE, GROUP_ID, 25);
        _armServiceReward(400);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 1, false);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        vm.expectCall(address(stake), abi.encodeCall(IStake.totalGovVotes, (address(token), VERIFY_PHASE)), 1);
        vm.prank(MEMBER1);
        uint256 paid = executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(paid == 60, "combined claim pays 40 recipient and 20 Provider from actual budget");
        require(actionTarget.mintRewardCalls() == 1, "combined claim mints one service budget");
        require(token.burnedTotal() == 0, "owner still settles the overflow");
    }

    function testPrimaryRoleClaimsWaitForMintWindow() external {
        _preparePrimaryOnly(200, 200, VERIFIER_ID);
        _atPhase(VERIFY_PHASE);
        bytes memory expected = abi.encodeWithSelector(
            IActionExecutorErrors.RoundAfterMintWindow.selector, SERVICE_ROUND, SERVICE_ROUND - 1
        );

        vm.expectRevert(expected);
        vm.prank(GROUP_OWNER);
        executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        vm.expectRevert(expected);
        vm.prank(VERIFIER);
        executor.mintVerifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        require(actionTarget.mintRewardCalls() == 0, "verification phase cannot mint service rewards");
    }

    function testGroupOwnerClaimRepricesZeroPreviewUsingActualBudget() external {
        _preparePrimaryOnly(1, 2, VERIFIER_ID);
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 0 && status == MemberRewardStatus.Unavailable, "owner preview rounds to zero");

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 1,
            "owner claim uses the actual budget"
        );
        require(actionTarget.mintRewardCalls() == 1, "owner claim mints one service budget");
    }

    function testVerifierClaimRepricesZeroPreviewUsingActualBudget() external {
        _preparePrimaryOnly(1, 2, VERIFIER_ID);
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.verifierReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        require(pending == 0 && minted == 0 && status == MemberRewardStatus.Unavailable, "verifier preview rounds to zero");

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
        _prepareSingleGroup(4, 4, 3, PRECISION, 1, 1);
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
        executor.mintProviderRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(actionTarget.mintRewardCalls() == 1, "already-minted budget is not retried");
    }

    function testRoundClaimsCheckMintWindowBeforeEmptyPool() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _atPhase(VERIFY_PHASE);

        _expectRoundClaimsToRevert(abi.encodeWithSelector(
            IActionExecutorErrors.RoundAfterMintWindow.selector, SERVICE_ROUND, SERVICE_ROUND - 1
        ));
    }

    function testRoundClaimsRejectEmptySourcePool() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        _expectRoundClaimsToRevert(abi.encodeWithSelector(
            IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), SERVICE_ROUND
        ));
        require(actionTarget.mintRewardCalls() == 0, "empty source pool cannot mint");
    }

    function testRoundClaimsRejectEmptyServicePoolBeforeCheckingMemberWeight() external {
        _prepareSingleGroup(0, 200, 100, 0.5e18, 50, 50);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        _expectRoundClaimsToRevert(abi.encodeWithSelector(
            IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), SERVICE_ROUND
        ));
        require(actionTarget.mintRewardCalls() == 0, "empty service pool cannot mint");
    }

    function testRoundClaimsRollBackWhenActualServiceBudgetIsZero() external {
        _prepareSingleGroup(200, 0, 100, 0.5e18, 50, 50);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        _expectRoundClaimsToRevert(abi.encodeWithSelector(
            IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), SERVICE_ROUND
        ));
        require(actionTarget.mintRewardCalls() == 0 && token.balanceOf(MEMBER1) == 0, "empty budget mint rolls back");
    }

    function testRoundProviderClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 100, 0.5e18, 50, 50);
        _atPhase(MINT_PHASE);

        (uint256 pending,,) = executor.providerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(pending == 0, "provider preview rounds to zero");
        vm.prank(MEMBER1);
        require(executor.mintProviderReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 25);
        require(actionTarget.mintRewardCalls() == 1, "provider uses the actual budget");
    }

    function testRoundRecipientClaimRepricesZeroPreviewUsingActualBudget() external {
        _prepareSingleGroup(1, 200, 100, 0.5e18, 50, 50);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        (uint256 pending,,) = executor.recipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(pending == 0, "recipient preview rounds to zero");
        vm.prank(MEMBER1);
        require(executor.mintRecipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID) == 37);
        require(actionTarget.mintRewardCalls() == 1, "recipient uses the actual budget");
    }

    function testUnrewardedSourcesHaveNoMemberWeight() external {
        _prepareSingleGroup(200, 200, 100, 0.5e18, 50, 50);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        groupAction.setActionReward(address(token), SERVICE_ROUND, GROUP_ACTION_ID, 0);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _atPhase(MINT_PHASE);

        _expectRoundClaimsToRevert(abi.encodeWithSelector(
            IActionExecutorErrors.ZeroRewardWeight.selector, address(token), SERVICE_ACTION_ID, MEMBER1_ID
        ));
        require(actionTarget.mintRewardCalls() == 0, "unrewarded sources cannot mint");
    }

    function testProviderClaimsRollBackBudgetWhenAllSharesRoundToZero() external {
        _prepareSingleGroup(4, 4, 3, PRECISION, 1, 1);
        _atPhase(MINT_PHASE);

        bytes memory expected = abi.encodeWithSelector(
            IActionExecutorErrors.MemberRewardRoundedToZero.selector, address(token), SERVICE_ROUND, MEMBER1_ID
        );
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintProviderReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(actionTarget.mintRewardCalls() == 0 && token.balanceOf(MEMBER1) == 0, "zero provider reward rolls back");
    }

    function testRecipientClaimsRollBackBudgetWhenAllSharesRoundToZero() external {
        _prepareSingleGroup(2, 2, 100, 0, 0, 0);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(0.5e18));
        _atPhase(MINT_PHASE);

        bytes memory expected = abi.encodeWithSelector(
            IActionExecutorErrors.MemberRewardRoundedToZero.selector, address(token), SERVICE_ROUND, MEMBER1_ID
        );
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintRecipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(actionTarget.mintRewardCalls() == 0 && token.balanceOf(MEMBER1) == 0, "zero recipient reward rolls back");
    }

    function _expectRoundClaimsToRevert(bytes memory expected) private {
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintRecipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintProviderReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        vm.expectRevert(expected);
        vm.prank(MEMBER1);
        executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
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
