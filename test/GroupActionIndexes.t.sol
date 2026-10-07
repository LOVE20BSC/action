// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {MockGroupActionToken} from "./mocks/GroupActionExecutorMocks.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionIndexesTest is GroupActionExecutorTestBase {
    uint256 internal constant ACTION_2 = 22;
    uint256 internal constant ACTION_3 = 23;

    MockGroupActionToken internal token2;

    function testIsGroupMemberLifecycle() external {
        _openJoinPhase();
        require(!executor.isGroupMember(GROUP_ID, MEMBER1_ID), "not a member before join");

        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 1e18, 0);
        require(executor.isGroupMember(GROUP_ID, MEMBER1_ID), "member after join");

        _join(MEMBER1_ID, 1e18, 0);
        require(executor.isGroupMember(GROUP_ID, MEMBER1_ID), "append keeps membership");

        _exit(MEMBER1_ID);
        require(!executor.isGroupMember(GROUP_ID, MEMBER1_ID), "gone after last relation");
    }

    function testIndexesSpanTokenAndActionRelations() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);

        // Relation 1: (token, action 21).
        _join(MEMBER1_ID, 1e18, 0);

        // Relation 2: same token, second action.
        vote.setVotesNumByProposalId(address(token), 2, ACTION_2, 1000e18);
        _createActionWith(ACTION_2, _targetData());
        _activateGroupOn(address(token), ACTION_2, GROUP_ID);
        _joinOn(address(token), ACTION_2, GROUP_ID, MEMBER1_ID, 1e18);

        (address[] memory tokenAddresses, uint256 tokenTotal) =
            executor.gTokenAddressesByGroupIdByMemberId(GROUP_ID, MEMBER1_ID, 0, 10, false);
        require(tokenTotal == 1 && tokenAddresses[0] == address(token), "same token stays one entry");

        // Relation 3: second token.
        token2 = new MockGroupActionToken();
        vote.setVotesNum(address(token2), 2, 1000e18);
        vote.setVotesNumByProposalId(address(token2), 2, ACTION_3, 1000e18);
        token2.mint(GROUP_OWNER, ACTIVATION_STAKE);
        vm.prank(GROUP_OWNER);
        token2.approve(address(executor), type(uint256).max);
        _createActionOn(address(token2), ACTION_3, _targetDataWith(address(joinToken), ACTIVATION_STAKE, PRECISION, 0));
        _activateGroupOn(address(token2), ACTION_3, GROUP_ID);
        _joinOn(address(token2), ACTION_3, GROUP_ID, MEMBER1_ID, 1e18);

        (tokenAddresses, tokenTotal) = executor.gTokenAddressesByGroupIdByMemberId(GROUP_ID, MEMBER1_ID, 0, 10, false);
        require(tokenTotal == 2, "two tokens");
        (uint256[] memory groupIds, uint256 groupTotal) = executor.gGroupIdsByMemberId(MEMBER1_ID, 0, 10, false);
        require(groupTotal == 1 && groupIds[0] == GROUP_ID, "single group");
        (uint256[] memory memberIds, uint256 memberTotal) =
            executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, false);
        require(memberTotal == 1 && memberIds[0] == MEMBER1_ID, "single member");
        (memberIds, memberTotal) = executor.gMemberIds(0, 10, false);
        require(memberTotal == 1, "global member set");
        (groupIds, groupTotal) = executor.gGroupIds(0, 10, false);
        require(groupTotal == 1 && groupIds[0] == GROUP_ID, "global group set");

        // Drop the second-token relation: membership survives, that token entry disappears.
        _exitOn(address(token2), ACTION_3, MEMBER1_ID);
        require(executor.isGroupMember(GROUP_ID, MEMBER1_ID), "still a member");
        (tokenAddresses, tokenTotal) = executor.gTokenAddressesByGroupIdByMemberId(GROUP_ID, MEMBER1_ID, 0, 10, false);
        require(tokenTotal == 1 && tokenAddresses[0] == address(token), "token entry removed");
        (memberIds, memberTotal) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, false);
        require(memberTotal == 1, "member set untouched");

        // Drop the remaining relations.
        _exitOn(address(token), ACTION_2, MEMBER1_ID);
        _exit(MEMBER1_ID);
        require(!executor.isGroupMember(GROUP_ID, MEMBER1_ID), "membership cleared");
        (tokenAddresses, tokenTotal) = executor.gTokenAddressesByGroupIdByMemberId(GROUP_ID, MEMBER1_ID, 0, 10, false);
        require(tokenTotal == 0, "token set cleared");
        (groupIds, groupTotal) = executor.gGroupIdsByMemberId(MEMBER1_ID, 0, 10, false);
        require(groupTotal == 0, "member group set cleared");
        (memberIds, memberTotal) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, false);
        require(memberTotal == 0, "group member set cleared");
        (memberIds, memberTotal) = executor.gMemberIds(0, 10, false);
        require(memberTotal == 0, "global member set cleared");
        (groupIds, groupTotal) = executor.gGroupIds(0, 10, false);
        require(groupTotal == 0, "global group set cleared");
    }

    function testIndexPaginationContract() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 1e18);
        _fundJoinTokenFor(MEMBER2, 1e18);
        _fundJoinTokenFor(PROVIDER, 1e18);
        _join(MEMBER1_ID, 1e18, 0);
        _join(MEMBER2_ID, 1e18, 0);
        _join(PROVIDER_ID, 1e18, 0);

        (uint256[] memory memberIds, uint256 total) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 2, false);
        require(total == 3 && memberIds.length == 2, "first page");
        require(memberIds[0] == MEMBER1_ID && memberIds[1] == MEMBER2_ID, "forward order");
        (memberIds, total) = executor.gMemberIdsByGroupId(GROUP_ID, 1, 10, false);
        require(total == 3 && memberIds.length == 2 && memberIds[0] == MEMBER2_ID, "offset page");
        (memberIds, total) = executor.gMemberIdsByGroupId(GROUP_ID, 5, 10, false);
        require(total == 3 && memberIds.length == 0, "out of range");
        (memberIds, total) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 0, false);
        require(total == 3 && memberIds.length == 0, "zero limit returns total only");
        (memberIds, total) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, true);
        require(total == 3 && memberIds.length == 3 && memberIds[0] == PROVIDER_ID, "reverse order");

        (uint256[] memory groupIds, uint256 groupTotal) = executor.gGroupIds(0, 10, false);
        require(groupTotal == 1 && groupIds[0] == GROUP_ID, "global groups");
    }

    function testIndexesSurviveDeactivation() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 1e18, 0);

        _atPhase(4);
        _deactivateGroup(GROUP_ID);
        require(!executor.isGroupActive(address(token), ACTION_ID, GROUP_ID), "inactive");
        require(executor.isGroupMember(GROUP_ID, MEMBER1_ID), "membership untouched");
        (uint256[] memory memberIds, uint256 total) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, false);
        require(total == 1 && memberIds[0] == MEMBER1_ID, "index untouched");

        _exit(MEMBER1_ID);
        require(!executor.isGroupMember(GROUP_ID, MEMBER1_ID), "exit after deactivation");
        (memberIds, total) = executor.gMemberIdsByGroupId(GROUP_ID, 0, 10, false);
        require(total == 0, "cleared on last exit");
    }

    function testMemberIndexAcrossGroups() external {
        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        vote.setVotesNumByProposalId(address(token), 2, ACTION_2, 1000e18);
        _createActionWith(ACTION_2, _targetData());
        _activateGroupOn(address(token), ACTION_2, GROUP_B_ID);

        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 1e18, 0);
        _joinOn(address(token), ACTION_2, GROUP_B_ID, MEMBER1_ID, 1e18);

        (uint256[] memory groupIds, uint256 groupTotal) = executor.gGroupIdsByMemberId(MEMBER1_ID, 0, 10, false);
        require(groupTotal == 2 && groupIds[0] == GROUP_ID && groupIds[1] == GROUP_B_ID, "two groups");
        (groupIds, groupTotal) = executor.gGroupIds(0, 10, false);
        require(groupTotal == 2, "global groups two");
        (uint256[] memory memberIds, uint256 memberTotal) = executor.gMemberIdsByGroupId(GROUP_B_ID, 0, 10, false);
        require(memberTotal == 1 && memberIds[0] == MEMBER1_ID, "group B member");

        _exitOn(address(token), ACTION_2, MEMBER1_ID);
        (groupIds, groupTotal) = executor.gGroupIdsByMemberId(MEMBER1_ID, 0, 10, false);
        require(groupTotal == 1 && groupIds[0] == GROUP_ID, "one group left");
        (groupIds, groupTotal) = executor.gGroupIds(0, 10, false);
        require(groupTotal == 1 && groupIds[0] == GROUP_ID, "global group removed");

        _exit(MEMBER1_ID);
        (groupIds, groupTotal) = executor.gGroupIdsByMemberId(MEMBER1_ID, 0, 10, false);
        require(groupTotal == 0, "all cleared");
    }
}
