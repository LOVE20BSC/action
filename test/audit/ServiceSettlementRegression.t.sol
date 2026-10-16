// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";
import {GroupServiceTestBase} from "../GroupServiceTestBase.sol";

/// @notice Regression suite for the three settlement defects found by the audit repros.
/// @dev Mutable source mocks isolate accounting; not a full Core exploit. Each case used to
///      demonstrate a live-book read that could overpay or brick the action, and now pins the
///      frozen-book behaviour that prevents it.
contract ServiceSettlementRegressionTest is GroupServiceTestBase {
    /// @dev Live owner weight against a frozen divisor: the second owner used to be able to spend
    ///      past the service reward because their slice was re-read from the served ledger.
    function testRegression_FrozenBookBlocksOwnerOverpay() external {
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

        // The served ledger doubles after the first settlement froze the round.
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID, SERVICE_ROUND, GROUP_ID, 100e18);
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID, SERVICE_ROUND, GROUP_OWNER_B_ID, 100e18);

        (uint256 second,) = _settleService(GROUP_OWNER_B_ID);
        require(second == 450e18, "second owner reads the frozen book");
        require(first + second == SERVICE_REWARD, "budget held");
        require(executor.totalGroupActionReward(address(token), SERVICE_ROUND) == 100e18, "frozen divisor persists");
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
        stake.setGlobalGovVotes(address(token), 1);
        stake.setValidGovVotes(address(token), GROUP_ID, 1);
        _atPhase(MINT_PHASE);

        // The cap never binds, so the theoretical owner reward is paid and nothing overflows.
        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        require(mintAmount == SERVICE_REWARD, "theoretical owner reward paid");
        require(burnAmount == 0, "nothing burned");
    }

    /// @dev A zero-rated action used to stay out of the cache, so a later ledger move handed it a
    ///      second helping of the same service reward.
    function testRegression_ZeroRatedActionStaysZero() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyCandidate(VERIFIER_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _joinService(VERIFIER_ID);
        _joinService(GROUP_OWNER_B_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100e18), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_OWNER_B_ID), _amounts(0), GROUP_OWNER_B_ID);
        _armServiceReward(SERVICE_REWARD);
        token.mint(address(executor), SERVICE_REWARD);
        _atPhase(MINT_PHASE);

        (uint256 first,) = _settleService(VERIFIER_ID);
        require(first == SERVICE_REWARD, "verifier takes the whole reward");

        // The zero-rated action gains a reward after the freeze: it stays frozen at zero.
        groupAction.setGroupReward(address(token), GROUP_ACTION_ID_B, SERVICE_ROUND, GROUP_OWNER_B_ID, 100e18);

        (uint256 projected,,) =
            executor.memberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
        require(projected == 0, "frozen zero stays zero");

        vm.prank(GROUP_OWNER_B);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NoRewardAvailable.selector));
        executor.mintMemberReward(address(token), SERVICE_ACTION_ID, GROUP_OWNER_B_ID, SERVICE_ROUND);
    }
}
