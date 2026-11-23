// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupServiceExecutorErrors} from "../src/interfaces/IGroupServiceExecutor.sol";
import {GroupServiceStorage} from "../src/GroupServiceStorage.sol";
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
        require(executor.MAX_RECIPIENTS_PER_ACTION() == MAX_RECIPIENTS_PER_ACTION, "max recipients");
        require(
            executor.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP()
                == GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP,
            "max recipient actions"
        );
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
        require(
            executor.providerIncentiveRatio(address(token), SERVICE_ACTION_ID) == 0,
            "Provider ratio defaults to the creation parameter"
        );

    }

    function testOnProposalCreatedStoresProviderIncentiveRatio() external {
        uint256 providerIncentiveRatio = PRECISION / 5;
        bytes memory creationData = abi.encode(address(token), 0, PRECISION / 2, providerIncentiveRatio);

        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), SERVICE_ACTION_ID, creationData);

        (bool success, bytes memory returnData) = address(executor).staticcall(
            abi.encodeWithSignature("providerIncentiveRatio(address,uint256)", address(token), SERVICE_ACTION_ID)
        );
        require(success, "service action exposes its fixed Provider ratio");
        require(abi.decode(returnData, (uint256)) == providerIncentiveRatio, "creation ratio is stored");
    }

    function testOnProposalCreatedRejectsProviderRatioAboveOneHundredPercent() external {
        bytes memory creationData = abi.encode(address(token), 0, PRECISION / 2, PRECISION + 1);
        vm.expectRevert(abi.encodeWithSignature("InvalidProviderIncentiveRatio(uint256)", PRECISION + 1));
        vm.prank(address(actionTarget));
        executor.onProposalCreated(address(token), SERVICE_ACTION_ID, creationData);
    }

    function testOnProposalCreatedAcceptsZeroAndFullProviderRatios() external {
        vm.prank(address(actionTarget));
        executor.onProposalCreated(
            address(token), SERVICE_ACTION_ID, abi.encode(address(token), 0, PRECISION / 2, 0)
        );
        vm.prank(address(actionTarget));
        executor.onProposalCreated(
            address(token), SERVICE_ACTION_ID + 1, abi.encode(address(token), 0, PRECISION / 2, PRECISION)
        );

        (bool zeroSuccess, bytes memory zeroData) = address(executor).staticcall(
            abi.encodeWithSignature("providerIncentiveRatio(address,uint256)", address(token), SERVICE_ACTION_ID)
        );
        (bool fullSuccess, bytes memory fullData) = address(executor).staticcall(
            abi.encodeWithSignature("providerIncentiveRatio(address,uint256)", address(token), SERVICE_ACTION_ID + 1)
        );
        require(zeroSuccess && abi.decode(zeroData, (uint256)) == 0, "zero market ratio is valid");
        require(fullSuccess && abi.decode(fullData, (uint256)) == PRECISION, "full market ratio is valid");
    }

    function testOnProposalCreatedAcceptsDirectParentToken() external {
        _atPhase(CREATION_PHASE);
        // The service token is the community token's direct parent.
        _createServiceActionOn(address(token), address(childToken), SERVICE_ACTION_ID, 0, PRECISION - 1);
        require(
            executor.actionTokenAddress(address(token), SERVICE_ACTION_ID) == address(childToken),
            "child community token bound"
        );

        _atPhase(3);
        _createServiceActionOn(address(token), address(token), SERVICE_ACTION_ID + 1, 0, PRECISION - 1);
        require(
            executor.actionTokenAddress(address(token), SERVICE_ACTION_ID + 1) == address(token), "same token bound"
        );
    }

    function testOnProposalCreatedRejectsInvalidCreationData() external {
        uint256 invalidTokenWord = (uint256(1) << 160) | uint160(address(token));
        _expectCreateRevert(
            address(token),
            new bytes(127),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidCreationDataLength.selector, 127, 128)
        );
        _expectCreateRevert(
            address(token),
            new bytes(129),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidCreationDataLength.selector, 129, 128)
        );
        _expectCreateRevert(
            address(token),
            abi.encode(invalidTokenWord, 0, PRECISION - 1, 0),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidCreationDataEncoding.selector)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(0), 0, PRECISION),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.ZeroActionTokenAddress.selector)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, PRECISION + 1),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidRatioForPublicVerifier.selector, PRECISION + 1)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, PRECISION),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidRatioForPublicVerifier.selector, PRECISION)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, 0),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidRatioForPublicVerifier.selector, 0)
        );
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(token), 0, PRECISION - 1, PRECISION + 1),
            abi.encodeWithSelector(IGroupServiceExecutorErrors.InvalidProviderIncentiveRatio.selector, PRECISION + 1)
        );
    }

    function testOnProposalCreatedRejectsNonDirectTokenRelations() external {
        // Grandchild community token: only its direct parent may serve it.
        _expectCreateRevert(
            address(token),
            _serviceTargetData(address(grandChildToken), 0, PRECISION - 1),
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
            _serviceTargetData(address(token), 0, PRECISION - 1),
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
            _serviceTargetData(address(stranger), 0, PRECISION - 1),
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ActionTokenParentMismatch.selector,
                address(stranger),
                address(token),
                address(0)
            )
        );
        _expectCreateRevert(
            address(childToken),
            _serviceTargetData(address(stranger), 0, PRECISION - 1),
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
        executor.onProposalCreated(address(token), SERVICE_ACTION_ID, "");
    }

    function testOnProposalSubmittedChecksCallerOnly() external {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(0xBEEF)));
        executor.onProposalSubmitted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, "");

        vm.prank(address(actionTarget));
        executor.onProposalSubmitted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, "");
    }

    function testOnProposalVotedChecksCallerAndData() external {
        bytes memory voteData = abi.encode(uint256(1));
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, address(0xBEEF)));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, voteData);

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(IGroupServiceExecutorErrors.UnexpectedVoteData.selector));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, voteData);

        vm.prank(address(actionTarget));
        executor.onProposalVoted(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 1, "");
    }

    function _expectCreateRevert(
        address serviceTokenAddress,
        bytes memory creationData,
        bytes memory expectedRevert
    ) internal {
        _atPhase(CREATION_PHASE);
        vm.prank(address(actionTarget));
        vm.expectRevert(expectedRevert);
        executor.onProposalCreated(serviceTokenAddress, SERVICE_ACTION_ID, creationData);
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
