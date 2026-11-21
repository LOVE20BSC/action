// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {GroupActionCreationParams, IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
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
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == ACTIVATION_STAKE, "staked");
        require(executor.totalActivationStake(address(token)) == ACTIVATION_STAKE, "total staked");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == ACTIVATION_STAKE, "owner staked");

        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        _activateGroupWith(GROUP_8, _defaultConfig());
        require(executor.totalActivationStake(address(token)) == ACTIVATION_STAKE * 2, "both groups staked");

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
        (actionIds, actionTotal) = executor.actionIdsWithActiveGroups(address(token), 0, 10, false);
        require(actionTotal == 1 && actionIds[0] == ACTION_ID, "action ids");

        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 3, GROUP_ID)))
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
        require(executor.requiredVerifierStake(address(token), ACTION_ID) == VERIFIER_STAKE, "stake configured");

        _castVerifierVotes();
        _atPhase(3);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 5);
        _activateGroup();

        require(executor.activationStakeByActionId(address(token), ACTION_ID) == ACTIVATION_STAKE, "action ledger holds the activation stake only");
        require(executor.totalActivationStake(address(token)) == ACTIVATION_STAKE, "token total holds the activation stake only");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == ACTIVATION_STAKE, "group owner stake");
        require(executor.activationStakeByGroupId(address(token), VERIFIER_ID) == 0, "verifier stake excluded");
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

        GroupConfig memory zeroOnActive = GroupConfig({
            description: "x",
            maxCapacity: 0,
            minJoinAmount: 0,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.ZeroMinJoinAmount.selector));
        executor.activateGroup(address(token), ACTION_ID, GROUP_ID, zeroOnActive);

        GroupConfig memory zeroMin = GroupConfig({
            description: "x",
            maxCapacity: 0,
            minJoinAmount: 0,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.ZeroMinJoinAmount.selector));
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

    function testActivationNeedsOnlyTheActionToExist() external {
        _atPhase(1);
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0, VERIFIER_STAKE));
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);

        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        (, bool active, uint256 activatedRound,) = executor.groupState(address(token), ACTION_2, GROUP_8);
        require(active && activatedRound == 1, "activated in the creation round");
        require(executor.activationStakeByGroupId(address(token), GROUP_8) == ACTIVATION_STAKE, "stake taken");
    }

    function testActivationMinGovRatioGate() external {
        _createActionWith(ACTION_2, _targetDataWith(address(joinToken), 0, PRECISION, 1e17, VERIFIER_STAKE));
        _atPhase(3);
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);

        stake.setTotalGovVotes(address(token), 0);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NoGovVotes.selector, address(token)));
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        stake.setTotalGovVotes(address(token), 1000e18);
        stake.setGovVotes(address(token), GROUP_8, 50e18);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.InsufficientActivationMinGovRatio.selector, GROUP_8, 1e17, 5e16));
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());

        stake.setGovVotes(address(token), GROUP_8, 100e18);
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());
        require(executor.isGroupActive(address(token), ACTION_2, GROUP_8), "activated at the ratio boundary");
        require(executor.activationStakeByActionId(address(token), ACTION_2) == 0, "no activation stake configured");
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
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == 0, "staked cleared");
        require(executor.totalActivationStake(address(token)) == 0, "total cleared");
        require(executor.totalActivationStakeByRound(address(token), 1) == 0, "before activation");
        require(executor.totalActivationStakeByRound(address(token), 2) == ACTIVATION_STAKE, "join round keeps activation stake");
        require(executor.activationStakeByGroupIdByRound(address(token), 2, GROUP_ID) == ACTIVATION_STAKE, "member history retained");
        require(executor.totalActivationStakeByRound(address(token), 3) == 0, "next join round clears stake");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == 0, "owner cleared");

        (uint256[] memory groupIds, uint256 total) = executor.activeGroupIds(address(token), ACTION_ID, 0, 10, false);
        require(total == 0 && groupIds.length == 0, "no active groups");
        (, uint256 tokenTotal) = executor.tokenAddressesByGroupId(GROUP_ID, 0, 10, false);
        require(tokenTotal == 0, "token link removed");
        (, uint256 actionTotal) = executor.actionIdsByGroupId(address(token), GROUP_ID, 0, 10, false);
        require(actionTotal == 0, "action link removed");
        (, actionTotal) = executor.actionIdsWithActiveGroups(address(token), 0, 10, false);
        require(actionTotal == 0, "action ids removed");
        require(!executor.hasActiveGroups(address(token), GROUP_OWNER_ID), "active after false");
    }

    function testDeactivateReverts() external {
        _openJoinPhase();

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.DeactivationLockedInActivatedRound.selector, GROUP_ID, 3));
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
        executor.setGroupConfig(address(token), ACTION_ID, GROUP_ID, updated);

        (GroupConfig memory config, bool active, uint256 activatedRound, uint256 deactivatedRound) =
            executor.groupState(address(token), ACTION_ID, GROUP_ID);
        require(active && activatedRound == 3 && deactivatedRound == 0, "group info flags");
        require(keccak256(bytes(config.description)) == keccak256(bytes("v2")), "description updated");
        require(
            config.maxCapacity == 500e18 && config.minJoinAmount == 2e18 && config.maxJoinAmount == 20e18
                && config.maxAccounts == 3,
            "config updated"
        );
        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 4, GROUP_ID)))
                == keccak256(bytes("v2")),
            "description history at update round"
        );
        require(
            keccak256(bytes(executor.descriptionByRound(address(token), ACTION_ID, 3, GROUP_ID)))
                == keccak256(bytes("group")),
            "history keeps activation round"
        );

        memberNFT.setOwner(GROUP_99, GROUP_OWNER);
        GroupConfig memory zeroMin = GroupConfig({
            description: "x",
            maxCapacity: 0,
            minJoinAmount: 0,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.ZeroMinJoinAmount.selector));
        executor.setGroupConfig(address(token), ACTION_ID, GROUP_99, zeroMin);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_99));
        executor.setGroupConfig(address(token), ACTION_ID, GROUP_99, updated);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.NotGroupOwner.selector, GROUP_ID));
        executor.setGroupConfig(address(token), ACTION_ID, GROUP_ID, updated);
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

    function testJoinTokenWithoutTotalSupplyIsRejected() external {
        bytes memory wrongToken = _targetDataWith(address(0xdead), 0, 0, 0, 0);
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidJoinTokenAddress.selector, address(0xdead))
        );
        executor.onProposalCreated(address(token), ACTION_2, wrongToken);

        // A mistyped token never becomes the stored join token, so the derived cap view stays callable.
        _openJoinPhase();
        require(executor.maxJoinAmount(address(token), ACTION_2) == 0, "uncreated action caps at zero");
    }

    function testVerifierPunishmentRatioConfiguration() external {
        GroupActionCreationParams memory params = _groupCreationParams();
        _createActionWith(ACTION_2, abi.encode(params));
        require(executor.verifierPunishmentRatio(address(token), ACTION_2) == 9e17, "configured punishment ratio");
        require(executor.verifierPunishmentRatio(address(token), ACTION_ID) == 9e17, "other action ratio unchanged");

        params.verifierPunishmentRatio = 0;
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidVerifierPunishmentRatio.selector, 0));
        executor.onProposalCreated(address(token), 23, abi.encode(params));

        params.verifierPunishmentRatio = PRECISION;
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidVerifierPunishmentRatio.selector, PRECISION));
        executor.onProposalCreated(address(token), 23, abi.encode(params));

        params.verifierPunishmentRatio = PRECISION + 1;
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidVerifierPunishmentRatio.selector, PRECISION + 1));
        executor.onProposalCreated(address(token), 24, abi.encode(params));
    }

    function testOnProposalCreatedReverts() external {
        bytes memory creationData = _targetData();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(this)));
        executor.onProposalCreated(address(token), ACTION_2, creationData);

        GroupActionCreationParams memory params = _groupCreationParams();
        params.joinTokenAddress = address(0);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.ZeroJoinTokenAddress.selector));
        executor.onProposalCreated(address(token), ACTION_2, abi.encode(params));

        params = _groupCreationParams();
        params.maxJoinAmountRatio = PRECISION + 1;
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidMaxJoinAmountRatio.selector, PRECISION + 1));
        executor.onProposalCreated(address(token), ACTION_2, abi.encode(params));

        params = _groupCreationParams();
        params.activationMinGovRatio = PRECISION + 1;
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidActivationMinGovRatio.selector, PRECISION + 1));
        executor.onProposalCreated(address(token), ACTION_2, abi.encode(params));

        string[] memory keys = new string[](1);
        keys[0] = "k";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "a";
        descriptions[1] = "b";
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.VerificationInfoLengthMismatch.selector, 1, 2));
        executor.onProposalCreated(address(token), ACTION_2, _targetDataWithSchema(keys, descriptions));

        string[] memory tooManyKeys = new string[](17);
        string[] memory tooManyDescriptions = new string[](17);
        for (uint256 i = 0; i < 17; i++) {
            tooManyKeys[i] = "k";
            tooManyDescriptions[i] = "d";
        }
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionManagerErrors.TooManyVerificationEntries.selector, 17, 16)
        );
        executor.onProposalCreated(
            address(token), ACTION_2, _targetDataWithSchema(tooManyKeys, tooManyDescriptions)
        );

        string[] memory longKey = new string[](1);
        longKey[0] = string(new bytes(1025));
        string[] memory oneDescription = new string[](1);
        oneDescription[0] = "d";
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionManagerErrors.VerificationKeyTooLong.selector, 0, 1025, 1024)
        );
        executor.onProposalCreated(address(token), ACTION_2, _targetDataWithSchema(longKey, oneDescription));

        string[] memory oneKey = new string[](1);
        oneKey[0] = "k";
        string[] memory longDescription = new string[](1);
        longDescription[0] = string(new bytes(1025));
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionManagerErrors.VerificationDescriptionTooLong.selector, 0, 1025, 1024)
        );
        executor.onProposalCreated(address(token), ACTION_2, _targetDataWithSchema(oneKey, longDescription));
    }

    function testOnProposalCreatedRejectsMalformedConfig() external {
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidGroupActionCreationData.selector, 0)
        );
        executor.onProposalCreated(address(token), ACTION_2, "");

        bytes memory truncatedData = _targetData();
        assembly ("memory-safe") {
            mstore(truncatedData, sub(mload(truncatedData), 32))
        }
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidGroupActionCreationData.selector, truncatedData.length)
        );
        executor.onProposalCreated(address(token), ACTION_2, truncatedData);

        require(executor.joinTokenAddress(address(token), ACTION_2) == address(0), "config never written");
    }

    function testOnProposalCreatedBubblesPhaseFailure() external {
        bytes memory createCall = abi.encodeCall(executor.onProposalCreated, (address(token), ACTION_2, _targetData()));
        bytes memory readPhaseCall = abi.encodeCall(phase.currentPhase, ());
        bytes memory phaseError = abi.encodeWithSignature("PhaseUnavailable(uint256)", 5);
        vm.mockCallRevert(address(phase), readPhaseCall, phaseError);

        vm.prank(address(actionTarget));
        vm.expectRevert(phaseError);
        executor.onProposalCreated(address(token), ACTION_2, _targetData());

        vm.mockCallRevert(address(phase), readPhaseCall, "");
        vm.prank(address(actionTarget));
        (bool success, bytes memory reason) = address(executor).call(createCall);
        require(!success && reason.length == 0, "empty dependency error preserved");
        require(executor.joinTokenAddress(address(token), ACTION_2) == address(0), "config rolled back");
    }

    function testVerificationKeysMustBeNonemptyAndUnique() external {
        string[] memory keys = new string[](3);
        keys[0] = "proof";
        keys[1] = "account";
        keys[2] = "proof";
        string[] memory descriptions = new string[](3);

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.DuplicateVerificationKey.selector, 2, 0));
        executor.onProposalCreated(address(token), ACTION_2, _targetDataWithSchema(keys, descriptions));

        keys[2] = "";
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.VerificationKeyEmpty.selector, 2));
        executor.onProposalCreated(address(token), ACTION_2, _targetDataWithSchema(keys, descriptions));

        keys[2] = "link";
        _createActionWith(ACTION_2, _targetDataWithSchema(keys, descriptions));
        (string[] memory storedKeys,) = executor.verificationSchema(address(token), ACTION_2);
        require(storedKeys.length == 3 && keccak256(bytes(storedKeys[2])) == keccak256(bytes("link")), "valid schema stored");
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
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == 0, "action stake ledger cleared");
        require(executor.totalActivationStake(address(token)) == 0, "token stake ledger cleared");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == 0, "member stake ledger cleared");
    }

    function testPreActivationCannotEnterWithoutPayingTheStake() external {
        _atPhase(3);
        memberNFT.setOwner(GROUP_8, GROUP_OWNER);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE * 4);

        _activateGroup();
        require(
            executor.activationStakeByGroupId(address(token), GROUP_ID) == ACTIVATION_STAKE, "attacker paid on A1"
        );

        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), ACTION_2)
        );
        executor.activateGroup(address(token), ACTION_2, GROUP_ID, _defaultConfig());

        _createAction(ACTION_2);
        vm.prank(GROUP_OWNER);
        executor.activateGroup(address(token), ACTION_2, GROUP_8, _defaultConfig());
        require(executor.activationStakeByActionId(address(token), ACTION_2) == ACTIVATION_STAKE, "honest stake recorded");

        _atPhase(4);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_ID));
        executor.deactivateGroup(address(token), ACTION_2, GROUP_ID);

        require(executor.activationStakeByActionId(address(token), ACTION_2) == ACTIVATION_STAKE, "honest stake intact");
        require(executor.totalActivationStake(address(token)) == ACTIVATION_STAKE * 2, "both stakes held");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == ACTIVATION_STAKE, "A1 stake untouched");
    }

    function testDeactivateThenReactivateKeepsTheStakeLedgerClosed() external {
        _openJoinPhase();
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == ACTIVATION_STAKE, "paid on first activation");

        _atPhase(4);
        uint256 balanceBefore = token.balanceOf(GROUP_OWNER);
        _deactivateGroup(GROUP_ID);
        require(
            token.balanceOf(GROUP_OWNER) == balanceBefore + ACTIVATION_STAKE, "refunded on first deactivation"
        );
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == 0, "member ledger closed");

        _atPhase(5);
        _activateGroupWith(GROUP_ID, _defaultConfig());
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == ACTIVATION_STAKE, "paid on reactivation");
        require(
            executor.activationStakeByGroupId(address(token), GROUP_ID) == ACTIVATION_STAKE, "member ledger reopened"
        );

        _atPhase(6);
        balanceBefore = token.balanceOf(GROUP_OWNER);
        _deactivateGroup(GROUP_ID);
        require(
            token.balanceOf(GROUP_OWNER) == balanceBefore + ACTIVATION_STAKE, "refunded on second deactivation"
        );
        require(executor.activationStakeByActionId(address(token), ACTION_ID) == 0, "action ledger closed");
        require(executor.totalActivationStake(address(token)) == 0, "token ledger closed");
        require(executor.activationStakeByGroupId(address(token), GROUP_ID) == 0, "member ledger closed again");
    }
}

contract GroupActionManagerActivationRoundTest is GroupActionExecutorTestBase {
    function testActivationRecordsTheVoteRoundAndLocksThatRoundOnly() external {
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);
        _activateGroup();

        (, bool active, uint256 activatedRound,) = executor.groupState(address(token), ACTION_ID, GROUP_ID);
        require(active, "active");
        require(activatedRound == CREATION_PHASE, "activation round is the vote round");

        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionManagerErrors.DeactivationLockedInActivatedRound.selector,
                GROUP_ID,
                CREATION_PHASE
            )
        );
        _deactivateGroup(GROUP_ID);

        _atPhase(CREATION_PHASE + 1);
        _deactivateGroup(GROUP_ID);
    }

    function testReactivationRecordsTheNewVoteRound() external {
        _atPhase(CREATION_PHASE + 1);
        _fundTokenFor(GROUP_OWNER, ACTIVATION_STAKE);
        _activateGroup();

        _atPhase(CREATION_PHASE + 2);
        _deactivateGroup(GROUP_ID);

        _atPhase(CREATION_PHASE + 3);
        _activateGroup();

        (, , uint256 activatedRound,) = executor.groupState(address(token), ACTION_ID, GROUP_ID);
        require(activatedRound == CREATION_PHASE + 3, "reactivation round is the new vote round");
    }
}

contract GroupActionManagerMaxJoinAmountTest is GroupActionExecutorTestBase {
    function testMaxJoinAmountSkipsActionsWithoutAJoinToken() external {
        uint256 unknownActionId = 999;
        _atPhase(CREATION_PHASE + 1);
        vote.setVotesNumByProposalId(address(token), CREATION_PHASE, unknownActionId, 500e18);

        require(executor.maxJoinAmount(address(token), unknownActionId) == 0, "no join token yields no cap");

        _fundJoinTokenFor(MEMBER1, 100e18);
        uint256 actionMaxJoinAmount = executor.maxJoinAmount(address(token), ACTION_ID);
        require(actionMaxJoinAmount > 0, "this executor's action still reports a cap");
    }
}
