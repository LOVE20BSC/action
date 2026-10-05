// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../src/ActionTarget.sol";
import {MockExecutor, MockMemberNFT, MockMint, MockPhase, MockToken, MockVote} from "./mocks/ActionTargetMocks.sol";

interface ActionTargetVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata data) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function assume(bool condition) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

abstract contract ActionTargetTestBase {
    ActionTargetVm internal constant vm = ActionTargetVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MINT_AMOUNT = 1000;
    uint256 internal constant BURN_AMOUNT = 640;

    address internal constant SUBMIT_ADDRESS = address(0x5b1);
    address internal constant MEMBER1 = address(0x1001);
    address internal constant MEMBER2 = address(0x1002);
    address internal constant MEMBER3 = address(0x1003);
    address internal constant OUTSIDER = address(0x2001);

    ActionTarget internal actionTarget;
    MockPhase internal phase;
    MockVote internal vote;
    MockMint internal mint;
    MockToken internal token;
    MockMemberNFT internal memberNFT;
    MockExecutor internal executor;

    address internal submitAddress;
    address internal voteAddress;

    function setUp() public virtual {
        _deployMocks();
        actionTarget = new ActionTarget();
        executor = new MockExecutor(address(actionTarget));
        submitAddress = SUBMIT_ADDRESS;
        voteAddress = address(vote);
        phase.setPhase(1);
        mint.setVoteAddress(voteAddress);
        mint.setSubmitAddress(submitAddress);
        mint.setMemberNFTAddress(address(memberNFT));
        mint.setPhaseAddress(address(phase));
        actionTarget.init(address(mint));
    }

    function _deployMocks() internal {
        phase = new MockPhase();
        vote = new MockVote();
        mint = new MockMint();
        mint.setMintAmount(MINT_AMOUNT);
        token = new MockToken();
        memberNFT = new MockMemberNFT();
        memberNFT.setOwner(1, MEMBER1);
        memberNFT.setOwner(2, MEMBER2);
        memberNFT.setOwner(3, MEMBER3);
    }

    function _targetData(address executorAddress) internal pure returns (bytes[] memory targetData) {
        targetData = new bytes[](1);
        targetData[0] = abi.encode(executorAddress);
    }

    function _targetDataWithBusiness(address executorAddress, uint256 businessValue)
        internal
        pure
        returns (bytes[] memory targetData)
    {
        targetData = new bytes[](2);
        targetData[0] = abi.encode(executorAddress);
        targetData[1] = abi.encode(businessValue);
    }

    function _createAction(uint256 actionId) internal {
        _createAction(actionId, executor);
    }

    function _createAction(uint256 actionId, MockExecutor executor_) internal {
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(token), actionId, _targetData(address(executor_)));
    }

    function _join(uint256 actionId, uint256 memberId) internal {
        vm.prank(address(executor));
        actionTarget.registerJoinState(address(token), actionId, memberId);
    }

    function _clear(uint256 actionId, uint256 memberId) internal {
        vm.prank(address(executor));
        actionTarget.clearJoinState(address(token), actionId, memberId);
    }

    function _forceExit(uint256 actionId, uint256 memberId) internal {
        vm.prank(memberNFT.ownerOf(memberId));
        actionTarget.forceExit(address(token), actionId, memberId);
    }
}
