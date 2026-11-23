// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {IMemberRewardExecutor} from "../src/interfaces/IMemberRewardExecutor.sol";
import {LpExecutorTestBase} from "./LpExecutorTestBase.sol";

uint256 constant EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE = 4;
uint256 constant OVERSIZED_MEMBER_REWARD_BATCH_SIZE = EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE + 1;

contract LpMemberRewardBatchLimitTest is LpExecutorTestBase {
    function testLpRejectsAnOversizedMemberRewardBatch() external {
        uint256[] memory rounds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory actionIds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        vm.expectRevert(_tooManyItemsError());
        vm.prank(MEMBER1);
        IMemberRewardExecutor(address(lpExecutor)).mintMemberRewards(address(token), rounds, actionIds, 1);
    }
}

contract GroupActionMemberRewardBatchLimitTest is GroupActionExecutorTestBase {
    function testGroupActionRejectsAnOversizedMemberRewardBatch() external {
        uint256[] memory rounds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory actionIds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        vm.expectRevert(_tooManyItemsError());
        vm.prank(MEMBER1);
        IMemberRewardExecutor(address(executor)).mintMemberRewards(address(token), rounds, actionIds, MEMBER1_ID);
    }
}

contract GroupServiceMemberRewardBatchLimitTest is GroupServiceTestBase {
    event log_named_uint(
        string key,
        uint256 value
    );

    function testGroupServiceRejectsAnOversizedMemberRewardBatch() external {
        uint256[] memory rounds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory actionIds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        vm.expectRevert(_tooManyItemsError());
        vm.prank(GROUP_OWNER);
        IMemberRewardExecutor(address(executor)).mintMemberRewards(address(token), rounds, actionIds, GROUP_ID);
    }

    function testMemberRewardBatchChecksOwnerBeforeSize() external {
        uint256[] memory rounds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory actionIds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, GROUP_ID));
        vm.prank(MEMBER2);
        IMemberRewardExecutor(address(executor)).mintMemberRewards(address(token), rounds, actionIds, GROUP_ID);
    }

    function testMemberRewardBatchChecksArrayShapeBeforeSize() external {
        uint256[] memory rounds = new uint256[](EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory actionIds = new uint256[](OVERSIZED_MEMBER_REWARD_BATCH_SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.BatchLengthMismatch.selector,
                OVERSIZED_MEMBER_REWARD_BATCH_SIZE,
                EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE
            )
        );
        vm.prank(GROUP_OWNER);
        IMemberRewardExecutor(address(executor)).mintMemberRewards(address(token), rounds, actionIds, GROUP_ID);
    }

    function testMaximumMemberRewardBatchFitsThePublicGasBudget() external {
        uint256[] memory actionIds = new uint256[](EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE);
        uint256[] memory rounds = new uint256[](EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE);
        for (uint256 i; i < EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE; ++i) {
            actionIds[i] = SERVICE_ACTION_ID + i;
            rounds[i] = SERVICE_ROUND;
            _createServiceAction(actionIds[i], 0, 0.5e18);
        }

        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        for (uint256 i; i < EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE; ++i) {
            _joinServiceOn(actionIds[i], GROUP_ID);
            _armServiceRewardOn(actionIds[i], SERVICE_REWARD);
        }
        _atPhase(MINT_PHASE);

        uint256 beforeGas = gasleft();
        vm.prank(GROUP_OWNER);
        uint256[] memory amounts =
            IMemberRewardExecutor(address(executor)).mintMemberRewards(address(token), rounds, actionIds, GROUP_ID);
        uint256 gasUsed = beforeGas - gasleft();
        emit log_named_uint("maximum member reward batch gas", gasUsed);
        require(gasUsed < 10_000_000, "maximum member batch exceeds public gas budget");
        require(amounts.length == EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE, "maximum batch returns aligned amounts");
        for (uint256 i; i < amounts.length; ++i) {
            require(amounts[i] == SERVICE_REWARD / 2, "each service action pays its owner share");
        }
    }
}

function _tooManyItemsError() pure returns (bytes memory) {
    return abi.encodeWithSelector(
        IActionExecutorErrors.TooManyMemberRewardActions.selector,
        OVERSIZED_MEMBER_REWARD_BATCH_SIZE,
        EXPECTED_MAX_MEMBER_REWARD_BATCH_SIZE
    );
}
