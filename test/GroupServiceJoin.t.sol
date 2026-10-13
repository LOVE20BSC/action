// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IActionTargetErrors} from "../src/interfaces/IActionTarget.sol";
import {IGroupServiceExecutorErrors, IGroupServiceExecutorEvents} from "../src/interfaces/IGroupServiceExecutor.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceJoinTest is GroupServiceTestBase, IGroupServiceExecutorEvents {
    function testJoinOwnerBranchViaActiveGroups() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);

        vm.expectEmit(true, true, true, true);
        emit Joined(address(token), SERVICE_ACTION_ID, GROUP_ID, SERVICE_ROUND);
        _joinService(GROUP_ID);

        require(actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "target joined");
        require(executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID), "round snapshot");
        require(executor.joinedAmountTokenAddress(address(token), SERVICE_ACTION_ID) == address(token), "join token");
    }

    function testJoinCandidateBranchViaVerifierApplication() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        // The member owns no group; qualification comes from an open verifier
        // application inside the service round's community action set.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyCandidate(VERIFIER_ID);

        _joinService(VERIFIER_ID);
        require(actionTarget.isJoined(address(token), SERVICE_ACTION_ID, VERIFIER_ID), "candidate joined");
    }

    function testJoinRequiresEitherBranch() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);

        // No active groups and no application at all.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NoActiveGroups.selector));
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_ID);

        // An application in a different action, outside the community set, does not count.
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        groupAction.setVerifierApplication(address(token), GROUP_ACTION_ID_B, VERIFIER_ID, 1);
        vm.prank(VERIFIER);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NoActiveGroups.selector));
        executor.join(address(token), SERVICE_ACTION_ID, VERIFIER_ID);

        // An active group in a different community does not count either.
        groupAction.setHasActiveGroups(address(childToken), GROUP_OWNER_B_ID, true);
        vm.prank(GROUP_OWNER_B);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NoActiveGroups.selector));
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID);
    }

    function testJoinRejectsNonMemberOwner() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, GROUP_ID));
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_ID);
    }

    function testJoinRejectsDuplicate() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.AlreadyJoined.selector));
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_ID);
    }

    function testJoinBeforeWindowRevertsFromTarget() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _qualifyGroupOwner(GROUP_ID);

        // Joining at the creation round itself: the target refuses the snapshot.
        vm.prank(GROUP_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.JoinNotOpen.selector,
                address(token),
                SERVICE_ACTION_ID,
                CREATION_PHASE,
                CREATION_PHASE
            )
        );
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_ID);
        require(!actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "no snapshot written");
    }

    function testExitClearsJoinStateAndEmitsEvent() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        _atPhase(VERIFY_PHASE);
        vm.expectEmit(true, true, true, true);
        emit Exited(address(token), SERVICE_ACTION_ID, GROUP_ID, VERIFY_PHASE - 1);
        _exitService(GROUP_ID);

        require(!actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "target cleared");
        require(
            !executor.joinInfo(address(token), SERVICE_ACTION_ID, VERIFY_PHASE - 1, GROUP_ID),
            "current round snapshot cleared"
        );
    }

    function testExitWithoutJoinReverts() external {
        _atPhase(JOIN_PHASE);
        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.NotJoined.selector));
        executor.exit(address(token), SERVICE_ACTION_ID, GROUP_ID);
    }

    function testExitRejectsNonMemberOwner() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, GROUP_ID));
        executor.exit(address(token), SERVICE_ACTION_ID, GROUP_ID);
    }

    function testExitDoesNotReclaimPastRounds() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        _atPhase(MINT_PHASE);
        _exitService(GROUP_ID);

        require(!actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "current state cleared");
        require(
            executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID),
            "past round snapshot survives the exit"
        );
        require(
            !executor.joinInfo(address(token), SERVICE_ACTION_ID, MINT_PHASE - 1, GROUP_ID),
            "exit round snapshot is cleared"
        );
    }

    function testJoinInfoRejectsFutureRounds() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        require(!executor.joinInfo(address(token), SERVICE_ACTION_ID, 0, GROUP_ID), "before join is empty");
        require(executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID), "join round recorded");
        require(
            !executor.joinInfo(address(token), SERVICE_ACTION_ID, SERVICE_ROUND + 1, GROUP_ID), "future round false"
        );
    }

    function testExitFollowsCurrentOwnerAfterTransfer() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);

        memberNFT.setOwner(GROUP_ID, MEMBER2);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, GROUP_ID));
        executor.exit(address(token), SERVICE_ACTION_ID, GROUP_ID);

        vm.prank(MEMBER2);
        executor.exit(address(token), SERVICE_ACTION_ID, GROUP_ID);
        require(!actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "new holder exited");
    }

    function testJoinBeforePhaseTwoReverts() external {
        // The action exists from the vote phase, but the join round is phase - 1
        // and stays 0 until phase 2: there is no round to snapshot a join into.
        _atPhase(1);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _qualifyGroupOwner(GROUP_ID);

        vm.prank(GROUP_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.join(address(token), SERVICE_ACTION_ID, GROUP_ID);
        require(!actionTarget.isJoined(address(token), SERVICE_ACTION_ID, GROUP_ID), "no snapshot written");
    }

    function testJoinedAmountFamilyProxiesCommunityStake() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        groupAction.setTotalStaked(address(token), 777e18);
        groupAction.setTotalStakedByMemberId(address(token), GROUP_ID, 123e18);

        require(executor.joinedAmount(address(token), SERVICE_ACTION_ID, SERVICE_ROUND) == 777e18, "action total");
        require(
            executor.joinedAmountByMemberId(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID) == 123e18,
            "member total"
        );
        require(
            executor.joinedAmount(address(token), SERVICE_ACTION_ID, SERVICE_ROUND + 1) == 0, "future round reads zero"
        );
        require(
            executor.joinedAmountByMemberId(address(token), SERVICE_ACTION_ID, SERVICE_ROUND + 1, GROUP_ID) == 0,
            "future round member reads zero"
        );

        // The proxy is the live community stake, not a per-round history.
        groupAction.setTotalStaked(address(token), 888e18);
        require(executor.joinedAmount(address(token), SERVICE_ACTION_ID, SERVICE_ROUND) == 888e18, "live value");
    }
}
