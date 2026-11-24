// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupRecipientsErrors, IGroupRecipientsEvents} from "../src/interfaces/IGroupRecipients.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {GroupServiceStorage} from "../src/GroupServiceStorage.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockGroupServiceMemberNFT} from "./mocks/GroupServiceMocks.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceRecipientsTest is GroupServiceTestBase, IGroupRecipientsEvents {
    function testSetRecipientsStoresTheVerifyRoundAndEmits() external {
        _prepareRecipientsScenario();

        string[] memory remarks = new string[](1);
        remarks[0] = "";
        vm.expectEmit(true, true, true, true, address(executor));
        emit RecipientsChanged({
            sourceTokenAddress: address(token),
            sourceActionId: GROUP_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            recipientIds: _ids(MEMBER1_ID),
            ratios: _ratios(PRECISION / 2),
            remarks: remarks,
            prevRecipientIds: new uint256[](0),
            prevRatios: new uint256[](0),
            prevRemarks: new string[](0)
        });
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory storedRemarks) =
            executor.recipients(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID);
        require(recipientIds.length == 1 && recipientIds[0] == MEMBER1_ID, "recipient stored");
        require(ratios[0] == PRECISION / 2, "ratio stored");
        require(storedRemarks.length == 1 && keccak256(bytes(storedRemarks[0])) == keccak256(""), "remark stored");

        uint256[] memory actionIds;
        (actionIds,) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, false);
        require(actionIds.length == 1 && actionIds[0] == GROUP_ACTION_ID, "action registered");
    }

    function testSetRecipientsCarriesThePreviousTable() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        string[] memory remarks = new string[](1);
        remarks[0] = "second";
        vm.expectEmit(true, true, true, true, address(executor));
        emit RecipientsChanged({
            sourceTokenAddress: address(token),
            sourceActionId: GROUP_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            recipientIds: _ids(MEMBER2_ID),
            ratios: _ratios(PRECISION / 4),
            remarks: remarks,
            prevRecipientIds: _ids(MEMBER1_ID),
            prevRatios: _ratios(PRECISION / 2),
            prevRemarks: new string[](1)
        });
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(PRECISION / 4), remarks);
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

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.DuplicateMemberId.selector, MEMBER1_ID));
        executor.setRecipients(
            address(token), unknownActionId, GROUP_ID, _ids(MEMBER1_ID, MEMBER1_ID), _ratios(1, 1), new string[](2)
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
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testSetRecipientsValidationChain() external {
        _prepareRecipientsScenario();

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.RecipientArrayLengthMismatch.selector, 1, 2, 1));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION, PRECISION), new string[](1)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.RecipientArrayLengthMismatch.selector, 1, 1, 0));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](0)
        );

        uint256[] memory tooMany = new uint256[](MAX_RECIPIENTS_PER_ACTION + 1);
        uint256[] memory unitRatios = new uint256[](MAX_RECIPIENTS_PER_ACTION + 1);
        string[] memory unitRemarks = new string[](MAX_RECIPIENTS_PER_ACTION + 1);
        for (uint256 i = 0; i < unitRatios.length; i++) {
            tooMany[i] = MEMBER1_ID + i;
            unitRatios[i] = 1;
            unitRemarks[i] = "";
        }
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.TooManyRecipients.selector, MAX_RECIPIENTS_PER_ACTION + 1, MAX_RECIPIENTS_PER_ACTION));
        executor.setRecipients(address(token), GROUP_ACTION_ID, GROUP_ID, tooMany, unitRatios, unitRemarks);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupRecipientsErrors.ZeroRecipientRatio.selector, MEMBER1_ID));
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
                IERC721Errors.ERC721NonexistentToken.selector, MEMBER1_ID + MAX_RECIPIENTS_PER_ACTION + 5
            )
        );
        executor.setRecipients(
            address(token),
            GROUP_ACTION_ID,
            GROUP_ID,
            _ids(MEMBER1_ID + MAX_RECIPIENTS_PER_ACTION + 5),
            _ratios(PRECISION),
            new string[](1)
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupRecipientsErrors.RemarkTooLong.selector, 0, 257, 256)
        );
        string[] memory longRemarks = new string[](1);
        longRemarks[0] = string(new bytes(257));
        executor.setRecipients(
            address(token), GROUP_ACTION_ID, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), longRemarks
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
            executor.recipients(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID);
        require(recipientIds[0] == MEMBER1_ID, "full precision configuration accepted");
    }

    function testRecipientsLazyInheritanceAndSameRoundOverwrite() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));

        // A later round inherits the last configuration at or before it.
        (uint256[] memory recipientIds, uint256[] memory ratios,) =
            executor.recipients(address(token), SERVICE_ROUND + 3, GROUP_ACTION_ID, GROUP_ID);
        require(recipientIds[0] == MEMBER1_ID && ratios[0] == PRECISION / 2, "inherited by a later round");

        // Nothing is recorded before the first configuration.
        (recipientIds,,) = executor.recipients(address(token), SERVICE_ROUND - 1, GROUP_ACTION_ID, GROUP_ID);
        require(recipientIds.length == 0, "no configuration before");

        // A same-round update overwrites that round's snapshot.
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(PRECISION));
        (recipientIds, ratios,) = executor.recipients(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID);
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
            executor.recipients(address(token), VERIFY_PHASE + 1, GROUP_ACTION_ID, GROUP_ID);
        require(recipientIds.length == 0, "cleared configuration is empty");

        // The earlier round keeps its snapshot.
        (actionIds, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 10, false);
        require(total == 1 && actionIds[0] == GROUP_ACTION_ID, "history survives the later clear");
        (recipientIds,,) = executor.recipients(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID);
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

    function testRecipientRewardsRoundDownIndependently() external {
        _prepareRecipientsScenario();
        _armServiceReward(6);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID, MEMBER2_ID), _ratios(PRECISION / 2, PRECISION / 4));
        _atPhase(MINT_PHASE);

        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 1, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER2_ID, 0, false);
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 1, "recipient receives the rounded amount");
        (uint256 ownerAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(ownerAmount == 2 && burnAmount == 0, "the owner receives the remainder");
    }

    function testPreMintDistributionProjectionMatchesSettlement() external {
        _prepareRecipientsScenario();
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));

        // Pre-mint projection at the mint round: the member has not settled
        // yet. Divisor 100e18, owner weight 100e18, so the owner theoretical
        // reward is 450e18. Action A slices 270e18 (MEMBER1 takes half) and
        // action B 180e18 (MEMBER2 takes a quarter).
        _atPhase(MINT_PHASE);
        (,,, uint256 projectedReserved, uint256 projectedRemaining, bool claimed) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(!claimed, "projection runs before the mint");
        require(projectedReserved == 180e18, "reserved rewards equal both shares");
        require(projectedRemaining == 270e18, "projected remainder kept by the owner");

        (uint256 mintAmount,) = _settleService(GROUP_ID);
        require(mintAmount == 270e18, "owner receives only the projected remainder");
        require(token.balanceOf(MEMBER1) == 0 && token.balanceOf(MEMBER2) == 0, "recipients can claim separately");
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);
        _claimRecipient(GROUP_ACTION_ID_B, MEMBER2_ID);
        require(token.balanceOf(MEMBER1) == 135e18, "first recipient paid");
        require(token.balanceOf(MEMBER2) == 45e18, "second recipient paid");
        require(token.balanceOf(GROUP_OWNER) == 270e18, "owner remainder paid");
        require(
            token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2) == projectedReserved,
            "executed distribution equals the projection"
        );
        require(token.balanceOf(GROUP_OWNER) == projectedRemaining, "executed remainder equals the projection");
    }

    function testZeroRewardActionSkipsRecipientDistribution() external {
        _prepareRecipientsScenario();
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        // The group is listed in action B but earned nothing there, and has
        // recipients configured there anyway.
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(0), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 2));
        _atPhase(MINT_PHASE);

        // The projection skips the zero-reward action exactly like the payout.
        (,,, uint256 projectedDistributed, uint256 projectedRemaining, bool claimed) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(!claimed, "projection runs before the mint");
        require(projectedDistributed == 225e18, "projection skips the zero-reward action");
        require(projectedRemaining == 225e18, "projected remainder kept by the owner");

        // Divisor and owner weight are both 60e18: the owner theoretical reward
        // is 450e18, and every wei flows through action A.
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 225e18 && burnAmount == 0, "owner paid on the earning action only");
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupServiceExecutorErrors.ZeroRecipientReward.selector, GROUP_ACTION_ID_B, GROUP_ID, MEMBER2_ID)
        );
        _claimRecipient(GROUP_ACTION_ID_B, MEMBER2_ID);
        require(token.balanceOf(MEMBER1) == 225e18, "recipient of the earning action paid");
        require(token.balanceOf(MEMBER2) == 0, "zero-reward action contributes no slice");

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(verifierMint == 450e18, "verifier paid the other half");
        require(token.balanceOf(GROUP_OWNER) == 225e18, "owner keeps the remainder");
        require(token.balanceOf(address(executor)) == 0, "executor drained");
    }

    function testSettlementDistributesOwnerSlicePerSourceAction() external {
        _prepareRecipientsScenario();
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));
        _atPhase(MINT_PHASE);

        // Projections before settlement follow the same math.
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 135e18, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER2_ID, 0, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID_B, MEMBER2_ID, 45e18, false);

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == 270e18 && burnAmount == 0, "owner receives the remainder");
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);
        _claimRecipient(GROUP_ACTION_ID_B, MEMBER2_ID);
        require(token.balanceOf(MEMBER1) == 135e18, "first recipient paid");
        require(token.balanceOf(MEMBER2) == 45e18, "second recipient paid");
        require(token.balanceOf(GROUP_OWNER) == 270e18, "owner keeps the remainder");

        (,,, uint256 ownerDistributed, uint256 ownerRemaining,) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
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

        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 225e18, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID_B, GROUP_ACTION_ID, MEMBER1_ID, 225e18, false);
        (uint256 ownerA,,) = executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        (uint256 ownerB,,) = executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, GROUP_ID);
        require(ownerA == 225e18 && ownerA == ownerB, "both proposals quote the same owner amount");

        // Each proposal uses the shared configuration and has a separate claim.
        (uint256 mintAmountB, uint256 burnAmountB) = _settleServiceOn(SERVICE_ACTION_ID_B, GROUP_ID);
        require(mintAmountB == 225e18 && burnAmountB == 0, "second proposal settles the owner remainder");
        _claimRecipientOn(SERVICE_ACTION_ID_B, GROUP_ACTION_ID, MEMBER1_ID);
        require(token.balanceOf(MEMBER1) == 225e18, "shared recipient paid from the second proposal");
        require(token.balanceOf(GROUP_OWNER) == 225e18, "owner keeps the shared remainder");
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.RecipientRewardAlreadyMinted.selector,
                address(token), SERVICE_ACTION_ID_B, SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
            )
        );
        _claimRecipientOn(SERVICE_ACTION_ID_B, GROUP_ACTION_ID, MEMBER1_ID);

        (,,, uint256 ownerDistributedB, uint256 ownerRemainingB,) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID_B, GROUP_ID);
        require(ownerDistributedB == 225e18 && ownerRemainingB == 225e18, "recorded split matches the transfers");

        _assertRecipientRewardOn(SERVICE_ACTION_ID_B, GROUP_ACTION_ID, MEMBER1_ID, 225e18, true);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 225e18, false);
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);
        (uint256 mintAmountA, uint256 burnAmountA) = _settleService(GROUP_ID);
        require(mintAmountA == 225e18 && burnAmountA == 0, "first proposal settles the owner remainder");
        require(token.balanceOf(MEMBER1) == 450e18, "shared recipient paid from both proposals");
        require(token.balanceOf(GROUP_OWNER) == 450e18, "owner keeps both remainders");

        // The two verifier shares stay in the executor; nothing else moved.
        require(
            token.balanceOf(address(executor)) + token.balanceOf(MEMBER1) + token.balanceOf(GROUP_OWNER)
                    + token.burnedTotal() == 2 * SERVICE_REWARD,
            "both rewards fully accounted for"
        );
    }

    function testHistoricalRecipientRewardFollowsTheCurrentNFTHolder() external {
        _prepareRecipientsScenario();
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION));
        _atPhase(MINT_PHASE + 10);

        memberNFT.setOwner(MEMBER1_ID, MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);

        vm.prank(MEMBER2);
        uint256 paid = executor.mintRecipientRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, MEMBER1_ID
        );
        require(paid == 450e18, "historical entitlement paid");
        require(token.balanceOf(MEMBER1) == 0, "old holder not paid");
        require(token.balanceOf(MEMBER2) == 450e18, "new holder paid");
        require(token.balanceOf(GROUP_OWNER) == 0, "owner keeps nothing at full allocation");
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 450e18, true);
    }

    function testRecipientCannotClaimBeforeTheMintWindow() external {
        _prepareRecipientsScenario();
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, SERVICE_ROUND, SERVICE_ROUND - 1)
        );
        _claimRecipient(GROUP_ACTION_ID, MEMBER1_ID);

        _atPhase(MINT_PHASE);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER1_ID, 225e18, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, MEMBER2_ID, 0, false);
        _assertRecipientRewardOn(SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, 0, false);
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 225e18, "share becomes payable in the mint window");
    }

    function testRecipientCanMintWhenNeitherIdentityRegisteredForService() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _atPhase(MINT_PHASE);

        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 225e18, "unregistered recipient mints");
        require(token.balanceOf(MEMBER1) == 225e18, "unregistered recipient paid");
    }

    function testRecipientActionsLimitRejectsTheActionOverTheLimit() external {
        _prepareRecipientsScenario();
        _fillRecipientActions(GROUP_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);

        (, uint256 total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "set filled to the limit");

        uint256 overflowActionId = GROUP_ACTION_ID + GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;
        groupAction.setJoinTokenAddress(address(token), overflowActionId, address(token));

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupRecipientsErrors.RecipientActionsLimitExceeded.selector,
                address(token),
                GROUP_ID,
                GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP,
                GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP
            )
        );
        executor.setRecipients(
            address(token), overflowActionId, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testRecipientActionsLimitKeepsExistingUpdatesAndClearsUsable() external {
        _prepareRecipientsScenario();
        _fillRecipientActions(GROUP_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);

        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(PRECISION / 2));

        (, uint256 total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "updating an existing action adds no slot");

        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, new uint256[](0), new uint256[](0));

        (, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP - 1, "clearing an existing action frees its slot");

        uint256 replacementActionId = GROUP_ACTION_ID + GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;
        groupAction.setJoinTokenAddress(address(token), replacementActionId, address(token));
        _setRecipients(GROUP_ID, replacementActionId, _ids(MEMBER1_ID), _ratios(PRECISION));

        (, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "freed slot accepts a new action");
    }

    function testRecipientActionsLimitIsScopedToEachGroup() external {
        _prepareRecipientsScenario();
        _fillRecipientActions(GROUP_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);
        _fillRecipientActions(GROUP_OWNER_B_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);

        (, uint256 total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "group A is full");
        (, total) = executor.actionIdsWithRecipients(address(token), GROUP_OWNER_B_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "group B has its own full budget");
    }

    function testRecipientActionsLimitSurvivesTheVerifyRound() external {
        _prepareRecipientsScenario();
        _fillRecipientActions(GROUP_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);

        // Cross into the next verify round: the earlier configurations are inherited, not reset.
        _atPhase(MINT_PHASE);
        (, uint256 total) =
            executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND + 1, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "previous rounds remain registered");

        uint256 overflowActionId = GROUP_ACTION_ID + GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;
        groupAction.setJoinTokenAddress(address(token), overflowActionId, address(token));

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupRecipientsErrors.RecipientActionsLimitExceeded.selector,
                address(token),
                GROUP_ID,
                GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP,
                GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP
            )
        );
        executor.setRecipients(
            address(token), overflowActionId, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );
    }

    function testRecipientActionsLimitIsScopedToEachSourceToken() external {
        _prepareRecipientsScenario();
        _fillRecipientActions(GROUP_ID, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, GROUP_ACTION_ID);

        (, uint256 total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "primary token is full");

        uint256 siblingActionId = GROUP_ACTION_ID + GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;
        groupAction.setJoinTokenAddress(address(childToken), siblingActionId, address(childToken));

        vm.prank(GROUP_OWNER);
        executor.setRecipients(
            address(childToken), siblingActionId, GROUP_ID, _ids(MEMBER1_ID), _ratios(PRECISION), new string[](1)
        );

        (, total) = executor.actionIdsWithRecipients(address(childToken), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == 1, "sibling token has its own quota");
        (, total) = executor.actionIdsWithRecipients(address(token), GROUP_ID, SERVICE_ROUND, 0, 0, false);
        require(total == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP, "primary token keeps its full set");
    }

    function _assertRecipientRewardOn(
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 recipientId,
        uint256 expectedAmount,
        bool expectedMinted
    ) private view {
        (uint256 amount, bool isMinted) = executor.recipientRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, serviceActionId, sourceActionId, GROUP_ID, recipientId
        );
        require(amount == expectedAmount && isMinted == expectedMinted, "recipient amount and state match");
    }

    function _fillRecipientActions(uint256 groupId, uint256 count, uint256 firstActionId) internal {
        for (uint256 i; i < count; ++i) {
            uint256 actionId = firstActionId + i;
            groupAction.setJoinTokenAddress(address(token), actionId, address(token));
            _setRecipients(groupId, actionId, _ids(MEMBER1_ID), _ratios(PRECISION));
        }
    }

    function _prepareRecipientsScenario() internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
    }

    /// 边界成功值：上限个收款人 + 每条 256 字节备注，恰好等于上限时接受。
    function testSetRecipientsAcceptsFullTableAndMaxRemarks() external {
        _prepareRecipientsScenario();

        uint256 count = MAX_RECIPIENTS_PER_ACTION;
        uint256[] memory ids = new uint256[](count);
        uint256[] memory ratios = new uint256[](count);
        string[] memory remarks = new string[](count);
        uint256 id = 100;
        for (uint256 i; i < count; ++i) {
            ids[i] = id++;
            memberNFT.setOwner(ids[i], address(uint160(0x2000 + i)));
            ratios[i] = PRECISION / count;
            remarks[i] = _repeat("R", 256);
        }

        _setRecipients(GROUP_ID, GROUP_ACTION_ID, ids, ratios, remarks);

        (uint256[] memory storedIds,, string[] memory storedRemarks) =
            executor.recipients(address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID);
        require(storedIds.length == count, "full recipient table stored");
        require(bytes(storedRemarks[count - 1]).length == 256, "max remark stored");
    }

    function _repeat(bytes1 char, uint256 count) private pure returns (string memory result) {
        bytes memory out = new bytes(count);
        for (uint256 i; i < count; ++i) {
            out[i] = char;
        }
        result = string(out);
    }

    function testHugeRatiosRevertWithDistributionOverflow() external {
        _prepareRecipientsScenario();

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupRecipientsErrors.DistributionOverflow.selector, type(uint256).max, PRECISION
            )
        );
        executor.setRecipients(
            address(token),
            GROUP_ACTION_ID,
            GROUP_ID,
            _ids(MEMBER1_ID, MEMBER2_ID),
            _ratios(type(uint256).max, 1),
            new string[](2)
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
    }
}
