// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTargetIntegrationFixture} from "../integration/ActionTargetRealIntegration.t.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupActionCreationParams} from "../../src/interfaces/IGroupActionExecutor.sol";
import {GroupServiceCreationParams} from "../../src/interfaces/IGroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {DistributorMode} from "@core/interfaces/ILaunch.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {ProposalBody, TargetMode} from "@core/interfaces/ISubmit.sol";

contract GroupServiceClaimGasTest is ActionTargetIntegrationFixture {
    uint256 private constant MEMBER_ID = 1;
    uint256 private constant PROVIDER_ID = 2;
    uint256 private constant SUBMIT_ROUND_LIMIT = 1_000;
    uint256 private constant SINGLE_ACTION_CLAIM_BUDGET = 500_000;
    uint256 private constant FULL_ROUND_CLAIM_BUDGET = 16_000_000;
    uint256 private constant FULL_ROUND_BATCH_MEASUREMENT_BUDGET = 25_000_000;
    uint160 private constant FIRST_RECIPIENT = 0x2000;

    GroupActionExecutor private group;
    GroupServiceExecutor private service;
    LOVE20Token private sourceToken;

    event log_named_uint(
        string name,
        uint256 value
    );

    function setUp() public {
        // A one-vote submit threshold and zero reward threshold let all 1,000 actions earn a share.
        _setUpProtocol(1, 0);
        group = new GroupActionExecutor(address(actionTarget));
        service = new GroupServiceExecutor(address(group));
        vm.prank(address(mint));
        launch.addLaunchCount(address(token), MEMBER_ID, 1);
        vm.prank(member1);
        sourceToken = LOVE20Token(
            launch.launchToken("GASC", address(token), MEMBER_ID, member1, DistributorMode.NoCallback, "")
        );
        vm.prank(distributor);
        token.transfer(member1, 10_000);
        vm.startPrank(member1);
        sourceToken.approve(address(stake), type(uint256).max);
        sourceToken.approve(address(group), type(uint256).max);
        token.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(sourceToken), 5_000, 5_000, 1, MEMBER_ID, type(uint256).max);
        vm.stopPrank();
    }

    function testOwnerClaimIgnoresTwoThousandPastParticipations() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory firstActions = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, false);
        _advancePhase();
        _joinActions(firstActions, MEMBER_ID, member1);
        uint256[] memory secondActions = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, false);
        _advancePhase();
        _joinActions(secondActions, MEMBER_ID, member1);

        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, 1, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(1, 0);
        _finishServiceRound(sourceActionIds, serviceActionIds, new uint256[](0), false);
        (, uint256 participationCount) = group.joinedActionIdsByGroupId(address(sourceToken), MEMBER_ID, round, 0, 0, false);
        require(participationCount == 2 * SUBMIT_ROUND_LIMIT + 1, "historical positions carry forward");
        vm.resumeGasMetering();

        _assertClaim(round, serviceActionIds[0], SINGLE_ACTION_CLAIM_BUDGET, 0);
    }

    function testOwnerClaimWithAThousandRewardedActionsAndFullRecipientLists() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(1, 0);
        _finishServiceRound(sourceActionIds, serviceActionIds, proposers, false);
        vm.resumeGasMetering();

        uint256 serviceActionId = serviceActionIds[0];
        uint256 perRecipient = _recipientReward(round, 1);
        uint256 distributed = perRecipient * _recipientCount();
        _assertClaim(round, serviceActionId, FULL_ROUND_CLAIM_BUDGET, distributed);
        _assertRecipientBalances(0);
    }

    function testBatchClaimWithTwoServicesSharingOwnerWeight() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(2, 0);
        _finishServiceRound(sourceActionIds, serviceActionIds, proposers, false);
        vm.resumeGasMetering();

        _assertBatchClaim(round, serviceActionIds, FULL_ROUND_BATCH_MEASUREMENT_BUDGET);
        _assertRecipientBalances(0);
    }

    function testOwnerClaimsWithAThousandProviderActions() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(1, 0.5e18);
        _finishServiceRound(sourceActionIds, serviceActionIds, proposers, true);
        vm.resumeGasMetering();

        uint256 ownerBudget = mint.proposalReward(address(token), round) / 2;
        uint256 marketBudget = ownerBudget / 2;
        uint256 ownerMarket = marketBudget / 2;
        uint256 partnershipSlice =
            (ownerBudget - marketBudget) / SUBMIT_ROUND_LIMIT + ownerMarket / SUBMIT_ROUND_LIMIT;
        uint256 recipient = partnershipSlice / service.MAX_RECIPIENTS_PER_ACTION();
        uint256 distributed = marketBudget - ownerMarket + recipient * _recipientCount();
        _assertOwnerQuote(round, serviceActionIds[0], distributed);
        _assertClaim(round, serviceActionIds[0], FULL_ROUND_CLAIM_BUDGET, distributed);
    }

    function testOwnerClaimGasIgnoresOtherGroupsVerifiedActions() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory allActions = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, true);
        uint256 round = phase.currentPhase();
        uint256 serviceActionId = _createServiceActions(1, 0.5e18)[0];
        uint256[] memory ownActions = new uint256[](1);
        ownActions[0] = allActions[0];
        uint256[] memory otherActions = new uint256[](allActions.length - 1);
        for (uint256 i; i < otherActions.length; ++i) {
            otherActions[i] = allActions[i + 1];
        }

        vm.prank(member1);
        sourceToken.transfer(member2, otherActions.length);
        vm.prank(member2);
        sourceToken.approve(address(group), type(uint256).max);
        _advancePhase();
        _joinActions(ownActions, MEMBER_ID, member1);
        _joinActions(otherActions, PROVIDER_ID, member2);
        _advancePhase();
        _verifyActions(ownActions, MEMBER_ID, false);
        _verifyActions(otherActions, PROVIDER_ID, false);
        _advancePhase();
        vm.resumeGasMetering();

        uint256 communityWeight = group.totalGeneratedActionReward(address(sourceToken), round);
        uint256 ownWeight = group.generatedActionRewardByGroupId(address(sourceToken), round, ownActions[0], MEMBER_ID);
        require(ownWeight != 0 && communityWeight == ownWeight * SUBMIT_ROUND_LIMIT, "all actions earned rewards");
        require(group.totalGeneratedActionRewardByGroupId(address(sourceToken), round, MEMBER_ID) == ownWeight, "own list");
        uint256 ownerBudget = mint.proposalReward(address(token), round) / (2 * SUBMIT_ROUND_LIMIT);
        _coolClaimContracts();
        vm.prank(member1);
        uint256 beforeGas = gasleft();
        uint256 paid = service.mintGroupOwnerReward{gas: SINGLE_ACTION_CLAIM_BUDGET}(
            address(token), round, serviceActionId, MEMBER_ID
        );
        emit log_named_uint("single group claim gas", beforeGas - gasleft());
        require(paid == ownerBudget && paid != 0, "owner paid for one verified action");
    }

    function _assertOwnerQuote(uint256 round, uint256 serviceActionId, uint256 distributed) private view {
        (uint256 amount, bool minted) = service.groupOwnerReward(address(token), round, serviceActionId, MEMBER_ID);
        require(amount == mint.proposalReward(address(token), round) / 2 - distributed && !minted, "owner quote");
    }

    function _createProposers() private returns (uint256[] memory proposerIds) {
        proposerIds = new uint256[](SUBMIT_ROUND_LIMIT);
        vm.startPrank(member1);
        for (uint256 i; i < proposerIds.length; ++i) {
            (uint256 proposerId,) = memberNFT.mint(string.concat("proposer", vm.toString(i)));
            stake.stakeLiquidity(address(sourceToken), 1, 1, 1, proposerId, type(uint256).max);
            proposerIds[i] = proposerId;
        }
        vm.stopPrank();
    }

    function _createAndVoteOnActions(uint256[] memory proposers, uint256 count, bool electVerifier)
        private
        returns (uint256[] memory actionIds)
    {
        bytes memory creationData = abi.encodePacked(address(group), abi.encode(GroupActionCreationParams({
            joinTokenAddress: address(sourceToken),
            activationStakeAmount: 0,
            maxJoinAmountRatio: 1e18,
            activationMinGovRatio: 0,
            verifierStakeAmount: 0,
            verifierPunishmentRatio: 9e17,
            verificationKeys: new string[](0),
            verificationDescriptions: new string[](0)
        })));

        bytes[] memory voteData = new bytes[](1);
        if (electVerifier) {
            voteData[0] = abi.encode(MEMBER_ID);
        }

        uint256[] memory proposalIds = new uint256[](1);
        uint256[] memory voteAmounts = new uint256[](1);
        voteAmounts[0] = 1;
        actionIds = new uint256[](count);
        vm.startPrank(member1);
        for (uint256 i; i < count; ++i) {
            uint256 actionId = submit.submitNewProposal(
                address(sourceToken),
                proposers[i],
                ProposalBody({
                    title: "Chain group action",
                    details: "",
                    target: address(actionTarget),
                    targetMode: TargetMode.Callback,
                    creationData: creationData
                }),
                ""
            );
            if (electVerifier) group.submitVerifierApplication(address(sourceToken), actionId, MEMBER_ID, "");
            actionIds[i] = actionId;
            proposalIds[0] = actionId;
            vote.vote(address(sourceToken), MEMBER_ID, proposalIds, voteAmounts, voteData);
        }
        vm.stopPrank();
    }

    function _joinActions(uint256[] memory actionIds, uint256 groupId, address groupOwner) private {
        GroupConfig memory config =
            GroupConfig({description: "Group", maxCapacity: 0, minJoinAmount: 1, maxJoinAmount: 0, maxAccounts: 0});
        vm.startPrank(groupOwner);
        for (uint256 i; i < actionIds.length; ++i) {
            group.activateGroup(address(sourceToken), actionIds[i], groupId, config);
            group.join(address(sourceToken), actionIds[i], groupId, groupId, 1, 0, new string[](0));
        }
        vm.stopPrank();
    }

    function _createServiceActions(uint256 count, uint256 providerIncentiveRatio)
        private
        returns (uint256[] memory serviceActionIds)
    {
        serviceActionIds = new uint256[](count);
        bytes memory serviceData = abi.encodePacked(
            address(service), abi.encode(GroupServiceCreationParams(address(sourceToken), 0, 5e17, providerIncentiveRatio))
        );
        for (uint256 i; i < count; ++i) {
            uint256 proposerId = i + 1;
            uint256 serviceActionId = _submitActionProposal(proposerId, "Group service", serviceData);
            _voteOne(proposerId, serviceActionId, 1, "");
            serviceActionIds[i] = serviceActionId;
        }
    }

    function _finishServiceRound(
        uint256[] memory sourceActionIds,
        uint256[] memory serviceActionIds,
        uint256[] memory recipientCandidates,
        bool withProvider
    ) private {
        _advancePhase();
        _joinActions(sourceActionIds, MEMBER_ID, member1);
        if (withProvider) _joinProviderActors(sourceActionIds);
        vm.startPrank(member1);
        for (uint256 i; i < serviceActionIds.length; ++i) {
            service.join(address(token), serviceActionIds[i], MEMBER_ID);
        }
        vm.stopPrank();

        _advancePhase();
        if (recipientCandidates.length != 0) _setFullRecipientLists(sourceActionIds, recipientCandidates);
        _verifyActions(sourceActionIds, MEMBER_ID, withProvider);
        _advancePhase();
    }

    function _verifyActions(uint256[] memory sourceActionIds, uint256 groupId, bool withProvider) private {
        uint256[] memory scores = new uint256[](withProvider ? 2 : 1);
        scores[0] = 100;
        if (withProvider) scores[1] = 100;
        vm.startPrank(member1);
        for (uint256 i; i < sourceActionIds.length; ++i) {
            group.submitOriginScores(address(sourceToken), sourceActionIds[i], MEMBER_ID, groupId, 0, scores);
        }
        vm.stopPrank();
    }

    function _joinProviderActors(uint256[] memory sourceActionIds) private {
        vm.prank(member1);
        sourceToken.transfer(member2, sourceActionIds.length);
        vm.startPrank(member2);
        (uint256 actorId,) = memberNFT.mint("ProviderActor");
        sourceToken.approve(address(group), type(uint256).max);
        vm.stopPrank();

        uint256[] memory actorIds = new uint256[](1);
        actorIds[0] = actorId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            uint256 sourceActionId = sourceActionIds[i];
            vm.prank(member2);
            group.addProviderQuota(address(sourceToken), sourceActionId, MEMBER_ID, PROVIDER_ID, actorIds, amounts);
            vm.prank(member2);
            group.join(address(sourceToken), sourceActionId, MEMBER_ID, actorId, 1, PROVIDER_ID, new string[](0));
        }
    }

    function _setFullRecipientLists(uint256[] memory sourceActionIds, uint256[] memory recipientCandidates) private {
        uint256 actionLimit = service.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP();
        uint256 recipientLimit = service.MAX_RECIPIENTS_PER_ACTION();
        uint256[] memory recipients = new uint256[](recipientLimit);
        uint256[] memory ratios = new uint256[](recipientLimit);
        string[] memory remarks = new string[](recipientLimit);
        vm.startPrank(member1);
        for (uint256 i; i < actionLimit; ++i) {
            for (uint256 j; j < recipientLimit; ++j) {
                uint256 index = i * recipientLimit + j;
                uint256 recipientId = recipientCandidates[index];
                memberNFT.transferFrom(member1, address(FIRST_RECIPIENT + uint160(index)), recipientId);
                recipients[j] = recipientId;
                ratios[j] = 1e18 / recipientLimit;
            }
            service.setRecipients(address(sourceToken), sourceActionIds[i], MEMBER_ID, recipients, ratios, remarks);
        }
        vm.stopPrank();
    }

    function _recipientCount() private view returns (uint256) {
        return service.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP() * service.MAX_RECIPIENTS_PER_ACTION();
    }

    function _recipientReward(uint256 round, uint256 serviceCount) private view returns (uint256 perRecipient) {
        uint256 serviceReward = mint.proposalReward(address(token), round) / serviceCount;
        perRecipient = serviceReward / 2 / SUBMIT_ROUND_LIMIT / service.MAX_RECIPIENTS_PER_ACTION();
        require(perRecipient > 0, "every recipient earns a positive amount");
    }

    function _assertRecipientBalances(uint256 amount) private view {
        uint256 count = _recipientCount();
        for (uint256 i; i < count; ++i) {
            require(token.balanceOf(address(FIRST_RECIPIENT + uint160(i))) == amount, "recipient was paid");
        }
    }

    function _assertClaim(
        uint256 round,
        uint256 serviceActionId,
        uint256 gasBudget,
        uint256 expectedDistributed
    ) private {
        uint256 expected = 2 * (mint.proposalReward(address(token), round) / 2);
        require(expected > 0, "positive service reward");
        uint256 beforeBalance = token.balanceOf(member1);

        _coolClaimContracts();
        vm.prank(member1);
        uint256 beforeGas = gasleft();
        uint256 paid =
            service.mintMemberReward{gas: gasBudget}(address(token), round, serviceActionId, MEMBER_ID);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("claim gas", gasUsed);
        require(gasUsed < gasBudget, "claim exceeds the local gas budget");
        require(paid == expected - expectedDistributed, "owner and verifier receive their shares");
        require(token.balanceOf(member1) - beforeBalance == paid, "claim pays the owner's balance");
    }

    function _assertBatchClaim(uint256 round, uint256[] memory serviceActionIds, uint256 gasBudget) private {
        uint256[] memory rounds = new uint256[](serviceActionIds.length);
        for (uint256 i; i < rounds.length; ++i) {
            rounds[i] = round;
        }
        uint256 reservedPerService = _recipientReward(round, serviceActionIds.length) * _recipientCount();
        uint256 expectedPerService =
            2 * (mint.proposalReward(address(token), round) / serviceActionIds.length / 2) - reservedPerService;
        uint256 beforeBalance = token.balanceOf(member1);
        _coolClaimContracts();
        vm.prank(member1);
        uint256 beforeGas = gasleft();
        uint256[] memory paid =
            service.mintMemberRewards{gas: gasBudget}(address(token), rounds, serviceActionIds, MEMBER_ID);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("batch claim gas", gasUsed);
        require(gasUsed < gasBudget, "batch exceeds its measurement budget");
        for (uint256 i; i < paid.length; ++i) {
            require(paid[i] == expectedPerService, "both services paid once");
        }
        require(
            token.balanceOf(member1) - beforeBalance == paid.length * expectedPerService,
            "batch pays the owner's balance"
        );
    }

    function _coolClaimContracts() private {
        vm.cool(address(service));
        vm.cool(address(group));
        vm.cool(address(actionTarget));
        vm.cool(address(mint));
        vm.cool(address(vote));
        vm.cool(address(submit));
        vm.cool(address(launch));
        vm.cool(address(phase));
        vm.cool(address(memberNFT));
        vm.cool(address(token));
    }

    function _advancePhase() private {
        vm.roll(block.number + BLOCKS_PER_PHASE);
    }
}
