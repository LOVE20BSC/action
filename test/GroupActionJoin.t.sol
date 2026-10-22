// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionJoinErrors} from "../src/interfaces/IGroupActionJoin.sol";
import {GroupConfig} from "../src/interfaces/IGroupActionManager.sol";
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

        (uint256 joinedRound, uint256 amount, uint256 groupId, uint256 ownAmount, uint256 providerAmount) =
            executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(joinedRound == 2 && groupId == GROUP_ID, "member 1 round and group");
        require(ownAmount == 150e18 && providerAmount == 0 && amount == 150e18, "member 1 amounts");

        (joinedRound, amount, groupId, ownAmount, providerAmount) =
            executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(groupId == GROUP_ID && ownAmount == 0 && providerAmount == 80e18, "member 2 provider only");
        require(amount == 80e18, "member 2 total");

        require(
            executor.totalJoinedAmountByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 230e18,
            "group total"
        );
        require(executor.joinedAmount(address(token), ACTION_ID, 2) == 230e18, "action total");
        require(joinToken.balanceOf(MEMBER1) == 0, "own tokens pulled");
        require(joinToken.balanceOf(PROVIDER) == 0, "quota tokens deposited");
        require(actionTarget.registerCalls() == 2, "join state registered once per member");

        (uint256[] memory memberIds, uint256 total) =
            executor.memberIdsByGroupId(address(token), ACTION_ID, 2, GROUP_ID, 0, 10, false);
        require(total == 2 && memberIds.length == 2, "member set size");
        require(memberIds[0] == MEMBER1_ID && memberIds[1] == MEMBER2_ID, "member set order");
    }

    function testProviderQuotaAddRemoveRefundsOnlyUnused() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 200e18);

        _grantQuota(PROVIDER_ID, MEMBER2_ID, 200e18);
        require(joinToken.balanceOf(address(executor)) == 200e18, "quota grant deposits");

        _join(MEMBER2_ID, 150e18, PROVIDER_ID);
        require(joinToken.balanceOf(address(executor)) == 200e18, "join moves no tokens");

        (uint256[] memory memberIds, uint256[] memory amounts, , uint256 total) =
            executor.providerQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER2_ID && amounts[0] == 50e18, "remaining quota enumerated");

        uint256 providerBefore = joinToken.balanceOf(PROVIDER);
        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        require(joinToken.balanceOf(PROVIDER) - providerBefore == 50e18, "only unused refunded");
        require(joinToken.balanceOf(address(executor)) == 150e18, "invested part stays");

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaNotGranted.selector, MEMBER2_ID));
        executor.providerQuotaRemove(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID));

        _exit(MEMBER2_ID);
        require(joinToken.balanceOf(address(executor)) == 150e18, "restored quota stays inside");
        (memberIds, amounts, , total) = executor.providerQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER2_ID && amounts[0] == 150e18, "quota restored on exit");

        providerBefore = joinToken.balanceOf(PROVIDER);
        _quotaRemove(PROVIDER_ID, MEMBER2_ID);
        require(joinToken.balanceOf(PROVIDER) - providerBefore == 150e18, "restored quota leaves the contract");
        require(joinToken.balanceOf(address(executor)) == 0, "contract emptied");
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

        (uint256 joinedRound, uint256 amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(joinedRound == 0 && amount == 0, "membership cleared");

        (uint256[] memory memberIds, uint256[] memory amounts, , uint256 total) =
            executor.providerQuota(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER2_ID && amounts[0] == 150e18, "invested restored as quota");

        _join(MEMBER2_ID, 150e18, PROVIDER_ID);
        require(joinToken.balanceOf(address(executor)) == 150e18, "re-join moves no new tokens");
        (joinedRound, amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(joinedRound == 2 && amount == 150e18, "restored quota reused");
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
        (uint256 joinedRound, uint256 amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(joinedRound == 2 && amount == 60e18, "partial withdraw stays joined");

        _withdraw(MEMBER1_ID, 60e18);
        (joinedRound, amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER1_ID);
        require(joinedRound == 0 && amount == 0, "full own withdraw without provider exits");

        _withdraw(MEMBER2_ID, 10e18);
        (joinedRound, amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(joinedRound == 2 && amount == 150e18, "provider keeps membership alive");

        require(actionTarget.clearCalls() == 1, "cleared once");
    }

    function testProviderWithdrawReturnsInvestedAndUnlocksExit() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 150e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 150e18);
        _join(MEMBER2_ID, 150e18, PROVIDER_ID);

        uint256 before = joinToken.balanceOf(PROVIDER);
        vm.prank(PROVIDER);
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 50e18);
        require(joinToken.balanceOf(PROVIDER) - before == 50e18, "partial provider withdraw paid");
        (uint256 joinedRound, uint256 amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(joinedRound == 2 && amount == 100e18, "membership survives partial withdraw");

        before = joinToken.balanceOf(PROVIDER);
        vm.prank(PROVIDER);
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 100e18);
        require(joinToken.balanceOf(PROVIDER) - before == 100e18, "full provider withdraw paid");
        (joinedRound, amount, , , ) = executor.joinInfo(address(token), ACTION_ID, 2, MEMBER2_ID);
        require(joinedRound == 0 && amount == 0, "emptied member exits");
    }

    function testJoinReverts() external {
        _openJoinPhase();

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidParticipationAmount.selector));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 0, 0, new string[](0));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidGroupId.selector));
        executor.join(address(token), ACTION_ID, 0, MEMBER1_ID, 1e18, 0, new string[](0));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.CannotJoinInactiveGroup.selector));
        executor.join(address(token), ACTION_ID, 99, MEMBER1_ID, 1e18, 0, new string[](0));

        _fundJoinTokenFor(MEMBER1, 10e18);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidParticipationAmount.selector));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 5e17, 0, new string[](0));

        _join(MEMBER1_ID, 1e18, 0);
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(GROUP_B_ID, _defaultConfig());
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.AlreadyInOtherGroup.selector));
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
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.GroupAccountsFull.selector));
        executor.join(address(token), ACTION_ID, GROUP_B_ID, PROVIDER_ID, 10e18, 0, new string[](0));

        _joinAt(GROUP_B_ID, MEMBER2_ID, 10e18, 0);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ExceedsGroupMaxJoinAmount.selector));
        executor.join(address(token), ACTION_ID, GROUP_B_ID, MEMBER2_ID, 1, 0, new string[](0));
    }

    function testWithdrawAndExitGuards() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 10e18);
        _join(MEMBER1_ID, 1e18, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidParticipationAmount.selector));
        executor.withdraw(address(token), ACTION_ID, MEMBER1_ID, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidParticipationAmount.selector));
        executor.withdraw(address(token), ACTION_ID, MEMBER1_ID, 2e18);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.NotJoinedAction.selector));
        executor.exit(address(token), ACTION_ID, MEMBER2_ID);

        _fundJoinTokenFor(PROVIDER, 1e18);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, 1e18);
        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidParticipationAmount.selector));
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 0);
    }

    function testProviderQuotaReverts() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 100e18);

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidGroupId.selector));
        executor.providerQuotaAdd(address(token), ACTION_ID, 0, PROVIDER_ID, _ids(MEMBER2_ID), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InvalidGroupId.selector));
        executor.providerQuotaRemove(address(token), ACTION_ID, 0, PROVIDER_ID, _ids(MEMBER2_ID));

        uint256[] memory memberIds = new uint256[](2);
        memberIds[0] = MEMBER2_ID;
        memberIds[1] = PROVIDER_ID;
        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaArrayLengthMismatch.selector));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, memberIds, _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaMemberZero.selector));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(0), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaMemberIsProvider.selector));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(PROVIDER_ID), _ids(1e18));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaAmountZero.selector));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(0));

        vm.prank(PROVIDER);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.QuotaNotGranted.selector, MEMBER2_ID));
        executor.providerQuotaRemove(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, PROVIDER_ID));
        executor.providerQuotaAdd(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, _ids(MEMBER2_ID), _ids(1e18));

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, PROVIDER_ID));
        executor.providerWithdraw(address(token), ACTION_ID, MEMBER2_ID, PROVIDER_ID, 1e18);
    }
}
