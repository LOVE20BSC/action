// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";
import {GroupServiceTestBase} from "../GroupServiceTestBase.sol";

/// @notice Regression suite for the three settlement defects found by the audit repros.
/// @dev Mutable source mocks isolate accounting; not a full Core exploit. Each case used to
///      demonstrate a live-numerator / snapshot-divisor read that could overpay the action.
contract ServiceSettlementRegressionTest is GroupServiceTestBase {
    /// @dev Reading the owner weight from the served ledger while the divisor stayed behind let the
    ///      second owner spend past the service reward. Both sides are read live now, and a reward
    ///      move rescales them together.
    function testRegression_RewardMoveCannotOverpayTheBudget() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, 0);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(50e18, 50e18), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        token.mint(address(executor), SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        (uint256 first,) = _settleService(GROUP_ID);
        require(first == 450e18, "first owner receives half");

        // The served action's own reward doubles between the two settlements. Every action of the round
        // divides the same pool, so the divisor and both owners' slices rescale together.
        groupAction.setActionReward(address(token), GROUP_ACTION_ID, SERVICE_ROUND, 200e18);

        (uint256 second,) = _settleService(GROUP_OWNER_B_ID);
        require(second == 450e18, "second owner keeps the same share");
        require(first + second == SERVICE_REWARD, "budget held");
        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 200e18, "divisor follows the live reward"
        );
    }

    /// @dev An accepted extreme `govRatioMultiplier` used to overflow the cross-multiplied cap
    ///      comparison, reverting every settlement of the action and stranding its reward.
    function testRegression_MaxMultiplierStillSettles() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, type(uint256).max, 0);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(GROUP_REWARD), VERIFIER_ID);
        _armServiceReward(SERVICE_REWARD);
        stake.setTotalValidGovVotes(address(token), 1);
        stake.setValidGovVotes(address(token), GROUP_ID, 1);
        _atPhase(MINT_PHASE);

        // The cap never binds, so the theoretical owner reward is paid and nothing overflows.
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD, "theoretical owner reward paid");
        require(burnAmount == 0, "nothing burned");
    }

    /// @dev A zero-rated action stays out of the divisor and out of every weight, so it cannot collect
    ///      the same service reward twice. The guard lives in `generatedActionReward`, which refuses an
    ///      action with no final score at all.
    function testRegression_ZeroRatedActionContributesNothing() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyVerifier(VERIFIER_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(VERIFIER_ID);
        _joinService(GROUP_OWNER_B_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_OWNER_B_ID), _amounts(0), GROUP_OWNER_B_ID);
        _armServiceReward(SERVICE_REWARD);
        token.mint(address(executor), SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        require(
            executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18,
            "zero-rated action stays out of the divisor"
        );

        (uint256 first,) = _settleService(VERIFIER_ID);
        require(first == SERVICE_REWARD, "verifier takes the whole reward");

        (uint256 projected,,) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
        require(projected == 0, "zero-rated action projects nothing");

        vm.prank(GROUP_OWNER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector,
                address(token),
                SERVICE_ACTION_ID,
                GROUP_OWNER_B_ID,
                SERVICE_ROUND
            )
        );
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
    }
}
