// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorEvents} from "../src/interfaces/IGroupServiceExecutor.sol";
import {GroupServiceTestBase, GroupServiceVm} from "./GroupServiceTestBase.sol";

contract GroupServiceEventsTest is GroupServiceTestBase, IGroupServiceExecutorEvents, IActionExecutorEvents {
    function testSettlementEventsReconstructAssetChanges() external {
        _prepareCappedTwoActionScenario();
        uint256 ownerBalance = token.balanceOf(GROUP_OWNER);
        _assertOwnerReward(54e18, 360e18, false);

        vm.expectEmit(true, true, true, true, address(executor));
        emit RecipientPaid({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            sourceTokenAddress: address(token),
            sourceActionId: GROUP_ACTION_ID,
            recipientId: MEMBER1_ID,
            amount: 27e18
        });
        vm.recordLogs();
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 27e18, "first recipient received the capped share");
        GroupServiceVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 2, "recipient transfer and payout event");
        require(logs[0].topics[0] == keccak256("Transfer(address,address,uint256)"), "transfer precedes payout event");
        require(logs[1].topics[0] == IGroupServiceExecutorEvents.RecipientPaid.selector, "recipient payout");

        require(_claimRecipient(GROUP_ACTION_ID_B, MEMBER2_ID) == 9e18, "second recipient received the capped share");
        _assertOwnerReward(54e18, 360e18, false);

        vm.expectEmit(true, true, true, true, address(executor));
        emit ServiceOwnerRewardBurned({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            amount: 360e18
        });

        vm.expectEmit(true, true, true, true, address(executor));
        emit MemberRewardMinted({
            tokenAddress: address(token),
            actionId: SERVICE_ACTION_ID,
            memberId: GROUP_ID,
            round: SERVICE_ROUND,
            mintAmount: 54e18,
            burnAmount: 360e18
        });
        vm.expectEmit(true, true, true, true, address(executor));
        emit ServiceRewardsDistributed({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            actionTokenAddress: address(token),
            memberId: GROUP_ID,
            verifierReward: 0,
            ownerReward: 90e18,
            ownerRemaining: 54e18
        });
        vm.recordLogs();
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        logs = vm.getRecordedLogs();
        require(logs.length == 5, "owner burn and payout events");
        require(logs[0].topics[0] == keccak256("TokenBurned(address,uint256)"), "actual burn precedes its attribution");
        require(logs[1].topics[0] == IGroupServiceExecutorEvents.ServiceOwnerRewardBurned.selector, "owner overflow");
        require(logs[2].topics[0] == keccak256("Transfer(address,address,uint256)"), "transfer precedes payout event");
        require(logs[3].topics[0] == IActionExecutorEvents.MemberRewardMinted.selector, "owner payout");
        require(logs[4].topics[0] == IGroupServiceExecutorEvents.ServiceRewardsDistributed.selector, "owner accounting");
        require(mintAmount == 54e18 && burnAmount == 360e18, "owner received the remainder and burned the overflow");
        require(token.balanceOf(GROUP_OWNER) - ownerBalance == mintAmount, "reported payout matches the owner's balance increase");
        _assertOwnerReward(54e18, 360e18, true);

        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(
            token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2) + token.balanceOf(GROUP_OWNER)
                + verifierMint + token.burnedTotal() == SERVICE_REWARD,
            "payouts and burn account for the budget"
        );
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
        require(token.burnedTotal() == 360e18, "exactly one budget overflow burned");
    }

    function _assertOwnerReward(uint256 payout, uint256 burn, bool settled) private view {
        (uint256 amount, uint256 burnAmount, bool claimed) =
            _memberAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(amount == payout && burnAmount == burn && claimed == settled, "owner query reports the personal payout");
    }

    function testVerifierSettlementEventPair() external {
        _prepareCappedTwoActionScenario();
        (uint256 ownerPaid, uint256 ownerBurned) = _settleService(GROUP_ID);
        require(ownerPaid == 54e18 && ownerBurned == 360e18, "owner can settle before the recipients");
        require(_claimRecipient(GROUP_ACTION_ID, MEMBER1_ID) == 27e18, "same recipient payout when owner goes first");
        require(token.burnedTotal() == 360e18, "recipient did not repeat the owner's burn");

        vm.expectEmit(true, true, true, true, address(executor));
        emit MemberRewardMinted({
            tokenAddress: address(token),
            actionId: SERVICE_ACTION_ID,
            memberId: VERIFIER_ID,
            round: SERVICE_ROUND,
            mintAmount: 450e18,
            burnAmount: 0
        });
        (uint256 mintAmount, uint256 burnAmount) = _settleService(VERIFIER_ID);
        require(mintAmount == 450e18 && burnAmount == 0, "verifier paid the whole verifier share");

        (uint256 verifierReward, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, VERIFIER_ID);
        require(claimed, "verifier claimed");
        require(verifierReward == 450e18 && ownerReward == 0, "verifier roles");
        require(ownerDistributed == 0 && ownerRemaining == 0, "no owner share to split");
    }

    function testExitEvent() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _atPhase(VERIFY_PHASE);

        vm.expectEmit(true, true, true, true, address(executor));
        emit ServiceExited({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            memberId: GROUP_ID,
            round: VERIFY_PHASE - 1
        });
        _exitService(GROUP_ID);
    }

    function testServiceActionCreatedEmitsFromTheExecutor() external {
        _atPhase(CREATION_PHASE);
        vm.recordLogs();
        // A child action token keeps `tokenAddress` and `actionTokenAddress` distinguishable.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 2e18, PRECISION / 2, PRECISION / 5);
        GroupServiceVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single creation event");
        require(logs[0].emitter == address(executor), "emitter is the executor");
        require(
            logs[0].topics[0] == keccak256("ServiceActionCreated(address,uint256,address,uint256,uint256,uint256)"),
            "creation signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(SERVICE_ACTION_ID), "action topic");
        (address actionTokenAddress, uint256 govRatioMultiplier, uint256 publicVerifierRatio, uint256 providerRatio) =
            abi.decode(logs[0].data, (address, uint256, uint256, uint256));
        require(actionTokenAddress == address(childToken), "action token");
        require(govRatioMultiplier == 2e18, "gov ratio multiplier");
        require(publicVerifierRatio == PRECISION / 2, "public verifier ratio");
        require(providerRatio == PRECISION / 5, "fixed Provider ratio");
    }

    function _prepareCappedTwoActionScenario() internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyVerifier(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        stake.setTotalGovVotes(address(token), SERVICE_ROUND, 100e18);
        stake.setGovVotes(address(token), SERVICE_ROUND, GROUP_ID, 10e18);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));
        _atPhase(MINT_PHASE);
    }
}
