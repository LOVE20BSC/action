// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceExecutor} from "../src/GroupServiceExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {MockGroupServiceStake, MockGroupServiceToken} from "./mocks/GroupServiceMocks.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceInitTest is GroupServiceTestBase {
    function testInitStoresAddressesAndDerivesDependencies() external view {
        require(executor.actionTarget() == address(actionTarget), "action target stored");
        require(executor.initialized(), "initialized");
        // Derived dependencies are read back through the round getters: they
        // only answer when phaseAddress is wired.
        require(executor.currentVoteRound() == CREATION_PHASE, "vote round derives phase");
    }

    function testInitRejectsZeroAddresses() external {
        _expectInitRevert(address(0), address(stake), address(groupAction));
        _expectInitRevert(address(actionTarget), address(0), address(groupAction));
        _expectInitRevert(address(actionTarget), address(stake), address(0));
    }

    function testInitRejectsZeroDerivedAddresses() external {
        MockGroupServiceStake broken = new MockGroupServiceStake();
        broken.setPhaseAddress(address(phase));
        broken.setLaunchAddress(address(launch));

        GroupServiceExecutor fresh = new GroupServiceExecutor();
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidAddress.selector));
        fresh.init(address(actionTarget), address(broken), address(groupAction));
        require(!fresh.initialized(), "zero member nft leaves the flag clear");

        broken.setMemberNFTAddress(address(memberNFT));
        broken.setPhaseAddress(address(0));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidAddress.selector));
        fresh.init(address(actionTarget), address(broken), address(groupAction));
        require(!fresh.initialized(), "zero phase leaves the flag clear");

        broken.setPhaseAddress(address(phase));
        broken.setLaunchAddress(address(0));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidAddress.selector));
        fresh.init(address(actionTarget), address(broken), address(groupAction));
        require(!fresh.initialized(), "zero launch rejected too");

        broken.setLaunchAddress(address(launch));

        actionTarget.setMintAddress(address(0));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidAddress.selector));
        fresh.init(address(actionTarget), address(broken), address(groupAction));
        require(!fresh.initialized(), "zero mint leaves the flag clear");
        actionTarget.setMintAddress(address(mint));

        fresh.init(address(actionTarget), address(broken), address(groupAction));
        require(fresh.initialized(), "retry after fixing the dependency succeeds");
    }

    function testInitCannotRunTwice() external {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.AlreadyInitialized.selector));
        executor.init(address(actionTarget), address(stake), address(groupAction));
    }

    function testRoundGetters() external {
        _atPhase(0);
        _expectCurrentVoteRoundRevert();
        _expectCurrentJoinRoundRevert();
        _expectCurrentVerifyRoundRevert();
        _expectCurrentMintRoundRevert();

        _atPhase(1);
        require(executor.currentVoteRound() == 1, "vote round is the phase");
        _expectCurrentJoinRoundRevert();
        _expectCurrentVerifyRoundRevert();
        _expectCurrentMintRoundRevert();

        _atPhase(2);
        require(executor.currentVoteRound() == 2, "vote round tracks the phase");
        require(executor.currentJoinRound() == 1, "join round is the phase - 1");
        _expectCurrentVerifyRoundRevert();
        _expectCurrentMintRoundRevert();

        _atPhase(3);
        require(executor.currentJoinRound() == 2, "join round follows the phase");
        require(executor.currentVerifyRound() == 1, "verify round is the phase - 2");
        _expectCurrentMintRoundRevert();

        _atPhase(4);
        require(executor.currentVerifyRound() == 2, "verify round follows the phase");
        require(executor.currentMintRound() == 1, "mint round is the phase - 3");

        _atPhase(5);
        require(executor.currentMintRound() == 2, "mint round follows the phase");
    }

    function testConstants() external view {
        require(executor.PRECISION() == PRECISION, "precision");
        require(executor.DEFAULT_MAX_RECIPIENTS() == DEFAULT_MAX_RECIPIENTS, "max recipients");
    }

    function testOnProposalCreatedStoresConfiguration() external {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 3e18, PRECISION / 4);

        require(
            executor.ACTION_TOKEN_ADDRESS(address(token), SERVICE_ACTION_ID) == address(token), "action token bound"
        );
        require(executor.GOV_RATIO_MULTIPLIER(address(token), SERVICE_ACTION_ID) == 3e18, "multiplier bound");
        require(
            executor.RATIO_FOR_PUBLIC_VERIFIER(address(token), SERVICE_ACTION_ID) == PRECISION / 4,
            "verifier ratio bound"
        );

    }

    function testOnProposalCreatedAcceptsDirectParentToken() external {
        _atPhase(CREATION_PHASE);
        // The service token is the community token's direct parent.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 0, PRECISION);
        require(
            executor.ACTION_TOKEN_ADDRESS(address(token), SERVICE_ACTION_ID) == address(childToken),
            "child community token bound"
        );

        _atPhase(3);
        _createServiceActionOn(address(token), address(token), SERVICE_ACTION_ID + 1, 0, PRECISION);
        require(
            executor.ACTION_TOKEN_ADDRESS(address(token), SERVICE_ACTION_ID + 1) == address(token), "same token bound"
        );
    }

    function testOnProposalCreatedRejectsInvalidTargetData() external {
        _expectCreateRevert(address(token), _serviceTargetData(address(token), 0, 0), 3);
        _expectCreateRevert(address(token), _serviceTargetData(address(token), 0, 0), 5);
        _expectCreateRevert(address(token), _shortItemTargetData(), 4);
        _expectCreateRevert(address(token), _serviceTargetData(address(0), 0, PRECISION), 4);
        _expectCreateRevert(address(token), _serviceTargetData(address(token), 0, PRECISION + 1), 4);
    }

    function testOnProposalCreatedRejectsNonDirectTokenRelations() external {
        // Grandchild community token: only its direct parent may serve it.
        _expectCreateRevert(address(token), _serviceTargetData(address(grandChildToken), 0, PRECISION), 4);
        // A child service token cannot serve its own parent community.
        _expectCreateRevert(address(grandChildToken), _serviceTargetData(address(token), 0, PRECISION), 4);
        // Unrelated tokens in both directions.
        MockGroupServiceToken stranger = new MockGroupServiceToken();
        _expectCreateRevert(address(token), _serviceTargetData(address(stranger), 0, PRECISION), 4);
        _expectCreateRevert(address(childToken), _serviceTargetData(address(stranger), 0, PRECISION), 4);
    }

    function testOnProposalCreatedRejectsUnauthorizedCaller() external {
        _atPhase(CREATION_PHASE);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.UnauthorizedCallback.selector));
        executor.onProposalCreated(address(token), SERVICE_ACTION_ID, _serviceTargetData(address(token), 0, PRECISION));
    }

    function testOnProposalSubmittedChecksCallerOnly() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.UnauthorizedCallback.selector));
        executor.onProposalSubmitted(address(token), SERVICE_ACTION_ID, GROUP_ID, new bytes[](0));

        vm.prank(address(actionTarget));
        executor.onProposalSubmitted(address(token), SERVICE_ACTION_ID, GROUP_ID, new bytes[](0));
    }

    function testOnProposalVotedChecksCallerAndTargetData() external {
        bytes[] memory tooMany = new bytes[](2);
        tooMany[0] = abi.encode(address(executor));

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.UnauthorizedCallback.selector));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, tooMany);

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidTargetDataLength.selector));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, tooMany);

        bytes[] memory single = new bytes[](1);
        single[0] = abi.encode(address(executor));
        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, single);

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, new bytes[](0));
    }

    function _expectInitRevert(address actionTargetAddress, address stakeAddress, address groupActionExecutorAddress)
        internal
    {
        GroupServiceExecutor fresh = new GroupServiceExecutor();
        vm.prank(address(fresh));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidAddress.selector));
        fresh.init(actionTargetAddress, stakeAddress, groupActionExecutorAddress);
        require(!fresh.initialized(), "zero init argument leaves the flag clear");
    }

    function _expectCreateRevert(address serviceTokenAddress, bytes[] memory targetData, uint256 length) internal {
        bytes[] memory data = _clone(targetData);
        if (data.length < length) {
            bytes[] memory grown = new bytes[](length);
            for (uint256 i = 0; i < data.length; i++) {
                grown[i] = data[i];
            }
            data = grown;
        } else if (data.length > length) {
            bytes[] memory shrunk = new bytes[](length);
            for (uint256 i = 0; i < length; i++) {
                shrunk[i] = data[i];
            }
            data = shrunk;
        }
        _atPhase(CREATION_PHASE);
        vm.prank(address(actionTarget));
        vm.expectRevert();
        executor.onProposalCreated(serviceTokenAddress, SERVICE_ACTION_ID, data);
    }

    function _shortItemTargetData() internal view returns (bytes[] memory targetData) {
        targetData = new bytes[](4);
        targetData[0] = abi.encode(address(executor));
        targetData[1] = abi.encode(address(token));
        targetData[2] = new bytes(31);
        targetData[3] = abi.encode(PRECISION);
    }

    function _clone(bytes[] memory data) internal pure returns (bytes[] memory copy) {
        copy = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            copy[i] = data[i];
        }
    }

    function _expectCurrentVoteRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.currentVoteRound();
    }

    function _expectCurrentJoinRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.currentJoinRound();
    }

    function _expectCurrentVerifyRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.currentVerifyRound();
    }

    function _expectCurrentMintRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector));
        executor.currentMintRound();
    }
}
