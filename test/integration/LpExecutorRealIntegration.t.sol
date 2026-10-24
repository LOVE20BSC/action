// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../../src/ActionTarget.sol";
import {LpExecutor} from "../../src/LpExecutor.sol";
import {IActionExecutorErrors} from "../../src/interfaces/IActionExecutor.sol";
import {IActionTargetErrors} from "../../src/interfaces/IActionTarget.sol";
import {ILpExecutorErrors} from "../../src/interfaces/ILpExecutor.sol";
import {MockERC20} from "../mocks/LpExecutorMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair, MockUniswapV2Router} from "../mocks/UniswapV2Mocks.sol";
import {Phase} from "@core/Phase.sol";
import {MemberNFT} from "@core/MemberNFT.sol";
import {Mint} from "@core/Mint.sol";
import {Vote} from "@core/Vote.sol";
import {Submit, ProposalBody} from "@core/Submit.sol";
import {Stake} from "@core/Stake.sol";
import {Launch} from "@core/Launch.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {LaunchInitParams} from "@core/interfaces/ILaunch.sol";
import {TargetMode} from "@core/interfaces/ISubmit.sol";

interface LpExecutorIntegrationVm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata data) external;
    function roll(uint256 blockNumber) external;
}

contract LpExecutorRealIntegrationTest {
    LpExecutorIntegrationVm internal constant vm =
        LpExecutorIntegrationVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PHASE_ORIGIN = 100;
    uint256 internal constant BLOCKS_PER_PHASE = 1000;
    uint256 internal constant ROLL_PAST_ROUND0 = 200;
    uint256 internal constant STAKE_AMOUNT = 5000;
    uint256 internal constant BOOST_AMOUNT = 100;
    uint256 internal constant MEMBER1_VOTES = 100;
    uint256 internal constant SLIPPAGE_100_PERCENT = 1e18;
    uint256 internal constant PROMISED_WAITING_PHASES = 1;
    uint256 internal constant TOKEN_TRANSFER_AMOUNT = 10000;
    uint256 internal constant LP_JOIN_AMOUNT = 1000;
    uint256 internal constant GOV_RATIO_MULTIPLIER = 1e18;
    uint256 internal constant MIN_GOV_RATIO = 1e17;
    uint256 internal constant PRECISION = 1e18;

    Phase internal phase;
    MemberNFT internal memberNFT;
    Mint internal mint;
    Vote internal vote;
    Submit internal submit;
    Stake internal stake;
    Launch internal launch;
    ActionTarget internal actionTarget;
    LpExecutor internal lpExecutor;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router internal router;
    MockERC20 internal otherToken;
    MockUniswapV2Pair internal lpPair;
    LOVE20Token internal rootToken;
    LOVE20Token internal token;

    address internal owner = address(this);
    address internal distributor = address(0x9001);
    address internal member1 = address(0x1001);
    address internal member2 = address(0x1002);

    function setUp() public {
        phase = new Phase(PHASE_ORIGIN, BLOCKS_PER_PHASE, 3600, 10, 50);
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router();
        rootToken = new LOVE20Token("RootCommunity", "ROOT", 1000000, 100000000, owner, owner, address(this));
        memberNFT = new MemberNFT(1e18, 4, 2, 20);
        mint = new Mint();
        vote = new Vote();
        submit = new Submit();
        stake = new Stake();
        launch = new Launch();

        launch.init(
            LaunchInitParams({
                mintAddress: address(mint),
                memberNFTAddress: address(memberNFT),
                rootParentTokenAddress: address(rootToken),
                pairFactoryAddress: address(factory),
                distributor: distributor,
                launchRatio: 1e16,
                maxLaunchCount: 1000,
                tokenSymbolLength: 4,
                launchAmount: 50000,
                maxSupply: 1000000,
                name: "TestCommunity",
                symbol: "TEST"
            })
        );
        (address[] memory tokenList,) = launch.tokens(0, 1, false);
        token = LOVE20Token(tokenList[0]);

        submit.init(address(phase), address(stake), address(memberNFT), 5e16);
        stake.init(
            address(phase),
            address(memberNFT),
            address(vote),
            address(launch),
            address(router),
            address(factory),
            1,
            100,
            3e15 // fee settlement ratio: 0.3% of the withdrawable LP per settlement
        );
        vote.init(address(phase), address(stake), address(submit), address(memberNFT));
        mint.init(address(vote), address(submit), address(launch), address(memberNFT), 5e16, 1e17, 1e17, 2);

        actionTarget = new ActionTarget();
        actionTarget.init(address(mint));
        lpExecutor = new LpExecutor();
        lpExecutor.init(address(actionTarget), address(stake));

        otherToken = new MockERC20();
        lpPair = MockUniswapV2Pair(factory.createPair(address(token), address(otherToken)));

        vm.roll(block.number + ROLL_PAST_ROUND0);
        _setUpMembers();
    }

    function _setUpMembers() internal {
        vm.prank(distributor);
        token.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(distributor);
        token.transfer(member2, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member2, TOKEN_TRANSFER_AMOUNT);

        vm.startPrank(member1);
        memberNFT.mint("Alice");
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT, STAKE_AMOUNT, SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);
        stake.stakeBoost(address(token), BOOST_AMOUNT, PROMISED_WAITING_PHASES, 1);
        vm.stopPrank();

        vm.startPrank(member2);
        memberNFT.mint("Bob");
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT, STAKE_AMOUNT, SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 2);
        stake.stakeBoost(address(token), BOOST_AMOUNT, PROMISED_WAITING_PHASES, 2);
        vm.stopPrank();
    }

    function _lpTargetData() internal view returns (bytes[] memory targetData) {
        targetData = new bytes[](4);
        targetData[0] = abi.encode(address(lpExecutor));
        targetData[1] = abi.encode(address(lpPair));
        targetData[2] = abi.encode(GOV_RATIO_MULTIPLIER);
        targetData[3] = abi.encode(MIN_GOV_RATIO);
    }

    function _createLpProposal(address proposer, uint256 memberId) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = submit.submitNewProposal(
            address(token),
            memberId,
            ProposalBody({
                title: "LP action",
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                targetData: _lpTargetData()
            })
        );
    }

    function _voteOne(address voter, uint256 memberId, uint256 proposalId, uint256 votes) internal {
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = votes;
        bytes[][] memory targetData = new bytes[][](1);
        targetData[0] = new bytes[](0);
        vm.prank(voter);
        vote.vote(address(token), memberId, proposalIds, amounts, targetData);
    }

    function _advanceToPhaseStart(uint256 targetPhase) internal {
        (uint256 startBlock,) = phase.phaseInfo(targetPhase);
        vm.roll(startBlock);
        require(phase.currentPhase() == targetPhase, "phase advanced as expected");
    }

    function _fundMemberLp(address member, uint256 amount) internal {
        lpPair.mintTo(member, amount);
        vm.prank(member);
        lpPair.approve(address(lpExecutor), type(uint256).max);
    }

    function testRealIntegration_LpLifecycle() external {
        uint256 round = phase.currentPhase();
        uint256 proposalId = _createLpProposal(member1, 1);
        require(
            lpExecutor.joinedAmountTokenAddress(address(token), proposalId) == address(lpPair),
            "join token configured"
        );
        require(
            lpExecutor.GOV_RATIO_MULTIPLIER(address(token), proposalId) == GOV_RATIO_MULTIPLIER,
            "multiplier configured"
        );
        require(lpExecutor.MIN_GOV_RATIO(address(token), proposalId) == MIN_GOV_RATIO, "min ratio configured");

        _voteOne(member1, 1, proposalId, MEMBER1_VOTES);

        _advanceToPhaseStart(round + 1);
        require(lpExecutor.currentJoinRound() == round, "join round is the creation round");

        _fundMemberLp(member1, LP_JOIN_AMOUNT);
        vm.prank(member1);
        lpExecutor.join(address(token), proposalId, 1, LP_JOIN_AMOUNT);
        _assertJoinLedger(proposalId, round);

        _advanceToPhaseStart(round + 2);
        _assertSettlement(proposalId, round);
        _expectRewardAlreadyMinted(proposalId, round);
    }

    function _assertJoinLedger(uint256 proposalId, uint256 round) internal view {
        require(actionTarget.isJoined(address(token), proposalId, 1), "action target joined");
        require(lpExecutor.joinedAmount(address(token), proposalId, round) == LP_JOIN_AMOUNT, "join ledger");
        (uint256 deduction,,) = lpExecutor.deduction(address(token), proposalId, round, 1);
        require(deduction == 0, "joined at the phase start");
        require(lpPair.balanceOf(address(lpExecutor)) == LP_JOIN_AMOUNT, "lp escrowed");
    }

    function _assertSettlement(uint256 proposalId, uint256 round) internal {
        require(lpExecutor.currentMintRound() == round, "mint round reached");
        (uint256 expectedReward,) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(expectedReward > 0, "reward available");
        (uint256 expectedMint, uint256 expectedBurn) = _expectedSplit(expectedReward);

        uint256 memberBefore = token.balanceOf(member1);
        vm.prank(member1);
        (uint256 mintAmount, uint256 burnAmount) = lpExecutor.mintMemberReward(address(token), proposalId, 1, round);
        require(mintAmount == expectedMint && burnAmount == expectedBurn, "split follows the cap");
        require(token.balanceOf(member1) - memberBefore == expectedMint, "member received the mint");
        require(token.balanceOf(address(lpExecutor)) == 0, "executor keeps no reward");
        require(mint.rewardMinted(address(token)) == expectedReward, "mint ledger matches the action reward");

        (uint256 recordedMint, uint256 recordedBurn, bool minted) =
            lpExecutor.memberReward(address(token), proposalId, 1, round);
        require(minted && recordedMint == mintAmount && recordedBurn == burnAmount, "settlement recorded");
        (uint256 ratio, bool ratioMinted) = lpExecutor.govRatio(address(token), proposalId, round, 1);
        require(
            ratioMinted
                && ratio
                    == stake.validGovVotes(address(token), 1) * PRECISION / stake.globalGovVotes(address(token)),
            "gov ratio recorded"
        );
        require(lpPair.balanceOf(address(lpExecutor)) == LP_JOIN_AMOUNT, "principal untouched");
    }

    function _expectRewardAlreadyMinted(uint256 proposalId, uint256 round) internal {
        vm.prank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), proposalId, 1, round
            )
        );
        lpExecutor.mintMemberReward(address(token), proposalId, 1, round);
    }

    function _expectedSplit(uint256 proposalReward) internal view returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 totalGovVotes = stake.globalGovVotes(address(token));
        if (totalGovVotes == 0) {
            return (0, proposalReward);
        }
        uint256 govRatio = stake.validGovVotes(address(token), 1) * PRECISION / totalGovVotes;
        uint256 capped = govRatio < PRECISION ? govRatio : PRECISION;
        mintAmount = proposalReward * capped / PRECISION;
        burnAmount = proposalReward - mintAmount;
    }

    function testRealIntegration_UnallocatedRoundStaysUnsettled() external {
        uint256 round = phase.currentPhase();
        uint256 proposalId = _createLpProposal(member1, 1);
        _voteOne(member1, 1, proposalId, MEMBER1_VOTES);

        _advanceToPhaseStart(round + 2);
        require(lpExecutor.currentMintRound() == round, "mint round reached");

        // Nobody joined the round, so its reserved share has no distribution path and stays
        // unsettled for good: the reservation is never released and no member can be paid.
        (uint256 expectedShare, bool minted) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(expectedShare > 0 && !minted, "share reserved but unminted");

        vm.prank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.MemberActionRewardUnavailable.selector, address(token), proposalId, 1, round
            )
        );
        lpExecutor.mintMemberReward(address(token), proposalId, 1, round);

        (expectedShare, minted) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(!minted, "still unallocatable after the attempt");
    }


    function testRealIntegration_WithdrawAndExit() external {
        uint256 round = phase.currentPhase();
        uint256 proposalId = _createLpProposal(member1, 1);
        _voteOne(member1, 1, proposalId, MEMBER1_VOTES);
        _advanceToPhaseStart(round + 1);

        _fundMemberLp(member1, LP_JOIN_AMOUNT);
        vm.prank(member1);
        lpExecutor.join(address(token), proposalId, 1, LP_JOIN_AMOUNT);

        uint256 memberBefore = lpPair.balanceOf(member1);
        vm.prank(member1);
        lpExecutor.withdraw(address(token), proposalId, 1, LP_JOIN_AMOUNT / 4);
        require(lpPair.balanceOf(member1) - memberBefore == LP_JOIN_AMOUNT / 4, "partial withdraw returned");
        require(actionTarget.isJoined(address(token), proposalId, 1), "partial withdraw keeps the join state");
        require(
            lpExecutor.joinedAmount(address(token), proposalId, round) == LP_JOIN_AMOUNT - LP_JOIN_AMOUNT / 4,
            "balance reduced"
        );

        vm.prank(member1);
        lpExecutor.withdraw(address(token), proposalId, 1, LP_JOIN_AMOUNT - LP_JOIN_AMOUNT / 4);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "full withdraw auto exits");
        require(lpExecutor.joinedAmount(address(token), proposalId, round) == 0, "ledger cleared");

        vm.prank(member1);
        lpExecutor.join(address(token), proposalId, 1, LP_JOIN_AMOUNT / 2);
        vm.prank(member1);
        lpExecutor.exit(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "explicit exit");
        require(
            lpExecutor.joinedAmountByMemberId(address(token), proposalId, round, 1) == 0,
            "member ledger cleared"
        );

        vm.prank(member1);
        lpExecutor.join(address(token), proposalId, 1, LP_JOIN_AMOUNT / 2);
        vm.prank(member1);
        memberNFT.transferFrom(member1, member2, 1);
        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.NotMemberOwner.selector, 1));
        lpExecutor.exit(address(token), proposalId, 1);
        vm.prank(member2);
        lpExecutor.exit(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "new holder exited");
    }

    function testRealIntegration_JoinBeforeWindowRollsBack() external {
        _advanceToPhaseStart(3);
        uint256 round = phase.currentPhase();
        uint256 proposalId = _createLpProposal(member1, 1);
        _voteOne(member1, 1, proposalId, MEMBER1_VOTES);

        _fundMemberLp(member1, LP_JOIN_AMOUNT);
        uint256 lpBefore = lpPair.balanceOf(member1);
        vm.prank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.JoinNotOpen.selector, address(token), proposalId, round, round
            )
        );
        lpExecutor.join(address(token), proposalId, 1, LP_JOIN_AMOUNT);

        require(lpPair.balanceOf(member1) == lpBefore, "lp not moved");
        require(lpExecutor.joinedAmount(address(token), proposalId, round) == 0, "join ledger rolled back");
        require(lpExecutor.totalDeduction(address(token), proposalId, round) == 0, "deduction rolled back");
    }

    function testRealIntegration_AdmissionRejects() external {
        address unregisteredPair = address(new MockUniswapV2Pair(address(token), address(otherToken)));
        _createProposalExpecting(
            member1,
            1,
            _targetDataWithItem(1, abi.encode(unregisteredPair)),
            abi.encodeWithSelector(
                ILpExecutorErrors.InvalidJoinTokenFactory.selector, unregisteredPair, address(factory)
            )
        );

        _createProposalExpecting(
            member1,
            1,
            _targetDataWithItem(1, abi.encode(address(0))),
            abi.encodeWithSelector(ILpExecutorErrors.ZeroJoinTokenAddress.selector)
        );

        _createProposalExpecting(
            member1,
            1,
            _targetDataWithItem(3, abi.encode(PRECISION + 1)),
            abi.encodeWithSelector(ILpExecutorErrors.InvalidMinGovRatio.selector, PRECISION + 1)
        );

        uint256 round = phase.currentPhase();
        bytes[] memory minData = _lpTargetData();
        minData[3] = abi.encode(PRECISION);
        vm.prank(member1);
        uint256 proposalId = submit.submitNewProposal(
            address(token),
            1,
            ProposalBody({
                title: "Strict LP action",
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                targetData: minData
            })
        );
        _voteOne(member1, 1, proposalId, MEMBER1_VOTES);
        _advanceToPhaseStart(round + 1);
        _fundMemberLp(member2, LP_JOIN_AMOUNT);
        uint256 member2GovRatio = stake.validGovVotes(address(token), 2) * PRECISION / stake.globalGovVotes(address(token));
        vm.prank(member2);
        vm.expectRevert(
            abi.encodeWithSelector(ILpExecutorErrors.InsufficientGovRatio.selector, PRECISION, member2GovRatio)
        );
        lpExecutor.join(address(token), proposalId, 2, LP_JOIN_AMOUNT);
    }

    function _targetDataWithItem(uint256 position, bytes memory item) internal view returns (bytes[] memory targetData) {
        targetData = _lpTargetData();
        targetData[position] = item;
    }

    function _createProposalExpecting(
        address proposer,
        uint256 memberId,
        bytes[] memory targetData,
        bytes memory expectedRevert
    ) internal {
        vm.prank(proposer);
        vm.expectRevert(expectedRevert);
        submit.submitNewProposal(
            address(token),
            memberId,
            ProposalBody({
                title: "LP action",
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                targetData: targetData
            })
        );
    }
}
