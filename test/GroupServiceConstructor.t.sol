// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {MockGroupServiceToken} from "./mocks/GroupServiceMocks.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

contract GroupServiceConstructorTest is GroupServiceTestBase {
    function testConstructorStoresAddressesAndDerivesDependencies() external view {
        require(executor.ACTION_TARGET_ADDRESS() == address(actionTarget), "action target stored");
        require(executor.GROUP_ACTION_EXECUTOR_ADDRESS() == address(groupAction), "group action executor stored");
        // Derived dependencies are read back through the round getters: they
        // only answer when phaseAddress is wired.
        require(executor.currentVoteRound() == CREATION_PHASE, "vote round derives phase");
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
            executor.actionTokenAddress(address(token), SERVICE_ACTION_ID) == address(token), "action token bound"
        );
        require(
            executor.joinTokenAddress(address(token), SERVICE_ACTION_ID) == address(token),
            "joined amount token bound"
        );
        require(executor.govRatioMultiplier(address(token), SERVICE_ACTION_ID) == 3e18, "multiplier bound");
        require(
            executor.publicVerifierRatio(address(token), SERVICE_ACTION_ID) == PRECISION / 4,
            "verifier ratio bound"
        );

    }

    function testOnProposalCreatedAcceptsDirectParentToken() external {
        _atPhase(CREATION_PHASE);
        // The service token is the community token's direct parent.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 0, PRECISION);
        require(
            executor.actionTokenAddress(address(token), SERVICE_ACTION_ID) == address(childToken),
            "child community token bound"
        );

        _atPhase(3);
        _createServiceActionOn(address(token), address(token), SERVICE_ACTION_ID + 1, 0, PRECISION);
        require(
            executor.actionTokenAddress(address(token), SERVICE_ACTION_ID + 1) == address(token), "same token bound"
        );
    }

    function testOnProposalCreatedRejectsInvalidTargetData() external {
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, 0),
            3,
            abi.encodeWithSelector(IGroupServiceExecutorErrors.TargetDataLengthMismatch.selector, 4, 3)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, 0),
            5,
            abi.encodeWithSelector(IGroupServiceExecutorErrors.TargetDataLengthMismatch.selector, 4, 5)
        );
        _expectCreateRevert(
            address(token),
            _shortItemTargetData(),
            4,
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidTargetDataShape.selector, 2, 31)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(0), 0, PRECISION),
            4,
            abi.encodeWithSelector(IGroupServiceExecutorErrors.ZeroActionTokenAddress.selector)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, PRECISION + 1),
            4,
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidRatioForPublicVerifier.selector, PRECISION + 1)
        );
    }

    function testOnProposalCreatedRejectsNonDirectTokenRelations() external {
        // Grandchild community token: only its direct parent may serve it.
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(grandChildToken), 0, PRECISION),
            4,
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ActionTokenParentMismatch.selector,
                address(grandChildToken),
                address(token),
                address(childToken)
            )
        );
        // A child service token cannot serve its own parent community.
        _expectCreateRevert(
            address(grandChildToken),
            _serviceTargetData(address(token), 0, PRECISION),
            4,
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ActionTokenParentMismatch.selector,
                address(token),
                address(grandChildToken),
                address(0)
            )
        );
        // Unrelated tokens in both directions.
        MockGroupServiceToken stranger = new MockGroupServiceToken();
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(stranger), 0, PRECISION),
            4,
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ActionTokenParentMismatch.selector,
                address(stranger),
                address(token),
                address(0)
            )
        );
        _expectCreateRevert(
            address(childToken),
            _serviceTargetData(address(stranger), 0, PRECISION),
            4,
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ActionTokenParentMismatch.selector,
                address(stranger),
                address(childToken),
                address(0)
            )
        );
    }

    function testOnProposalCreatedRejectsUnauthorizedCaller() external {
        _atPhase(CREATION_PHASE);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(0xBEEF)));
        executor.onProposalCreated(address(token), SERVICE_ACTION_ID, _serviceTargetData(address(token), 0, PRECISION));
    }

    function testOnProposalSubmittedChecksCallerOnly() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(0xBEEF)));
        executor.onProposalSubmitted(address(token), SERVICE_ACTION_ID, GROUP_ID, new bytes[](0));

        vm.prank(address(actionTarget));
        executor.onProposalSubmitted(address(token), SERVICE_ACTION_ID, GROUP_ID, new bytes[](0));
    }

    function testOnProposalVotedChecksCallerAndTargetData() external {
        bytes[] memory tooMany = new bytes[](2);
        tooMany[0] = abi.encode(address(executor));

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(0xBEEF)));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, tooMany);

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.TargetDataLengthMismatch.selector, 1, 2));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, tooMany);

        bytes[] memory single = new bytes[](1);
        single[0] = abi.encode(address(executor));
        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, single);

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, new bytes[](0));
    }

    function _expectCreateRevert(
        address serviceTokenAddress,
        bytes[] memory targetData,
        uint256 length,
        bytes memory expectedRevert
    ) internal {
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
        vm.expectRevert(expectedRevert);
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
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.currentVoteRound();
    }

    function _expectCurrentJoinRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.currentJoinRound();
    }

    function _expectCurrentVerifyRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.currentVerifyRound();
    }

    function _expectCurrentMintRoundRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        executor.currentMintRound();
    }
}
