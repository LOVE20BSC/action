// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
import {IGroupActionManagerErrors} from "../src/interfaces/IGroupActionManager.sol";
import {GroupConfig} from "../src/interfaces/IGroupActionManager.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionManagerTest is GroupActionExecutorTestBase {
    uint256 internal constant ACTION_2 = 22;
    uint256 internal constant GROUP_8 = 8;
    uint256 internal constant GROUP_99 = 99;

    function testActivateGroupAccountingAndSnapshots() external {
        _openJoinPhase();

        require(executor.isGroupActive(address(token), ACTION_ID, GROUP_ID), "active");
        require(executor.staked(address(token), ACTION_ID) == ACTIVATION_STAKE, "staked");
        require(executor.totalStaked(address(token)) == ACTIVATION_STAKE, "total staked");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == ACTIVATION_STAKE, "owner staked");

        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        _activateGroupWith(GROUP_8, _defaultConfig());
        require(executor.totalStaked(address(token)) == ACTIVATION_STAKE * 2, "both groups staked");

        (uint256[] memory groupIds, uint256 total) = executor.activeGroupIds(address(token), ACTION_ID, 0, 10, false);
        require(total == 2 && groupIds.length == 2, "two active groups");
        (groupIds, total) = executor.activeGroupIds(address(token), ACTION_ID, 1, 1, false);
        require(total == 2 && groupIds.length == 1 && groupIds[0] == GROUP_8, "active ids pagination");

        (address[] memory tokenAddresses, uint256 tokenTotal) =
            executor.tokenAddressesByGroupId(GROUP_ID, 0, 10, false);
        require(tokenTotal == 1 && tokenAddresses[0] == address(token), "token by group");
        (uint256[] memory actionIds, uint256 actionTotal) =
            executor.actionIdsByGroupId(address(token), GROUP_ID, 0, 10, false);
        require(actionTotal == 1 && actionIds[0] == ACTION_ID, "action by group");
        (actionIds, actionTotal) = executor.actionIds(address(token), 0, 10, false);
        require(actionTotal == 1 && actionIds[0] == ACTION_ID, "action ids");

        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 2, GROUP_ID)))
                == keccak256(bytes("group")),
            "description by round"
        );
        require(
            bytes(executor.descriptionByRound(address(token), ACTION_ID, 1, GROUP_ID)).length == 0,
            "no earlier description"
        );
    }

    function testVerifierStakeStaysOutOfActivationLedgers() external {
        _submitApplication();
        require(executor.VERIFIER_STAKE_AMOUNT(address(token), ACTION_ID) == VERIFIER_STAKE, "stake configured");

        _castCandidateVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();

        require(executor.staked(address(token), ACTION_ID) == ACTIVATION_STAKE, "action ledger holds the activation stake only");
        require(executor.totalStaked(address(token)) == ACTIVATION_STAKE, "token total holds the activation stake only");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == ACTIVATION_STAKE, "group owner stake");
        require(executor.totalStakedByMemberId(address(token), VERIFIER_ID) == 0, "verifier stake excluded");
        require(executor.hasActiveGroups(address(token), VERIFIER_ID) == false, "verifier stake grants no group");
        require(
            token.balanceOf(address(executor)) == VERIFIER_STAKE + ACTIVATION_STAKE, "both stakes held by the executor"
        );
    }

    function testHasActiveGroupsChecksMembershipAsGroup() external {
        _openJoinPhase();

        require(executor.hasActiveGroups(address(token), GROUP_ID), "owner counts without personal participation");

        _fundJoinTokenFor(MEMBER1, 1e18);
        _join(MEMBER1_ID, 1e18, 0);
        require(!executor.hasActiveGroups(address(token), MEMBER1_ID), "participant is not an active group");

        _atPhase(4);
        _deactivateGroup(GROUP_ID);
        require(!executor.hasActiveGroups(address(token), GROUP_ID), "deactivation clears the qualification");
    }

    function testActivateGroupReverts() external {
        _openJoinPhase();

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NotGroupOwner.selector, GROUP_ID));
        executor.activateGroup(address(token), ACTION_ID, GROUP_ID, _defaultConfig());

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotExist.selector, uint256(999)));
        executor.activateGroup(address(token), ACTION_ID, 999, _defaultConfig());

        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupAlreadyActivated.selector, GROUP_ID));
        executor.activateGroup(address(token), ACTION_ID, GROUP_ID, _defaultConfig());

        GroupConfig memory zeroMin = GroupConfig({
            description: "x",
            maxCapacity: 0,
            minJoinAmount: 0,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.InvalidMinJoinAmount.selector, 0));
        executor.activateGroup(address(token), ACTION_ID, GROUP_8, zeroMin);

        GroupConfig memory inverted = GroupConfig({
            description: "x",
            maxCapacity: 0,
            minJoinAmount: 10e18,
            maxJoinAmount: 5e18,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.InvalidMaxJoinAmount.selector, 10e18, 5e18));
        executor.activateGroup(address(token), ACTION_ID, GROUP_8, inverted);

        bytes memory longDescription = new bytes(1025);
        for (uint256 i = 0; i < longDescription.length; i++) {
            longDescription[i] = 0x61;
        }
        GroupConfig memory tooLong = GroupConfig({
            description: string(longDescription),
            maxCapacity: 0,
            minJoinAmount: 1e18,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.DescriptionTooLong.selector, 1025, 1024));
        executor.activateGroup(address(token), ACTION_ID, GROUP_8, tooLong);
    }

    function testActivationMinGovRatioGate() external {
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), 0, PRECISION, 1e17, VERIFIER_STAKE));
        _atPhase(3);
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);

        stake.setGlobalGovVotes(address(token), 0);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NoGovVotes.selector, address(token)));
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        stake.setGlobalGovVotes(address(token), 1000e18);
        stake.setValidGovVotes(address(token), GROUP_8, 50e18);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.InsufficientActivationMinGovRatio.selector, GROUP_8, 1e17, 5e16));
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        stake.setValidGovVotes(address(token), GROUP_8, 100e18);
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());
        require(executor.isGroupActive(address(token), ACTION_2, GROUP_8), "activated at the ratio boundary");
        require(executor.staked(address(token), ACTION_2) == 0, "no activation stake configured");
    }

    function testDeactivateRestoresStakeAndSnapshots() external {
        _openJoinPhase();
        _fundJoinTokenFor(GROUP_OWNER, 1e18);
        _join(GROUP_OWNER_ID, 1e18, 0);
        require(executor.hasActiveGroups(address(token), GROUP_OWNER_ID), "active before");

        _atPhase(4);
        uint256 before = token.balanceOf(GROUP_OWNER);
        _deactivateGroup(GROUP_ID);
        require(token.balanceOf(GROUP_OWNER) - before == ACTIVATION_STAKE, "stake returned");
        require(!executor.isGroupActive(address(token), ACTION_ID, GROUP_ID), "inactive");
        require(executor.staked(address(token), ACTION_ID) == 0, "staked cleared");
        require(executor.totalStaked(address(token)) == 0, "total cleared");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == 0, "owner cleared");

        (uint256[] memory groupIds, uint256 total) = executor.activeGroupIds(address(token), ACTION_ID, 0, 10, false);
        require(total == 0 && groupIds.length == 0, "no active groups");
        (, uint256 tokenTotal) = executor.tokenAddressesByGroupId(GROUP_ID, 0, 10, false);
        require(tokenTotal == 0, "token link removed");
        (, uint256 actionTotal) = executor.actionIdsByGroupId(address(token), GROUP_ID, 0, 10, false);
        require(actionTotal == 0, "action link removed");
        (, actionTotal) = executor.actionIds(address(token), 0, 10, false);
        require(actionTotal == 0, "action ids removed");
        require(!executor.hasActiveGroups(address(token), GROUP_OWNER_ID), "active after false");
    }

    function testDeactivateReverts() external {
        _openJoinPhase();

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.DeactivationLockedInActivatedRound.selector, GROUP_ID, 2));
        executor.deactivateGroup(address(token), ACTION_ID, GROUP_ID);

        memberNFT.setOwner(GROUP_99, GROUP_OWNER);
        _atPhase(4);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_99));
        executor.deactivateGroup(address(token), ACTION_ID, GROUP_99);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NotGroupOwner.selector, GROUP_ID));
        executor.deactivateGroup(address(token), ACTION_ID, GROUP_ID);
    }

    function testUpdateGroupConfigAndReverts() external {
        _openJoinPhase();
        _atPhase(4);

        GroupConfig memory updated = GroupConfig({
            description: "v2",
            maxCapacity: 500e18,
            minJoinAmount: 2e18,
            maxJoinAmount: 20e18,
            maxAccounts: 3
        });
        vm.prank(GROUP_OWNER);
        executor.updateGroupConfig(address(token), ACTION_ID, GROUP_ID, updated);

        (GroupConfig memory config, bool active, uint256 activatedRound, uint256 deactivatedRound) =
            executor.groupInfo(address(token), ACTION_ID, GROUP_ID);
        require(active && activatedRound == 2 && deactivatedRound == 0, "group info flags");
        require(keccak256(bytes(config.description)) == keccak256(bytes("v2")), "description updated");
        require(
            config.maxCapacity == 500e18 && config.minJoinAmount == 2e18 && config.maxJoinAmount == 20e18
                && config.maxAccounts == 3,
            "config updated"
        );
        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 3, GROUP_ID)))
                == keccak256(bytes("v2")),
            "description history at update round"
        );
        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 2, GROUP_ID)))
                == keccak256(bytes("group")),
            "history keeps activation round"
        );

        memberNFT.setOwner(GROUP_99, GROUP_OWNER);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_99));
        executor.updateGroupConfig(address(token), ACTION_ID, GROUP_99, updated);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NotGroupOwner.selector, GROUP_ID));
        executor.updateGroupConfig(address(token), ACTION_ID, GROUP_ID, updated);
    }

    function testMaxJoinAmountDerivation() external {
        _openJoinPhase();
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 0, "zero supply caps at zero");

        joinToken.mint(MEMBER1, 400e18);
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 400e18, "full vote rate");

        vote.setVotesNumByProposalId(address(token), 2, ACTION_ID, 250e18);
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 100e18, "quarter vote rate");

        vote.setVotesNum(address(token), 2, 0);
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 0, "zero total votes");

        vote.setVotesNumByProposalId(address(token), 2, ACTION_ID, 0);
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 0, "zero action votes");

        vote.setVotesNum(address(token), 2, 1000e18);
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), 0, 0, 0, 0));
        require(executor.maxJoinAmount(address(token), ACTION_2) == 0, "zero ratio");
    }

    function testOnProposalCreatedReverts() external {
        bytes[] memory data = _targetData();

        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(this)));
        executor.onProposalCreated(address(token), ACTION_2, data);

        bytes[] memory four = new bytes[](4);
        for (uint256 i = 0; i < 4; i++) {
            four[i] = data[i];
        }
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.TargetDataLengthMismatch.selector, 6, 4));
        executor.onProposalCreated(address(token), ACTION_2, four);

        bytes[] memory five = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            five[i] = data[i];
        }
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.TargetDataLengthMismatch.selector, 6, 5));
        executor.onProposalCreated(address(token), ACTION_2, five);

        bytes[] memory eight = new bytes[](8);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.TargetDataLengthMismatch.selector, 7, 8));
        executor.onProposalCreated(address(token), ACTION_2, eight);

        bytes[] memory badItem = _clone(data);
        badItem[2] = new bytes(31);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 2, 31));
        executor.onProposalCreated(address(token), ACTION_2, badItem);

        bytes[] memory badVerifierStake = _clone(data);
        badVerifierStake[5] = new bytes(31);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidTargetDataShape.selector, 5, 31));
        executor.onProposalCreated(address(token), ACTION_2, badVerifierStake);

        bytes[] memory zeroToken = _clone(data);
        zeroToken[1] = abi.encode(address(0));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.ZeroJoinTokenAddress.selector));
        executor.onProposalCreated(address(token), ACTION_2, zeroToken);

        bytes[] memory badRatio = _clone(data);
        badRatio[3] = abi.encode(PRECISION + 1);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidMaxJoinAmountRatio.selector, PRECISION + 1));
        executor.onProposalCreated(address(token), ACTION_2, badRatio);

        bytes[] memory badGov = _clone(data);
        badGov[4] = abi.encode(PRECISION + 1);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidActivationMinGovRatio.selector, PRECISION + 1));
        executor.onProposalCreated(address(token), ACTION_2, badGov);

        string[] memory keys = new string[](1);
        keys[0] = "k";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "a";
        descriptions[1] = "b";
        bytes[] memory seven = new bytes[](7);
        for (uint256 i = 0; i < 6; i++) {
            seven[i] = data[i];
        }
        seven[6] = abi.encode(keys, descriptions);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.VerificationInfoLengthMismatch.selector, 1, 2));
        executor.onProposalCreated(address(token), ACTION_2, seven);
    }

    function testActivateGroupRevertsForUncreatedAction() external {
        _atPhase(3);
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);

        // Without a creation callback the activation stake and the gov floor are still zero, so a
        // pre-activation would silently enter the action without ever paying the stake.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_2)
        );
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        require(!executor.isGroupActive(address(token), ACTION_2, GROUP_8), "no activation recorded");
        require(!executor.hasActiveGroups(address(token), GROUP_8), "no qualification granted");
    }

    function testDeactivateRefundsThePaidStake() external {
        _openJoinPhase();
        uint256 balanceBefore = token.balanceOf(GROUP_OWNER);

        _atPhase(4);
        _deactivateGroup(GROUP_ID);

        require(
            token.balanceOf(GROUP_OWNER) == balanceBefore + ACTIVATION_STAKE, "refund equals the paid stake"
        );
        require(executor.staked(address(token), ACTION_ID) == 0, "action stake ledger cleared");
        require(executor.totalStaked(address(token)) == 0, "token stake ledger cleared");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == 0, "member stake ledger cleared");
    }

    function testPreActivationCannotEnterWithoutPayingTheStake() external {
        _atPhase(3);
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 4);

        _activateGroup();
        require(
            executor.totalStakedByMemberId(address(token), GROUP_ID) == ACTIVATION_STAKE, "attacker paid on A1"
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_2)
        );
        executor.activateGroup(address(token), ACTION_2, GROUP_ID, _defaultConfig());

        _createAction(ACTION_2);
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());
        require(executor.staked(address(token), ACTION_2) == ACTIVATION_STAKE, "honest stake recorded");

        _atPhase(4);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_ID));
        executor.deactivateGroup(address(token), ACTION_2, GROUP_ID);

        require(executor.staked(address(token), ACTION_2) == ACTIVATION_STAKE, "honest stake intact");
        require(executor.totalStaked(address(token)) == ACTIVATION_STAKE * 2, "both stakes held");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == ACTIVATION_STAKE, "A1 stake untouched");
    }

    function testDeactivateThenReactivateKeepsTheStakeLedgerClosed() external {
        _openJoinPhase();
        require(executor.staked(address(token), ACTION_ID) == ACTIVATION_STAKE, "paid on first activation");

        _atPhase(4);
        uint256 balanceBefore = token.balanceOf(GROUP_OWNER);
        _deactivateGroup(GROUP_ID);
        require(
            token.balanceOf(GROUP_OWNER) == balanceBefore + ACTIVATION_STAKE, "refunded on first deactivation"
        );
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == 0, "member ledger closed");

        _atPhase(5);
        _activateGroupWith(GROUP_ID, _defaultConfig());
        require(executor.staked(address(token), ACTION_ID) == ACTIVATION_STAKE, "paid on reactivation");
        require(
            executor.totalStakedByMemberId(address(token), GROUP_ID) == ACTIVATION_STAKE, "member ledger reopened"
        );

        _atPhase(6);
        balanceBefore = token.balanceOf(GROUP_OWNER);
        _deactivateGroup(GROUP_ID);
        require(
            token.balanceOf(GROUP_OWNER) == balanceBefore + ACTIVATION_STAKE, "refunded on second deactivation"
        );
        require(executor.staked(address(token), ACTION_ID) == 0, "action ledger closed");
        require(executor.totalStaked(address(token)) == 0, "token ledger closed");
        require(executor.totalStakedByMemberId(address(token), GROUP_ID) == 0, "member ledger closed again");
    }
}
