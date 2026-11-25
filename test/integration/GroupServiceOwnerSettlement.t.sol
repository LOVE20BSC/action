// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTargetIntegrationFixture} from "./ActionTargetRealIntegration.t.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupActionCreationParams} from "../../src/interfaces/IGroupActionExecutor.sol";
import {GroupServiceCreationParams} from "../../src/interfaces/IGroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {MemberRewardStatus} from "../../src/interfaces/IMemberRewardExecutor.sol";
import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";

contract GroupServiceOwnerSettlementTest is ActionTargetIntegrationFixture {
    error RecipientTransferFailed();

    uint256 private constant OWNER_ID = 1;
    uint256 private constant VERIFIER_ID = 2;
    uint256 private constant OWNER_SCORE_A = 24;
    uint256 private constant OWNER_SCORE_C = 39;

    GroupActionExecutor private group;
    GroupServiceExecutor private service;
    uint256 private round;
    uint256 private actionA;
    uint256 private actionB;
    uint256 private actionC;
    uint256 private serviceActionId;
    uint256 private secondServiceActionId;
    uint256 private expectedWeight;
    uint256 private ownerReward;
    uint256 private secondOwnerReward;
    uint256 private recipientReward;
    uint256 private secondRecipientReward;

    function setUp() public {
        _setUpProtocol(1, 0);
        group = new GroupActionExecutor(address(actionTarget));
        service = new GroupServiceExecutor(address(group));
        round = phase.currentPhase();

        vm.prank(member1);
        token.approve(address(group), type(uint256).max);
        vm.prank(member2);
        token.approve(address(group), type(uint256).max);
        _createActions();

        _advancePhase();
        _joinGroup(actionA, OWNER_ID, member1);
        _joinGroup(actionA, VERIFIER_ID, member2);
        _joinGroup(actionB, VERIFIER_ID, member2);
        _joinGroup(actionC, OWNER_ID, member1);
        _joinGroup(actionC, VERIFIER_ID, member2);
        vm.startPrank(member1);
        service.join(address(token), serviceActionId, OWNER_ID);
        service.join(address(token), secondServiceActionId, OWNER_ID);
        vm.stopPrank();

        _advancePhase();
        _setRecipient();
        _score(actionC, OWNER_ID, OWNER_SCORE_C);
        require(
            group.totalGeneratedActionRewardByGroupId(address(token), round, OWNER_ID) == 0,
            "action weight awaits verification of every group"
        );
        _score(actionC, VERIFIER_ID, 100 - OWNER_SCORE_C);
        _score(actionB, VERIFIER_ID, 100);
        _score(actionA, OWNER_ID, OWNER_SCORE_A);
        _score(actionA, VERIFIER_ID, 100 - OWNER_SCORE_A);
        _advancePhase();
        _calculateExpectedRewards();
    }

    function testHistoricalGroupWeightSurvivesExitingBothActions() external {
        _assertGroupWeight();
        vm.startPrank(member1);
        group.exit(address(token), actionA, OWNER_ID);
        group.exit(address(token), actionC, OWNER_ID);
        vm.stopPrank();
        (, uint256 currentCount) =
            group.joinedActionIdsByGroupId(address(token), OWNER_ID, group.currentJoinRound(), 0, 0, false);
        require(currentCount == 0, "later join round has no participation");

        _assertGroupWeight();
        _claim(serviceActionId, ownerReward - recipientReward);
    }

    function testRecipientCanClaimBeforeTheOwnerUsingVerifiedSourceRewards() external {
        uint256 ownerBalance = token.balanceOf(member1);
        uint256 recipientBalance = token.balanceOf(member2);
        uint256 supply = token.totalSupply();
        (uint256 serviceBudget,) = actionTarget.actionReward(address(token), round, serviceActionId);
        _assertRecipientReward(serviceActionId, recipientReward, false);

        vm.prank(member2);
        uint256 paid = service.mintRecipientRewardBySourceActionIdByGroupId(
            address(token), round, serviceActionId, actionA, OWNER_ID, VERIFIER_ID
        );
        require(paid == recipientReward, "recipient claim matches the source share");
        require(token.balanceOf(member2) == recipientBalance + paid, "recipient paid");
        require(token.balanceOf(member1) == ownerBalance, "owner can claim separately");
        require(token.totalSupply() == supply + serviceBudget, "proposal minted on the first claim");
        _assertRecipientReward(serviceActionId, paid, true);

        _claim(serviceActionId, ownerReward - paid);
        require(token.balanceOf(member1) == ownerBalance + ownerReward - paid, "owner receives the remainder");
        require(token.balanceOf(member2) == recipientBalance + paid, "recipient paid once");
        require(token.totalSupply() == supply + serviceBudget, "proposal minted once");
    }

    function testClaimRevertsWithRecipientTransferAndPaysOnceOnRetry() external {
        _assertServiceReward(serviceActionId, ownerReward - recipientReward, false);
        uint256 ownerBalance = token.balanceOf(member1);
        uint256 recipientBalance = token.balanceOf(member2);
        uint256 supply = token.totalSupply();
        vm.mockCallRevert(
            address(token),
            abi.encodeCall(token.transfer, (member2, recipientReward)),
            abi.encodeWithSelector(RecipientTransferFailed.selector)
        );
        vm.expectRevert(abi.encodeWithSelector(RecipientTransferFailed.selector));
        _claimRecipient(serviceActionId);
        vm.clearMockedCalls();

        (, bool actionMinted) = actionTarget.actionReward(address(token), round, serviceActionId);
        require(!actionMinted && token.totalSupply() == supply, "proposal mint rolled back");
        require(token.balanceOf(member1) == ownerBalance, "owner balance rolled back");
        require(token.balanceOf(member2) == recipientBalance, "recipient transfer rolled back");
        _assertRecipientReward(serviceActionId, recipientReward, false);
        _assertServiceReward(serviceActionId, ownerReward - recipientReward, false);
        _assertGroupWeight();

        require(_claimRecipient(serviceActionId) == recipientReward, "retry paid the recipient");
        _claim(serviceActionId, ownerReward - recipientReward);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), serviceActionId, OWNER_ID, round
            )
        );
        vm.prank(member1);
        service.mintMemberReward(address(token), round, serviceActionId, OWNER_ID);
        require(token.balanceOf(member1) == ownerBalance + ownerReward - recipientReward, "owner paid once");
        require(token.balanceOf(member2) == recipientBalance + recipientReward, "recipient paid once");
    }

    function testTwoServicesUseTheSameVerifiedWeightAcrossPhases() external {
        _assertServiceReward(serviceActionId, ownerReward - recipientReward, false);
        _assertServiceReward(secondServiceActionId, secondOwnerReward - secondRecipientReward, false);
        _claim(serviceActionId, ownerReward - recipientReward);

        _advancePhase();
        _assertServiceReward(serviceActionId, ownerReward - recipientReward, true);
        _assertServiceReward(secondServiceActionId, secondOwnerReward - secondRecipientReward, false);
        _claim(secondServiceActionId, secondOwnerReward - secondRecipientReward);
        _assertRecipientReward(secondServiceActionId, secondRecipientReward, false);
        require(_claimRecipient(secondServiceActionId) == secondRecipientReward, "second service pays its own share");
        _assertGroupWeight();
    }

    function _createActions() private {
        bytes memory groupData = abi.encodePacked(address(group), abi.encode(GroupActionCreationParams({
            joinTokenAddress: address(token),
            activationStakeAmount: 0,
            maxJoinAmountRatio: 1e18,
            activationMinGovRatio: 0,
            verifierStakeAmount: 0,
            verifierPunishmentRatio: 9e17,
            verificationKeys: new string[](0),
            verificationDescriptions: new string[](0)
        })));
        actionA = _submitActionProposal(OWNER_ID, "Source A", groupData);
        actionB = _submitActionProposal(VERIFIER_ID, "Source B", groupData);
        actionC = _submitActionProposal(_newProposer("Carol"), "Source C", groupData);

        GroupServiceCreationParams memory params = GroupServiceCreationParams(address(token), 0, 5e17, 0);
        bytes memory serviceData = abi.encodePacked(address(service), abi.encode(params));
        serviceActionId = _submitActionProposal(_newProposer("David"), "Service A", serviceData);
        params.publicVerifierRatio = 75e16;
        serviceData = abi.encodePacked(address(service), abi.encode(params));
        secondServiceActionId = _submitActionProposal(_newProposer("Eve"), "Service B", serviceData);

        _voteForSource(actionA, 19);
        _voteForSource(actionB, 23);
        _voteForSource(actionC, 41);
        _voteOne(OWNER_ID, serviceActionId, 83, "");
        _voteOne(OWNER_ID, secondServiceActionId, 31, "");
    }

    function _newProposer(string memory name) private returns (uint256 proposerId) {
        vm.startPrank(member1);
        (proposerId,) = memberNFT.mint(name);
        stake.stakeLiquidity(address(token), 100, 100, PROMISED_WAITING_PHASES, proposerId, type(uint256).max);
        vm.stopPrank();
    }

    function _advancePhase() private {
        vm.roll(block.number + BLOCKS_PER_PHASE);
    }

    function _voteForSource(uint256 actionId, uint256 amount) private {
        vm.prank(member2);
        group.submitVerifierApplication(address(token), actionId, VERIFIER_ID, "");
        bytes memory data = abi.encode(VERIFIER_ID);
        _voteOne(OWNER_ID, actionId, amount, data);
    }

    function _joinGroup(uint256 actionId, uint256 groupId, address owner) private {
        GroupConfig memory config =
            GroupConfig({description: "Group", maxCapacity: 0, minJoinAmount: 1, maxJoinAmount: 0, maxAccounts: 0});
        vm.startPrank(owner);
        group.activateGroup(address(token), actionId, groupId, config);
        group.join(address(token), actionId, groupId, groupId, 1, 0, new string[](0));
        vm.stopPrank();
    }

    function _setRecipient() private {
        uint256[] memory ids = new uint256[](1);
        ids[0] = VERIFIER_ID;
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 5e17;
        vm.prank(member1);
        service.setRecipients(address(token), actionA, OWNER_ID, ids, ratios, new string[](1));
    }

    function _score(uint256 actionId, uint256 groupId, uint256 score) private {
        uint256[] memory scores = new uint256[](1);
        scores[0] = score;
        vm.prank(member2);
        group.submitOriginScores(address(token), actionId, VERIFIER_ID, groupId, 0, scores);
    }

    function _calculateExpectedRewards() private {
        (uint256 rewardA,) = actionTarget.actionReward(address(token), round, actionA);
        (uint256 rewardB,) = actionTarget.actionReward(address(token), round, actionB);
        (uint256 rewardC,) = actionTarget.actionReward(address(token), round, actionC);
        (uint256 firstBudget,) = actionTarget.actionReward(address(token), round, serviceActionId);
        (uint256 secondBudget,) = actionTarget.actionReward(address(token), round, secondServiceActionId);
        uint256 sliceA = rewardA * OWNER_SCORE_A / 100;
        expectedWeight = sliceA + rewardC * OWNER_SCORE_C / 100;
        require(
            expectedWeight + 1 == (rewardA * OWNER_SCORE_A + rewardC * OWNER_SCORE_C) / 100,
            "fixture distinguishes per-action rounding"
        );
        uint256 denominator = rewardA + rewardB + rewardC;
        ownerReward = firstBudget * expectedWeight / (2 * denominator);
        secondOwnerReward = secondBudget * expectedWeight / (4 * denominator);
        recipientReward = (ownerReward * sliceA / expectedWeight) / 2;
        secondRecipientReward = (secondOwnerReward * sliceA / expectedWeight) / 2;
        require(recipientReward > 0 && secondOwnerReward > 0, "fixture pays both services and the recipient");
    }

    function _assertGroupWeight() private view {
        require(
            group.totalGeneratedActionRewardByGroupId(address(token), round, OWNER_ID) == expectedWeight,
            "only this group's verified shares counted once"
        );
        uint256 ownerProviderReward = group.totalGeneratedActionRewardAttributionByGroupIdByProviderId(
            address(token), round, OWNER_ID, OWNER_ID
        );
        require(ownerProviderReward == expectedWeight, "all scores attributed to owner");
    }

    function _assertServiceReward(uint256 actionId, uint256 expected, bool alreadyClaimed) private view {
        (uint256 pending, uint256 paid, MemberRewardStatus status) = service.memberReward(address(token), round, actionId, OWNER_ID);
        require(pending == (alreadyClaimed ? 0 : expected) && paid == (alreadyClaimed ? expected : 0), "service reward amounts");
        require(status == (alreadyClaimed ? MemberRewardStatus.Settled : MemberRewardStatus.Pending), "service settlement status");
    }

    function _assertRecipientReward(uint256 serviceId, uint256 expected, bool expectedMinted) private view {
        (uint256 amount, bool isMinted) = service.recipientRewardBySourceActionIdByGroupId(
            address(token), round, serviceId, actionA, OWNER_ID, VERIFIER_ID
        );
        require(amount == expected && isMinted == expectedMinted, "recipient reward and claim status");
    }

    function _claim(uint256 actionId, uint256 expected) private {
        vm.prank(member1);
        uint256 amount = service.mintMemberReward(address(token), round, actionId, OWNER_ID);
        require(amount == expected, "claim matches preview");
    }

    function _claimRecipient(uint256 serviceId) private returns (uint256) {
        vm.prank(member2);
        return service.mintRecipientRewardBySourceActionIdByGroupId(address(token), round, serviceId, actionA, OWNER_ID, VERIFIER_ID);
    }
}
