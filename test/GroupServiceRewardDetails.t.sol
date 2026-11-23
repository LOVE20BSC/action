// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
import {MemberRewardSummary, ServiceRewardDetails} from "../src/interfaces/IGroupServiceExecutor.sol";

contract GroupServiceRewardDetailsTest is GroupServiceTestBase {
    function testZeroProviderRatioKeepsMemberQuoteAndMintWithinGasBudget() external {
        uint256 sourceActionCount = 32;
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0);
        for (uint256 i; i < sourceActionCount; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), MEMBER1_ID);
            groupAction.setMarketScores(address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50);
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 100 * sourceActionCount);
        _armServiceReward(1000);
        _atPhase(MINT_PHASE);

        (, uint256 total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 0, false);
        require(total == sourceActionCount, "source Provider candidates remain discoverable");

        uint256 gasBefore = gasleft();
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        uint256 quoteGas = gasBefore - gasleft();
        require(pending == 500 && minted == 0 && status == MemberRewardStatus.Pending, "verifier reward quoted");

        vm.prank(MEMBER1);
        gasBefore = gasleft();
        uint256 paid = executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID);
        uint256 mintGas = gasBefore - gasleft();
        require(paid == 500, "verifier reward paid");
        require(quoteGas < 100_000, "zero-Provider-ratio quote exceeds gas budget");
        require(mintGas < 350_000, "zero-Provider-ratio mint exceeds gas budget");
    }

    function testMemberRewardDetailsTrackAllFourRolesAcrossPartialAndCombinedMint() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.4e18);
        _setGroupLedger(
            GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID),
            _amounts(100, 100),
            GROUP_ID
        );
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_OWNER_B_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(300);

        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_OWNER_B_ID, 100, GROUP_ID, 50
        );
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_OWNER_B_ID, GROUP_ACTION_ID_B, _ids(GROUP_ID), _ratios(0.2e18));
        _atPhase(MINT_PHASE);

        _assertDetails(
            MemberRewardSummary(100, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(50, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(6, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(10, 0, MemberRewardStatus.Pending),
            50
        );

        vm.prank(GROUP_OWNER);
        require(
            executor.mintProviderReward(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID_B, GROUP_OWNER_B_ID, GROUP_ID
            ) == 10,
            "provider paid first"
        );
        _assertDetails(
            MemberRewardSummary(100, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(50, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(6, 0, MemberRewardStatus.Pending),
            MemberRewardSummary(0, 10, MemberRewardStatus.Settled),
            50
        );

        vm.prank(GROUP_OWNER);
        require(
            executor.mintMemberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 156,
            "remaining roles paid together"
        );
        _assertDetails(
            MemberRewardSummary(0, 100, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 50, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 6, MemberRewardStatus.Settled),
            MemberRewardSummary(0, 10, MemberRewardStatus.Settled),
            50
        );
        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.memberReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(pending == 0 && minted == 166 && status == MemberRewardStatus.Settled, "member total settled");
    }

    function _assertDetails(
        MemberRewardSummary memory verifier,
        MemberRewardSummary memory owner,
        MemberRewardSummary memory recipient,
        MemberRewardSummary memory provider,
        uint256 expectedOwnerBudget
    ) private view {
        ServiceRewardDetails memory details =
            executor.serviceRewardByMemberId(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        _assertSummary(details.verifier, verifier);
        _assertSummary(details.owner, owner);
        _assertSummary(details.recipient, recipient);
        _assertSummary(details.provider, provider);
        require(details.ownerBudget == expectedOwnerBudget, "owner budget separated from self reward");
    }

    function _assertSummary(MemberRewardSummary memory actual, MemberRewardSummary memory expected) private pure {
        require(
            actual.pendingAmount == expected.pendingAmount && actual.mintedAmount == expected.mintedAmount
                && actual.status == expected.status,
            "role summary"
        );
    }
}
