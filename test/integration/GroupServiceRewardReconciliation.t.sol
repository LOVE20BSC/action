// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {ActionTargetIntegrationFixture} from "./ActionTargetRealIntegration.t.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";
import {GroupActionCreationParams} from "../../src/interfaces/IGroupActionExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {IGroupActionJoinEvents} from "../../src/interfaces/IGroupActionJoin.sol";
import {IGroupActionVerifyEvents} from "../../src/interfaces/IGroupActionVerify.sol";
import {
    GroupServiceCreationParams,
    IGroupServiceExecutorEvents,
    IGroupServiceExecutorErrors
} from "../../src/interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "../../src/interfaces/IMemberRewardExecutor.sol";

contract GroupServiceRewardReconciliationTest is ActionTargetIntegrationFixture, IGroupServiceExecutorEvents {
    uint256 private constant OWNER_ID = 1;
    uint256 private constant PROVIDER_ID = 2;
    uint256 private constant PRECISION = 1e18;

    GroupActionExecutor private group;
    GroupServiceExecutor private service;
    uint256 private round;
    uint256 private sourceA;
    uint256 private sourceB;
    uint256 private serviceAction;
    uint256 private actorId;
    uint256 private firstJoinBlock;
    uint256 private externalProvider;

    struct Allocation {
        uint256 budget;
        uint256 provider;
        uint256 recipientA;
        uint256 recipientB;
        uint256 ownerSelf;
        uint256 burn;
        uint256 verifierA;
        uint256 verifierGroupShareA;
        uint256 verifierB;
    }

    function setUp() public {
        _setUpProtocol(1, 0);
        group = new GroupActionExecutor(address(actionTarget));
        service = new GroupServiceExecutor(address(group));
        round = phase.currentPhase();

        _createActions();
        _advancePhase();
        _joinSourceGroups();
        _advancePhase();
        _setRecipient(sourceA, OWNER_ID, PROVIDER_ID, 0.5e18);
        _setRecipient(sourceB, OWNER_ID, PROVIDER_ID, 0.25e18);
        _verifySources();
        _advancePhase();
    }

    function testGroupBreakdownMatchesRoleQuotesAndPayments() external {
        Allocation memory expected = _expectedAllocation();
        _assertSourcesAndVerifierShares(expected, false);
        _assertGroupShares(expected, false);
        (uint256 ownerBudget, uint256 ownerBudgetBeforeCap) =
            service.groupOwnerRewardBudget(address(token), round, serviceAction, OWNER_ID);
        require(ownerBudgetBeforeCap - ownerBudget == expected.burn, "owner burn amount is derived from budget");
        uint256 originalSupply = token.totalSupply();
        uint256 originalOwnerBalance = token.balanceOf(member1);
        uint256 originalProviderBalance = token.balanceOf(member2);

        _mintProvider(expected);
        require(
            token.totalSupply() - originalSupply == expected.budget,
            "provider settlement does not burn owner reward"
        );
        _mintRemainingRoles(expected);

        _assertSourcesAndVerifierShares(expected, true);
        _assertGroupShares(expected, true);
        require(token.totalSupply() - originalSupply == expected.budget - expected.burn, "one budget after burn");
        require(
            token.balanceOf(member1) - originalOwnerBalance == expected.ownerSelf + expected.verifierB, "owner payouts"
        );
        require(
            token.balanceOf(member2) - originalProviderBalance
                == expected.provider + expected.recipientA + expected.recipientB + expected.verifierA,
            "provider and partner payouts"
        );
    }

    function testRecipientPageAndAtomicBatchFollowTheCurrentNFTHolder() external {
        Allocation memory expected = _expectedAllocation();
        (uint256[] memory groupIds, uint256 total) = service.groupIdsWithRecipientRewardByRecipientId(
            address(token), round, serviceAction, PROVIDER_ID, 0, 1, false
        );
        require(total == 1 && groupIds.length == 1 && groupIds[0] == OWNER_ID, "recipient group page");
        (uint256[] memory page, uint256 actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round, serviceAction, OWNER_ID, PROVIDER_ID, 0, 1, false
        );
        require(actionCount == 2 && page.length == 1 && page[0] == sourceA, "first source page");
        (page, actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round, serviceAction, OWNER_ID, PROVIDER_ID, 0, 1, true
        );
        require(actionCount == 2 && page.length == 1 && page[0] == sourceB, "reverse source page");
        (page, actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round, serviceAction, OWNER_ID, PROVIDER_ID, 2, 1, false
        );
        require(actionCount == 2 && page.length == 0, "exhausted page");

        uint256[] memory batchSourceActionIds = _pair(sourceA, sourceA);
        uint256[] memory batchGroupIds = _pair(OWNER_ID, OWNER_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.RecipientRewardAlreadyMinted.selector,
                address(token),
                serviceAction,
                round,
                sourceA,
                OWNER_ID,
                PROVIDER_ID
            )
        );
        vm.prank(member2);
        service.mintRecipientRewards(
            address(token), round, serviceAction, PROVIDER_ID, batchSourceActionIds, batchGroupIds
        );
        (, bool budgetMinted) = actionTarget.actionReward(address(token), round, serviceAction);
        require(!budgetMinted, "failed batch did not mint budget");
        _assertGroupShares(expected, false);

        _advancePhase();
        _setRecipient(sourceA, OWNER_ID, actorId, 0.75e18);
        (page, actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round, serviceAction, OWNER_ID, PROVIDER_ID, 0, 2, false
        );
        require(actionCount == 2 && page.length == 2, "old shares stay discoverable");
        (page, actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round + 2, serviceAction, OWNER_ID, PROVIDER_ID, 0, 2, false
        );
        require(actionCount == 1 && page[0] == sourceB, "new configuration applies to its round");
        vm.prank(member1);
        service.setRecipients(address(token), sourceB, OWNER_ID, new uint256[](0), new uint256[](0), new string[](0));
        (page, actionCount) = service.actionIdsWithRecipientRewardByGroupIdByRecipientId(
            address(token), round + 2, serviceAction, OWNER_ID, PROVIDER_ID, 0, 2, false
        );
        require(actionCount == 0 && page.length == 0, "explicit clear removes last current key");

        batchSourceActionIds = _pair(sourceA, sourceB);
        address newHolder = address(0xCAFE);
        vm.prank(member2);
        memberNFT.transferFrom(member2, newHolder, PROVIDER_ID);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, PROVIDER_ID));
        vm.prank(member2);
        service.mintRecipientRewards(
            address(token), round, serviceAction, PROVIDER_ID, batchSourceActionIds, batchGroupIds
        );

        vm.prank(newHolder);
        uint256[] memory amounts =
            service.mintRecipientRewards(
                address(token), round, serviceAction, PROVIDER_ID, batchSourceActionIds, batchGroupIds
            );
        require(amounts[0] == expected.recipientA && amounts[1] == expected.recipientB, "batched payout matches quotes");
        require(token.balanceOf(newHolder) == expected.recipientA + expected.recipientB, "new holder paid");
        _assertRecipient(sourceA, expected.recipientA, true);
        _assertRecipient(sourceB, expected.recipientB, true);
    }

    function _createActions() private {
        bytes memory groupData = abi.encodePacked(
            address(group),
            abi.encode(
                GroupActionCreationParams({
                    joinTokenAddress: address(token),
                    activationStakeAmount: 0,
                    maxJoinAmountRatio: PRECISION,
                    activationMinGovRatio: 0,
                    verifierStakeAmount: 0,
                    verifierPunishmentRatio: 0.9e18,
                    verificationKeys: new string[](0),
                    verificationDescriptions: new string[](0)
                })
            )
        );
        sourceA = _submitActionProposal(OWNER_ID, "Source A", groupData);
        sourceB = _submitActionProposal(PROVIDER_ID, "Source B", groupData);
        vm.startPrank(member1);
        (actorId,) = memberNFT.mint("Carol");
        stake.stakeLiquidity(address(token), 100, 100, PROMISED_WAITING_PHASES, actorId, type(uint256).max);
        token.approve(address(group), type(uint256).max);
        vm.stopPrank();
        vm.prank(member2);
        token.approve(address(group), type(uint256).max);

        bytes memory serviceData =
            abi.encodePacked(address(service), abi.encode(GroupServiceCreationParams(address(token), 0.5e18, 0.5e18, 0.6e18)));
        serviceAction = _submitActionProposal(actorId, "Group Service", serviceData);

        vm.prank(member2);
        group.submitVerifierApplication(address(token), sourceA, PROVIDER_ID, "Verifier A");
        vm.startPrank(member1);
        group.submitVerifierApplication(address(token), sourceB, OWNER_ID, "Verifier B");
        vm.stopPrank();
        _voteOne(OWNER_ID, sourceA, 57, abi.encode(PROVIDER_ID));
        _voteOne(OWNER_ID, sourceB, 43, abi.encode(OWNER_ID));
        _voteOne(OWNER_ID, serviceAction, 90, "");
    }

    function _joinSourceGroups() private {
        GroupConfig memory config = GroupConfig("Group", 0, 1, 0, 0);
        vm.startPrank(member1);
        group.activateGroup(address(token), sourceA, OWNER_ID, config);
        group.activateGroup(address(token), sourceB, OWNER_ID, config);
        group.join(address(token), sourceA, OWNER_ID, OWNER_ID, 6, 0, new string[](0));
        group.join(address(token), sourceB, OWNER_ID, OWNER_ID, 10, 0, new string[](0));
        vm.stopPrank();
        vm.startPrank(member2);
        group.activateGroup(address(token), sourceA, PROVIDER_ID, config);
        group.join(address(token), sourceA, PROVIDER_ID, PROVIDER_ID, 6, 0, new string[](0));
        group.addProviderQuota(address(token), sourceA, OWNER_ID, PROVIDER_ID, _single(actorId), _single(3));
        vm.stopPrank();

        firstJoinBlock = block.number;
        vm.recordLogs();
        vm.prank(member1);
        group.join(address(token), sourceA, OWNER_ID, actorId, 3, PROVIDER_ID, new string[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(group) && entry.topics[0] == IGroupActionJoinEvents.GroupActionJoined.selector)
            {
                require(
                    uint256(entry.topics[2]) == sourceA && uint256(entry.topics[3]) == actorId, "first join identity"
                );
                (uint256 joinRound, uint256 groupId, uint256 providerId, uint256 amount,) =
                    abi.decode(entry.data, (uint256, uint256, uint256, uint256, string[]));
                require(joinRound == round && groupId == OWNER_ID && amount == 3, "first join details");
                externalProvider = providerId;
            }
        }
        require(externalProvider == PROVIDER_ID, "provider discovered from first join event");
    }

    function _verifySources() private {
        uint256[] memory scores = new uint256[](2);
        scores[0] = 100;
        scores[1] = 100;
        vm.expectEmit(true, true, true, true, address(group));
        emit IGroupActionVerifyEvents.OriginScoresSubmitted({
            tokenAddress: address(token),
            actionId: sourceA,
            groupId: OWNER_ID,
            round: round,
            verifierId: PROVIDER_ID,
            startIndex: 0,
            totalActionFinalScore: 900,
            verifiedGroupCount: 1,
            roundVerified: false,
            groupVerified: true,
            scores: scores
        });
        vm.prank(member2);
        group.submitOriginScores(address(token), sourceA, PROVIDER_ID, OWNER_ID, 0, scores);
        vm.prank(member2);
        group.submitOriginScores(address(token), sourceA, PROVIDER_ID, PROVIDER_ID, 0, _single(100));
        vm.prank(member1);
        group.submitOriginScores(address(token), sourceB, OWNER_ID, OWNER_ID, 0, _single(100));
    }

    function _expectedAllocation() private view returns (Allocation memory expected) {
        (uint256 rewardA,) = actionTarget.actionReward(address(token), round, sourceA);
        (uint256 rewardB,) = actionTarget.actionReward(address(token), round, sourceB);
        (expected.budget,) = actionTarget.actionReward(address(token), round, serviceAction);
        uint256 weightA = rewardA * 3 / 5;
        uint256 ownerWeight = weightA + rewardB;
        uint256 denominator = rewardA + rewardB;
        uint256 theoreticalBudget = expected.budget * ownerWeight / (2 * denominator);
        uint256 ownerGovRatio = PRECISION * stake.govVotes(address(token), round + 2, OWNER_ID)
            / stake.totalGovVotes(address(token), round + 2);
        uint256 cappedBudget = expected.budget * (ownerGovRatio / 2) / PRECISION;
        require(cappedBudget < theoreticalBudget, "fixture triggers group cap");
        expected.burn = theoreticalBudget - cappedBudget;
        _expectedDistribution(expected, cappedBudget, rewardA, rewardB);
        expected.verifierA = expected.budget * rewardA / (2 * denominator);
        expected.verifierGroupShareA = expected.verifierA * weightA / rewardA;
        expected.verifierB = expected.budget * rewardB / (2 * denominator);
        require(expected.provider != 0 && expected.recipientB != 0 && expected.burn != 0, "fixture has all shares");
    }

    function _expectedDistribution(Allocation memory expected, uint256 ownerBudget, uint256 rewardA, uint256 rewardB)
        private pure
    {
        uint256 weightA = rewardA * 3 / 5;
        uint256 ownerWeight = weightA + rewardB;
        uint256 marketBudget = ownerBudget * 3 / 5;
        uint256 ordinaryBudget = ownerBudget - marketBudget;
        uint256 ownerProviderWeightA = rewardA * 2 / 5;
        expected.provider = marketBudget * (rewardA / 5) / ownerWeight;
        uint256 partnershipA =
            ordinaryBudget * weightA / ownerWeight + marketBudget * ownerProviderWeightA / ownerWeight;
        uint256 partnershipB = ordinaryBudget * rewardB / ownerWeight + marketBudget * rewardB / ownerWeight;
        expected.recipientA = partnershipA / 2;
        expected.recipientB = partnershipB / 4;
        expected.ownerSelf = ordinaryBudget + marketBudget * (ownerProviderWeightA + rewardB) / ownerWeight
            - expected.recipientA - expected.recipientB;
    }

    function _assertSourcesAndVerifierShares(Allocation memory expected, bool minted) private view {
        (uint256[] memory sourceIds, uint256 total) =
            group.joinedActionIdsByGroupId(address(token), OWNER_ID, round, 0, 1, false);
        require(total == 2 && sourceIds[0] == sourceA, "first participating source");
        (sourceIds, total) = group.joinedActionIdsByGroupId(address(token), OWNER_ID, round, 1, 1, false);
        require(total == 2 && sourceIds[0] == sourceB, "second participating source");

        (uint256 attributedProvider, uint256 joinedBlock) = group.providerAttribution(OWNER_ID, actorId);
        require(
            attributedProvider == externalProvider && joinedBlock == firstJoinBlock, "persistent provider from event"
        );
        (uint256[] memory actors, uint256 actorCount) =
            group.memberIdsByGroupId(address(token), round, sourceA, OWNER_ID, 1, 1, false);
        require(actorCount == 2 && actors[0] == actorId, "verified batch position identifies the attributed actor");
        _assertVerifierShare(sourceA, PROVIDER_ID, expected.verifierA, expected.verifierGroupShareA, minted);
        _assertVerifierShare(sourceB, OWNER_ID, expected.verifierB, expected.verifierB, minted);
        require(
            group.generatedActionRewardByGroupId(address(token), round, sourceB, PROVIDER_ID) == 0,
            "absent group weight"
        );
        require(group.totalGeneratedActionRewardByVerifierId(address(token), round, actorId) == 0, "no verifier weight");
        (uint256 pending, uint256 mintedAmount, MemberRewardStatus status) =
            service.verifierReward(address(token), round, serviceAction, actorId);
        require(pending == 0 && mintedAmount == 0 && status == MemberRewardStatus.Unavailable, "no verifier allocation");
    }

    function _assertVerifierShare(
        uint256 actionId,
        uint256 expectedVerifier,
        uint256 expectedTotal,
        uint256 expectedShare,
        bool minted
    ) private view {
        (uint256 verifierId,,) = group.verifier(address(token), round, actionId);
        require(verifierId == expectedVerifier, "source verifier identity");
        {
            (uint256 pending, uint256 mintedAmount, MemberRewardStatus status) =
                service.verifierReward(address(token), round, serviceAction, verifierId);
            _assertPrimaryReward(pending, mintedAmount, status, expectedTotal, minted);
        }
        uint256 groupWeight = group.generatedActionRewardByGroupId(address(token), round, actionId, OWNER_ID);
        uint256 verifierWeight = group.totalGeneratedActionRewardByVerifierId(address(token), round, verifierId);
        uint256 expectedGroupWeight = actionId == sourceA ? verifierWeight * 3 / 5 : verifierWeight;
        require(groupWeight == expectedGroupWeight, "verified group weight");
        require(expectedTotal * groupWeight / verifierWeight == expectedShare, "group verifier share with slice rounding");
    }

    function _assertGroupShares(Allocation memory expected, bool minted) private view {
        require(service.recipientRatio(address(token), round, sourceA, OWNER_ID, PROVIDER_ID) == 0.5e18, "source A ratio");
        require(service.recipientRatio(address(token), round, sourceB, OWNER_ID, PROVIDER_ID) == 0.25e18, "source B ratio");
        (uint256 pending, uint256 mintedAmount, MemberRewardStatus status) =
            service.groupOwnerReward(address(token), round, serviceAction, OWNER_ID);
        _assertPrimaryReward(pending, mintedAmount, status, expected.ownerSelf, minted);
        (uint256 amount, bool paid) =
            service.providerRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceA, OWNER_ID, externalProvider);
        require(amount == expected.provider && paid == minted, "provider quote and status");
        (amount, paid) = service.providerRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceB, OWNER_ID, OWNER_ID);
        require(amount == 0 && !paid, "self-funded source has no owner provider share");
        _assertRecipient(sourceA, expected.recipientA, minted);
        _assertRecipient(sourceB, expected.recipientB, minted);
    }

    function _assertPrimaryReward(
        uint256 pendingAmount,
        uint256 mintedAmount,
        MemberRewardStatus status,
        uint256 expectedAmount,
        bool minted
    ) private pure {
        require(pendingAmount == (minted ? 0 : expectedAmount), "round pending amount");
        require(mintedAmount == (minted ? expectedAmount : 0), "round minted amount");
        require(status == (minted ? MemberRewardStatus.Settled : MemberRewardStatus.Pending), "round reward status");
    }

    function _assertRecipient(uint256 actionId, uint256 expected, bool minted) private view {
        (uint256 amount, bool paid) =
            service.recipientRewardBySourceActionIdByGroupId(address(token), round, serviceAction, actionId, OWNER_ID, PROVIDER_ID);
        require(amount == expected && paid == minted, "partner quote and status");
    }

    function _mintProvider(Allocation memory expected) private {
        vm.expectEmit(true, true, true, true, address(service));
        emit IGroupServiceExecutorEvents.ProviderPaid({
            serviceTokenAddress: address(token),
            serviceActionId: serviceAction,
            round: round,
            groupId: OWNER_ID,
            sourceTokenAddress: address(token),
            sourceActionId: sourceA,
            providerId: externalProvider,
            amount: expected.provider
        });
        vm.prank(member2);
        require(
            service.mintProviderRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceA, OWNER_ID, externalProvider)
                == expected.provider,
            "provider mints first"
        );
    }

    function _mintRemainingRoles(Allocation memory expected) private {
        vm.expectEmit(true, true, true, true, address(service));
        emit IGroupServiceExecutorEvents.RecipientPaid({
            serviceTokenAddress: address(token),
            serviceActionId: serviceAction,
            round: round,
            groupId: OWNER_ID,
            sourceTokenAddress: address(token),
            sourceActionId: sourceA,
            recipientId: PROVIDER_ID,
            amount: expected.recipientA
        });
        vm.prank(member2);
        require(
            service.mintRecipientRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceA, OWNER_ID, PROVIDER_ID)
                == expected.recipientA,
            "partner A"
        );
        vm.prank(member2);
        require(
            service.mintRecipientRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceB, OWNER_ID, PROVIDER_ID)
                == expected.recipientB,
            "partner B"
        );
        vm.expectEmit(true, true, true, true, address(service));
        emit IGroupServiceExecutorEvents.ServiceOwnerRewardBurned({
            serviceTokenAddress: address(token),
            serviceActionId: serviceAction,
            round: round,
            groupId: OWNER_ID,
            amount: expected.burn
        });
        vm.prank(member1);
        require(
            service.mintGroupOwnerReward(address(token), round, serviceAction, OWNER_ID) == expected.ownerSelf,
            "owner self"
        );
        vm.prank(member2);
        require(
            service.mintVerifierReward(address(token), round, serviceAction, PROVIDER_ID) == expected.verifierA,
            "verifier A"
        );
        vm.prank(member1);
        require(
            service.mintVerifierReward(address(token), round, serviceAction, OWNER_ID) == expected.verifierB,
            "verifier B"
        );
    }

    function _setRecipient(uint256 actionId, uint256 groupId, uint256 recipientId, uint256 ratio) private {
        vm.prank(member1);
        service.setRecipients(address(token), actionId, groupId, _single(recipientId), _single(ratio), new string[](1));
    }

    function _advancePhase() private {
        vm.roll(block.number + BLOCKS_PER_PHASE);
    }

    function _pair(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = first;
        values[1] = second;
    }

    function _single(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
