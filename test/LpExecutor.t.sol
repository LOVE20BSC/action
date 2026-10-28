// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LpExecutor} from "../src/LpExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {ILpExecutorErrors} from "../src/interfaces/ILpExecutor.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MockLpActionTarget,
    MockLpMemberNFT,
    MockLpPhase,
    MockRevertingPair,
    MockRevertingPairFactory,
    MockRevertingPairToken1
} from "./mocks/LpExecutorMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair} from "./mocks/UniswapV2Mocks.sol";
import {LpExecutorTestBase} from "./LpExecutorTestBase.sol";

contract LpExecutorTest is LpExecutorTestBase {
    function _cloneTargetData() internal view returns (bytes[] memory copy) {
        bytes[] memory data = _targetData();
        copy = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            copy[i] = data[i];
        }
    }

    function testInitDerivesDependenciesFromStake() external {
        require(lpExecutor.initialized(), "initialized");
        require(lpExecutor.actionTarget() == address(actionTarget), "action target bound");

        MockLpPhase otherPhase = new MockLpPhase();
        otherPhase.setCurrentPhase(7);
        stake.setPhaseAddress(address(otherPhase));
        LpExecutor freshPhase = new LpExecutor();
        freshPhase.init(address(actionTarget), address(stake));
        require(freshPhase.currentJoinRound() == 6, "phase derived from stake");
        stake.setPhaseAddress(address(phase));

        MockLpMemberNFT otherMemberNFT = new MockLpMemberNFT();
        otherMemberNFT.setOwner(1, MEMBER2);
        stake.setMemberNFTAddress(address(otherMemberNFT));
        LpExecutor freshMemberNFT = new LpExecutor();
        freshMemberNFT.init(address(actionTarget), address(stake));
        vm.prank(address(actionTarget));
        freshMemberNFT.onProposalCreated(address(token), ACTION_ID, _targetData());
        vm.prank(MEMBER2);
        joinToken.approve(address(freshMemberNFT), type(uint256).max);
        vm.prank(MEMBER2);
        freshMemberNFT.join(address(token), ACTION_ID, 1, 1e18);
        require(
            freshMemberNFT.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 1e18,
            "member NFT derived from stake"
        );
        stake.setMemberNFTAddress(address(memberNFT));

        MockUniswapV2Factory emptyFactory = new MockUniswapV2Factory();
        stake.setPairFactoryAddress(address(emptyFactory));
        LpExecutor freshFactory = new LpExecutor();
        freshFactory.init(address(actionTarget), address(stake));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidJoinTokenFactory.selector, address(joinToken), address(emptyFactory)));
        freshFactory.onProposalCreated(address(token), ACTION_ID, _targetData());
        stake.setPairFactoryAddress(address(factory));
    }

    function testInitIsPermissionless() external {
        LpExecutor fresh = new LpExecutor();
        vm.prank(OUTSIDER);
        fresh.init(address(actionTarget), address(stake));
        require(fresh.initialized(), "outsider init succeeds");
        require(fresh.actionTarget() == address(actionTarget), "binding set");
    }

    function testInitRejectsSecondCall() external {
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.AlreadyInitialized.selector));
        lpExecutor.init(address(actionTarget), address(stake));
        require(lpExecutor.actionTarget() == address(actionTarget), "binding unchanged");
    }

    function testCreateStoresConfig() external view {
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), ACTION_ID) == address(joinToken),
            "join token stored"
        );
        require(
            lpExecutor.GOV_RATIO_MULTIPLIER(address(token), ACTION_ID) == GOV_RATIO_MULTIPLIER,
            "multiplier stored"
        );
        require(lpExecutor.MIN_GOV_RATIO(address(token), ACTION_ID) == MIN_GOV_RATIO, "min ratio stored");
    }

    function testCreateRejectsNonActionTargetCaller() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, _targetData());
    }

    function testCreateRejectsWrongItemCount() external {
        uint256[3] memory counts = [uint256(0), 3, 5];
        for (uint256 c = 0; c < counts.length; c++) {
            bytes[] memory targetData = new bytes[](counts[c]);
            for (uint256 i = 0; i < counts[c]; i++) {
                targetData[i] = abi.encode(uint256(i));
            }
            vm.prank(address(actionTarget));
            vm.expectRevert(
                abi.encodeWithSelector(ILpExecutorErrors.TargetDataLengthMismatch.selector, 4, counts[c])
            );
            lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
        }
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), SECOND_ACTION_ID) == address(0),
            "nothing stored"
        );
    }

    function testCreateRejectsMalformedItemLengths() external {
        uint256[4] memory lengths = [uint256(0), 31, 33, 64];
        for (uint256 position = 0; position < 4; position++) {
            for (uint256 i = 0; i < lengths.length; i++) {
                bytes[] memory targetData = _cloneTargetData();
                targetData[position] = new bytes(lengths[i]);
                vm.prank(address(actionTarget));
                vm.expectRevert(
                    abi.encodeWithSelector(ILpExecutorErrors.InvalidTargetDataShape.selector, position, lengths[i])
                );
                lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
            }
        }
    }

    function testCreateRejectsZeroJoinToken() external {
        bytes[] memory targetData = _cloneTargetData();
        targetData[1] = abi.encode(address(0));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.ZeroJoinTokenAddress.selector));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
    }

    function testCreateRejectsUnregisteredJoinToken() external {
        address[6] memory candidates = [
            address(0xdead),
            address(lpBaseToken),
            address(new MockUniswapV2Pair(address(token), address(lpBaseToken))),
            address(new MockUniswapV2Pair(address(token), address(token))),
            address(new MockRevertingPair()),
            address(new MockRevertingPairToken1(address(token)))
        ];
        for (uint256 i = 0; i < candidates.length; i++) {
            bytes[] memory targetData = _cloneTargetData();
            targetData[1] = abi.encode(candidates[i]);
            vm.prank(address(actionTarget));
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILpExecutorErrors.InvalidJoinTokenFactory.selector, candidates[i], address(factory)
                )
            );
            lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
        }
    }

    function testCreateRejectsRevertingFactory() external {
        address revertingFactory = address(new MockRevertingPairFactory());
        stake.setPairFactoryAddress(revertingFactory);
        LpExecutor freshReverting = new LpExecutor();
        freshReverting.init(address(actionTarget), address(stake));
        vm.prank(address(actionTarget));
        vm.expectRevert(
            abi.encodeWithSelector(
                ILpExecutorErrors.InvalidJoinTokenFactory.selector, address(joinToken), revertingFactory
            )
        );
        freshReverting.onProposalCreated(address(token), ACTION_ID, _targetData());

        stake.setPairFactoryAddress(address(factory));
        _createAction(SECOND_ACTION_ID);
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), SECOND_ACTION_ID) == address(joinToken),
            "valid create succeeds"
        );
    }

    function testCreateRejectsMinGovRatioAbovePrecision() external {
        bytes[] memory targetData = _cloneTargetData();
        targetData[3] = abi.encode(PRECISION + 1);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidMinGovRatio.selector, PRECISION + 1));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
    }

    function testCreateAcceptsBoundaryConfigs() external {
        bytes[] memory targetData = _cloneTargetData();
        targetData[2] = abi.encode(uint256(0));
        targetData[3] = abi.encode(PRECISION);
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
        require(lpExecutor.GOV_RATIO_MULTIPLIER(address(token), SECOND_ACTION_ID) == 0, "zero multiplier");
        require(lpExecutor.MIN_GOV_RATIO(address(token), SECOND_ACTION_ID) == PRECISION, "full min ratio");
    }

    function testCreateRollsBackOnFailure() external {
        bytes[] memory targetData = _cloneTargetData();
        targetData[3] = abi.encode(PRECISION + 1);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidMinGovRatio.selector, PRECISION + 1));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);

        require(
            lpExecutor.GOV_RATIO_MULTIPLIER(address(token), SECOND_ACTION_ID) == 0,
            "multiplier not stored"
        );
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), SECOND_ACTION_ID) == address(0),
            "join token not stored"
        );

        _createAction(SECOND_ACTION_ID);
        require(
            lpExecutor.GOV_RATIO_MULTIPLIER(address(token), SECOND_ACTION_ID) == GOV_RATIO_MULTIPLIER,
            "retry succeeds"
        );
    }

    function testSubmittedCallbackGatesCaller() external {
        vm.prank(address(actionTarget));
        lpExecutor.onProposalSubmitted(address(token), ACTION_ID, 1, _targetData());

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalSubmitted(address(token), ACTION_ID, 1, _targetData());
    }

    function testVotedCallbackGatesCallerAndDataLength() external {
        vm.prank(address(actionTarget));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, new bytes[](0));

        bytes[] memory oneItem = new bytes[](1);
        oneItem[0] = abi.encode(address(lpExecutor));
        vm.prank(address(actionTarget));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, oneItem);

        bytes[] memory twoItems = new bytes[](2);
        twoItems[0] = abi.encode(address(lpExecutor));
        twoItems[1] = abi.encode(uint256(1));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.TargetDataLengthMismatch.selector, 1, 2));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, twoItems);

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, new bytes[](0));
    }

    function testJoinRecordsDeductionAtPhaseStart() external {
        _atPhaseBlock(3, 3000);
        uint256 executorBefore = joinToken.balanceOf(address(lpExecutor));
        _join(1, 100e18);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 100e18, "total joined");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 100e18,
            "member joined"
        );
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "no deduction at start");

        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 0, "deduction zero");
        require(blocks.length == 1 && blocks[0] == 3000, "join block recorded");
        require(amounts.length == 1 && amounts[0] == 100e18, "join amount recorded");

        require(joinToken.balanceOf(address(lpExecutor)) - executorBefore == 100e18, "lp deposited");
        require(actionTarget.registerCalls() == 1, "join state registered");
        require(actionTarget.lastRegisterTokenAddress() == address(token), "token forwarded");
        require(actionTarget.lastRegisterActionId() == ACTION_ID, "action forwarded");
        require(actionTarget.lastRegisterMemberId() == 1, "member forwarded");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1), "target state joined");
    }

    function testJoinAccumulatesDeductionWithinRound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(3, 3400);
        _join(1, 50e18);

        (uint256 deduction,, uint256[] memory amounts) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 20e18, "second join deduction");
        require(amounts.length == 2 && amounts[0] == 100e18 && amounts[1] == 50e18, "both amounts recorded");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 150e18, "balance sum");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 150e18, "total sum");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 20e18, "total deduction sum");
    }

    function testJoinUsesJoinPhaseInfoAndFreezesDeduction() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        phase.setPhaseInfo(3, 3000, 500);
        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 30e18, "recorded deduction is frozen");

        phase.setPhaseInfo(4, 4000, 250);
        _atPhaseBlock(4, 4100);
        _join(1, 100e18);
        (deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 3, 1);
        require(deduction == 40e18, "next round uses its own phase window");
    }

    function testJoinAtLastBlockOfPhase() external {
        _atPhaseBlock(3, 3999);
        _join(1, 100e18);
        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 999e17, "deduction near full phase");
    }

    function testJoinCapsDeductionAtAmount() external {
        phase.setPhaseInfo(3, 3000, 100);
        _atPhaseBlock(3, 3200);
        _join(1, 7);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 7, "deduction capped at the join amount");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 7, "total deduction capped");
    }

    function testJoinRequiresMemberOwner() external {
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "nothing recorded");
    }

    function testJoinChecksOwnerBeforeAmount() external {
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.join(address(token), ACTION_ID, 1, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.ZeroParticipationAmount.selector));
        lpExecutor.join(address(token), ACTION_ID, 1, 0);
    }

    function testJoinFirstRequiresMinGovRatio() external {
        _join(3, 1e18);
        _join(1, 1e18);

        stake.setValidGovVotes(address(token), 2, 99e18);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, 1e17, 99e15));
        lpExecutor.join(address(token), ACTION_ID, 2, 1e18);
        require(actionTarget.isJoined(address(token), ACTION_ID, 2) == false, "not registered");
    }

    function testJoinSecondSkipsGovCheck() external {
        _join(1, 10e18);
        stake.setValidGovVotes(address(token), 1, 1);
        _join(1, 10e18);
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 20e18, "second join allowed");
        require(actionTarget.registerCalls() == 1, "registered once");
    }

    function testJoinSkipsGovCheckForPreJoinedMember() external {
        actionTarget.setJoined(address(token), ACTION_ID, 2, true);
        stake.setValidGovVotes(address(token), 2, 0);
        _join(2, 1e18);
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 2) == 1e18, "join allowed");
        require(actionTarget.registerCalls() == 0, "already registered member");
    }

    function testJoinZeroTotalValidGovVotesRequiresZeroMinRatio() external {
        stake.setTotalValidGovVotes(address(token), 0);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, 1e17, 0));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);

        _createActionWithConfig(SECOND_ACTION_ID, GOV_RATIO_MULTIPLIER, 0);
        _join(SECOND_ACTION_ID, 1, 1e18);
        require(
            lpExecutor.joinedAmountByMemberId(address(token), SECOND_ACTION_ID, 2, 1) == 1e18,
            "zero min ratio opens admission"
        );
    }

    function testJoinPropagatesRegisterFailureAndRollsBack() external {
        actionTarget.setRevertRegister(true);
        _atPhaseBlock(3, 3300);
        uint256 memberBefore = joinToken.balanceOf(MEMBER1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(MockLpActionTarget.RegisterJoinStateReverted.selector));
        lpExecutor.join(address(token), ACTION_ID, 1, 100e18);

        require(joinToken.balanceOf(MEMBER1) == memberBefore, "transfer rolled back");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "total rolled back");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction rolled back");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 0 && blocks.length == 0 && amounts.length == 0, "records rolled back");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target state untouched");
    }

    function testJoinTransferFailureRollsBack() external {
        joinToken.setFailTransferFrom(true);
        _atPhaseBlock(3, 3300);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(joinToken)));
        lpExecutor.join(address(token), ACTION_ID, 1, 100e18);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "ledger rolled back");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target rolled back");
    }

    function testJoinRoundFollowsPhaseMapping() external {
        _atPhase(1);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);

        _atPhase(5);
        _join(1, 100e18);
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 4) == 100e18, "join round 4");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 3) == 0, "round 3 untouched");
    }

    function testJoinBalancesCarryAcrossRounds() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(4, 4300);
        _join(1, 50e18);

        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 100e18,
            "round 2 frozen"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 3, 1) == 150e18,
            "round 3 carries the balance"
        );
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "round 2 deduction");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 3) == 15e18, "round 3 deduction only");
    }

    function testWithdrawPartialRoundsDeductionDown() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _withdraw(1, 40e18);

        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 160e18, "balance reduced");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 160e18, "total reduced");
        (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 24e18, "deduction scaled down");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 24e18, "total deduction scaled");
        require(joinToken.balanceOf(MEMBER1) - memberBefore == 40e18, "part returned");
        require(actionTarget.clearCalls() == 0, "partial withdraw keeps the join state");
    }

    function testWithdrawPartialKeepsJoinRecords() external {
        phase.setPhaseInfo(3, 3000, 7);
        _atPhaseBlock(3, 3003);
        _join(1, 7);

        (uint256 deductionBefore,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deductionBefore == 3, "deduction 3 of 7");
        _withdraw(1, 2);

        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 5, "balance 5");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 3, "deduction stays 3");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 3, "total deduction stays 3");
        require(blocks.length == 1 && amounts.length == 1 && amounts[0] == 7, "join records retained");
    }

    function testWithdrawFullAutoExits() external {
        phase.setPhaseInfo(3, 3000, 7);
        _atPhaseBlock(3, 3003);
        _join(1, 7);
        _withdraw(1, 2);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _withdraw(1, 5);

        require(joinToken.balanceOf(MEMBER1) - memberBefore == 5, "remainder returned");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 0, "balance cleared");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "total cleared");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction taken");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 0 && blocks.length == 0 && amounts.length == 0, "records cleared");
        require(actionTarget.clearCalls() == 1, "join state cleared");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target cleared");
    }

    function testWithdrawFullAfterDeductionTakesRemainder() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        _withdraw(1, 100e18);
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction taken exactly");
    }

    function testWithdrawUpdatesOnlyCurrentRound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(4, 4000);
        _withdraw(1, 40e18);

        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 100e18,
            "past round frozen"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 3, 1) == 60e18,
            "current round reduced"
        );
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 100e18, "past total frozen");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 3) == 60e18, "current total reduced");
    }

    function testWithdrawRejectsZeroAndOverdraft() external {
        _join(1, 10e18);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.ZeroParticipationAmount.selector));
        lpExecutor.withdraw(address(token), ACTION_ID, 1, 0);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(ILpExecutorErrors.WithdrawAmountExceeded.selector, 10e18 + 1, 10e18)
        );
        lpExecutor.withdraw(address(token), ACTION_ID, 1, 10e18 + 1);
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 10e18, "balance retained");
    }

    function testWithdrawRequiresMemberOwner() external {
        _join(1, 10e18);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.withdraw(address(token), ACTION_ID, 1, 1);
    }

    function testWithdrawNeedsNoWaitingPeriod() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        _withdraw(1, 40e18);
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 60e18, "same block withdraw");
    }

    function testWithdrawAfterFullRevertsInvalidAmount() external {
        _join(1, 10e18);
        _withdraw(1, 10e18);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.WithdrawAmountExceeded.selector, 1, 0));
        lpExecutor.withdraw(address(token), ACTION_ID, 1, 1);
    }

    function testWithdrawPropagatesClearFailureAndRollsBack() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        actionTarget.setRevertClear(true);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(MockLpActionTarget.ClearJoinStateReverted.selector));
        lpExecutor.withdraw(address(token), ACTION_ID, 1, 100e18);

        require(joinToken.balanceOf(MEMBER1) == memberBefore, "transfer rolled back");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 100e18, "balance retained");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 30e18, "deduction retained");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1), "target state retained");
    }

    function testExitReturnsBalanceAndClearsState() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _exit(1);

        require(joinToken.balanceOf(MEMBER1) - memberBefore == 100e18, "balance returned");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 0, "member cleared");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 0, "total cleared");
        require(lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == 0, "deduction taken");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), ACTION_ID, 2, 1);
        require(deduction == 0 && blocks.length == 0 && amounts.length == 0, "records cleared");
        require(actionTarget.clearCalls() == 1, "join state cleared");
    }

    function testExitRequiresOwnerBeforeJoinedCheck() external {
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.exit(address(token), ACTION_ID, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(ILpExecutorErrors.NotJoined.selector, address(token), ACTION_ID, uint256(1))
        );
        lpExecutor.exit(address(token), ACTION_ID, 1);
    }

    function testExitInheritsBalanceFromPastRound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _exit(1);

        require(joinToken.balanceOf(MEMBER1) - memberBefore == 100e18, "inherited balance returned");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 100e18, "past round retained");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 4) == 0, "current round cleared");
    }

    function testExitTwiceRevertsNotJoined() external {
        _join(1, 10e18);
        _exit(1);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(ILpExecutorErrors.NotJoined.selector, address(token), ACTION_ID, uint256(1))
        );
        lpExecutor.exit(address(token), ACTION_ID, 1);
    }

    function testExitPropagatesClearFailureAndRollsBack() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);
        actionTarget.setRevertClear(true);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(MockLpActionTarget.ClearJoinStateReverted.selector));
        lpExecutor.exit(address(token), ACTION_ID, 1);

        require(joinToken.balanceOf(MEMBER1) == memberBefore, "transfer rolled back");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 1) == 100e18, "balance retained");
    }

    function testMintMemberRewardSettlesWithGovCap() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        uint256 memberBefore = token.balanceOf(MEMBER1);
        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);

        require(mintAmount == 200e18, "mint capped by gov ratio");
        require(burnAmount == 800e18, "theoretical minus mint burned");
        require(token.balanceOf(MEMBER1) - memberBefore == 200e18, "mint transferred");
        require(token.burnCalls() == 1 && token.lastBurnAmount() == 800e18, "burn called once");
        require(actionTarget.mintRewardCalls() == 1, "action reward pulled once");
        require(actionTarget.lastMintTokenAddress() == address(token), "token forwarded");
        require(actionTarget.lastMintActionId() == ACTION_ID, "action forwarded");
        require(actionTarget.lastMintRound() == 2, "round forwarded");

        (uint256 recordedMint, uint256 recordedBurn, bool minted) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(minted && recordedMint == 200e18 && recordedBurn == 800e18, "settlement recorded");
        (uint256 ratio, bool ratioMinted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(ratioMinted && ratio == 1e17, "gov ratio snapshot at mint");
    }

    function testMintMemberRewardSplitsBetweenMembers() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhaseBlock(3, 3500);
        _join(SECOND_ACTION_ID, 2, 100e18);
        _atPhase(4);
        _setActionReward(SECOND_ACTION_ID, 2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mint1, uint256 burn1) = _mintMemberReward(SECOND_ACTION_ID, 1, 2);
        (uint256 mint2, uint256 burn2) = _mintMemberReward(SECOND_ACTION_ID, 2, 2);

        require(mint1 == 666666666666666666666 && burn1 == 0, "member 1 proportional share");
        require(mint2 == 333333333333333333333 && burn2 == 0, "member 2 proportional share");
        require(mint1 + mint2 <= PROPOSAL_REWARD, "not over budget");
    }

    function testMintMemberRewardKeepsZeroBurnWhenCapDoesNotBind() external {
        _createActionWithConfig(SECOND_ACTION_ID, 10e18, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhaseBlock(3, 3500);
        _join(SECOND_ACTION_ID, 2, 100e18);
        _atPhase(4);
        _setActionReward(SECOND_ACTION_ID, 2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mint1, uint256 burn1) = _mintMemberReward(SECOND_ACTION_ID, 1, 2);
        (uint256 mint2, uint256 burn2) = _mintMemberReward(SECOND_ACTION_ID, 2, 2);

        require(mint1 == 666666666666666666666 && burn1 == 0, "truncated ratio must not burn");
        require(mint2 == 333333333333333333333 && burn2 == 0, "truncated ratio must not burn");
    }

    function testMintMemberRewardWithCapDisabled() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhase(4);
        _setActionReward(SECOND_ACTION_ID, 2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(SECOND_ACTION_ID, 1, 2);
        require(mintAmount == PROPOSAL_REWARD, "full theoretical reward");
        require(burnAmount == 0, "no burn with cap disabled");
        require(token.burnCalls() == 0, "burn not called");
    }

    function testMintMemberRewardBurnsAllWhenNoGovVotes() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        stake.setTotalValidGovVotes(address(token), 0);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        uint256 memberBefore = token.balanceOf(MEMBER1);
        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(mintAmount == 0, "nothing minted");
        require(burnAmount == PROPOSAL_REWARD, "theoretical reward burned");
        require(token.balanceOf(MEMBER1) == memberBefore, "no transfer");
        require(token.burnCalls() == 1 && token.lastBurnAmount() == PROPOSAL_REWARD, "pure burn");
    }

    function testMintMemberRewardMintsAllWhenCapAboveLpRatio() external {
        stake.setValidGovVotes(address(token), 1, 1000e18);
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(mintAmount == PROPOSAL_REWARD && burnAmount == 0, "lp ratio is the cap");
        require(token.burnCalls() == 0, "no burn");
    }

    function testMintMemberRewardUsesMintedActionRewardWithoutPull() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, 500e18, true);
        _fundExecutor(500e18);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(actionTarget.mintRewardCalls() == 0, "no pull after the action was minted");
        require(mintAmount == 100e18 && burnAmount == 400e18, "settled against the recorded amount");
    }

    function testMintMemberRewardUsesPullReturnedAmount() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, 500e18, false);
        actionTarget.setMintReturnAmount(700e18);
        _fundExecutor(700e18);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(actionTarget.mintRewardCalls() == 1, "pull executed");
        require(mintAmount == 140e18 && burnAmount == 560e18, "the pull return drives the split");
    }

    function testMintMemberRewardRevertsOnZeroEffective() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _withdraw(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
        require(actionTarget.mintRewardCalls() == 0, "no pull without effective participation");
        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(!minted, "not marked minted");
    }

    function testMintMemberRewardRevertsForNonParticipant() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);

        uint256 memberBefore = token.balanceOf(MEMBER2);
        vm.prank(MEMBER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), ACTION_ID, 2, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 2, 2);
        require(token.balanceOf(MEMBER2) == memberBefore, "no transfer");
        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 2, 2);
        require(!minted, "not marked minted");
    }

    function testMintMemberRewardRevertsOnZeroProposalReward() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, 0, false);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
        require(actionTarget.mintRewardCalls() == 0, "no pull with zero reward");
    }

    function testMintMemberRewardRejectsRoundsOutOfRange() external {
        // An action that was never created is reported as such, not as an early round.
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), SECOND_ACTION_ID)
        );
        lpExecutor.mintMemberReward(address(token), SECOND_ACTION_ID, 1, 2);

        _atPhase(3);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, 1, 2));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 3, 1));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 3);

        _atPhase(2);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 2, 0));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
    }

    function testMintMemberRewardRequiresMemberOwner() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
    }

    function testMintMemberRewardChecksOwnerBeforeRound() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 9);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 9, 2));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 9);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, 0, 2));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 0);
    }

    function testMintMemberRewardRejectsRepeat() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);
        _mintMemberReward(1, 2);

        uint256 memberBefore = token.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);
        require(token.balanceOf(MEMBER1) == memberBefore, "no second transfer");
        require(actionTarget.mintRewardCalls() == 1, "no second pull");
    }

    function testMintMemberRewardPropagatesPullFailureAndRollsBack() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setRevertMint(true);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(MockLpActionTarget.MintActionRewardReverted.selector));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);

        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(minted == false, "settlement rolled back");
        require(token.burnCalls() == 0, "burn rolled back");
    }

    function testMintMemberRewardTransferFailureRollsBack() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);
        token.setFailTransfer(true);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        lpExecutor.mintMemberReward(address(token), ACTION_ID, 1, 2);

        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(minted == false, "settlement rolled back");
        require(token.burnCalls() == 0, "burn rolled back");
        require(token.balanceOf(address(lpExecutor)) == PROPOSAL_REWARD, "reward retained by the executor");
    }

    function testMintMemberRewardRoundsAreIndependent() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(3, 500e18, true);
        _fundExecutor(1500e18);

        (uint256 mint2, uint256 burn2) = _mintMemberReward(1, 2);
        (uint256 mint3, uint256 burn3) = _mintMemberReward(1, 3);
        require(mint2 == 200e18 && burn2 == 800e18, "round 2 settlement");
        require(mint3 == 100e18 && burn3 == 400e18, "round 3 settlement");
        (uint256 ratio2, bool minted2) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        (uint256 ratio3, bool minted3) = lpExecutor.govRatio(address(token), ACTION_ID, 3, 1);
        require(minted2 && minted3 && ratio2 == 1e17 && ratio3 == 1e17, "per round snapshots");
    }

    function testMintMemberRewardsAlignsByIndex() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(SECOND_ACTION_ID, 2, PROPOSAL_REWARD, true);
        _fundExecutor(2000e18);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = SECOND_ACTION_ID;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 2;

        vm.prank(MEMBER1);
        (uint256[] memory mintAmounts, uint256[] memory burnAmounts) =
            lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);

        require(mintAmounts.length == 2 && burnAmounts.length == 2, "aligned lengths");
        require(mintAmounts[0] == 200e18 && burnAmounts[0] == 800e18, "capped action");
        require(mintAmounts[1] == PROPOSAL_REWARD && burnAmounts[1] == 0, "uncapped action");
        require(actionTarget.mintRewardCalls() == 0, "no pulls for recorded rewards");
    }

    function testMintMemberRewardsBatchMintsSequentialRounds() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(3, 500e18, true);
        _fundExecutor(1500e18);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 3;

        vm.prank(MEMBER1);
        (uint256[] memory mintAmounts, uint256[] memory burnAmounts) =
            lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);
        require(mintAmounts[0] == 200e18 && mintAmounts[1] == 100e18, "per round mints");
        require(burnAmounts[0] == 800e18 && burnAmounts[1] == 400e18, "per round burns");
    }

    function testMintMemberRewardsRejectsLengthMismatch() external {
        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID;
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = 2;

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);
    }

    function testMintMemberRewardsEmptyArraysDoNothing() external {
        uint256[] memory empty = new uint256[](0);
        vm.prank(MEMBER1);
        (uint256[] memory mintAmounts, uint256[] memory burnAmounts) =
            lpExecutor.mintMemberRewards(address(token), empty, 1, empty);
        require(mintAmounts.length == 0 && burnAmounts.length == 0, "empty result");
        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(minted == false, "no state change");
    }

    function testMintMemberRewardsRollsBackAllOnElementFailure() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(3, 500e18, true);
        _fundExecutor(1500e18);
        _mintMemberReward(1, 2);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 3;

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberRewards(address(token), actionIds, 1, rounds);

        (,, bool minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 3);
        require(minted == false, "later element rolled back");
    }

    function testCurrentRoundsFollowPhaseMapping() external {
        _atPhase(0);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentVoteRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentJoinRound();
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentMintRound();

        _atPhase(1);
        require(lpExecutor.currentVoteRound() == 1, "vote round is the phase");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentJoinRound();

        _atPhase(2);
        require(lpExecutor.currentJoinRound() == 1, "join round is phase minus one");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.currentMintRound();

        _atPhase(3);
        require(lpExecutor.currentMintRound() == 1, "mint round is phase minus two");
    }

    function testJoinedAmountsReturnZeroBeyondJoinRound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);

        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == 100e18, "current round");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 3) == 0, "beyond join round");
        require(lpExecutor.joinedAmount(address(token), ACTION_ID, 1) == 0, "before first record");
        require(lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, 2) == 0, "unknown member");
    }

    function testJoinedAmountTokenAddressDefaults() external view {
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), ACTION_ID) == address(joinToken),
            "configured join token"
        );
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), SECOND_ACTION_ID) == address(0),
            "unknown action defaults to zero"
        );
    }

    function testGettersDefaultToZeroForUnknownAction() external view {
        require(lpExecutor.GOV_RATIO_MULTIPLIER(address(token), 99) == 0, "multiplier default");
        require(lpExecutor.MIN_GOV_RATIO(address(token), 99) == 0, "min ratio default");
    }

    function testGovRatioReturnsCurrentThenRecorded() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);
        _mintMemberReward(1, 2);

        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(minted && ratio == 1e17, "recorded at mint");

        stake.setValidGovVotes(address(token), 1, 900e18);
        (ratio, minted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(minted && ratio == 1e17, "stake changes do not rewrite the snapshot");
        (ratio, minted) = lpExecutor.govRatio(address(token), ACTION_ID, 3, 1);
        require(minted == false && ratio == 9e17, "unminted round reads the current ratio");
    }

    function testGovRatioZeroWithoutTotalValidGovVotes() external {
        stake.setTotalValidGovVotes(address(token), 0);
        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), ACTION_ID, 2, 1);
        require(ratio == 0 && minted == false, "zero denominator returns zero");
    }

    function testMemberRewardPendingMatchesSettlement() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 pendingMint, uint256 pendingBurn, bool mintedBefore) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(mintedBefore == false, "not minted yet");
        require(pendingMint == 200e18 && pendingBurn == 800e18, "pending computation");

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(1, 2);
        require(mintAmount == pendingMint && burnAmount == pendingBurn, "settlement matches the quote");

        (uint256 recordedMint, uint256 recordedBurn, bool mintedAfter) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(mintedAfter && recordedMint == mintAmount && recordedBurn == burnAmount, "recorded values");
    }

    function testMemberRewardReturnsZeroOutsideRange() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);

        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 1);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "before creation");
        (mintAmount, burnAmount, minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 3);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "after mint round");
        (mintAmount, burnAmount, minted) = lpExecutor.memberReward(address(token), ACTION_ID, 2, 2);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "non participant");
        (mintAmount, burnAmount, minted) = lpExecutor.memberReward(address(token), SECOND_ACTION_ID, 1, 2);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "unbound action");
    }

    function testMemberRewardPendingReturnsZeroWithoutEffectiveParticipation() external {
        _atPhase(4);
        (uint256 mintAmount, uint256 burnAmount, bool minted) =
            lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "round without participants");

        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _withdraw(1, 100e18);
        _atPhase(4);
        (mintAmount, burnAmount, minted) = lpExecutor.memberReward(address(token), ACTION_ID, 1, 2);
        require(mintAmount == 0 && burnAmount == 0 && minted == false, "fully withdrawn round");
    }

    function testUnallocatedRoundBlocksSettlement() external {
        _atPhase(4);
        // Nobody joined the creation round, so its reserved share has no distribution path.
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), ACTION_ID, 1, 2
            )
        );
        _mintMemberReward(1, 2);
    }
}
