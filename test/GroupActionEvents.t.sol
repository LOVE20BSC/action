// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionJoinEvents} from "../src/interfaces/IGroupActionJoin.sol";
import {IGroupActionManagerEvents} from "../src/interfaces/IGroupActionManager.sol";
import {IGroupActionVerifyEvents} from "../src/interfaces/IGroupActionVerify.sol";
import {GroupConfig} from "../src/interfaces/IGroupActionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GroupActionExecutorTestBase, GroupActionExecutorVm} from "./GroupActionExecutorTestBase.sol";

contract GroupActionEventsTest is
    GroupActionExecutorTestBase,
    IGroupActionJoinEvents,
    IGroupActionVerifyEvents,
    IGroupActionManagerEvents,
    IActionExecutorEvents
{
    function testQuotaAndJoinEvents() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 100e18);

        uint256[] memory memberIds = new uint256[](2);
        memberIds[0] = MEMBER2_ID;
        memberIds[1] = GROUP_OWNER_ID;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 60e18;
        amounts[1] = 40e18;

        vm.recordLogs();
        vm.prank(PROVIDER);
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, memberIds, amounts);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 2, "one quota event per member");
        require(
            logs[0].topics[0] == keccak256("ProviderQuotaAdded(address,uint256,uint256,uint256,uint256,uint256)"),
            "quota event signature"
        );
        require(logs[0].topics[3] == bytes32(GROUP_ID), "quota group topic");
        (uint256 providerId, uint256 memberId, uint256 amount) = abi.decode(logs[0].data, (uint256, uint256, uint256));
        require(providerId == PROVIDER_ID && memberId == MEMBER2_ID && amount == 60e18, "first grant decoded");
        (, memberId, amount) = abi.decode(logs[1].data, (uint256, uint256, uint256));
        require(memberId == GROUP_OWNER_ID && amount == 40e18, "second grant decoded");

        vm.expectEmit(true, true, true, true);
        emit Joined(address(token), ACTION_ID, MEMBER2_ID, 2, 60e18, PROVIDER_ID, GROUP_ID);
        _join(MEMBER2_ID, 60e18, PROVIDER_ID);

        vm.expectEmit(true, true, true, true);
        emit ProviderQuotaRemoved(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, GROUP_OWNER_ID, 40e18);
        _quotaRemove(PROVIDER_ID, GROUP_OWNER_ID);
    }

    function testExitEmitsPerSourceWithdrawnThenExited() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER2, 20e18);
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);
        _join(MEMBER2_ID, 20e18, 0);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);

        vm.recordLogs();
        _exit(MEMBER2_ID);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 3, "own leg, provider leg, exited");
        require(
            logs[0].topics[0] == keccak256("Withdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "withdrawn signature"
        );
        (uint256 round, uint256 amount, uint256 providerId, uint256 groupId) =
            abi.decode(logs[0].data, (uint256, uint256, uint256, uint256));
        require(round == 2 && amount == 20e18 && providerId == 0 && groupId == GROUP_ID, "own leg fields");
        (, amount, providerId, groupId) = abi.decode(logs[1].data, (uint256, uint256, uint256, uint256));
        require(amount == 150e18 && providerId == PROVIDER_ID && groupId == GROUP_ID, "provider leg fields");
        require(
            logs[2].topics[0] == keccak256("Exited(address,uint256,uint256,uint256,uint256)"),
            "exited signature"
        );
        (round, groupId) = abi.decode(logs[2].data, (uint256, uint256));
        require(round == 2 && groupId == GROUP_ID, "exited fields");
    }

    function testWithdrawAndProviderWithdrawEvents() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);

        vm.expectEmit(true, true, true, true);
        emit Joined(address(token), ACTION_ID, MEMBER1_ID, 2, 100e18, 0, GROUP_ID);
        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(address(token), ACTION_ID, MEMBER1_ID, 2, 40e18, 0, GROUP_ID);
        _withdraw(MEMBER1_ID, 40e18);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(address(token), ACTION_ID, MEMBER2_ID, 2, 50e18, PROVIDER_ID, GROUP_ID);
        vm.prank(PROVIDER);
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 50e18);
    }

    function testGroupLifecycleEvents() external {
        _submitApplication();
        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);

        vm.expectEmit(true, true, true, true);
        emit GroupActivated(address(token), ACTION_ID, 2, GROUP_ID, ACTIVATION_STAKE);
        _activateGroup();

        _atPhase(4);
        GroupConfig memory updated = GroupConfig({
            description: "v2",
            maxCapacity: 500e18,
            minJoinAmount: 2e18,
            maxJoinAmount: 20e18,
            maxAccounts: 3
        });
        vm.expectEmit(true, true, true, true);
        emit GroupConfigUpdated(address(token), ACTION_ID, 3, GROUP_ID, "v2", 500e18, 2e18, 20e18, 3);
        vm.prank(GROUP_OWNER);
        executor.updateGroupConfig(address(token), ACTION_ID, GROUP_ID, updated);

        vm.expectEmit(true, true, true, true);
        emit GroupDeactivated(address(token), ACTION_ID, 3, GROUP_ID, ACTIVATION_STAKE);
        _deactivateGroup(GROUP_ID);
    }

    function testVerificationEvents() external {
        vm.expectEmit(true, true, true, true);
        emit VerifierStakeDeposited(address(token), ACTION_ID, VERIFIER_ID, 2, VERIFIER_STAKE);
        vm.expectEmit(true, true, true, true);
        emit VerifierApplicationSubmitted(address(token), ACTION_ID, VERIFIER_ID, 2, 1);
        _submitApplication();

        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _fundJoinTokenFor(PROVIDER, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, PROVIDER_QUOTA);
        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, PROVIDER_QUOTA, PROVIDER_ID);

        _atPhase(4);
        uint256[] memory scores = _scores(100, 60);
        vm.expectEmit(true, true, true, true);
        emit VerifierLocked(address(token), ACTION_ID, 2, VERIFIER_ID);
        vm.expectEmit(true, true, true, true);
        emit OriginScoresSubmitted(address(token), ACTION_ID, GROUP_ID, 2, VERIFIER_ID, 0, scores);
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, scores);
    }

    function testVerifierApplicationCancelEvent() external {
        _submitApplication();

        vm.expectEmit(true, true, true, true);
        emit VerifierStakeRefunded(address(token), ACTION_ID, VERIFIER_ID, 2, VERIFIER_STAKE);
        vm.expectEmit(true, true, true, true);
        emit VerifierApplicationCancelled(address(token), ACTION_ID, VERIFIER_ID, 2, 1);
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
    }

    function testVerifierStakeEventsFireOncePerPayment() external {
        vm.recordLogs();
        _submitApplication();
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "replaced");
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();

        uint256 deposits;
        uint256 submissions;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("VerifierStakeDeposited(address,uint256,uint256,uint256,uint256)")) {
                deposits++;
                (uint256 round, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
                require(round == 2 && amount == VERIFIER_STAKE, "deposit payload");
                require(logs[i].topics[3] == bytes32(VERIFIER_ID), "deposit member topic");
            }
            if (
                logs[i].topics[0]
                    == keccak256("VerifierApplicationSubmitted(address,uint256,uint256,uint256,uint256)")
            ) {
                submissions++;
            }
        }
        require(deposits == 1 && submissions == 2, "stake paid once across replacement");

        vm.recordLogs();
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
        logs = vm.getRecordedLogs();
        uint256 refunds;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("VerifierStakeRefunded(address,uint256,uint256,uint256,uint256)")) {
                refunds++;
                (uint256 round, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
                require(round == 2 && amount == VERIFIER_STAKE, "refund payload");
            }
        }
        require(refunds == 1, "refund event once");
    }

    function testMemberRewardMintedEvent() external {
        _prepareRound();
        _atPhase(4);
        _submitScores(_scores(100, 60));

        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, 100e18 * 100, 100e18 * 100 + PROVIDER_QUOTA * 60);
        vm.expectEmit(true, true, true, true);
        emit MemberRewardMinted(address(token), ACTION_ID, MEMBER1_ID, 2, expected1, 0);
        _settle(MEMBER1_ID, 2);
    }

    function _scores(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }
}
