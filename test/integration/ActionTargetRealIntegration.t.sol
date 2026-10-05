// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../../src/ActionTarget.sol";
import {IActionTargetErrors} from "../../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "../mocks/ActionTargetMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Router} from "../mocks/UniswapV2Mocks.sol";
import {Phase} from "core/src/Phase.sol";
import {MemberNFT} from "core/src/MemberNFT.sol";
import {Mint} from "core/src/Mint.sol";
import {Vote} from "core/src/Vote.sol";
import {Submit, ProposalBody} from "core/src/Submit.sol";
import {Stake} from "core/src/Stake.sol";
import {Launch} from "core/src/Launch.sol";
import {LOVE20Token} from "core/src/LOVE20Token.sol";
import {LaunchInitParams} from "core/src/interfaces/ILaunch.sol";
import {TargetMode} from "core/src/interfaces/ISubmit.sol";
import {IMintErrors} from "core/src/interfaces/IMint.sol";

interface ActionTargetIntegrationVm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function roll(uint256 blockNumber) external;
    function expectRevert(bytes calldata data) external;
}

contract ActionTargetRealIntegrationTest {
    ActionTargetIntegrationVm internal constant vm =
        ActionTargetIntegrationVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PHASE_ORIGIN = 100;
    uint256 internal constant BLOCKS_PER_PHASE = 1000;
    uint256 internal constant ROLL_PAST_ROUND0 = 200;
    uint256 internal constant STAKE_AMOUNT = 5000;
    uint256 internal constant BOOST_AMOUNT = 100;
    uint256 internal constant MEMBER1_VOTES = 100;
    uint256 internal constant MEMBER2_VOTES = 60;
    uint256 internal constant SLIPPAGE_100_PERCENT = 1e18;
    uint256 internal constant PROMISED_WAITING_PHASES = 1;
    uint256 internal constant TOKEN_TRANSFER_AMOUNT = 10000;

    Phase internal phase;
    MemberNFT internal memberNFT;
    Mint internal mint;
    Vote internal vote;
    Submit internal submit;
    Stake internal stake;
    Launch internal launch;
    ActionTarget internal actionTarget;
    MockExecutor internal executor;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router internal router;
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
        rootToken = new LOVE20Token("RootCommunity", "ROOT", 1000000, 100000000, owner, owner, address(1));
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

        submit.init(address(phase), address(stake), address(memberNFT), 50);
        stake.init(address(phase), address(memberNFT), address(vote), address(launch), address(router), address(factory), 1, 100, 10);
        vote.init(address(phase), address(stake), address(submit), address(memberNFT));
        mint.init(address(vote), address(submit), address(launch), address(memberNFT), 50, 100, 100, 2);

        actionTarget = new ActionTarget();
        actionTarget.init(address(memberNFT), address(submit), address(vote), address(mint));
        executor = new MockExecutor(address(actionTarget));

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

    function _executorTargetData(address executorAddress) internal pure returns (bytes[] memory targetData) {
        targetData = new bytes[](1);
        targetData[0] = abi.encode(executorAddress);
    }

    function _createActionProposal(uint256 memberId) internal returns (uint256 proposalId) {
        vm.prank(memberId == 1 ? member1 : member2);
        proposalId = submit.submitNewProposal(
            address(token),
            memberId,
            ProposalBody({
                title: "Action proposal",
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                targetData: _executorTargetData(address(executor))
            })
        );
    }

    function _voteOne(
        uint256 memberId,
        uint256 proposalId,
        uint256 votes,
        bytes[] memory proposalTargetData
    ) internal {
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = votes;
        bytes[][] memory targetData = new bytes[][](1);
        targetData[0] = proposalTargetData;
        vm.prank(memberId == 1 ? member1 : member2);
        vote.vote(address(token), memberId, proposalIds, amounts, targetData);
    }

    function testRealIntegration_ActionLifecycle() external {
        uint256 proposalId = _createActionProposal(1);
        require(proposalId == 1, "first proposal");
        _assertCreationCallbacks(proposalId);

        uint256 round = phase.currentPhase();
        _voteWithBusinessData(round, proposalId);
        _rejectMismatchedVoteData(proposalId);
        _votePlainProposal(round);

        vm.roll(block.number + BLOCKS_PER_PHASE);
        require(phase.currentPhase() > round, "round advanced");
        require(vote.isRoundEnded(round), "round ended");
        _assertMint(round, proposalId);
    }

    function _assertCreationCallbacks(uint256 proposalId) internal view {
        require(actionTarget.executor(address(token), proposalId) == address(executor), "executor bound");
        require(executor.createdCalls() == 1, "creation callback forwarded");
        require(executor.submittedCalls() == 1, "submission callback forwarded");
        require(
            executor.lastCreatedTargetDataHash()
                == keccak256(abi.encode(_executorTargetData(address(executor)))),
            "creation target data forwarded verbatim"
        );
        require(
            executor.lastSubmittedTargetDataHash()
                == keccak256(abi.encode(_executorTargetData(address(executor)))),
            "submission target data forwarded verbatim"
        );
    }

    function _voteWithBusinessData(uint256 round, uint256 proposalId) internal {
        bytes[] memory voteTargetData = new bytes[](2);
        voteTargetData[0] = abi.encode(address(executor));
        voteTargetData[1] = abi.encode(uint256(42));
        _voteOne(1, proposalId, MEMBER1_VOTES, voteTargetData);
        require(executor.votedCalls() == 1, "vote callback forwarded");
        require(executor.lastVotedRound() == round, "vote round forwarded");
        require(executor.lastVotedProposalId() == proposalId, "proposal id forwarded");
        require(executor.lastVotedVoterId() == 1, "voter id forwarded");
        require(executor.lastVotedVotes() == MEMBER1_VOTES, "vote amount forwarded");
        require(executor.lastVotedTargetDataHash() == keccak256(abi.encode(voteTargetData)), "vote data forwarded");
    }

    function _rejectMismatchedVoteData(uint256 proposalId) internal {
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = MEMBER1_VOTES;
        bytes[][] memory mismatchedData = new bytes[][](1);
        mismatchedData[0] = new bytes[](1);
        mismatchedData[0][0] = abi.encode(address(0xdead));
        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        vote.vote(address(token), 1, proposalIds, amounts, mismatchedData);
        require(executor.votedCalls() == 1, "failed callback rolled the vote back");
    }

    function _votePlainProposal(uint256 round) internal {
        vm.prank(member2);
        uint256 plainId = submit.submitNewProposal(
            address(token),
            2,
            ProposalBody({
                title: "Plain proposal",
                details: "details",
                target: address(0x4001),
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );
        _voteOne(1, plainId, 10, new bytes[](0));

        (uint256[] memory actionIds, address[] memory executors, uint256 total) =
            actionTarget.votedActions(address(token), round, 0, 10, false);
        require(total == 1 && actionIds.length == 1, "only bound voted actions");
        require(actionIds[0] == 1, "bound action id");
        require(executors[0] == address(executor), "executor aligned");
        require(executor.votedCalls() == 1, "plain proposal does not call the executor");
    }

    function _assertMint(uint256 round, uint256 proposalId) internal {
        (uint256 expectedAmount,) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(expectedAmount > 0, "reward available");
        vm.prank(address(executor));
        uint256 amount = actionTarget.mintActionReward(address(token), proposalId, round);
        require(amount == expectedAmount, "minted amount matches quote");
        require(token.balanceOf(address(executor)) == amount, "executor received the full reward");
        require(mint.rewardMinted(address(token)) == amount, "mint ledger matches");
        (uint256 recorded, bool mintedFlag) = actionTarget.actionReward(address(token), proposalId, round);
        require(recorded == amount && mintedFlag, "action reward query");

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.AlreadyMinted.selector, address(token), proposalId, round)
        );
        actionTarget.mintActionReward(address(token), proposalId, round);
    }

    function testRealIntegration_JoinWindowAndForceExit() external {
        bytes[] memory badData = new bytes[](1);
        badData[0] = abi.encode(address(0xdead));
        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(IActionTargetErrors.InvalidExecutor.selector));
        submit.submitNewProposal(
            address(token),
            1,
            ProposalBody({
                title: "Bad executor",
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                targetData: badData
            })
        );

        uint256 proposalId = _createActionProposal(1);
        uint256 createdRound = phase.currentPhase();

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.JoinNotOpen.selector, address(token), proposalId, createdRound, createdRound
            )
        );
        actionTarget.registerJoinState(address(token), proposalId, 1);

        vm.roll(block.number + BLOCKS_PER_PHASE);
        require(phase.currentPhase() == createdRound + 1, "advanced exactly one round");

        vm.prank(address(executor));
        actionTarget.registerJoinState(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1), "joined");
        require(
            actionTarget.isJoinedByRound(address(token), proposalId, 1, createdRound),
            "snapshot lands on the first join round"
        );
        (uint256[] memory memberIds, uint256 total) =
            actionTarget.memberIdsByActionId(address(token), proposalId, createdRound, 0, 10, false);
        require(total == 1 && memberIds[0] == 1, "first join window list");

        vm.prank(member1);
        actionTarget.forceExit(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "force exit cleared");
        vm.prank(address(executor));
        actionTarget.clearJoinState(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "clear after forceExit is idempotent");
    }

    function testRealIntegration_BurnSettlement() external {
        uint256 proposalId = _createActionProposal(1);
        uint256 round = phase.currentPhase();
        _voteOne(1, proposalId, MEMBER1_VOTES, new bytes[](0));
        vm.roll(block.number + BLOCKS_PER_PHASE);
        require(vote.isRoundEnded(round), "round ended");

        executor.setNeedBurn(true);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        uint256 supplyBefore = token.totalSupply();
        uint256 executorBalanceBefore = token.balanceOf(address(executor));
        (uint256 expectedBurn,) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(expectedBurn > 0, "burnable reward");

        vm.prank(address(0xBEEF));
        actionTarget.burnRewardIfNeeded(address(token), proposalId, round);

        require(mint.rewardBurned(address(token)) - burnedBefore == expectedBurn, "mint burned ledger");
        (uint256 recorded, bool burned) = actionTarget.burnInfo(address(token), proposalId, round);
        require(recorded == expectedBurn && burned, "action burn ledger matches mint");
        require(token.totalSupply() == supplyBefore, "burn moves no tokens");
        require(token.balanceOf(address(executor)) == executorBalanceBefore, "executor balance untouched");
        (, bool settled) = mint.proposalRewardByProposalId(address(token), round, proposalId);
        require(settled, "proposal settled by burn");

        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        actionTarget.mintActionReward(address(token), proposalId, round);

        vm.prank(address(0xBEEF));
        actionTarget.burnRewardIfNeeded(address(token), proposalId, round);
        require(mint.rewardBurned(address(token)) - burnedBefore == expectedBurn, "repeat burn is a no-op");
    }

    function testRealIntegration_UnvotedActionCannotMint() external {
        uint256 proposalId = _createActionProposal(2);
        uint256 round = phase.currentPhase();
        require(vote.isProposalIdVoted(address(token), round, proposalId) == false, "not voted yet");
        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.ProposalNotVoted.selector, address(token), proposalId)
        );
        actionTarget.mintActionReward(address(token), proposalId, round);
    }
}
