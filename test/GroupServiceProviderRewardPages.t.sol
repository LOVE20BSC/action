// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {GroupRewardKey} from "../src/interfaces/IGroupActionVerify.sol";

contract GroupServiceProviderRewardPagesTest is GroupServiceTestBase {
    function testProviderPagesMatchSingleRewardQuotesAcrossGroupsAndActions() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _setGroupLedger(
            GROUP_ACTION_ID,
            _ids(GROUP_ID, GROUP_OWNER_B_ID),
            _amounts(100, 100),
            VERIFIER_ID
        );
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(900);

        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_ID, 100, MEMBER1_ID, 100
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID, GROUP_OWNER_B_ID, 100, MEMBER1_ID, 100
        );
        groupAction.setMarketScores(
            address(token), SERVICE_ROUND, GROUP_ACTION_ID_B, GROUP_ID, 100, MEMBER1_ID, 100
        );
        _atPhase(MINT_PHASE);

        (GroupRewardKey[] memory keys, uint256 total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, false);
        require(total == 3 && keys.length == 1, "first page count");
        _assertKey(keys[0], GROUP_ACTION_ID, GROUP_ID);
        _assertReward(keys[0], 75, false);

        (keys, total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 1, 1, false);
        require(total == 3 && keys.length == 1, "second page count");
        _assertKey(keys[0], GROUP_ACTION_ID, GROUP_OWNER_B_ID);
        _assertReward(keys[0], 75, false);

        (keys, total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 2, 1, false);
        require(total == 3 && keys.length == 1, "third page count");
        _assertKey(keys[0], GROUP_ACTION_ID_B, GROUP_ID);
        _assertReward(keys[0], 75, false);

        (keys, total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 0, 1, true);
        require(total == 3 && keys.length == 1, "reverse page count");
        _assertKey(keys[0], GROUP_ACTION_ID_B, GROUP_ID);

        (keys, total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 3, 1, false);
        require(total == 3 && keys.length == 0, "exhausted page count");

        vm.prank(MEMBER1);
        require(
            executor.mintProviderReward(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_OWNER_B_ID, MEMBER1_ID
            ) == 75,
            "selected provider reward paid"
        );
        (keys, total) =
            executor.providerRewardKeys(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, MEMBER1_ID, 1, 1, false);
        require(total == 3 && keys.length == 1, "page remains stable after mint");
        _assertKey(keys[0], GROUP_ACTION_ID, GROUP_OWNER_B_ID);
        _assertReward(keys[0], 75, true);
    }

    function _assertKey(GroupRewardKey memory key, uint256 sourceActionId, uint256 groupId) private pure {
        require(key.sourceActionId == sourceActionId && key.groupId == groupId, "page key order");
    }

    function _assertReward(GroupRewardKey memory key, uint256 expectedAmount, bool expectedMinted) private view {
        (uint256 amount, bool isMinted) = executor.providerReward(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, key.sourceActionId, key.groupId, MEMBER1_ID
        );
        require(amount == expectedAmount && isMinted == expectedMinted, "page quote matches single reward");
    }
}
