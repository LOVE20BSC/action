// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorEvents} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorEvents} from "../src/interfaces/IGroupActionExecutor.sol";
import {IGroupActionJoinErrors, IGroupActionJoinEvents} from "../src/interfaces/IGroupActionJoin.sol";
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
    IGroupActionExecutorEvents,
    IActionExecutorEvents
{
    uint256 internal constant ACTION_2 = 22;

    function testGroupActionCreatedEvent() external {
        _atPhase(CREATION_PHASE);
        vm.recordLogs();
        _createAction(ACTION_2);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single creation event");
        require(logs[0].emitter == address(executor), "emitter is the executor");
        require(
            logs[0].topics[0]
                == keccak256("GroupActionCreated(address,uint256,address,uint256,uint256,uint256,uint256,string[],string[])"),
            "creation signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(ACTION_2), "action topic");
        (
            address joinTokenAddress,
            uint256 activationStakeAmount,
            uint256 maxJoinAmountRatio,
            uint256 activationMinGovRatio,
            uint256 verifierStakeAmount,
            string[] memory keys,
            string[] memory descriptions
        ) = abi.decode(logs[0].data, (address, uint256, uint256, uint256, uint256, string[], string[]));
        require(joinTokenAddress == address(joinToken), "join token");
        require(activationStakeAmount == ACTIVATION_STAKE, "activation stake");
        require(maxJoinAmountRatio == PRECISION, "max join ratio");
        require(activationMinGovRatio == 0, "activation min gov ratio");
        require(verifierStakeAmount == VERIFIER_STAKE, "verifier stake");
        require(keys.length == 0 && descriptions.length == 0, "empty schema");
    }

    function testGroupActionCreatedCarriesTheVerificationSchema() external {
        string[] memory keys = _strings("twitter", "github");
        string[] memory descriptions = _strings("Twitter handle", "GitHub handle");
        bytes[] memory data = _targetDataWithSchema(keys, descriptions);

        vm.prank(address(actionTarget));
        vm.expectEmit(true, true, true, true);
        emit GroupActionCreated(
            address(token),
            ACTION_2,
            address(joinToken),
            ACTIVATION_STAKE,
            PRECISION,
            0,
            VERIFIER_STAKE,
            keys,
            descriptions
        );
        executor.onProposalCreated(address(token), ACTION_2, data);
    }

    function testQuotaAndJoinEvents() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 150e18);

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
        require(logs[0].emitter == address(executor), "quota event emitted by the executor");
        require(
            logs[0].topics[0]
                == keccak256("ProviderQuotaAdded(address,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "quota event signature"
        );
        require(logs[0].topics[3] == bytes32(GROUP_ID), "quota group topic");
        (uint256 providerId, uint256 memberId, uint256 amount, uint256 quotaTotal) =
            abi.decode(logs[0].data, (uint256, uint256, uint256, uint256));
        require(providerId == PROVIDER_ID && memberId == MEMBER2_ID && amount == 60e18, "first grant decoded");
        require(quotaTotal == 60e18, "first grant total");
        (, memberId, amount, quotaTotal) = abi.decode(logs[1].data, (uint256, uint256, uint256, uint256));
        require(memberId == GROUP_OWNER_ID && amount == 40e18, "second grant decoded");
        require(quotaTotal == 40e18, "second grant total");

        vm.prank(PROVIDER);
        vm.expectEmit(true, true, true, true);
        emit ProviderQuotaAdded(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, MEMBER2_ID, 10e18, 70e18);
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(10e18));

        vm.expectEmit(true, true, true, true);
        emit GroupActionJoined(address(token), ACTION_ID, MEMBER2_ID, 2, GROUP_ID, PROVIDER_ID, 60e18, _strings());
        _join(MEMBER2_ID, 60e18, PROVIDER_ID);

        vm.expectEmit(true, true, true, true);
        emit ProviderQuotaRemoved(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, GROUP_OWNER_ID, 40e18);
        _quotaRemove(PROVIDER_ID, GROUP_OWNER_ID);
    }

    function testGroupActionJoinedCarriesVerificationValues() external {
        string[] memory keys = _strings("twitter", "github");
        string[] memory descriptions = _strings("Twitter handle", "GitHub handle");
        bytes[] memory data = _targetDataWithSchema(keys, descriptions);
        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), ACTION_ID, data);
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);

        string[] memory values = _strings("alice", "alice-gh");
        vm.prank(MEMBER1);
        vm.expectEmit(true, true, true, true);
        emit GroupActionJoined(address(token), ACTION_ID, MEMBER1_ID, 2, GROUP_ID, 0, 100e18, values);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, values);
    }

    /// 追加加入不提交验证值：事件里的空数组表示「本次无新值」，折叠不得清空既有值。
    function testGroupActionJoinedTopUpCarriesNoVerificationValues() external {
        string[] memory keys = _strings("twitter");
        string[] memory descriptions = _strings("Twitter handle");
        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), ACTION_ID, _targetDataWithSchema(keys, descriptions));
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 200e18);

        vm.prank(MEMBER1);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, _strings("alice"));

        vm.prank(MEMBER1);
        vm.expectEmit(true, true, true, true);
        emit GroupActionJoined(address(token), ACTION_ID, MEMBER1_ID, 2, GROUP_ID, 0, 100e18, _strings());
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, _strings());

        require(
            keccak256(bytes(executor.verificationValue(address(token), ACTION_ID, MEMBER1_ID, "twitter")))
                == keccak256(bytes("alice")),
            "stored value survives the top-up"
        );
    }

    function testGroupActionJoinedEmitsFromTheExecutor() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        vm.recordLogs();
        _join(MEMBER1_ID, 100e18, 0);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "single join event");
        require(logs[0].emitter == address(executor), "emitter is the executor");
        require(logs[0].topics.length == 4, "three indexed fields");
        require(
            logs[0].topics[0]
                == keccak256("GroupActionJoined(address,uint256,uint256,uint256,uint256,uint256,uint256,string[])"),
            "join signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(token)))), "token topic");
        require(logs[0].topics[2] == bytes32(ACTION_ID), "action topic");
        require(logs[0].topics[3] == bytes32(MEMBER1_ID), "member topic");
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
        require(logs.length == 3, "own leg, provider refund, exited");
        require(
            logs[0].topics[0]
                == keccak256("GroupActionWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "withdrawn signature"
        );
        (uint256 round, uint256 groupId, uint256 providerId, uint256 amount) =
            abi.decode(logs[0].data, (uint256, uint256, uint256, uint256));
        require(round == 2 && amount == 20e18 && providerId == 0 && groupId == GROUP_ID, "own leg fields");
        require(
            logs[1].topics[0]
                == keccak256("ProviderQuotaRefunded(address,uint256,uint256,uint256,uint256,uint256)"),
            "provider refund signature"
        );
        (uint256 refundProviderId, uint256 refundMemberId, uint256 refundAmount) =
            abi.decode(logs[1].data, (uint256, uint256, uint256));
        require(refundProviderId == PROVIDER_ID && refundMemberId == MEMBER2_ID, "provider refund parties");
        require(refundAmount == 150e18, "provider refund amount");
        require(logs[1].topics[3] == bytes32(GROUP_ID), "provider refund group topic");
        require(
            logs[2].topics[0] == keccak256("GroupActionExited(address,uint256,uint256,uint256,uint256)"),
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
        emit GroupActionJoined(address(token), ACTION_ID, MEMBER1_ID, 2, GROUP_ID, 0, 100e18, _strings());
        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);

        vm.expectEmit(true, true, true, true);
        emit GroupActionWithdrawn(address(token), ACTION_ID, MEMBER1_ID, 2, GROUP_ID, 0, 40e18);
        _withdraw(MEMBER1_ID, 40e18);

        vm.expectEmit(true, true, true, true);
        emit GroupActionWithdrawn(address(token), ACTION_ID, MEMBER2_ID, 2, GROUP_ID, PROVIDER_ID, 50e18);
        vm.prank(PROVIDER);
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 50e18);
    }

    /// E4：`GroupActionWithdrawn` → `JoinStateCleared` → `GroupActionExited`，终态标记最后发。
    function testExitOrdersWithdrawnThenRegistryClearThenExited() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 100e18, 0);
        actionTarget.setEmitClearEvent(true, 2);

        vm.recordLogs();
        _exit(MEMBER1_ID);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 3, "withdrawn, registry clear, exited");
        require(
            logs[0].topics[0]
                == keccak256("GroupActionWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256)"),
            "withdrawn first"
        );
        require(logs[1].emitter == address(actionTarget), "clear emitted by ActionTarget");
        require(
            logs[1].topics[0] == keccak256("JoinStateCleared(address,uint256,uint256,uint256,bool)"),
            "registry clear second"
        );
        require(
            logs[2].topics[0] == keccak256("GroupActionExited(address,uint256,uint256,uint256,uint256)"),
            "exited last"
        );
        (uint256 round, uint256 groupId) = abi.decode(logs[2].data, (uint256, uint256));
        require(round == 2 && groupId == GROUP_ID, "exited payload");
    }

    /// `GroupDeactivated` 是可逆状态迁移，不是终态：停用后可再次激活并重置 deactivatedRound。
    function testGroupDeactivatedIsReversible() external {
        _submitApplication();
        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();

        _atPhase(4);
        vm.recordLogs();
        _deactivateGroup(GROUP_ID);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        require(
            logs[0].topics[0] == keccak256("GroupDeactivated(address,uint256,uint256,uint256,uint256)"),
            "deactivated"
        );
        (, bool active, uint256 activatedRound, uint256 deactivatedRound) =
            executor.groupInfo(address(token), ACTION_ID, GROUP_ID);
        require(!active && deactivatedRound == 3, "inactive with deactivated round");

        _atPhase(5);
        vm.recordLogs();
        _activateGroup();
        logs = vm.getRecordedLogs();
        require(
            logs[0].topics[0] == keccak256("GroupActivated(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,string)"),
            "reactivated"
        );
        (bool activeAfter, uint256 reactivatedRound, uint256 deactivatedRoundAfter) = _groupState();
        require(activeAfter, "active again");
        require(reactivatedRound == 4, "reactivation round");
        require(deactivatedRoundAfter == 0, "deactivation round reset");
        require(activatedRound == 2, "original activation round");
    }

    function _groupState() private view returns (bool active, uint256 activatedRound, uint256 deactivatedRound) {
        (, active, activatedRound, deactivatedRound) = executor.groupInfo(address(token), ACTION_ID, GROUP_ID);
    }

    function testGroupLifecycleEvents() external {
        _submitApplication();
        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);

        vm.expectEmit(true, true, true, true);
        emit GroupActivated(address(token), ACTION_ID, 2, GROUP_ID, ACTIVATION_STAKE, 0, 1e18, 0, 0, "group");
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
        emit GroupConfigChanged(
            address(token),
            ACTION_ID,
            3,
            GROUP_ID,
            500e18,
            2e18,
            20e18,
            3,
            "v2",
            0,
            1e18,
            0,
            0,
            "group"
        );
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
        emit VerifierApplicationSubmitted(address(token), ACTION_ID, VERIFIER_ID, 2, 1, 0, false, "verifier");
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
        uint256 expectedTotal = 100e18 * 100 + PROVIDER_QUOTA * 60;
        vm.expectEmit(true, true, true, true);
        emit VerifierLocked(address(token), ACTION_ID, VERIFIER_ID, 2);
        vm.expectEmit(true, true, true, true);
        emit OriginScoresSubmitted(
            address(token), ACTION_ID, GROUP_ID, 2, VERIFIER_ID, 0, expectedTotal, 1, true, scores
        );
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, scores);

        require(executor.totalFinalScore(address(token), ACTION_ID, 2) == expectedTotal, "ledger total");
        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "round verified");
    }

    function testApplicationVoteRecordedEmitsFromTheExecutor() external {
        _submitApplication();
        vm.recordLogs();
        _castVotesFor(VERIFIER_ID, 100e18);
        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ApplicationVoteRecorded(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed fields");
            found = true;
        }
        require(found, "missing ApplicationVoteRecorded from executor");
    }

    function testApplicationVoteRecordedSeparatesRounds() external {
        _submitApplication();
        _castVotesFor(VERIFIER_ID, 100e18);
        _atPhase(4);

        vm.expectEmit(true, true, true, true);
        emit ApplicationVoteRecorded(address(token), ACTION_ID, 4, 1, VERIFIER_ID, 60e18, 60e18);
        _castVotesForAt(VERIFIER_ID, 60e18, 4);
    }

    function testApplicationVoteRecordedEvent() external {
        _submitApplication();

        vm.expectEmit(true, true, true, true);
        emit ApplicationVoteRecorded(address(token), ACTION_ID, CREATION_PHASE, 1, VERIFIER_ID, 100e18, 100e18);
        _castVotesFor(VERIFIER_ID, 100e18);

        vm.expectEmit(true, true, true, true);
        emit ApplicationVoteRecorded(address(token), ACTION_ID, CREATION_PHASE, 1, VERIFIER_ID, 60e18, 160e18);
        _castVotesFor(VERIFIER_ID, 60e18);
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

    function testVerifierApplicationCancelEventCarriesTheCancelRound() external {
        _submitApplication();
        _atPhase(4);

        vm.expectEmit(true, true, true, true);
        emit VerifierStakeRefunded(address(token), ACTION_ID, VERIFIER_ID, 4, VERIFIER_STAKE);
        vm.expectEmit(true, true, true, true);
        emit VerifierApplicationCancelled(address(token), ACTION_ID, VERIFIER_ID, 4, 1);
        vm.prank(VERIFIER);
        executor.cancelVerifierApplication(address(token), ACTION_ID, VERIFIER_ID);
    }

    function testVerifierApplicationReplacementCarriesThePreviousId() external {
        _submitApplication();

        vm.expectEmit(true, true, true, true);
        emit VerifierApplicationSubmitted(address(token), ACTION_ID, VERIFIER_ID, 2, 2, 1, true, "replaced");
        vm.prank(VERIFIER);
        executor.submitVerifierApplication(address(token), ACTION_ID, VERIFIER_ID, "replaced");
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
                    == keccak256("VerifierApplicationSubmitted(address,uint256,uint256,uint256,uint256,uint256,bool,string)")
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

    function _strings() internal pure returns (string[] memory out) {
        out = new string[](0);
    }

    function _strings(string memory a) internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = a;
    }

    function _strings(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }

    /// 边界成功值：16 个 verification key/value 恰好等于上限时接受。
    function testGroupActionCreatedAcceptsSixteenVerificationKeys() external {
        string[] memory keys = new string[](16);
        string[] memory descriptions = new string[](16);
        for (uint256 i; i < 16; ++i) {
            keys[i] = _letter(i);
            descriptions[i] = "d";
        }
        bytes[] memory data = _targetDataWithSchema(keys, descriptions);

        vm.prank(address(actionTarget));
        vm.expectEmit(true, true, true, true);
        emit GroupActionCreated(
            address(token),
            ACTION_2,
            address(joinToken),
            ACTIVATION_STAKE,
            PRECISION,
            0,
            VERIFIER_STAKE,
            keys,
            descriptions
        );
        executor.onProposalCreated(address(token), ACTION_2, data);
    }

    /// 累计值：`OriginScoresSubmitted.totalFinalScore` 必须等于按日志顺序折叠的加权分。
    function testOriginScoresSubmittedTotalFinalScoreMatchesFold() external {
        _prepareRound();
        _atPhase(4);

        uint256[] memory firstBatch = new uint256[](1);
        firstBatch[0] = 10;
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, firstBatch);

        uint256[] memory secondBatch = new uint256[](1);
        secondBatch[0] = 20;
        vm.recordLogs();
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, secondBatch);

        GroupActionExecutorVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "OriginScoresSubmitted(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256[])"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic) continue;
            (, , uint256 startIndex, uint256 totalFinalScore,,,) = abi.decode(
                logs[i].data, (uint256, uint256, uint256, uint256, uint256, bool, uint256[])
            );
            require(startIndex == 1, "second batch start index");
            require(totalFinalScore == 100e18 * 10 + PROVIDER_QUOTA * 20, "totalFinalScore equals fold");
            found = true;
        }
        require(found, "missing OriginScoresSubmitted");
    }

    function _letter(uint256 index) private pure returns (string memory) {
        bytes memory out = new bytes(2);
        out[0] = bytes1(uint8(97 + index));
        out[1] = "x";
        return string(out);
    }

    /// 边界成功值：16 个 verification value 恰好等于上限时接受。
    function testGroupActionJoinedAcceptsSixteenVerificationValues() external {
        string[] memory keys = new string[](16);
        string[] memory descriptions = new string[](16);
        string[] memory values = new string[](16);
        for (uint256 i; i < 16; ++i) {
            keys[i] = _letter(i);
            descriptions[i] = "d";
            values[i] = _letter(i);
        }

        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), ACTION_ID, _targetDataWithSchema(keys, descriptions));
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);

        vm.prank(MEMBER1);
        vm.expectEmit(true, true, true, true);
        emit GroupActionJoined(address(token), ACTION_ID, MEMBER1_ID, 2, GROUP_ID, 0, 100e18, values);
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, values);
    }

    /// 边界：17 个 verification value 超过上限时回滚。
    function testGroupActionJoinedRejectsSeventeenVerificationValues() external {
        string[] memory keys = new string[](16);
        string[] memory descriptions = new string[](16);
        for (uint256 i; i < 16; ++i) {
            keys[i] = _letter(i);
            descriptions[i] = "d";
        }

        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), ACTION_ID, _targetDataWithSchema(keys, descriptions));
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);

        string[] memory values = new string[](17);
        for (uint256 i; i < 17; ++i) {
            values[i] = "v";
        }
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.TooManyVerificationValues.selector, 17, 16));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, values);
    }

    /// 边界成功值：1024 字节 description 恰好等于上限时接受。
    function testGroupActivatedAcceptsMaxDescription() external {
        _submitApplication();
        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);

        GroupConfig memory config = _defaultConfig();
        config.description = _repeat("D", 1024);
        _activateGroupWith(GROUP_ID, config);

        (GroupConfig memory stored,,,) = executor.groupInfo(address(token), ACTION_ID, GROUP_ID);
        require(bytes(stored.description).length == 1024, "max description stored");
    }

    function _repeat(bytes1 char, uint256 count) private pure returns (string memory result) {
        bytes memory out = new bytes(count);
        for (uint256 i; i < count; ++i) {
            out[i] = char;
        }
        result = string(out);
    }
}
