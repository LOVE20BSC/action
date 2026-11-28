// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LpExecutor} from "../src/LpExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IMemberRewardExecutor, MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
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
    function testConstructorDerivesDependenciesFromStake() external {
        require(lpExecutor.ACTION_TARGET_ADDRESS() == address(actionTarget), "action target bound");
        require(lpExecutor.MEMBER_NFT_ADDRESS() == address(memberNFT), "member nft bound");
        require(lpExecutor.PHASE_ADDRESS() == address(phase), "phase bound");
        require(lpExecutor.STAKE_ADDRESS() == address(stake), "stake bound");
        require(lpExecutor.PAIR_FACTORY_ADDRESS() == stake.PAIR_FACTORY_ADDRESS(), "pair factory bound");

        MockLpPhase otherPhase = new MockLpPhase();
        otherPhase.setCurrentPhase(7);
        stake.setPhaseAddress(address(otherPhase));
        LpExecutor freshPhase = new LpExecutor(address(actionTarget));
        require(freshPhase.currentJoinRound() == 6, "phase derived from stake");
        stake.setPhaseAddress(address(phase));

        MockLpMemberNFT otherMemberNFT = new MockLpMemberNFT();
        otherMemberNFT.setOwner(1, MEMBER2);
        stake.setMemberNFTAddress(address(otherMemberNFT));
        LpExecutor freshMemberNFT = new LpExecutor(address(actionTarget));
        vm.prank(address(actionTarget));
        freshMemberNFT.onProposalCreated(address(token), ACTION_ID, _targetData());
        vm.prank(MEMBER2);
        joinToken.approve(address(freshMemberNFT), type(uint256).max);
        vm.prank(MEMBER2);
        freshMemberNFT.join(address(token), ACTION_ID, 1, 1e18);
        require(
            freshMemberNFT.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 1e18,
            "member NFT derived from stake"
        );
        stake.setMemberNFTAddress(address(memberNFT));

        MockUniswapV2Factory emptyFactory = new MockUniswapV2Factory();
        stake.setPairFactoryAddress(address(emptyFactory));
        LpExecutor freshFactory = new LpExecutor(address(actionTarget));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidJoinTokenFactory.selector, address(joinToken), address(emptyFactory)));
        freshFactory.onProposalCreated(address(token), ACTION_ID, _targetData());
        stake.setPairFactoryAddress(address(factory));
    }

    function testCreateStoresConfig() external view {
        require(
            lpExecutor.joinTokenAddress(address(token), ACTION_ID) == address(joinToken),
            "join token stored"
        );
        require(
            lpExecutor.govRatioMultiplier(address(token), ACTION_ID) == GOV_RATIO_MULTIPLIER,
            "multiplier stored"
        );
        require(lpExecutor.minGovRatio(address(token), ACTION_ID) == MIN_GOV_RATIO, "min ratio stored");
    }

    function testCreateRejectsNonActionTargetCaller() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, "");
    }

    function testCreateRejectsWrongDataLength() external {
        uint256[5] memory lengths = [uint256(0), 64, 95, 97, 128];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory creationData = new bytes(lengths[i]);
            vm.prank(address(actionTarget));
            vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidCreationDataLength.selector, lengths[i], 96));
            lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, creationData);
        }
        require(lpExecutor.joinTokenAddress(address(token), SECOND_ACTION_ID) == address(0), "nothing stored");
    }

    function testCreateRejectsInvalidAddressEncoding() external {
        uint256 invalidTokenWord = (uint256(1) << 160) | uint160(address(joinToken));
        bytes memory creationData = abi.encode(invalidTokenWord, GOV_RATIO_MULTIPLIER, MIN_GOV_RATIO);
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidCreationDataEncoding.selector));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, creationData);
        require(lpExecutor.joinTokenAddress(address(token), SECOND_ACTION_ID) == address(0), "nothing stored");
    }

    function testCreateRejectsZeroJoinToken() external {
        bytes memory targetData = _targetDataWithConfig(GOV_RATIO_MULTIPLIER, MIN_GOV_RATIO, address(0));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.ZeroJoinTokenAddress.selector));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
    }

    function testCreateRejectsUnregisteredJoinToken() external {
        address[6] memory joinTokens = [
            address(0xdead),
            address(lpBaseToken),
            address(new MockUniswapV2Pair(address(token), address(lpBaseToken))),
            address(new MockUniswapV2Pair(address(token), address(token))),
            address(new MockRevertingPair()),
            address(new MockRevertingPairToken1(address(token)))
        ];
        for (uint256 i = 0; i < joinTokens.length; i++) {
            bytes memory targetData = _targetDataWithConfig(GOV_RATIO_MULTIPLIER, MIN_GOV_RATIO, joinTokens[i]);
            vm.prank(address(actionTarget));
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILpExecutorErrors.InvalidJoinTokenFactory.selector, joinTokens[i], address(factory)
                )
            );
            lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
        }
    }

    function testCreateRejectsRevertingFactory() external {
        address revertingFactory = address(new MockRevertingPairFactory());
        stake.setPairFactoryAddress(revertingFactory);
        LpExecutor freshReverting = new LpExecutor(address(actionTarget));
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
            lpExecutor.joinTokenAddress(address(token), SECOND_ACTION_ID) == address(joinToken),
            "valid create succeeds"
        );
    }

    function testCreateRejectsMinGovRatioAbovePrecision() external {
        bytes memory targetData = _targetDataWithConfig(GOV_RATIO_MULTIPLIER, PRECISION + 1, address(joinToken));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidMinGovRatio.selector, PRECISION + 1));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
    }

    function testCreateAcceptsBoundaryConfigs() external {
        bytes memory targetData = _targetDataWithConfig(0, PRECISION, address(joinToken));
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);
        require(lpExecutor.govRatioMultiplier(address(token), SECOND_ACTION_ID) == 0, "zero multiplier");
        require(lpExecutor.minGovRatio(address(token), SECOND_ACTION_ID) == PRECISION, "full min ratio");
    }

    function testCreateRollsBackOnFailure() external {
        bytes memory targetData = _targetDataWithConfig(GOV_RATIO_MULTIPLIER, PRECISION + 1, address(joinToken));
        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InvalidMinGovRatio.selector, PRECISION + 1));
        lpExecutor.onProposalCreated(address(token), SECOND_ACTION_ID, targetData);

        require(
            lpExecutor.govRatioMultiplier(address(token), SECOND_ACTION_ID) == 0,
            "multiplier not stored"
        );
        require(
            lpExecutor.joinTokenAddress(address(token), SECOND_ACTION_ID) == address(0),
            "join token not stored"
        );

        _createAction(SECOND_ACTION_ID);
        require(
            lpExecutor.govRatioMultiplier(address(token), SECOND_ACTION_ID) == GOV_RATIO_MULTIPLIER,
            "retry succeeds"
        );
    }

    function testSubmittedCallbackGatesCaller() external {
        vm.prank(address(actionTarget));
        lpExecutor.onProposalSubmitted(address(token), 3, ACTION_ID, 1, "");

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalSubmitted(address(token), 3, ACTION_ID, 1, "");
    }

    function testVotedCallbackGatesCallerAndDataLength() external {
        vm.prank(address(actionTarget));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, "");

        vm.prank(address(actionTarget));
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.UnexpectedVoteData.selector));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, abi.encode(uint256(1)));

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotActionTarget.selector, OUTSIDER));
        lpExecutor.onProposalVoted(address(token), 3, ACTION_ID, 1, 100, abi.encode(uint256(1)));
    }

    function testJoinRecordsDeductionAtPhaseStart() external {
        _atPhaseBlock(3, 3000);
        uint256 executorBefore = joinToken.balanceOf(address(lpExecutor));
        _join(1, 100e18);

        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 100e18, "total joined");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 100e18,
            "member joined"
        );
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "no deduction at start");

        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
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

        (uint256 deduction,, uint256[] memory amounts) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 20e18, "second join deduction");
        require(amounts.length == 2 && amounts[0] == 100e18 && amounts[1] == 50e18, "both amounts recorded");
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 150e18, "balance sum");
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 150e18, "total sum");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 20e18, "total deduction sum");
    }

    function testJoinUsesJoinPhaseInfoAndFreezesDeduction() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        phase.setPhaseInfo(3, 3000, 500);
        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 30e18, "recorded deduction is frozen");

        phase.setPhaseInfo(4, 4000, 250);
        _atPhaseBlock(4, 4100);
        _join(1, 100e18);
        (deduction,,) = lpExecutor.deduction(address(token), 3, ACTION_ID, 1);
        require(deduction == 40e18, "next round uses its own phase window");
    }

    function testJoinAtLastBlockOfPhase() external {
        _atPhaseBlock(3, 3999);
        _join(1, 100e18);
        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 999e17, "deduction near full phase");
    }

    function testJoinCapsDeductionAtAmount() external {
        phase.setPhaseInfo(3, 3000, 100);
        _atPhaseBlock(3, 3200);
        _join(1, 7);

        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 7, "deduction capped at the join amount");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 7, "total deduction capped");
    }

    function testJoinRequiresMemberOwner() external {
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 0, "nothing recorded");
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

        stake.setGovPower(address(token), 2, 99e18);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, 1e17, 99e15));
        lpExecutor.join(address(token), ACTION_ID, 2, 1e18);
        require(actionTarget.isJoined(address(token), ACTION_ID, 2) == false, "not registered");
    }

    function testJoinSecondSkipsGovCheck() external {
        _join(1, 10e18);
        stake.setGovPower(address(token), 1, 1);
        _join(1, 10e18);
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 20e18, "second join allowed");
        require(actionTarget.registerCalls() == 1, "registered once");
    }

    function testJoinSkipsGovCheckForPreJoinedMember() external {
        actionTarget.setJoined(address(token), ACTION_ID, 2, true);
        stake.setGovPower(address(token), 2, 0);
        _join(2, 1e18);
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 2) == 1e18, "join allowed");
        require(actionTarget.registerCalls() == 0, "already registered member");
    }

    function testJoinZeroTotalGovPowerRequiresZeroMinRatio() external {
        stake.setTotalGovPower(address(token), 0);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, 1e17, 0));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);

        _createActionWithConfig(SECOND_ACTION_ID, GOV_RATIO_MULTIPLIER, 0);
        _join(SECOND_ACTION_ID, 1, 1e18);
        require(
            lpExecutor.joinedAmountByMemberId(address(token), 2, SECOND_ACTION_ID, 1) == 1e18,
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
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 0, "total rolled back");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "deduction rolled back");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 0 && blocks.length == 0 && amounts.length == 0, "records rolled back");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target state untouched");
    }

    function testJoinRejectsForeignActionEvenWhenAlreadyJoinedElsewhere() external {
        _atPhase(3);
        actionTarget.setJoined(address(token), 999, 1, true);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), 999));
        lpExecutor.join(address(token), 999, 1, 1e18);
    }

    function testJoinTransferFailureRollsBack() external {
        joinToken.setFailTransferFrom(true);
        _atPhaseBlock(3, 3300);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(joinToken)));
        lpExecutor.join(address(token), ACTION_ID, 1, 100e18);

        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 0, "ledger rolled back");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target rolled back");
    }

    function testJoinRoundFollowsPhaseMapping() external {
        _atPhase(1);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.join(address(token), ACTION_ID, 1, 1e18);

        _atPhase(5);
        _join(1, 100e18);
        require(lpExecutor.joinedAmountByActionId(address(token), 4, ACTION_ID) == 100e18, "join round 4");
        require(lpExecutor.joinedAmountByActionId(address(token), 3, ACTION_ID) == 0, "round 3 untouched");
    }

    function testJoinBalancesCarryAcrossRounds() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(4, 4300);
        _join(1, 50e18);

        require(
            lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 100e18,
            "round 2 frozen"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), 3, ACTION_ID, 1) == 150e18,
            "round 3 carries the balance"
        );
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "round 2 deduction");
        require(lpExecutor.deductionByRound(address(token), 3, ACTION_ID) == 15e18, "round 3 deduction only");
    }

    function testWithdrawPartialRoundsDeductionDown() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _withdraw(1, 40e18);

        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 160e18, "balance reduced");
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 160e18, "total reduced");
        (uint256 deduction,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 24e18, "deduction scaled down");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 24e18, "total deduction scaled");
        require(joinToken.balanceOf(MEMBER1) - memberBefore == 40e18, "part returned");
        require(actionTarget.clearCalls() == 0, "partial withdraw keeps the join state");
    }

    function testWithdrawPartialKeepsJoinRecords() external {
        phase.setPhaseInfo(3, 3000, 7);
        _atPhaseBlock(3, 3003);
        _join(1, 7);

        (uint256 deductionBefore,,) = lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deductionBefore == 3, "deduction 3 of 7");
        _withdraw(1, 2);

        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 5, "balance 5");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 3, "deduction stays 3");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 3, "total deduction stays 3");
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
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 0, "balance cleared");
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 0, "total cleared");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "deduction taken");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
        require(deduction == 0 && blocks.length == 0 && amounts.length == 0, "records cleared");
        require(actionTarget.clearCalls() == 1, "join state cleared");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1) == false, "target cleared");
    }

    function testWithdrawFullAfterDeductionTakesRemainder() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        _withdraw(1, 100e18);
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "deduction taken exactly");
    }

    function testWithdrawUpdatesOnlyCurrentRound() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhaseBlock(4, 4000);
        _withdraw(1, 40e18);

        require(
            lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 100e18,
            "past round frozen"
        );
        require(
            lpExecutor.joinedAmountByMemberId(address(token), 3, ACTION_ID, 1) == 60e18,
            "current round reduced"
        );
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 100e18, "past total frozen");
        require(lpExecutor.joinedAmountByActionId(address(token), 3, ACTION_ID) == 60e18, "current total reduced");
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
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 10e18, "balance retained");
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
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 60e18, "same block withdraw");
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
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 100e18, "balance retained");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 30e18, "deduction retained");
        require(actionTarget.isJoined(address(token), ACTION_ID, 1), "target state retained");
    }

    function testExitReturnsBalanceAndClearsState() external {
        _atPhaseBlock(3, 3300);
        _join(1, 100e18);

        uint256 memberBefore = joinToken.balanceOf(MEMBER1);
        _exit(1);

        require(joinToken.balanceOf(MEMBER1) - memberBefore == 100e18, "balance returned");
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 0, "member cleared");
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 0, "total cleared");
        require(lpExecutor.deductionByRound(address(token), 2, ACTION_ID) == 0, "deduction taken");
        (uint256 deduction, uint256[] memory blocks, uint256[] memory amounts) =
            lpExecutor.deduction(address(token), 2, ACTION_ID, 1);
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
        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 100e18, "past round retained");
        require(lpExecutor.joinedAmountByActionId(address(token), 4, ACTION_ID) == 0, "current round cleared");
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
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 1) == 100e18, "balance retained");
    }

    function testMintMemberRewardSettlesWithGovCap() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        uint256 memberBefore = token.balanceOf(MEMBER1);
        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);

        require(mintAmount == 200e18, "mint capped by gov ratio");
        require(burnAmount == 800e18, "theoretical minus mint burned");
        require(token.balanceOf(MEMBER1) - memberBefore == 200e18, "mint transferred");
        require(token.burnCalls() == 1 && token.lastBurnAmount() == 800e18, "burn called once");
        require(actionTarget.mintRewardCalls() == 1, "action reward pulled once");
        require(actionTarget.lastMintTokenAddress() == address(token), "token forwarded");
        require(actionTarget.lastMintActionId() == ACTION_ID, "action forwarded");
        require(actionTarget.lastMintRound() == 2, "round forwarded");

        (uint256 pending, uint256 recordedMint, MemberRewardStatus status) =
            lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        (, uint256 recordedBurn,) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(pending == 0 && status == MemberRewardStatus.Settled && recordedMint == 200e18, "settlement recorded");
        require(recordedBurn == 800e18, "burn recorded");
        (uint256 ratio, bool ratioMinted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(ratioMinted && ratio == 1e17, "gov ratio snapshot at mint");
    }

    function testMintMemberRewardSplitsBetweenMembers() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhaseBlock(3, 3500);
        _join(SECOND_ACTION_ID, 2, 100e18);
        _atPhase(4);
        _setActionReward(2, SECOND_ACTION_ID, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mint1, uint256 burn1) = _mintMemberReward(2, SECOND_ACTION_ID, 1);
        (uint256 mint2, uint256 burn2) = _mintMemberReward(2, SECOND_ACTION_ID, 2);

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
        _setActionReward(2, SECOND_ACTION_ID, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mint1, uint256 burn1) = _mintMemberReward(2, SECOND_ACTION_ID, 1);
        (uint256 mint2, uint256 burn2) = _mintMemberReward(2, SECOND_ACTION_ID, 2);

        require(mint1 == 666666666666666666666 && burn1 == 0, "truncated ratio must not burn");
        require(mint2 == 333333333333333333333 && burn2 == 0, "truncated ratio must not burn");
    }

    function testMintMemberRewardWithCapDisabled() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhase(4);
        _setActionReward(2, SECOND_ACTION_ID, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, SECOND_ACTION_ID, 1);
        require(mintAmount == PROPOSAL_REWARD, "full theoretical reward");
        require(burnAmount == 0, "no burn with cap disabled");
        require(token.burnCalls() == 0, "burn not called");
    }

    function testMintMemberRewardBurnsAllWhenTotalGovPowerIsZero() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        stake.setTotalGovPower(address(token), 0);
        stake.setGovPower(address(token), 1, 0);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        IMemberRewardExecutor rewards = IMemberRewardExecutor(address(lpExecutor));
        (uint256 pending, uint256 paid, MemberRewardStatus status) = rewards.memberReward(address(token), 2, ACTION_ID, 1);
        require(pending == 0 && paid == 0 && status == MemberRewardStatus.Pending, "pure burn is executable");
        (uint256 lpMint, uint256 lpBurn, MemberRewardStatus lpStatus) =
            lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(lpMint == 0 && lpBurn == PROPOSAL_REWARD && lpStatus == status, "burn is pending");
        uint256 memberBefore = token.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        require(rewards.mintMemberReward(address(token), 2, ACTION_ID, 1) == 0, "nothing paid");
        require(token.balanceOf(MEMBER1) == memberBefore, "no transfer");
        require(token.burnCalls() == 1 && token.lastBurnAmount() == PROPOSAL_REWARD, "pure burn");
        (pending, paid, status) = rewards.memberReward(address(token), 2, ACTION_ID, 1);
        require(pending == 0 && paid == 0 && status == MemberRewardStatus.Settled, "pure burn settles the reward");
        (lpMint, lpBurn, lpStatus) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(lpMint == 0 && lpBurn == PROPOSAL_REWARD && lpStatus == status, "burn is recorded");
    }

    function testMintMemberRewardMintsAllWhenCapAboveLpRatio() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        stake.setGovPower(address(token), 1, 1000e18);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);
        require(mintAmount == PROPOSAL_REWARD && burnAmount == 0, "lp ratio is the cap");
        require(token.burnCalls() == 0, "no burn");
    }

    function testMintMemberRewardUsesMintedActionRewardWithoutPull() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, 500e18, true);
        _fundExecutor(500e18);

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);
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

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);
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
                IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), 2
            )
        );
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);
        require(actionTarget.mintRewardCalls() == 0, "no pull without effective participation");
        (,, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Unavailable, "no member reward without effective participation");
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
                IActionExecutorErrors.ZeroEffectiveJoinAmount.selector, address(token), ACTION_ID, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 2);
        require(token.balanceOf(MEMBER2) == memberBefore, "no transfer");
        (,, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 2);
        require(status == MemberRewardStatus.Unavailable, "no share for non-participant");
    }

    function testMintMemberRewardRevertsOnZeroProposalReward() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, 0, false);

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), 2
            )
        );
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);
        require(actionTarget.mintRewardCalls() == 0, "no pull with zero reward");
    }

    function testMintMemberRewardRejectsRoundsOutOfRange() external {
        // An action that was never created is reported as such, not as an early round.
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionExecutorErrors.ActionNotCreated.selector, address(token), SECOND_ACTION_ID)
        );
        lpExecutor.mintMemberReward(address(token), 2, SECOND_ACTION_ID, 1);

        _atPhase(3);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, 1, 2));
        lpExecutor.mintMemberReward(address(token), 1, ACTION_ID, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 3, 1));
        lpExecutor.mintMemberReward(address(token), 3, ACTION_ID, 1);

        _atPhase(2);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 1, 0));
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);
    }

    function testMintMemberRewardRequiresMemberOwner() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);
    }

    function testMintMemberRewardChecksOwnerBeforeRound() external {
        _atPhase(4);
        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberReward(address(token), 9, ACTION_ID, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundAfterMintWindow.selector, 9, 2));
        lpExecutor.mintMemberReward(address(token), 9, ACTION_ID, 1);

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundBeforeActionCreated.selector, 0, 2));
        lpExecutor.mintMemberReward(address(token), 0, ACTION_ID, 1);
    }

    function testMintMemberRewardRejectsRepeat() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);
        _mintMemberReward(2, 1);

        uint256 memberBefore = token.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);
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
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);

        (,, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Pending, "settlement rolled back");
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
        lpExecutor.mintMemberReward(address(token), 2, ACTION_ID, 1);

        (,, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Pending, "settlement rolled back");
        require(token.burnCalls() == 0, "burn rolled back");
        require(token.balanceOf(address(lpExecutor)) == PROPOSAL_REWARD, "reward retained by the executor");
    }

    function testMintMemberRewardRoundsAreIndependent() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);
        stake.setTotalGovPower(address(token), 1200e18);
        stake.setGovPower(address(token), 1, 300e18);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(3, 500e18, true);
        _fundExecutor(1500e18);

        (uint256 mint2, uint256 burn2) = _mintMemberReward(2, 1);
        (uint256 mint3, uint256 burn3) = _mintMemberReward(3, 1);
        require(mint2 == 500e18 && burn2 == 500e18, "round 2 uses the latest votes");
        require(mint3 == 250e18 && burn3 == 250e18, "round 3 uses the latest votes");
        (uint256 ratio2, bool minted2) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        (uint256 ratio3, bool minted3) = lpExecutor.govRatio(address(token), 3, ACTION_ID, 1);
        require(minted2 && minted3 && ratio2 == 25e16 && ratio3 == 25e16, "per round settlement ratios");
    }

    function testMintMemberRewardsAlignsByIndex() external {
        _createActionWithConfig(SECOND_ACTION_ID, 0, 0);
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _join(SECOND_ACTION_ID, 1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(2, SECOND_ACTION_ID, PROPOSAL_REWARD, true);
        _fundExecutor(2000e18);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = SECOND_ACTION_ID;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 2;
        rounds[1] = 2;

        vm.prank(MEMBER1);
        uint256[] memory mintAmounts = lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);

        require(mintAmounts.length == 2, "aligned length");
        require(mintAmounts[0] == 200e18, "capped action");
        require(mintAmounts[1] == PROPOSAL_REWARD, "uncapped action");
        (, uint256 cappedBurn,) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        (, uint256 uncappedBurn,) = lpExecutor.rewardDetail(address(token), 2, SECOND_ACTION_ID, 1);
        require(cappedBurn == 800e18 && uncappedBurn == 0, "burns recorded by action");
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
        uint256[] memory mintAmounts = lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);
        require(mintAmounts[0] == 200e18 && mintAmounts[1] == 100e18, "per round mints");
        (, uint256 firstBurn,) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        (, uint256 secondBurn,) = lpExecutor.rewardDetail(address(token), 3, ACTION_ID, 1);
        require(firstBurn == 800e18 && secondBurn == 400e18, "per round burns");
    }

    function testMintMemberRewardsRejectsLengthMismatch() external {
        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID;
        uint256[] memory rounds = new uint256[](1);
        rounds[0] = 2;

        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.BatchLengthMismatch.selector, 2, 1));
        lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);

        vm.prank(MEMBER2);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);
    }

    function testMintMemberRewardsEmptyArraysDoNothing() external {
        uint256[] memory empty = new uint256[](0);
        vm.prank(MEMBER1);
        uint256[] memory mintAmounts = lpExecutor.mintMemberRewards(address(token), empty, empty, 1);
        require(mintAmounts.length == 0, "empty result");
        (,, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Unavailable, "no state change");
    }

    function testMintMemberRewardsRollsBackAllOnElementFailure() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(5);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _setActionReward(3, 500e18, true);
        _fundExecutor(1500e18);
        _mintMemberReward(2, 1);

        uint256[] memory actionIds = new uint256[](2);
        actionIds[0] = ACTION_ID;
        actionIds[1] = ACTION_ID;
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 3;
        rounds[1] = 2;

        uint256 balance = token.balanceOf(MEMBER1);
        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, 1, 2
            )
        );
        lpExecutor.mintMemberRewards(address(token), rounds, actionIds, 1);

        (uint256 pending, uint256 paid, MemberRewardStatus status) = lpExecutor.memberReward(address(token), 3, ACTION_ID, 1);
        require(pending == 100e18 && paid == 0 && status == MemberRewardStatus.Pending, "first element rolled back");
        require(token.balanceOf(MEMBER1) == balance && token.burnCalls() == 1, "batch transfers and burns rolled back");
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

        require(lpExecutor.joinedAmountByActionId(address(token), 2, ACTION_ID) == 100e18, "current round");
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.RoundNotStarted.selector, 3, 2));
        lpExecutor.joinedAmountByActionId(address(token), 3, ACTION_ID);
        require(lpExecutor.joinedAmountByActionId(address(token), 1, ACTION_ID) == 0, "before first record");
        require(lpExecutor.joinedAmountByMemberId(address(token), 2, ACTION_ID, 2) == 0, "unknown member");
    }

    function testJoinedAmountTokenAddressDefaults() external view {
        require(
            lpExecutor.joinTokenAddress(address(token), ACTION_ID) == address(joinToken),
            "configured join token"
        );
        require(
            lpExecutor.joinTokenAddress(address(token), SECOND_ACTION_ID) == address(0),
            "unknown action defaults to zero"
        );
    }

    function testGettersDefaultToZeroForUnknownAction() external view {
        require(lpExecutor.govRatioMultiplier(address(token), 99) == 0, "multiplier default");
        require(lpExecutor.minGovRatio(address(token), 99) == 0, "min ratio default");
    }

    function testGovRatioReturnsLatestThenRecorded() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, true);
        _fundExecutor(PROPOSAL_REWARD);
        (uint256 pendingMint, uint256 pendingBurn,) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(pendingMint == 200e18 && pendingBurn == 800e18, "initial cap");
        stake.setTotalGovPower(address(token), 1200e18);
        stake.setGovPower(address(token), 1, 300e18);
        (pendingMint, pendingBurn,) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(pendingMint == 500e18 && pendingBurn == 500e18, "latest numerator and denominator set the cap");
        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(!minted && ratio == 25e16, "pending ratio follows the latest votes");
        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);
        require(mintAmount == pendingMint && burnAmount == pendingBurn, "settlement matches the latest quote");

        (ratio, minted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(minted && ratio == 25e16, "recorded at mint");

        stake.setTotalGovPower(address(token), 3000e18);
        (ratio, minted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(minted && ratio == 25e16, "stake changes do not rewrite the settlement ratio");
        {
            (uint256 paid, uint256 burned, MemberRewardStatus status) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
            require(status == MemberRewardStatus.Settled && paid == 500e18 && burned == 500e18, "settled rewards stay fixed");
        }
        (ratio, minted) = lpExecutor.govRatio(address(token), 3, ACTION_ID, 1);
        require(minted == false && ratio == 1e17, "unminted round follows the latest total votes");
    }

    function testGovRatioZeroWithoutTotalGovPower() external {
        stake.setTotalGovPower(address(token), 2, 0);
        (uint256 ratio, bool minted) = lpExecutor.govRatio(address(token), 2, ACTION_ID, 1);
        require(ratio == 0 && minted == false, "zero denominator returns zero");
    }

    function testMemberRewardPendingMatchesSettlement() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);
        _setActionReward(2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);
        _fundExecutor(PROPOSAL_REWARD);

        (uint256 pendingMint, uint256 paid, MemberRewardStatus status) =
            lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        (uint256 quotedMint, uint256 pendingBurn, MemberRewardStatus lpStatus) =
            lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Pending && paid == 0, "unsettled reward");
        require(quotedMint == pendingMint && lpStatus == status, "LP quote matches summary");
        require(pendingMint == 200e18 && pendingBurn == 800e18, "pending computation");

        (uint256 mintAmount, uint256 burnAmount) = _mintMemberReward(2, 1);
        require(mintAmount == pendingMint && burnAmount == pendingBurn, "settlement matches the quote");

        (pendingMint, paid, status) = lpExecutor.memberReward(address(token), 2, ACTION_ID, 1);
        (quotedMint, pendingBurn, lpStatus) = lpExecutor.rewardDetail(address(token), 2, ACTION_ID, 1);
        require(status == MemberRewardStatus.Settled && pendingMint == 0, "settled reward");
        require(quotedMint == paid && lpStatus == status, "LP record matches summary");
        require(paid == mintAmount && pendingBurn == burnAmount, "recorded values");
    }

    function testMemberRewardReturnsZeroOutsideRange() external {
        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _atPhase(4);

        _assertUnavailableReward(1, ACTION_ID, 1, "before creation");
        _assertUnavailableReward(3, ACTION_ID, 1, "after mint round");
        _assertUnavailableReward(2, ACTION_ID, 2, "non participant");
        _assertUnavailableReward(2, SECOND_ACTION_ID, 1, "unbound action");
    }

    function testMemberRewardPendingReturnsZeroWithoutEffectiveParticipation() external {
        _atPhase(4);
        _assertUnavailableReward(2, ACTION_ID, 1, "round without participants");

        _atPhaseBlock(3, 3000);
        _join(1, 100e18);
        _withdraw(1, 100e18);
        _atPhase(4);
        _assertUnavailableReward(2, ACTION_ID, 1, "fully withdrawn round");
    }

    function _assertUnavailableReward(uint256 round, uint256 actionId, uint256 memberId, string memory reason)
        private view
    {
        (uint256 pending, uint256 paid, MemberRewardStatus status) =
            lpExecutor.memberReward(address(token), round, actionId, memberId);
        require(pending == 0 && paid == 0 && status == MemberRewardStatus.Unavailable, reason);
        (uint256 lpMint, uint256 lpBurn, MemberRewardStatus lpStatus) =
            lpExecutor.rewardDetail(address(token), round, actionId, memberId);
        require(lpMint == 0 && lpBurn == 0 && lpStatus == status, reason);
    }

    function testUnallocatedRoundBlocksSettlement() external {
        _atPhase(4);
        // Nobody joined the creation round, so its reserved share has no distribution path.
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberRewardPoolEmpty.selector, address(token), 2
            )
        );
        _mintMemberReward(2, 1);
    }
}
