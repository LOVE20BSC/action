// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IGroupActionJoinErrors} from "../src/interfaces/IGroupActionJoin.sol";
import {GroupConfig, IGroupActionManagerErrors} from "../src/interfaces/IGroupActionManager.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionEdgeCasesTest is GroupActionExecutorTestBase {
    function testMaxCapacityBoundary() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupWith(
            GROUP_B_ID,
            GroupConfig({description: "cap", maxCapacity: 100e18, minJoinAmount: 1e18, maxJoinAmount: 0, maxAccounts: 0})
        );
        _fundJoinTokenFor(MEMBER2, 101e18);

        _joinAt(GROUP_B_ID, MEMBER2_ID, 60e18, 0);
        _joinAt(GROUP_B_ID, MEMBER2_ID, 40e18, 0);
        require(
            executor.totalJoinedAmountByGroupId(address(token), ACTION_ID, 2, GROUP_B_ID) == 100e18,
            "capacity filled exactly"
        );

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.GroupCapacityExceeded.selector));
        executor.join(address(token), ACTION_ID, GROUP_B_ID, MEMBER2_ID, 1, 0, new string[](0));
    }

    function testDescriptionLengthBoundary() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);

        bytes memory atLimit = new bytes(1024);
        for (uint256 i = 0; i < atLimit.length; i++) {
            atLimit[i] = 0x61;
        }
        GroupConfig memory config = GroupConfig({
            description: string(atLimit),
            maxCapacity: 0,
            minJoinAmount: 1e18,
            maxJoinAmount: 0,
            maxAccounts: 0
        });
        _activateGroupWith(GROUP_B_ID, config);
        require(
            bytes(executor.descriptionByRound(address(token), ACTION_ID, 2, GROUP_B_ID)).length == 1024,
            "1024 bytes accepted"
        );
    }

    function testActionMaxJoinAmountBoundary() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 10e18);
        // Supply 10e18 with a full vote rate and a 1e18 ratio caps joins at 10e18.
        _join(MEMBER1_ID, 10e18, 0);
        require(executor.maxJoinAmount(address(token), ACTION_ID) == 10e18, "cap derived");

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.ExceedsActionMaxJoinAmount.selector));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 1, 0, new string[](0));
    }

    function testReactivateGroupFlow() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER2, 10e18);

        _atPhase(4);
        _deactivateGroup(GROUP_ID);
        require(executor.staked(address(token), ACTION_ID) == 0, "stake returned on deactivation");
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionManagerErrors.GroupNotActive.selector, GROUP_ID));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER2_ID, 1e18, 0, new string[](0));

        _atPhase(5);
        vote.setVotesNum(address(token), 4, 1000e18);
        vote.setVotesNumByProposalId(address(token), 4, ACTION_ID, 1000e18);
        _activateGroup();
        (GroupConfig memory config, bool active, uint256 activatedRound, uint256 deactivatedRound) =
            executor.groupInfo(address(token), ACTION_ID, GROUP_ID);
        require(active && activatedRound == 4 && deactivatedRound == 0, "reactivated at the new round");
        require(config.minJoinAmount == 1e18, "config restored");
        require(executor.staked(address(token), ACTION_ID) == ACTIVATION_STAKE, "stake taken again");

        _join(MEMBER2_ID, 1e18, 0);
        require(executor.joinedAmountByMemberId(address(token), ACTION_ID, 4, MEMBER2_ID) == 1e18, "join resumed");
    }

    function testGroupRoundSnapshotAfterLastExit() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        _activateGroupOn(address(token), ACTION_ID, GROUP_B_ID);
        _fundJoinTokenFor(MEMBER2, 10e18);
        _joinOn(address(token), ACTION_ID, GROUP_B_ID, MEMBER2_ID, 1e18);

        (uint256[] memory groupIds, uint256 total) = executor.groupIds(address(token), ACTION_ID, 2, 0, 10, false);
        require(total == 1 && groupIds[0] == GROUP_B_ID, "group registered for the join round");

        _atPhase(4);
        _exitOn(address(token), ACTION_ID, MEMBER2_ID);
        (groupIds, total) = executor.groupIds(address(token), ACTION_ID, 3, 0, 10, false);
        require(total == 0, "empty group leaves the later round");
        (groupIds, total) = executor.groupIds(address(token), ACTION_ID, 2, 0, 10, false);
        require(total == 1 && groupIds[0] == GROUP_B_ID, "join-round history kept");
        require(executor.isGroupActive(address(token), ACTION_ID, GROUP_B_ID), "group stays active");
    }
}
