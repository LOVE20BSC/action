// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../../src/ActionTarget.sol";
import {IActionTargetErrors} from "../../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "../mocks/ActionTargetMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Router} from "../mocks/UniswapV2Mocks.sol";
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
import {IMintErrors} from "@core/interfaces/IMint.sol";

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
        // Fee settlement ratio: 0.3% of the withdrawable LP per settlement.
        stake.init(address(phase), address(memberNFT), address(vote), address(launch), address(router), address(factory), 1, 100, 3e15);
        vote.init(address(phase), address(stake), address(submit), address(memberNFT));
        mint.init(address(vote), address(submit), address(launch), address(memberNFT), 5e16, 1e17, 1e17, 2);

        actionTarget = new ActionTarget();
        actionTarget.init(address(mint));
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
        require(actionTarget.executorByActionId(address(token), proposalId) == address(executor), "executor bound");
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
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionTargetErrors.TargetDataExecutorMismatch.selector, address(executor), address(0xdead)
            )
        );
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
        (uint256 quotedAmount, bool mintedBefore) = actionTarget.actionReward(address(token), proposalId, round);
        require(quotedAmount == expectedAmount && mintedBefore == false, "expected amount before mint");
        vm.prank(address(executor));
        uint256 amount = actionTarget.mintActionReward(address(token), proposalId, round);
        require(amount == expectedAmount, "minted amount matches quote");
        require(token.balanceOf(address(executor)) == amount, "executor received the full reward");
        require(mint.rewardMinted(address(token)) == amount, "mint ledger matches");
        (uint256 recorded, bool mintedFlag) = actionTarget.actionReward(address(token), proposalId, round);
        require(recorded == amount && mintedFlag, "action reward query");

        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), round, proposalId)
        );
        actionTarget.mintActionReward(address(token), proposalId, round);
    }

    function testRealIntegration_JoinWindowAndForceClearJoinState() external {
        bytes[] memory badData = new bytes[](1);
        badData[0] = abi.encode(address(0xdead));
        vm.prank(member1);
        vm.expectRevert(
            abi.encodeWithSelector(IActionTargetErrors.ExecutorNotContract.selector, address(0xdead))
        );
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
        actionTarget.forceClearJoinState(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "force clear cleared");
        vm.prank(address(executor));
        actionTarget.clearJoinState(address(token), proposalId, 1);
        require(actionTarget.isJoined(address(token), proposalId, 1) == false, "clear after forceClearJoinState is idempotent");
    }

    function testRealIntegration_SettlesToExecutorAndVoidsNothing() external {
        uint256 proposalId = _createActionProposal(1);
        uint256 round = phase.currentPhase();
        _voteOne(1, proposalId, MEMBER1_VOTES, new bytes[](0));
        vm.roll(block.number + BLOCKS_PER_PHASE);
        require(vote.isRoundEnded(round), "round ended");

        uint256 supplyBefore = token.totalSupply();
        (uint256 expectedShare, bool settledBefore) = actionTarget.actionReward(address(token), proposalId, round);
        require(expectedShare > 0 && !settledBefore, "expected share before settlement");

        vm.prank(address(executor));
        uint256 settled = actionTarget.mintActionReward(address(token), proposalId, round);
        require(settled == expectedShare, "settled share");
        require(token.balanceOf(address(executor)) == settled, "reward minted straight to the executor");
        require(token.totalSupply() == supplyBefore + settled, "supply grew by the reward");

        (uint256 recorded, bool settledAfter) = actionTarget.actionReward(address(token), proposalId, round);
        require(recorded == settled && settledAfter, "settled query");

        // ActionTarget holds no void path any more: a repeat settlement is rejected by Mint, and no
        // protocol path burns an unallocatable reward (ADR-004). The burn below only probes the
        // token ledger.
        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), round, proposalId)
        );
        actionTarget.mintActionReward(address(token), proposalId, round);

        vm.prank(address(executor));
        token.burn(settled);
        require(token.totalSupply() == supplyBefore, "destroying restores supply");
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
