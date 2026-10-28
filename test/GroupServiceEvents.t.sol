// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorEvents} from "../src/interfaces/IGroupServiceExecutor.sol";
import {GroupServiceTestBase, GroupServiceVm} from "./GroupServiceTestBase.sol";

contract GroupServiceEventsTest is GroupServiceTestBase, IGroupServiceExecutorEvents, IActionExecutorEvents {
    function testSettlementEventsReconstructAssetChanges() external {
        _prepareCappedTwoActionScenario();

        vm.recordLogs();
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        GroupServiceVm.Log[] memory logs = vm.getRecordedLogs();

        // Two recipient transfers, then the paired settlement events.
        GroupServiceVm.Log[] memory transfers = _logsWithTopic(
            logs, bytes32(keccak256("RecipientPaid(address,uint256,uint256,uint256,address,uint256,uint256,uint256)"))
        );
        GroupServiceVm.Log[] memory mintLogs = _logsWithTopic(
            logs, bytes32(keccak256("MemberRewardMinted(address,uint256,uint256,uint256,uint256,uint256)"))
        );
        GroupServiceVm.Log[] memory splitLogs = _logsWithTopic(
            logs,
            bytes32(
                keccak256(
                    "ServiceRewardsDistributed(address,uint256,uint256,address,uint256,uint256,uint256,uint256,uint256,uint256)"
                )
            )
        );
        _assertRecipientTransfers(transfers, address(token));
        require(transfers[0].emitter == address(executor), "recipient event emitted by the executor");
        require(mintLogs.length == 1 && splitLogs.length == 1, "one settlement event pair");
        require(_indexOf(logs, mintLogs[0]) < _indexOf(logs, splitLogs[0]), "base event precedes the role split");

        (, uint256 loggedMintAmount, uint256 loggedBurnAmount) =
            abi.decode(mintLogs[0].data, (uint256, uint256, uint256));
        require(loggedMintAmount == mintAmount && loggedBurnAmount == burnAmount, "mint event matches the return");
        // The event carries the member id in the data, after the round.
        require(splitLogs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "role split service token topic");
        require(splitLogs[0].topics[2] == bytes32(SERVICE_ACTION_ID), "role split action topic");
        require(splitLogs[0].topics[3] == bytes32(uint256(uint160(address(token)))), "role split action token topic");

        uint256 ownerBurned;
        uint256 ownerDistributed;
        uint256 ownerRemaining;
        uint256 ownerReward;
        uint256 verifierReward;
        (verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining) =
            _decodeOwnerSplit(splitLogs[0].data);
        require(verifierReward == 0, "owner holds no verifier share");
        require(ownerReward == 90e18, "owner reward capped by the gov ratio");
        require(ownerBurned == 360e18, "overflow burned");
        require(ownerDistributed == 36e18, "distributed to recipients");
        require(ownerRemaining == 54e18, "remainder kept by the owner");

        // The pair invariant: the base mint amount aggregates both roles.
        require(mintAmount == verifierReward + ownerReward, "mint amount aggregates the roles");
        require(burnAmount == ownerBurned, "burn amount is the owner overflow");

        // Full asset reconstruction from the event stream plus the token moves.
        (uint256 verifierMint,) = _settleService(VERIFIER_ID);
        require(
            27e18 + 9e18 + ownerRemaining + verifierMint + ownerBurned == SERVICE_REWARD,
            "transfers plus burn reconstruct the reward"
        );
        require(token.balanceOf(address(executor)) == 0, "executor emptied");
        require(token.burnedTotal() == 360e18, "burned ledger");
    }

    function _logsWithTopic(GroupServiceVm.Log[] memory logs, bytes32 topic)
        internal
        pure
        returns (GroupServiceVm.Log[] memory matches)
    {
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                count++;
            }
        }
        matches = new GroupServiceVm.Log[](count);
        uint256 index;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                matches[index] = logs[i];
                index++;
            }
        }
    }

    function _indexOf(GroupServiceVm.Log[] memory logs, GroupServiceVm.Log memory log) internal pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == log.topics[0] && logs[i].emitter == log.emitter) {
                return i;
            }
        }
        revert("log not found");
    }

    function _assertRecipientTransfers(GroupServiceVm.Log[] memory logs, address expectedSourceToken)
        internal
        pure
    {
        require(logs.length == 2, "one event per recipient transfer");
        require(logs[0].topics[3] == bytes32(uint256(GROUP_ID)), "recipient event group topic");

        (uint256 round, address sourceTokenAddress, uint256 sourceActionId, uint256 recipientId, uint256 amount) =
            abi.decode(logs[0].data, (uint256, address, uint256, uint256, uint256));
        require(sourceTokenAddress == expectedSourceToken, "first transfer source token");
        require(round == SERVICE_ROUND && sourceActionId == GROUP_ACTION_ID, "first transfer source");
        require(recipientId == MEMBER1_ID && amount == 27e18, "first transfer amount");

        address sourceTokenAddressB;
        (, sourceTokenAddressB, sourceActionId, recipientId, amount) =
            abi.decode(logs[1].data, (uint256, address, uint256, uint256, uint256));
        require(sourceTokenAddressB == expectedSourceToken, "second transfer source token");
        require(sourceActionId == GROUP_ACTION_ID_B && recipientId == MEMBER2_ID, "second transfer source");
        require(amount == 9e18, "second transfer amount");
    }

    function _decodeOwnerSplit(bytes memory data)
        internal
        pure
        returns (
            uint256 verifierReward,
            uint256 ownerReward,
            uint256 ownerBurned,
            uint256 ownerDistributed,
            uint256 ownerRemaining
        )
    {
        // (round, memberId, verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining)
        uint256 round;
        uint256 memberId;
        (round, memberId, verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        require(round == SERVICE_ROUND, "split event round");
        require(memberId == GROUP_ID, "split event member");
    }

    function testVerifierSettlementEventPair() external {
        _prepareCappedTwoActionScenario();
        _settleService(GROUP_ID);

        vm.expectEmit(true, true, true, true);
        emit MemberRewardMinted(address(token), SERVICE_ACTION_ID, VERIFIER_ID, SERVICE_ROUND, 450e18, 0);
        (uint256 mintAmount, uint256 burnAmount) = _settleService(VERIFIER_ID);
        require(mintAmount == 450e18 && burnAmount == 0, "verifier paid the whole verifier share");

        (uint256 verifierReward, uint256 ownerReward,, uint256 ownerDistributed, uint256 ownerRemaining, bool claimed) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, VERIFIER_ID);
        require(claimed, "verifier claimed");
        require(verifierReward == 450e18 && ownerReward == 0, "verifier roles");
        require(ownerDistributed == 0 && ownerRemaining == 0, "no owner share to split");
    }

    function testExitEvent() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _atPhase(VERIFY_PHASE);

        vm.expectEmit(true, true, true, true);
        emit ServiceExited(address(token), SERVICE_ACTION_ID, GROUP_ID, VERIFY_PHASE - 1);
        _exitService(GROUP_ID);
    }

    function testServiceActionCreatedEmitsFromTheExecutor() external {
        _atPhase(CREATION_PHASE);
        vm.recordLogs();
        // A child action token keeps `tokenAddress` and `actionTokenAddress` distinguishable.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 2e18, PRECISION / 2);
        GroupServiceVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single creation event");
        require(logs[0].emitter == address(executor), "emitter is the executor");
        require(
            logs[0].topics[0] == keccak256("ServiceActionCreated(address,uint256,address,uint256,uint256)"),
            "creation signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(SERVICE_ACTION_ID), "action topic");
        (address actionTokenAddress, uint256 govRatioMultiplier, uint256 ratioForPublicVerifier) =
            abi.decode(logs[0].data, (address, uint256, uint256));
        require(actionTokenAddress == address(childToken), "action token");
        require(govRatioMultiplier == 2e18, "gov ratio multiplier");
        require(ratioForPublicVerifier == PRECISION / 2, "public verifier ratio");
    }

    function _prepareCappedTwoActionScenario() internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 1e18, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyCandidate(VERIFIER_ID);
        _joinService(GROUP_ID);
        _joinService(VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(60e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(40e18), VERIFIER_ID);
        stake.setTotalValidGovVotes(address(token), 100e18);
        stake.setValidGovVotes(address(token), GROUP_ID, 10e18);
        _armServiceReward(SERVICE_REWARD);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID), _ratios(PRECISION / 2));
        _setRecipients(GROUP_ID, GROUP_ACTION_ID_B, _ids(MEMBER2_ID), _ratios(PRECISION / 4));
        _atPhase(MINT_PHASE);
    }
}
