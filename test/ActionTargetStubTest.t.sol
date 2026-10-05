// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../src/ActionTarget.sol";
import {IActionTargetErrors} from "../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract CallbackStub {
    address public phaseAddress;
    ActionTarget public target;

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setTarget(ActionTarget target_) external {
        target = target_;
    }

    function callCreated(address tokenAddress, uint256 proposalId, bytes[] calldata targetData) external {
        target.onProposalCreated(tokenAddress, proposalId, targetData);
    }

    function callSubmitted(
        address tokenAddress,
        uint256 proposalId,
        uint256 submitterId,
        bytes[] calldata targetData
    ) external {
        target.onProposalSubmitted(tokenAddress, proposalId, submitterId, targetData);
    }

    function callVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 votes,
        bytes[] calldata targetData
    ) external {
        target.onProposalVoted(tokenAddress, round, proposalId, voterId, votes, targetData);
    }
}

contract BrokenHandshakeExecutor {
    error HandshakeBroken();

    function actionTarget() external pure returns (address) {
        revert HandshakeBroken();
    }
}

contract ActionTargetStubTest is ActionTargetTestBase {
    CallbackStub internal stub;
    ActionTarget internal stubTarget;

    function setUp() public override {
        super.setUp();
        stub = new CallbackStub();
        stubTarget = new ActionTarget();
        stub.setPhaseAddress(address(phase));
        stubTarget.init(address(memberNFT), address(stub), address(stub), address(mint));
        stub.setTarget(stubTarget);
    }

    function testStubCallbacksRejectUnboundProposal() external {
        bytes[] memory targetData = _targetData(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.UnboundProposal.selector, address(token), 99)
        );
        stub.callSubmitted(address(token), 99, 7, targetData);

        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.UnboundProposal.selector, address(token), 98)
        );
        stub.callVoted(address(token), 3, 98, 5, 250, targetData);
        require(stubTarget.executor(address(token), 99) == address(0), "no binding created");
    }

    function testStubHandshakeRevertNormalizesToInvalidExecutor() external {
        BrokenHandshakeExecutor broken = new BrokenHandshakeExecutor();
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        stub.callCreated(address(token), 11, _targetData(address(broken)));
        require(stubTarget.executor(address(token), 11) == address(0), "no binding created");
    }

    function testStubTokenTransferFalseRevertsTransferFailed() external {
        _createAction(11);
        uint256 round = 5;
        vote.setProposalVoted(address(token), round, 11, true);
        token.setTransferResult(false);

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.TransferFailed.selector, address(token), address(executor), MINT_AMOUNT
            )
        );
        actionTarget.mintActionReward(address(token), 11, round);
        (uint256 amount, bool minted) = actionTarget.actionReward(address(token), 11, round);
        require(amount == 0 && minted == false, "ledger rolled back");
    }
}
