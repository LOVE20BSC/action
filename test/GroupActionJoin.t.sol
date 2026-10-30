// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionJoinErrors, JoinInfo} from "../src/interfaces/IGroupActionJoin.sol";
import {GroupConfig, IGroupActionManagerErrors} from "../src/interfaces/IGroupActionManager.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionJoinTest is GroupActionExecutorTestBase {
    function testJoinChecksOwnerBeforeAmount() external {
        _openJoinPhase();
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 0, new string[](0));
    }

    function testWithdrawChecksOwnerBeforeAmount() external {
        _openJoinPhase();
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.withdraw(address(token), ACTION_ID, MEMBER1_ID, 0);
    }

    function testExitChecksOwnerBeforeJoined() external {
        _openJoinPhase();
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, MEMBER1_ID));
        executor.exit(address(token), ACTION_ID, MEMBER1_ID);
    }

    function testJoinOwnAndProviderAppend() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 150e18);
        _fundJoinTokenFor(PROVIDER, 80e18);

        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER1_ID, 50e18, 0);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 80e18);
        _join(MEMBER2_ID, 80e18, PROVIDER_ID);

        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(info.joinedRound == 2 && info.groupId == GROUP_ID, "member 1 round and group");
        require(
            info.ownAmount == 150e18 && info.providerAmount == 0 && info.ownAmount + info.providerAmount == 150e18,
            "member 1 amounts"
        );

        info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(info.groupId == GROUP_ID && info.ownAmount == 0 && info.providerAmount == 80e18, "member 2 provider only");
        require(info.ownAmount + info.providerAmount == 80e18, "member 2 total");

        require(
            executor.joinedAmountByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 230e18,
            "group total"
        );
        require(executor.joinedAmountByActionId(address(token), ACTION_ID, 2) == 230e18, "action total");
        require(joinToken.balanceOf(MEMBER1) == 0, "own tokens pulled");
        require(joinToken.balanceOf(PROVIDER) == 0, "quota tokens deposited");
        require(actionTarget.registerCalls() == 2, "join state registered once per member");

        (uint256[] memory memberIds, uint256 total) =
            executor.memberIdsByGroupId(address(token), ACTION_ID, 2, GROUP_ID, 0, 10, false);
        require(total == 2 && memberIds.length == 2, "member set size");
        require(memberIds[0] == MEMBER1_ID && memberIds[1] == MEMBER2_ID, "member set order");
    }

    function testProviderQuotaRemoveTakesBackTheWholeGrant() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 200e18);

        _grantQuota(PROVIDER_ID, MEMBER2_ID, 200e18);
        require(joinToken.balanceOf(address(executor)) == 200e18, "quota grant deposits");

        _join(MEMBER2_ID, 150e18, PROVIDER_ID);
        require(joinToken.balanceOf(address(executor)) == 200e18, "join moves no tokens");
        require(executor.isGroupMember(GROUP_ID, MEMBER2_ID), "member joined");

        (uint256[] memory memberIds, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER2_ID, "grant enumerated");
        require(quotaAmounts[0] == 200e18 && used[0] == 150e18, "granted and used tracked");

        uint256 providerBefore = joinToken.balanceOf(PROVIDER);
        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        require(joinToken.balanceOf(PROVIDER) - providerBefore == 200e18, "whole grant refunded");
        require(joinToken.balanceOf(address(executor)) == 0, "used part leaves with the grant");

        (memberIds, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 0 && quotaAmounts.length == 0, "removed grant leaves the list");
        require(!executor.isGroupMember(GROUP_ID, MEMBER2_ID), "without quota the member exits");

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaNotGranted.selector, GROUP_ID, PROVIDER_ID, MEMBER2_ID));
        executor.removeProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID));
    }

    function testProviderQuotaUsedAmountIsScopedToCurrentGroup() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(GROUP_B_ID, _defaultConfig());
        _fundJoinTokenFor(PROVIDER, 200e18);

        _grantQuota(PROVIDER_ID, MEMBER2_ID, 100e18);
        _join(MEMBER2_ID, 60e18, PROVIDER_ID);
        vm.prank(PROVIDER);
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(100e18));

        _exit(MEMBER2_ID);
        _joinAt(GROUP_B_ID, MEMBER2_ID, 70e18, PROVIDER_ID);

        (uint256[] memory ids, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "old group grant kept");
        require(quotaAmounts[0] == 100e18 && used[0] == 0, "usage not attributed to the old group");

        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "new group grant listed");
        require(quotaAmounts[0] == 100e18 && used[0] == 70e18, "usage attributed to the current group");

        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 60e18);

        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && quotaAmounts[0] == 40e18 && used[0] == 0, "stale group grant shrinks by the withdrawn part");

        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "current group grant untouched");
        require(quotaAmounts[0] == 100e18 && used[0] == 70e18, "current group usage untouched");

        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_B_ID, MEMBER2_ID, PROVIDER_ID, 30e18);

        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && quotaAmounts[0] == 70e18 && used[0] == 70e18, "current group withdraw capped by availability");

        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(
            info.joinedRound == 2 && info.ownAmount + info.providerAmount == 70e18,
            "withdraw leaves participation intact"
        );
    }

    function testProviderQuotaRemoveReleasesGrantOfLeftGroup() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(GROUP_B_ID, _defaultConfig());
        _fundJoinTokenFor(PROVIDER, 200e18);

        _grantQuota(PROVIDER_ID, MEMBER2_ID, 100e18);
        _join(MEMBER2_ID, 60e18, PROVIDER_ID);
        vm.prank(PROVIDER);
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(100e18));
        _exit(MEMBER2_ID);
        _joinAt(GROUP_B_ID, MEMBER2_ID, 70e18, PROVIDER_ID);

        uint256 providerBefore = joinToken.balanceOf(PROVIDER);
        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        require(joinToken.balanceOf(PROVIDER) - providerBefore == 100e18, "stale grant refunded in full");

        (uint256[] memory ids, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 0, "released stale grant leaves the list");

        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "current group grant untouched");
        require(quotaAmounts[0] == 100e18 && used[0] == 70e18, "current group usage untouched");
    }

    function testProviderQuotaWithdrawIsPartialAndKeepsParticipation() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 100e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 100e18);
        _join(MEMBER2_ID, 40e18, PROVIDER_ID);

        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 40e18);
        (uint256[] memory ids, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "partially withdrawn grant stays listed");
        require(quotaAmounts[0] == 60e18 && used[0] == 40e18, "withdraw only takes the unused part");

        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 20e18);
        (ids, quotaAmounts, used, total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && quotaAmounts[0] == 40e18 && used[0] == 40e18, "fully used grant stays listed");

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InsufficientProviderQuota.selector, PROVIDER_ID, 1, 0));
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 1);

        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(
            info.joinedRound == 2 && info.ownAmount + info.providerAmount == 40e18,
            "withdraw leaves participation intact"
        );
    }

    function testProviderQuotaWithdrawDropsAnUnusedRow() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 50e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 50e18);

        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 50e18);
        (, , , uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 0, "withdrawn unused grant leaves the list");
    }

    function testProviderQuotaAddAfterRemoveStartsFromZero() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 200e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 100e18);
        _join(MEMBER2_ID, 60e18, PROVIDER_ID);

        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 25e18);

        (uint256[] memory ids, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && ids[0] == MEMBER2_ID, "regrant listed");
        require(quotaAmounts[0] == 25e18 && used[0] == 0, "regrant starts from zero");

        _join(MEMBER2_ID, 25e18, PROVIDER_ID);
        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionJoinErrors.InsufficientProviderQuota.selector, PROVIDER_ID, 1, 0)
        );
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 1, PROVIDER_ID, new string[](0));
    }

    function testJoinRejectsAmountAboveProviderQuota() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 100e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 50e18);

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionJoinErrors.InsufficientProviderQuota.selector, PROVIDER_ID, 80e18, 50e18
            )
        );
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 80e18, PROVIDER_ID, new string[](0));
    }

    function testExitReturnsOwnAndRestoresProviderQuota() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER2, 20e18);
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);
        _join(MEMBER2_ID, 20e18, 0);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);
        require(joinToken.balanceOf(address(executor)) == 170e18, "executor holds own and provider parts");

        uint256 memberBefore = joinToken.balanceOf(MEMBER2);
        _exit(MEMBER2_ID);
        require(joinToken.balanceOf(MEMBER2) - memberBefore == 20e18, "own part returned");
        require(joinToken.balanceOf(address(executor)) == 150e18, "provider part stays in the contract");

        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(info.joinedRound == 0 && info.ownAmount + info.providerAmount == 0, "membership cleared");

        (uint256[] memory memberIds, uint256[] memory quotaAmounts, uint256[] memory used, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER2_ID, "grant enumerated");
        require(quotaAmounts[0] == 150e18 && used[0] == 0, "invested restored as quota");

        _join(MEMBER2_ID, 150e18, PROVIDER_ID);
        require(joinToken.balanceOf(address(executor)) == 150e18, "re-join moves no new tokens");
        info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(info.joinedRound == 2 && info.ownAmount + info.providerAmount == 150e18, "restored quota reused");
        require(actionTarget.registerCalls() == 2, "join state re-registered");
    }

    function testWithdrawPartialKeepsStateAndFullWithdrawAutoExits() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _fundJoinTokenFor(MEMBER2, 10e18);
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);
        _join(MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, 10e18, 0);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);

        _withdraw(MEMBER1_ID, 40e18);
        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(
            info.joinedRound == 2 && info.ownAmount + info.providerAmount == 60e18, "partial withdraw stays joined"
        );

        _withdraw(MEMBER1_ID, 60e18);
        info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(info.joinedRound == 0 && info.ownAmount + info.providerAmount == 0, "full own withdraw without provider exits");

        _withdraw(MEMBER2_ID, 10e18);
        info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(info.joinedRound == 2 && info.ownAmount + info.providerAmount == 150e18, "provider keeps membership alive");

        require(actionTarget.clearCalls() == 1, "cleared once");
    }

    function testProviderQuotaWithdrawLeavesParticipationIntact() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);
        _join(MEMBER2_ID, 100e18, PROVIDER_ID);

        uint256 before = joinToken.balanceOf(PROVIDER);
        vm.prank(PROVIDER);
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 50e18);
        require(joinToken.balanceOf(PROVIDER) - before == 50e18, "unused quota paid out");
        JoinInfo memory info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(
            info.joinedRound == 2 && info.ownAmount + info.providerAmount == 100e18, "participation untouched"
        );
        require(executor.isGroupMember(GROUP_ID, MEMBER2_ID), "member stays joined");

        before = joinToken.balanceOf(PROVIDER);
        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        require(joinToken.balanceOf(PROVIDER) - before == 100e18, "revoke returns the used part");
        info = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(info.joinedRound == 0 && info.ownAmount + info.providerAmount == 0, "revoke without quota exits");
    }

    function testJoinRejectsUnboundedVerificationValues() external {
        string[] memory keys = new string[](1);
        keys[0] = "k";
        string[] memory descriptions = new string[](1);
        descriptions[0] = "d";
        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), ACTION_ID, _targetDataWithSchema(keys, descriptions));

        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);

        string[] memory values = new string[](17);
        for (uint256 i = 0; i < 17; i++) {
            values[i] = "v";
        }
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionJoinErrors.TooManyVerificationValues.selector, 17, 16)
        );
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 1e18, 0, values);

        string[] memory longValues = new string[](1);
        longValues[0] = string(new bytes(1025));
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionJoinErrors.VerificationValueTooLong.selector, 0, 1025, 1024)
        );
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 1e18, 0, longValues);
    }

    function testJoinReverts() external {
        _openJoinPhase();

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ZeroParticipationAmount.selector));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 0, new string[](0));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotExist.selector, uint256(0)));
        executor.join(address(token), ACTION_ID, 0, MEMBER1_ID, 1e18, 0, new string[](0));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotExist.selector, uint256(99)));
        executor.join(address(token), ACTION_ID, 99, MEMBER1_ID, 1e18, 0, new string[](0));

        _fundJoinTokenFor(MEMBER1, 10e18);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.BelowMinJoinAmount.selector, 5e17, 1e18));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 5e17, 0, new string[](0));

        _join(MEMBER1_ID, 1e18, 0);
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(GROUP_B_ID, _defaultConfig());
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionJoinErrors.AlreadyInOtherGroup.selector, MEMBER1_ID, GROUP_ID, GROUP_B_ID
            )
        );
        executor.join(address(token), ACTION_ID, GROUP_B_ID, MEMBER1_ID, 1e18, 0, new string[](0));
    }

    function testJoinGroupLimits() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(
            GROUP_B_ID,
            GroupConfig({description: "b", maxCapacity: 0, minJoinAmount: 1e18, maxJoinAmount: 50e18, maxAccounts: 1})
        );
        _fundJoinTokenFor(MEMBER2, 60e18);
        _fundJoinTokenFor(PROVIDER, 60e18);

        _joinAt(GROUP_B_ID, MEMBER2_ID, 40e18, 0);

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.GroupAccountsFull.selector, GROUP_B_ID, 1, 1));
        executor.join(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 10e18, 0, new string[](0));

        _joinAt(GROUP_B_ID, MEMBER2_ID, 10e18, 0);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.GroupMaxJoinAmountExceeded.selector, MEMBER2_ID, 50e18 + 1, 50e18));
        executor.join(address(token), ACTION_ID, GROUP_B_ID, MEMBER2_ID, 1, 0, new string[](0));
    }

    function testWithdrawAndExitGuards() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 10e18);
        _join(MEMBER1_ID, 1e18, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ZeroParticipationAmount.selector));
        executor.withdraw(address(token), ACTION_ID, MEMBER1_ID, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.WithdrawAmountExceeded.selector, 2e18, 1e18));
        executor.withdraw(address(token), ACTION_ID, MEMBER1_ID, 2e18);

        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionJoinErrors.NotJoined.selector, address(token), ACTION_ID, MEMBER2_ID)
        );
        executor.exit(address(token), ACTION_ID, MEMBER2_ID);

        _fundJoinTokenFor(PROVIDER, 1e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 1e18);
        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ZeroQuotaAmount.selector, MEMBER2_ID));
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 0);
    }

    function testProviderQuotaWithdrawAmountExceeded() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 2e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 2e18);
        _join(MEMBER2_ID, 1e18, PROVIDER_ID);

        vm.prank(PROVIDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupActionJoinErrors.InsufficientProviderQuota.selector, PROVIDER_ID, 1e18 + 1, 1e18
            )
        );
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 1e18 + 1);
    }

    function testProviderQuotaReverts() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 100e18);

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotExist.selector, uint256(0)));
        executor.addProviderQuota(address(token), ACTION_ID, 0, PROVIDER_ID, _ids(MEMBER2_ID), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotExist.selector, uint256(0)));
        executor.removeProviderQuota(address(token), ACTION_ID, 0, PROVIDER_ID, _ids(MEMBER2_ID));

        uint256[] memory memberIds = new uint256[](2);
        memberIds[0] = MEMBER2_ID;
        memberIds[1] = PROVIDER_ID;
        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaArrayLengthMismatch.selector, 2, 1));
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, memberIds, _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaArrayLengthMismatch.selector, 2, 1));
        executor.addProviderQuota(address(token), ACTION_ID, 0, PROVIDER_ID, memberIds, _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(0)));
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(0), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IGroupActionJoinErrors.QuotaMemberIsProvider.selector, PROVIDER_ID)
        );
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(PROVIDER_ID), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ZeroQuotaAmount.selector, MEMBER2_ID));
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(0));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaNotGranted.selector, GROUP_ID, PROVIDER_ID, MEMBER2_ID));
        executor.removeProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, PROVIDER_ID));
        executor.addProviderQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(1e18));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, PROVIDER_ID));
        executor.withdrawProviderQuota(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, 1e18);
    }
}
