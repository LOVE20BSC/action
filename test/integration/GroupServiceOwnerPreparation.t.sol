// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTargetIntegrationFixture} from "./ActionTargetRealIntegration.t.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {IGroupActionExecutorEvents} from "../../src/interfaces/IGroupActionExecutor.sol";
import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";

contract RevertingPreparation {
    error PreparationRolledBack(uint256 processedActionCount, uint256 totalActionCount);

    function prepareAndRevert(GroupActionExecutor group, address tokenAddress, uint256 round) external {
        (uint256 processedActionCount, uint256 totalActionCount) =
            group.prepareGeneratedActionRewardByGroupId(tokenAddress, round, 1, 2);
        revert PreparationRolledBack(processedActionCount, totalActionCount);
    }
}

contract GroupServiceOwnerPreparationTest is ActionTargetIntegrationFixture, IGroupActionExecutorEvents {
    error OwnerTransferFailed();

    uint256 private constant OWNER_ID = 1;
    uint256 private constant VERIFIER_ID = 2;
    uint256 private constant ACTION_COUNT = 3;
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
    uint256 private firstPageWeight;
    uint256 private expectedWeight;
    uint256 private ownerReward;
    uint256 private secondOwnerReward;
    uint256 private recipientReward;

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
        _score(actionC, VERIFIER_ID, 100 - OWNER_SCORE_C);
        _score(actionB, VERIFIER_ID, 100);
        _score(actionA, OWNER_ID, OWNER_SCORE_A);
        _score(actionA, VERIFIER_ID, 100 - OWNER_SCORE_A);
        _advancePhase();
        _calculateExpectedRewards();
    }

    function testRevertedPageResumesFromCommittedCursorAcrossCallers() external {
        _assertProgress(0);
        _expectProgress(0, 1, firstPageWeight, firstPageWeight);
        _prepare(member1, 1, 1);

        RevertingPreparation reverting = new RevertingPreparation();
        vm.expectRevert(abi.encodeWithSelector(RevertingPreparation.PreparationRolledBack.selector, 3, ACTION_COUNT));
        reverting.prepareAndRevert(group, address(token), round);
        _assertProgress(1);

        (bool success,) = address(group).call{gas: 900}(
            abi.encodeCall(group.prepareGeneratedActionRewardByGroupId, (address(token), round, OWNER_ID, 2))
        );
        require(!success, "gas-limited preparation failed");
        _assertProgress(1);

        vm.startPrank(member1);
        group.exit(address(token), actionA, OWNER_ID);
        group.exit(address(token), actionC, OWNER_ID);
        vm.stopPrank();
        (, uint256 currentCount) =
            group.joinedActionIdsByGroupId(address(token), OWNER_ID, group.currentJoinRound(), 0, 0, false);
        require(currentCount == 0, "later join round has no participation");

        _expectProgress(1, 2, 0, firstPageWeight);
        _prepare(member2, 1, 2);
        _expectProgress(2, 3, expectedWeight - firstPageWeight, expectedWeight);
        _prepare(member1, type(uint256).max, 3);
    }

    function testPreparationNoOpsDoNotEmitProgress() external {
        vm.recordLogs();
        _prepare(member2, 0, 0);
        require(vm.getRecordedLogs().length == 0, "zero limit emitted no event");

        _expectProgress(0, 3, expectedWeight, expectedWeight);
        _prepare(member2, type(uint256).max, 3);
        vm.recordLogs();
        _prepare(member1, 1, 3);
        require(vm.getRecordedLogs().length == 0, "completed preparation emitted no event");
    }

    function testPartialClaimRevertsWithOwnerTransferAndPaysOnceOnRetry() external {
        _prepare(member2, 1, 1);
        _assertServiceReward(serviceActionId, ownerReward, false);
        uint256 ownerBalance = token.balanceOf(member1);
        uint256 recipientBalance = token.balanceOf(member2);
        uint256 supply = token.totalSupply();
        vm.mockCallRevert(
            address(token),
            abi.encodeCall(token.transfer, (member1, ownerReward - recipientReward)),
            abi.encodeWithSelector(OwnerTransferFailed.selector)
        );
        vm.expectRevert(abi.encodeWithSelector(OwnerTransferFailed.selector));
        vm.prank(member1);
        service.mintMemberReward(address(token), serviceActionId, round, OWNER_ID);
        vm.clearMockedCalls();

        (, bool actionMinted) = actionTarget.actionReward(address(token), serviceActionId, round);
        require(!actionMinted && token.totalSupply() == supply, "proposal mint rolled back");
        require(token.balanceOf(member1) == ownerBalance, "owner balance rolled back");
        require(token.balanceOf(member2) == recipientBalance, "recipient transfer rolled back");
        _assertServiceReward(serviceActionId, ownerReward, false);
        _assertProgress(1);

        _claim(serviceActionId, ownerReward);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), serviceActionId, OWNER_ID, round
            )
        );
        vm.prank(member1);
        service.mintMemberReward(address(token), serviceActionId, round, OWNER_ID);
        require(token.balanceOf(member1) == ownerBalance + ownerReward - recipientReward, "owner paid once");
        require(token.balanceOf(member2) == recipientBalance + recipientReward, "recipient paid once");
        _assertProgress(1);
    }

    function testTwoServicesSharePreparationAcrossPhases() external {
        _assertServiceReward(serviceActionId, ownerReward, false);
        _assertServiceReward(secondServiceActionId, secondOwnerReward, false);
        _prepare(member2, 1, 1);
        _claim(serviceActionId, ownerReward);
        _assertProgress(1);

        _advancePhase();
        _prepare(member1, 2, 3);
        _assertServiceReward(serviceActionId, ownerReward, true);
        _assertServiceReward(secondServiceActionId, secondOwnerReward, false);
        _claim(secondServiceActionId, secondOwnerReward);
        _assertProgress(3);
    }

    function _createActions() private {
        bytes[] memory groupData = new bytes[](7);
        groupData[0] = abi.encode(address(group));
        groupData[1] = abi.encode(address(token));
        groupData[2] = abi.encode(uint256(0));
        groupData[3] = abi.encode(uint256(1e18));
        groupData[4] = abi.encode(uint256(0));
        groupData[5] = abi.encode(uint256(0));
        groupData[6] = abi.encode(uint256(9e17));
        actionA = _submitActionProposal(OWNER_ID, "Source A", groupData);
        actionB = _submitActionProposal(VERIFIER_ID, "Source B", groupData);
        actionC = _submitActionProposal(_newProposer("Carol"), "Source C", groupData);

        bytes[] memory serviceData = new bytes[](4);
        serviceData[0] = abi.encode(address(service));
        serviceData[1] = abi.encode(address(token));
        serviceData[2] = abi.encode(uint256(0));
        serviceData[3] = abi.encode(uint256(5e17));
        serviceActionId = _submitActionProposal(_newProposer("David"), "Service A", serviceData);
        serviceData[3] = abi.encode(uint256(75e16));
        secondServiceActionId = _submitActionProposal(_newProposer("Eve"), "Service B", serviceData);

        _voteForSource(actionA, 19);
        _voteForSource(actionB, 23);
        _voteForSource(actionC, 41);
        _voteOne(OWNER_ID, serviceActionId, 83, new bytes[](0));
        _voteOne(OWNER_ID, secondServiceActionId, 31, new bytes[](0));
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
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(address(group));
        data[1] = abi.encode(VERIFIER_ID);
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
        (uint256 rewardA,) = actionTarget.actionReward(address(token), actionA, round);
        (uint256 rewardB,) = actionTarget.actionReward(address(token), actionB, round);
        (uint256 rewardC,) = actionTarget.actionReward(address(token), actionC, round);
        (uint256 firstBudget,) = actionTarget.actionReward(address(token), serviceActionId, round);
        (uint256 secondBudget,) = actionTarget.actionReward(address(token), secondServiceActionId, round);
        uint256 sliceA = rewardA * OWNER_SCORE_A / 100;
        firstPageWeight = rewardC * OWNER_SCORE_C / 100;
        expectedWeight = sliceA + firstPageWeight;
        require(
            expectedWeight + 1 == (rewardA * OWNER_SCORE_A + rewardC * OWNER_SCORE_C) / 100,
            "fixture distinguishes per-action rounding"
        );
        uint256 denominator = rewardA + rewardB + rewardC;
        ownerReward = firstBudget * expectedWeight / (2 * denominator);
        secondOwnerReward = secondBudget * expectedWeight / (4 * denominator);
        recipientReward = (ownerReward * sliceA / expectedWeight) / 2;
        require(recipientReward > 0 && secondOwnerReward > 0, "fixture pays both services and the recipient");
    }

    function _expectProgress(uint256 startIndex, uint256 processedActionCount, uint256 weightAdded, uint256 totalWeight)
        private
    {
        vm.expectEmit(true, true, true, true, address(group));
        emit GroupRewardPreparationAdvanced({
            tokenAddress: address(token),
            groupId: OWNER_ID,
            round: round,
            startIndex: startIndex,
            processedActionCount: processedActionCount,
            totalActionCount: ACTION_COUNT,
            weightAdded: weightAdded,
            totalWeight: totalWeight
        });
    }

    function _prepare(address caller, uint256 limit, uint256 cursor) private {
        vm.prank(caller);
        (uint256 processed, uint256 count) =
            group.prepareGeneratedActionRewardByGroupId(address(token), round, OWNER_ID, limit);
        require(processed == cursor && count == ACTION_COUNT, "preparation returned expected cursor");
        _assertProgress(cursor);
    }

    function _assertProgress(uint256 cursor) private view {
        (uint256 processed, uint256 count) = group.groupRewardPreparation(address(token), round, OWNER_ID);
        require(processed == cursor && count == ACTION_COUNT, "stored cursor and source count");
        require(
            group.totalGeneratedActionRewardByGroupId(address(token), round, OWNER_ID) == expectedWeight,
            "all individually rounded slices counted once"
        );
    }

    function _assertServiceReward(uint256 actionId, uint256 expected, bool alreadyClaimed) private view {
        (uint256 amount, uint256 burned, bool claimed) = service.memberReward(address(token), actionId, round, OWNER_ID);
        require(amount == expected && burned == 0 && claimed == alreadyClaimed, "service reward and claim status");
    }

    function _claim(uint256 actionId, uint256 expected) private {
        vm.prank(member1);
        (uint256 amount, uint256 burned) = service.mintMemberReward(address(token), actionId, round, OWNER_ID);
        require(amount == expected && burned == 0, "claim matches preview");
    }
}
