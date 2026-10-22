// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupRecipientsErrors, IGroupRecipientsEvents} from "../src/interfaces/IGroupRecipients.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockGroupServiceMemberNFT} from "./mocks/GroupServiceMocks.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceRecipientsTest is GroupServiceTestBase, IGroupRecipientsEvents {
    function testSetRecipientsStoresTheVerifyRoundAndEmits() external {
        _prepareRecipientsScenario();

        vm.expectEmit(true, true, true, true);
        emit SetRecipients(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2)
        );
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory remarks) =
            executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(recipientIds.length == 1 && recipientIds[0] == MEMBER1_ID, "recipient stored");
        require(ratios[0] == PRECISION / 2, "ratio stored");
        require(remarks.length == 1 && keccak256(bytes(remarks[0])) == keccak256(""), "remark stored");

        uint256[] memory actionIds;
        (actionIds,) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, false);
        require(actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID, "action registered");
    }

    function testSetRecipientsRejectsUnknownSourceAction() external {
        _prepareRecipientsScenario();

        uint256 unknownActionId = 99;
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupRecipientsErrors.UnknownSourceAction.selector, address(token), unknownActionId
            )
        );
        executor.setRecipients(
            address(token), unknownActionId, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsRejectsNonOwner() external {
        _prepareRecipientsScenario();

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NotGroupOwner.selector, GROUP_ID));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsChecksOwnerBeforeRound() external {
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NotGroupOwner.selector, GROUP_ID));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsRejectsMissingGroup() external {
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupServiceExecutorErrors.GroupNotExist.selector, uint256(999999))
        );
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, 999999, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsOwnerStillChecksRound() external {
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsValidationChain() external {
        _prepareRecipientsScenario();

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.ArrayLengthMismatch.selector));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION, PRECISION), new string[](1)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.ArrayLengthMismatch.selector));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](0)
        );

        uint256[] memory tooMany = new uint256[](DEFAULT_MAX_RECIPIENTS + 1);
        uint256[] memory unitRatios = new uint256[](DEFAULT_MAX_RECIPIENTS + 1);
        string[] memory unitRemarks = new string[](DEFAULT_MAX_RECIPIENTS + 1);
        for (uint256 i = 0; i < unitRatios.length; i++) {
            tooMany[i] = MEMBER1_ID + i;
            unitRatios[i] = 1;
            unitRemarks[i] = "";
        }
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.TooManyRecipients.selector));
        executor.setRecipients(address(token), GROUP_ACTION_ID, GROUP_ID, tooMany, unitRatios, unitRemarks);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.ZeroRatio.selector));
        executor.setRecipients(address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(0), new string[](1));

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.DuplicateMemberId.selector, MEMBER1_ID));
        executor.setRecipients(
            address(token),
            GROUP_ACTION_ID,
            GROUP_ID,
            _ids(MEMBER1_ID, MEMBER1_ID),
            _ratios(PRECISION / 2, PRECISION / 2),
            new string[](2)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupRecipientsErrors.RecipientIsGroupId.selector, GROUP_ID, GROUP_ID)
        );
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(GROUP_ID), _ratios(PRECISION), new string[](1)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721NonexistentToken.selector, MEMBER1_ID + DEFAULT_MAX_RECIPIENTS + 5
            )
        );
        executor.setRecipients(
            address(token),
            GROUP_ACTION_ID,
            GROUP_ID,
            _ids(MEMBER1_ID + DEFAULT_MAX_RECIPIENTS + 5),
            _ratios(PRECISION),
            new string[](1)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupRecipientsErrors.DistributionOverflow.selector, PRECISION + 1, PRECISION)
        );
        executor.setRecipients(
            address(token),
            GROUP_ACTION_ID,
            GROUP_ID,
            _ids(MEMBER1_ID, MEMBER2_ID),
            _ratios(PRECISION, 1),
            new string[](2)
        );

        // Exactly the full precision is legal.
        vm.prank(GROUP_OWNER);
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
        (uint256[] memory recipientIds,,) =
            executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(recipientIds[0] == MEMBER1_ID, "full precision configuration accepted");
    }

    function testRecipientsLazyInheritanceAndSameRoundOverwrite() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        // A later round inherits the last configuration at or before it.
        (uint256[] memory recipientIds, uint256[] memory ratios,) =
            executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND + 3);
        require(recipientIds[0] == MEMBER1_ID && ratios[0] == PRECISION / 2, "inherited by a later round");

        // Nothing is recorded before the first configuration.
        (recipientIds,,) = executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND - 1);
        require(recipientIds.length == 0, "no configuration before");

        // A same-round update overwrites that round's snapshot.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(PRECISION));
        (recipientIds, ratios,) = executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(recipientIds.length == 1 && recipientIds[0] == MEMBER2_ID, "same round overwritten");
        require(ratios[0] == PRECISION, "ratio overwritten");
    }

    function testClearRemovesFromEnumerationButKeepsHistory() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        _atPhase(VERIFY_PHASE + 2);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, new uint256[](0), new uint256[](0));

        (uint256[] memory actionIds, uint256 total) =
            executor.actionIdsWithRecipients(address(token), GROUP_ID, VERIFY_PHASE + 1, 0, 10, false);
        require(total == 0 && actionIds.length == 0, "cleared round no longer enumerates");
        (uint256[] memory recipientIds,,) =
            executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, VERIFY_PHASE + 1);
        require(recipientIds.length == 0, "cleared configuration is empty");

        // The earlier round keeps its snapshot.
        (actionIds, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, false);
        require(total == 1 && actionIds[0] == GROUP_ACTION_ID, "history survives the later clear");
        (recipientIds,,) = executor.recipients(address(token), GROUP_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        require(recipientIds[0] == MEMBER1_ID, "recipient history survives");
    }

    function testActionIdsWithRecipientsPagination() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 2));

        (uint256[] memory page, uint256 total) =
            executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == 2 && page.length == 0, "limit zero returns the total only");

        (page, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 1, false);
        require(total == 2 && page.length == 1 && page[0] == GROUP_ACTION_ID, "first page");

        (page, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 1, 1, false);
        require(total == 2 && page.length == 1 && page[0] == GROUP_ACTION_ID_B, "second page");

        (page, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, true);
        require(total == 2 && page.length == 2 && page[0] == GROUP_ACTION_ID_B, "reverse walks storage backwards");

        (page, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 5, 10, false);
        require(total == 2 && page.length == 0, "out of range returns an empty page with the total");
    }

    function testGetDistributionProjectsArbitraryAmounts() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID, MEMBER2_ID), _ratios(PRECISION / 2, PRECISION / 4));

        (uint256[] memory recipientIds, uint256[] memory ratios, uint256[] memory amounts, uint256 ownerAmount) =
            executor.getDistribution(address(token), GROUP_ACTION_ID, GROUP_ID, 3, SERVICE_ROUND);
        require(recipientIds.length == 2 && recipientIds[0] == MEMBER1_ID, "recipients projected");
        require(ratios[0] == PRECISION / 2 && ratios[1] == PRECISION / 4, "ratios projected");
        require(amounts[0] == 1 && amounts[1] == 0, "each item floors independently");
        require(ownerAmount == 2, "remainder belongs to the owner");

        // 100% allocation of an odd amount does not underflow.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));
        (,, amounts, ownerAmount) =
            executor.getDistribution(address(token), GROUP_ACTION_ID, GROUP_ID, 3, SERVICE_ROUND);
        require(amounts[0] == 3 && ownerAmount == 0, "full allocation keeps the whole budget");

        // No configuration: the owner keeps everything.
        (,, amounts, ownerAmount) =
            executor.getDistribution(address(token), GROUP_ACTION_ID_B, GROUP_ID, 5, SERVICE_ROUND);
        require(amounts.length == 0 && ownerAmount == 5, "unconfigured action keeps the whole budget");
    }

    function testPreMintDistributionProjectionMatchesSettlement() external {
        _prepareRecipientsScenario();
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));

        // Pre-mint projection at the mint round: the member has not settled
        // yet. Divisor 100e18, owner weight 100e18, so the owner theoretical
        // reward is 450e18. Action A slices 270e18 (MEMBER1 takes half) and
        // action B 180e18 (MEMBER2 takes a quarter).
        _atPhase(MINT_PHASE);
        (,,, uint256 projectedDistributed, uint256 projectedRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(!claimed, "projection runs before the mint");
        require(projectedDistributed == 180e18, "projected distributed equals both slices");
        require(projectedRemaining == 270e18, "projected remainder kept by the owner");

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == 450e18, "owner theoretical reward");
        require(token.balanceOf(MEMBER1) == 135e18, "first recipient paid");
        require(token.balanceOf(MEMBER2) == 45e18, "second recipient paid");
        require(token.balanceOf(GROUP_OWNER) == 270e18, "owner remainder paid");
        require(
            token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2) == projectedDistributed,
            "executed distribution equals the projection"
        );
        require(token.balanceOf(GROUP_OWNER) == projectedRemaining, "executed remainder equals the projection");
    }

    function testZeroRewardActionSkipsRecipientDistribution() external {
        _prepareRecipientsScenario();
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        // The group is listed in action B but earned nothing there, and has
        // recipients configured there anyway.
        groupAction.setGroupIds(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, _ids(GROUP_ID));
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, GROUP_ID, 0);
        groupAction.setLockedVerifierId(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 2));
        _atPhase(MINT_PHASE);

        // The projection skips the zero-reward action exactly like the payout.
        (,,, uint256 projectedDistributed, uint256 projectedRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(!claimed, "projection runs before the mint");
        require(projectedDistributed == 225e18, "projection skips the zero-reward action");
        require(projectedRemaining == 225e18, "projected remainder kept by the owner");

        // Divisor and owner weight are both 60e18: the owner theoretical reward
        // is 450e18, and every wei flows through action A.
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18 && burnAmount == 0, "owner paid on the earning action only");
        require(token.balanceOf(MEMBER1) == 225e18, "recipient of the earning action paid");
        require(token.balanceOf(MEMBER2) == 0, "zero-reward action contributes no slice");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier paid the other half");
        require(token.balanceOf(GROUP_OWNER) == 225e18, "owner keeps the remainder");
        require(token.balanceOf(address(executor)) == 0, "executor drained");
    }

    function testSettlementDistributesOwnerSlicePerSourceAction() external {
        _prepareRecipientsScenario();
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));
        _atPhase(MINT_PHASE);

        // Projections before settlement follow the same math.
        (uint256[] memory recipientIds,, uint256[] memory amounts, uint256 ownerAmount) =
            executor.rewardDistribution(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID);
        require(
            recipientIds[0] == MEMBER1_ID && amounts[0] == 135e18 && ownerAmount == 135e18, "slice split per action"
        );
        require(
            executor.rewardByRecipient(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            ) == 135e18,
            "single recipient projection"
        );
        require(
            executor.rewardByRecipient(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, GROUP_ID
            ) == 135e18,
            "owner remainder projection"
        );
        require(
            executor.rewardByRecipient(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER2_ID
            ) == 0,
            "non recipient projects zero"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 450e18 && burnAmount == 0, "owner theoretical reward");
        require(token.balanceOf(MEMBER1) == 135e18, "first recipient paid");
        require(token.balanceOf(MEMBER2) == 45e18, "second recipient paid");
        require(token.balanceOf(GROUP_OWNER) == 270e18, "owner keeps the remainder");

        (,,, uint256 ownerDistributed, uint256 ownerRemaining,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        require(ownerDistributed == 180e18 && ownerRemaining == 270e18, "recorded split matches the transfers");

        // The verifier share is paid directly and never redistributed.
        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier paid in full");
        require(token.balanceOf(VERIFIER) == 450e18, "verifier received the direct share");
        require(
            token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2) + token.balanceOf(GROUP_OWNER)
                    + token.balanceOf(VERIFIER) == SERVICE_REWARD,
            "every wei of the reward left the executor"
        );
    }

    function testRecipientConfigIsReusedAcrossServiceProposals() external {
        // Two service proposals created in the same vote round, both drawing on
        // the same source action: the configuration is keyed by the source
        // action, so one setRecipients call serves both settlements.
        _atPhase(CREATION_PHASE);
        _createServiceActionOn(address(token), address(token), SERVICE_ACTION_ID, 0, PRECISION / 2);
        _createServiceActionOn(address(token), address(token), SERVICE_ACTION_ID_B, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _joinServiceOn(SERVICE_ACTION_ID_B, GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _armServiceRewardOn(SERVICE_ACTION_ID_B, SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);

        // A single configuration under the source action.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        // The enumeration is keyed by the source action and the group, not the proposal.
        (uint256[] memory actionIds, uint256 total) =
            executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, false);
        require(total == 1 && actionIds[0] == GROUP_ACTION_ID, "one source action serves both proposals");

        _atPhase(MINT_PHASE);

        // Both proposals project the same split from that one configuration.
        (uint256[] memory idsA,, uint256[] memory amountsA, uint256 ownerA) =
            executor.rewardDistribution(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID);
        (uint256[] memory idsB,, uint256[] memory amountsB, uint256 ownerB) =
            executor.rewardDistribution(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, GROUP_ACTION_ID, GROUP_ID);
        require(idsA.length == 1 && idsA[0] == MEMBER1_ID, "first proposal sees the recipient");
        require(idsB.length == 1 && idsB[0] == MEMBER1_ID, "second proposal reuses the same recipient");
        require(amountsA[0] == 225e18 && amountsA[0] == amountsB[0], "both project the same slice");
        require(ownerA == 225e18 && ownerA == ownerB, "both project the same remainder");

        // Settling the second proposal's owner pays through the shared configuration.
        (uint256 mintAmountB, uint256 burnAmountB) = _settleServiceOn(SERVICE_ACTION_ID_B, GROUP_ID);
        require(mintAmountB == 450e18 && burnAmountB == 0, "second proposal settles its own reward");
        require(token.balanceOf(MEMBER1) == 225e18, "shared recipient paid from the second proposal");
        require(token.balanceOf(GROUP_OWNER) == 225e18, "owner keeps the shared remainder");

        (,,, uint256 ownerDistributedB, uint256 ownerRemainingB,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID_B, SERVICE_ROUND, GROUP_ID);
        require(ownerDistributedB == 225e18 && ownerRemainingB == 225e18, "recorded split matches the transfers");

        // Settling the first proposal pays through the very same configuration.
        (uint256 mintAmountA, uint256 burnAmountA) = _settleService(GROUP_ID);
        require(mintAmountA == 450e18 && burnAmountA == 0, "first proposal settles its own reward");
        require(token.balanceOf(MEMBER1) == 450e18, "shared recipient paid from both proposals");
        require(token.balanceOf(GROUP_OWNER) == 450e18, "owner keeps both remainders");

        // The two verifier shares stay in the executor; nothing else moved.
        require(
            token.balanceOf(address(executor)) + token.balanceOf(MEMBER1) + token.balanceOf(GROUP_OWNER)
                    + token.burnedTotal() == 2 * SERVICE_REWARD,
            "both rewards fully accounted for"
        );
    }

    function testDistributionFollowsTheCurrentRecipientOwner() external {
        _prepareRecipientsScenario();
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));
        _atPhase(MINT_PHASE);

        // The recipient NFT moves before settlement: the new holder is paid.
        memberNFT.setOwner(MEMBER1_ID, MEMBER2);
        _settleService(GROUP_ID);
        require(token.balanceOf(MEMBER1) == 0, "old holder not paid");
        require(token.balanceOf(MEMBER2) == 450e18, "new holder paid");
        require(token.balanceOf(GROUP_OWNER) == 0, "owner keeps nothing at full allocation");
    }

    function _prepareRecipientsScenario() internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
    }
}
