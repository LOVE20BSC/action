// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../src/ActionTarget.sol";
import {MockExecutor, MockMemberNFT, MockMint, MockPhase, MockToken, MockVote} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase, ActionTargetVm} from "./ActionTargetTestBase.sol";

contract ActionTargetHandler {
    ActionTargetVm internal constant vm =
        ActionTargetVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant MINT_AMOUNT = 1000;
    uint256 public constant BURN_AMOUNT = 640;
    uint256 public constant JOIN_PHASE = 6;
    uint256 internal constant ACTION_ID_BASE = 11;
    uint256 internal constant ACTION_COUNT = 4;
    uint256 internal constant ROUND_COUNT = 3;
    uint256 internal constant MEMBER_COUNT = 3;
    uint256 internal constant CREATE_PHASE = 5;

    ActionTarget public actionTarget;
    MockPhase public phaseContract;
    MockVote public vote;
    MockMint public mint;
    MockToken public token;
    MockMemberNFT public memberNFT;
    address public executorAddress;
    address public submitAddress;

    mapping(uint256 => bool) public created;
    mapping(uint256 => mapping(uint256 => bool)) public joined;
    mapping(uint256 => mapping(uint256 => bool)) public minted;
    mapping(uint256 => mapping(uint256 => bool)) public burned;

    constructor(
        address actionTarget_,
        address phase_,
        address vote_,
        address mint_,
        address token_,
        address memberNFT_,
        address executorAddress_,
        address submitAddress_
    ) {
        actionTarget = ActionTarget(actionTarget_);
        phaseContract = MockPhase(phase_);
        vote = MockVote(vote_);
        mint = MockMint(mint_);
        token = MockToken(token_);
        memberNFT = MockMemberNFT(memberNFT_);
        executorAddress = executorAddress_;
        submitAddress = submitAddress_;
    }

    function create(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        if (created[actionId]) return;
        created[actionId] = true;
        phaseContract.setPhase(CREATE_PHASE);
        bytes[] memory targetData = new bytes[](1);
        targetData[0] = abi.encode(executorAddress);
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(token), actionId, targetData);
        phaseContract.setPhase(JOIN_PHASE);
    }

    function join(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        uint256 memberId = seed % MEMBER_COUNT + 1;
        if (!created[actionId] || joined[actionId][memberId]) return;
        joined[actionId][memberId] = true;
        phaseContract.setPhase(JOIN_PHASE);
        vm.prank(executorAddress);
        actionTarget.registerJoinState(address(token), actionId, memberId);
    }

    function clear(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        uint256 memberId = seed % MEMBER_COUNT + 1;
        if (!joined[actionId][memberId]) return;
        joined[actionId][memberId] = false;
        phaseContract.setPhase(JOIN_PHASE);
        vm.prank(executorAddress);
        actionTarget.clearJoinState(address(token), actionId, memberId);
    }

    function forceExit(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        uint256 memberId = seed % MEMBER_COUNT + 1;
        if (!joined[actionId][memberId]) return;
        joined[actionId][memberId] = false;
        phaseContract.setPhase(JOIN_PHASE);
        vm.prank(memberNFT.ownerOf(memberId));
        actionTarget.forceExit(address(token), actionId, memberId);
    }

    function mintReward(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        uint256 round = seed % ROUND_COUNT;
        if (!created[actionId] || minted[actionId][round] || burned[actionId][round]) return;
        minted[actionId][round] = true;
        vote.setProposalVoted(address(token), round, actionId, true);
        vm.prank(executorAddress);
        actionTarget.mintActionReward(address(token), actionId, round);
    }

    function burn(uint256 seed) external {
        uint256 actionId = ACTION_ID_BASE + seed % ACTION_COUNT;
        uint256 round = seed % ROUND_COUNT;
        if (!created[actionId] || minted[actionId][round] || burned[actionId][round]) return;
        burned[actionId][round] = true;
        vote.setRoundEnded(round, true);
        mint.setProposalReward(address(token), round, actionId, BURN_AMOUNT, false);
        vm.prank(executorAddress);
        actionTarget.burnRewardIfNeeded(address(token), actionId, round);
    }

    function actionIdAt(uint256 index) external pure returns (uint256) {
        return ACTION_ID_BASE + index;
    }
}

contract ActionTargetInvariantTest is ActionTargetTestBase {
    ActionTargetHandler internal handler;

    function setUp() public override {
        super.setUp();
        executor.setNeedBurn(true);
        handler = new ActionTargetHandler(
            address(actionTarget),
            address(phase),
            address(vote),
            address(mint),
            address(token),
            address(memberNFT),
            address(executor),
            submitAddress
        );
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_MembershipMirrorsModel() public view {
        for (uint256 i = 0; i < 4; i++) {
            uint256 actionId = handler.actionIdAt(i);
            for (uint256 memberId = 1; memberId <= 3; memberId++) {
                require(
                    actionTarget.isJoined(address(token), actionId, memberId) == handler.joined(actionId, memberId),
                    "isJoined matches handler model"
                );
            }
        }
    }

    function invariant_MemberActionListsMatchModel() public view {
        for (uint256 memberId = 1; memberId <= 3; memberId++) {
            (uint256[] memory page, uint256 total) =
                actionTarget.actionIdsByMemberId(address(token), memberId, 0, 4, false);
            uint256 expectedTotal;
            for (uint256 i = 0; i < 4; i++) {
                if (handler.joined(handler.actionIdAt(i), memberId)) expectedTotal++;
            }
            require(total == expectedTotal && page.length == expectedTotal, "member list total");
            for (uint256 i = 0; i < page.length; i++) {
                require(handler.joined(page[i], memberId), "member list entry");
            }
        }
    }

    function invariant_ActionMemberListsMatchModel() public view {
        uint256 joinRound = handler.JOIN_PHASE() - 1;
        for (uint256 i = 0; i < 4; i++) {
            uint256 actionId = handler.actionIdAt(i);
            (uint256[] memory page, uint256 total) =
                actionTarget.memberIdsByActionId(address(token), actionId, joinRound, 0, 3, false);
            uint256 expectedTotal;
            for (uint256 memberId = 1; memberId <= 3; memberId++) {
                if (handler.joined(actionId, memberId)) expectedTotal++;
            }
            require(total == expectedTotal && page.length == expectedTotal, "action list total");
            for (uint256 j = 0; j < page.length; j++) {
                require(handler.joined(actionId, page[j]), "action list entry");
            }
        }
    }

    function invariant_CreationIndexesTrackHandler() public view {
        uint256 expectedTotal;
        for (uint256 i = 0; i < 4; i++) {
            if (handler.created(handler.actionIdAt(i))) expectedTotal++;
        }
        (uint256[] memory page,, uint256 total) = actionTarget.actions(address(token), 0, 4, false);
        require(total == expectedTotal && page.length == expectedTotal, "creation index total");
        for (uint256 i = 0; i < page.length; i++) {
            require(handler.created(page[i]), "creation index entry");
        }
        (uint256[] memory executorPage, uint256 executorTotal) =
            actionTarget.actionIdsByExecutor(address(token), address(executor), 0, 4, false);
        require(executorTotal == expectedTotal && executorPage.length == expectedTotal, "executor index total");
    }

    function invariant_BoundActionsPointToExecutor() public view {
        for (uint256 i = 0; i < 4; i++) {
            uint256 actionId = handler.actionIdAt(i);
            if (handler.created(actionId)) {
                require(actionTarget.executor(address(token), actionId) == address(executor), "bound executor");
            } else {
                require(actionTarget.executor(address(token), actionId) == address(0), "unbound stays zero");
            }
        }
    }

    function invariant_RewardLedgersMatchModel() public view {
        for (uint256 i = 0; i < 4; i++) {
            uint256 actionId = handler.actionIdAt(i);
            for (uint256 round = 0; round < 3; round++) {
                (uint256 amount, bool mintedFlag) = actionTarget.actionReward(address(token), actionId, round);
                if (handler.minted(actionId, round)) {
                    require(mintedFlag && amount == handler.MINT_AMOUNT(), "minted ledger");
                } else {
                    require(mintedFlag == false && amount == 0, "unminted ledger");
                }
                (uint256 burnedAmount, bool burnedFlag) = actionTarget.burnInfo(address(token), actionId, round);
                if (handler.burned(actionId, round)) {
                    require(burnedFlag && burnedAmount == handler.BURN_AMOUNT(), "burned ledger");
                } else {
                    require(burnedFlag == false && burnedAmount == 0, "unburned ledger");
                }
            }
        }
    }

    function invariant_PageTotalsMatchPageLengths() public view {
        (uint256[] memory page,, uint256 total) = actionTarget.actions(address(token), 0, 2, true);
        require(page.length == (total < 2 ? total : 2), "actions window");
        (page, total) = actionTarget.actionIdsByMemberId(address(token), 1, 1, 10, false);
        uint256 expected = total <= 1 ? 0 : (total - 1 < 10 ? total - 1 : 10);
        require(page.length == expected, "member window");
    }
}
