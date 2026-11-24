// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "@forge-std/Vm.sol";
import {GroupServiceTestBase} from "../GroupServiceTestBase.sol";

contract GroupServiceRoleClaimGasTest is GroupServiceTestBase {
    Vm private constant forgeVm = Vm(address(vm));
    uint256 private constant FIRST_SOURCE = 1000;
    uint256 private constant UNREWARDED_SOURCE = 2000;
    uint256 private constant FIRST_UNRELATED_SOURCE = 3000;

    event log_named_uint(
        string name,
        uint256 value
    );

    function testOnePayableSource() external {
        _prepare(1, 0, 0);
        _measureClaims();
    }

    function testThirtyTwoGroupsWithoutPayableSources() external {
        _prepare(1, 32, 0);
        require(_measureClaims() < 2_000_000, "combined claim fits budget with unrewarded candidates");
    }

    function testSixtyFourUnrelatedActionsInPayableGroup() external {
        _prepare(1, 0, 64);
        _measureClaims();
    }

    function testSixteenPayableSources() external {
        _prepare(16, 0, 0);
        _measureClaims();
    }

    function testFifteenPayableSourcesAfterFirstSourceMinted() external {
        _prepare(16, 0, 0);
        _mintFirstSource();
        _measureClaims();
    }

    function _prepare(uint256 payableSources, uint256 unrewardedGroups, uint256 unrelatedActions) private {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);

        for (uint256 i = 0; i < payableSources; ++i) {
            uint256 sourceActionId = FIRST_SOURCE + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setJoinTokenAddress(address(token), sourceActionId, address(token));
            _addCandidate(sourceActionId, GROUP_ID);
        }
        for (uint256 i = 0; i < unrelatedActions; ++i) {
            _setGroupLedger(FIRST_UNRELATED_SOURCE + i, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        }
        if (unrewardedGroups != 0) _addUnrewardedGroups(unrewardedGroups);

        _atPhase(MINT_PHASE);
    }

    function _addUnrewardedGroups(uint256 count) private {
        uint256[] memory groupIds = new uint256[](count);
        uint256[] memory scores = new uint256[](count);
        groupAction.setJoinTokenAddress(address(token), UNREWARDED_SOURCE, address(token));
        for (uint256 i = 0; i < count; ++i) {
            uint256 groupId = 100 + i;
            groupIds[i] = groupId;
            scores[i] = 100;
            memberNFT.setOwner(groupId, GROUP_OWNER);
            _addCandidate(UNREWARDED_SOURCE, groupId);
        }
        _setGroupLedger(UNREWARDED_SOURCE, groupIds, scores, VERIFIER_ID);
        groupAction.setActionReward(address(token), SERVICE_ROUND, UNREWARDED_SOURCE, 0);
        _setGroupLedger(FIRST_UNRELATED_SOURCE, groupIds, scores, VERIFIER_ID);
    }

    function _addCandidate(uint256 sourceActionId, uint256 groupId) private {
        groupAction.setMarketScores(address(token), SERVICE_ROUND, sourceActionId, groupId, 50, MEMBER1_ID, 50);
        vm.prank(GROUP_OWNER);
        executor.setRecipients(
            address(token), sourceActionId, groupId, _ids(MEMBER1_ID), _ratios(0.5e18), new string[](1)
        );
    }

    function _mintFirstSource() private {
        vm.prank(MEMBER1);
        require(executor.mintProviderRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, FIRST_SOURCE, GROUP_ID, MEMBER1_ID
        ) != 0, "positive first provider share");
        vm.prank(MEMBER1);
        require(executor.mintRecipientRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, FIRST_SOURCE, GROUP_ID, MEMBER1_ID
        ) != 0, "positive first recipient share");
    }

    function _measureClaims() private returns (uint256 combinedGas) {
        (uint256 provider,,) = executor.providerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        (uint256 recipient,,) = executor.recipientReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        (uint256 combined,,) = executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        require(provider != 0 && recipient != 0 && combined == provider + recipient, "positive expected shares");

        uint256 snapshot = forgeVm.snapshotState();
        _measureClaim(executor.mintProviderReward, provider, "Provider claim gas");
        require(forgeVm.revertToState(snapshot), "reset after provider claim");
        _measureClaim(executor.mintRecipientReward, recipient, "Recipient claim gas");
        require(forgeVm.revertToStateAndDelete(snapshot), "reset after recipient claim");
        combinedGas = _measureClaim(executor.mintMemberReward, combined, "Combined claim gas");
    }

    function _measureClaim(
        function(address, uint256, uint256, uint256) external returns (uint256) claim,
        uint256 expected,
        string memory label
    ) private returns (uint256 gasUsed) {
        uint256 balance = token.balanceOf(MEMBER1);
        forgeVm.cool(address(executor));
        forgeVm.cool(address(actionTarget));
        forgeVm.cool(address(groupAction));
        forgeVm.cool(address(token));
        forgeVm.cool(address(phase));
        forgeVm.cool(address(memberNFT));
        vm.prank(MEMBER1);
        uint256 gasBefore = gasleft();
        uint256 paid = claim(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint(label, gasUsed);
        require(paid == expected && token.balanceOf(MEMBER1) - balance == paid, "claim pays the quoted shares");
        require(actionTarget.mintRewardCalls() == 1, "service budget minted once");
    }
}
