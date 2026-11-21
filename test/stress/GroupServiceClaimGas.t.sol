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
    uint256 private constant SUBMIT_ROUND_LIMIT = 1_000;
    uint256 private constant SINGLE_ACTION_CLAIM_BUDGET = 500_000;
    uint256 private constant ACTIONS_PER_PAGE = 200;
    uint256 private constant PAGE_GAS_BUDGET = 3_000_000;
    uint256 private constant UNPREPARED_CLAIM_BUDGET = 16_000_000;
    uint256 private constant ONE_PAGE_CLAIM_BUDGET = 14_000_000;
    uint256 private constant PREPARED_CLAIM_BUDGET = 10_000_000;
    uint256 private constant UNPREPARED_BATCH_MEASUREMENT_BUDGET = 25_000_000;
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
        _joinActions(firstActions);
        uint256[] memory secondActions = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, false);
        _advancePhase();
        _joinActions(secondActions);

        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, 1, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(1);
        _finishServiceRound(sourceActionIds, serviceActionIds, new uint256[](0));
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
        uint256[] memory serviceActionIds = _createServiceActions(1);
        _finishServiceRound(sourceActionIds, serviceActionIds, proposers);
        vm.resumeGasMetering();

        uint256 serviceActionId = serviceActionIds[0];
        uint256 perRecipient = _recipientReward(round, 1);
        uint256 distributed = perRecipient * _recipientCount();
        uint256 unpreparedSnapshot = vm.snapshotState();
        _assertProgress(round, 0);
        _assertClaim(round, serviceActionId, UNPREPARED_CLAIM_BUDGET, distributed);
        _assertRecipientBalances(perRecipient);
        require(vm.revertToStateAndDelete(unpreparedSnapshot), "restore unprepared claim");

        uint256 firstPageGas = _preparePage(round, ACTIONS_PER_PAGE);
        uint256 onePageSnapshot = vm.snapshotState();
        _assertClaim(round, serviceActionId, ONE_PAGE_CLAIM_BUDGET, distributed);
        _assertRecipientBalances(perRecipient);
        require(vm.revertToStateAndDelete(onePageSnapshot), "restore partially prepared claim");

        _finishPreparation(round, ACTIONS_PER_PAGE, firstPageGas);
        _assertClaim(round, serviceActionId, PREPARED_CLAIM_BUDGET, distributed);
        _assertRecipientBalances(perRecipient);
    }

    function testBatchClaimWithTwoServicesSharingOwnerWeight() external {
        vm.pauseGasMetering();
        uint256[] memory proposers = _createProposers();
        uint256[] memory sourceActionIds = _createAndVoteOnActions(proposers, SUBMIT_ROUND_LIMIT, true);
        uint256 round = phase.currentPhase();
        uint256[] memory serviceActionIds = _createServiceActions(2);
        _finishServiceRound(sourceActionIds, serviceActionIds, proposers);
        vm.resumeGasMetering();

        uint256 perRecipient = _recipientReward(round, 2);
        uint256 unpreparedSnapshot = vm.snapshotState();
        _assertProgress(round, 0);
        _assertBatchClaim(round, serviceActionIds, UNPREPARED_BATCH_MEASUREMENT_BUDGET);
        _assertRecipientBalances(perRecipient * 2);
        require(vm.revertToStateAndDelete(unpreparedSnapshot), "restore unprepared batch");

        _finishPreparation(round, 0, 0);
        _assertBatchClaim(round, serviceActionIds, PREPARED_CLAIM_BUDGET);
        _assertRecipientBalances(perRecipient * 2);
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

    function _joinActions(uint256[] memory actionIds) private {
        GroupConfig memory config =
            GroupConfig({description: "Group", maxCapacity: 0, minJoinAmount: 1, maxJoinAmount: 0, maxAccounts: 0});
        vm.startPrank(member1);
        for (uint256 i; i < actionIds.length; ++i) {
            group.activateGroup(address(sourceToken), actionIds[i], MEMBER_ID, config);
            group.join(address(sourceToken), actionIds[i], MEMBER_ID, MEMBER_ID, 1, 0, new string[](0));
        }
        vm.stopPrank();
    }

    function _createServiceActions(uint256 count) private returns (uint256[] memory serviceActionIds) {
        serviceActionIds = new uint256[](count);
        bytes memory serviceData =
            abi.encodePacked(address(service), abi.encode(GroupServiceCreationParams(address(sourceToken), 0, 5e17)));
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
        uint256[] memory recipientCandidates
    ) private {
        _advancePhase();
        _joinActions(sourceActionIds);
        vm.startPrank(member1);
        for (uint256 i; i < serviceActionIds.length; ++i) {
            service.join(address(token), serviceActionIds[i], MEMBER_ID);
        }
        vm.stopPrank();

        _advancePhase();
        if (recipientCandidates.length != 0) _setFullRecipientLists(sourceActionIds, recipientCandidates);
        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;
        vm.startPrank(member1);
        for (uint256 i; i < sourceActionIds.length; ++i) {
            group.submitOriginScores(address(sourceToken), sourceActionIds[i], MEMBER_ID, MEMBER_ID, 0, scores);
        }
        vm.stopPrank();
        _advancePhase();
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

    function _preparePage(uint256 round, uint256 expectedProcessed) private returns (uint256 gasUsed) {
        vm.cool(address(group));
        vm.prank(member2);
        uint256 beforeGas = gasleft();
        (uint256 processed, uint256 total) = group.prepareGeneratedActionRewardByGroupId{gas: PAGE_GAS_BUDGET}(
            address(sourceToken), round, MEMBER_ID, ACTIONS_PER_PAGE
        );
        gasUsed = beforeGas - gasleft();
        require(processed == expectedProcessed && total == SUBMIT_ROUND_LIMIT, "preparation resumes at stored offset");
        require(gasUsed < PAGE_GAS_BUDGET, "page exceeds the local gas budget");
    }

    function _finishPreparation(uint256 round, uint256 alreadyProcessed, uint256 maxPageGas) private {
        for (
            uint256 processed = alreadyProcessed + ACTIONS_PER_PAGE;
            processed <= SUBMIT_ROUND_LIMIT;
            processed += ACTIONS_PER_PAGE
        ) {
            uint256 gasUsed = _preparePage(round, processed);
            if (gasUsed > maxPageGas) maxPageGas = gasUsed;
        }
        emit log_named_uint("largest preparation page gas", maxPageGas);

        _assertProgress(round, SUBMIT_ROUND_LIMIT);
        (uint256 processedCount, uint256 actionCount) =
            group.prepareGeneratedActionRewardByGroupId(address(sourceToken), round, MEMBER_ID, type(uint256).max);
        require(processedCount == actionCount && actionCount == SUBMIT_ROUND_LIMIT, "completed preparation is idempotent");
    }

    function _assertProgress(uint256 round, uint256 expectedProcessed) private view {
        (uint256 processed, uint256 count) = group.groupRewardPreparation(address(sourceToken), round, MEMBER_ID);
        require(processed == expectedProcessed && count == SUBMIT_ROUND_LIMIT, "expected full-round cursor");
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
        (uint256 paid, uint256 burned) =
            service.mintMemberReward{gas: gasBudget}(address(token), round, serviceActionId, MEMBER_ID);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("claim gas", gasUsed);
        require(gasUsed < gasBudget, "claim exceeds the local gas budget");
        require(paid == expected && burned == 0, "owner and verifier receive their shares");
        require(token.balanceOf(member1) - beforeBalance == paid - expectedDistributed, "claim pays the owner's balance");
    }

    function _assertBatchClaim(uint256 round, uint256[] memory serviceActionIds, uint256 gasBudget) private {
        uint256[] memory rounds = new uint256[](serviceActionIds.length);
        for (uint256 i; i < rounds.length; ++i) {
            rounds[i] = round;
        }
        uint256 expectedPerService = 2 * (mint.proposalReward(address(token), round) / serviceActionIds.length / 2);
        uint256 beforeBalance = token.balanceOf(member1);
        _coolClaimContracts();
        vm.prank(member1);
        uint256 beforeGas = gasleft();
        (uint256[] memory paid, uint256[] memory burned) =
            service.mintMemberRewards{gas: gasBudget}(address(token), rounds, serviceActionIds, MEMBER_ID);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("batch claim gas", gasUsed);
        require(gasUsed < gasBudget, "batch exceeds its measurement budget");
        for (uint256 i; i < paid.length; ++i) {
            require(paid[i] == expectedPerService && burned[i] == 0, "both services paid once");
        }
        uint256 distributedPerService = _recipientReward(round, serviceActionIds.length) * _recipientCount();
        require(
            token.balanceOf(member1) - beforeBalance == paid.length * (expectedPerService - distributedPerService),
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
