// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTarget} from "../../src/ActionTarget.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupActionCreationParams} from "../../src/interfaces/IGroupActionExecutor.sol";
import {GroupServiceCreationParams} from "../../src/interfaces/IGroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {IMemberRewardExecutor, MemberRewardStatus} from "../../src/interfaces/IMemberRewardExecutor.sol";
import {IActionTargetErrors} from "../../src/interfaces/IActionTarget.sol";
import {MockExecutor} from "../mocks/ActionTargetMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Router} from "../mocks/UniswapV2Mocks.sol";
import {Phase} from "@core/Phase.sol";
import {MemberNFT} from "@core/MemberNFT.sol";
import {Mint} from "@core/Mint.sol";
import {Vote} from "@core/Vote.sol";
import {Submit, ProposalBody} from "@core/Submit.sol";
import {Stake} from "@core/Stake.sol";
import {DexConfig} from "@core/interfaces/IStake.sol";
import {Launch} from "@core/Launch.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {LaunchInitParams} from "@core/interfaces/ILaunch.sol";
import {TargetMode} from "@core/interfaces/ISubmit.sol";
import {IMintErrors} from "@core/interfaces/IMint.sol";
import {Vm} from "@forge-std/Vm.sol";

abstract contract ActionTargetIntegrationFixture {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PHASE_ORIGIN = 100;
    uint256 internal constant BLOCKS_PER_PHASE = 1000;
    uint256 internal constant ROLL_PAST_ROUND0 = 200;
    uint256 internal constant STAKE_AMOUNT = 5000;
    uint256 internal constant BOOST_AMOUNT = 100;
    uint256 internal constant MEMBER1_VOTES = 100;
    uint256 internal constant MEMBER2_VOTES = 60;
    uint256 internal constant BELOW_THRESHOLD_VOTES = 5;
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

    function _setUpProtocol(uint256 submitMinRatio, uint256 proposalMinVoteRatio) internal {
        phase = new Phase(PHASE_ORIGIN, BLOCKS_PER_PHASE, 3600, 10, 50);
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router();
        rootToken = new LOVE20Token("RootCommunity", "ROOT", 1000000, 100000000, owner, owner, address(this));

        uint256 nonce = vm.getNonce(address(this));
        address predictedMemberNFT = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVote = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedMint = vm.computeCreateAddress(address(this), nonce + 5);

        launch = new Launch(
            LaunchInitParams({
                mintAddress: predictedMint,
                memberNFTAddress: predictedMemberNFT,
                rootParentTokenAddress: address(rootToken),
                pairFactoryAddress: address(factory),
                distributor: distributor,
                launchCountThresholdRatio: 1e16,
                maxLaunchCount: 1000,
                tokenSymbolLength: 4,
                launchAmount: 50000,
                maxSupply: 1000000,
                name: "TestCommunity",
                symbol: "TEST"
            })
        );
        token = LOVE20Token(launch.FIRST_TOKEN_ADDRESS());

        memberNFT = new MemberNFT(1e18, 4, 2, 20, address(token));
        stake = new Stake(
            address(phase),
            address(memberNFT),
            predictedVote,
            address(launch),
            DexConfig({
                router: address(router),
                pairFactory: address(factory),
                swapFeeForLpRatio: 3000000000000000,
                swapFeeForProtocolRatio: 0
            }),
            1,
            100,
            3e15, // fee settlement ratio from the integration profile (0.3%)
            2,
            5
        );
        submit = new Submit(address(phase), address(stake), address(memberNFT), submitMinRatio);
        vote = new Vote(address(phase), address(stake), address(submit), address(memberNFT), predictedMint);
        mint = new Mint(
            address(phase), address(vote), address(submit), address(launch), address(memberNFT), proposalMinVoteRatio, 1e17, 1e17
        );

        actionTarget = new ActionTarget(address(mint));
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
        stake.stakeLiquidity(address(token), STAKE_AMOUNT, STAKE_AMOUNT, PROMISED_WAITING_PHASES, 1, type(uint256).max);
        stake.stakeBoost(address(token), BOOST_AMOUNT, PROMISED_WAITING_PHASES, 1, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(member2);
        memberNFT.mint("Bob");
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT, STAKE_AMOUNT, PROMISED_WAITING_PHASES, 2, type(uint256).max);
        stake.stakeBoost(address(token), BOOST_AMOUNT, PROMISED_WAITING_PHASES, 2, type(uint256).max);
        vm.stopPrank();
    }

    function _executorTargetData(address executorAddress) internal pure returns (bytes memory) {
        return abi.encodePacked(executorAddress);
    }

    function _createActionProposal(uint256 memberId) internal returns (uint256 proposalId) {
        return _submitActionProposal(memberId, "Action proposal", _executorTargetData(address(executor)));
    }

    function _submitActionProposal(uint256 memberId, string memory title, bytes memory creationData)
        internal returns (uint256 proposalId)
    {
        address proposer = memberNFT.ownerOf(memberId);
        vm.prank(proposer);
        proposalId = submit.submitNewProposal(
            address(token),
            memberId,
            ProposalBody({
                title: title,
                details: "details",
                target: address(actionTarget),
                targetMode: TargetMode.Callback,
                creationData: creationData
            }),
            ""
        );
    }

    function _voteOne(
        uint256 memberId,
        uint256 proposalId,
        uint256 votes,
        bytes memory proposalVoteData
    ) internal {
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = votes;
        bytes[] memory voteData = new bytes[](1);
        voteData[0] = proposalVoteData;
        vm.prank(memberId == 1 ? member1 : member2);
        vote.vote(address(token), memberId, proposalIds, amounts, voteData);
    }
}

contract ActionTargetRealIntegrationTest is ActionTargetIntegrationFixture {
    function setUp() public {
        _setUpProtocol(5e16, 5e16);
    }

    function testRealIntegration_GroupActionCreationForwardsConfig() external {
        GroupActionExecutor groupExecutor = new GroupActionExecutor(address(actionTarget));
        string[] memory keys = new string[](2);
        keys[0] = "account";
        keys[1] = "submission";
        string[] memory descriptions = new string[](2);
        descriptions[0] = "Account used to complete the action";
        descriptions[1] = "Link to the submitted work";

        uint256 proposalId = _createGroupActionProposal(groupExecutor, 0, keys, descriptions);
        require(actionTarget.executorByActionId(address(token), proposalId) == address(groupExecutor), "group executor bound");
        require(groupExecutor.requiredVerifierStake(address(token), proposalId) == 40, "stake forwarded");
        require(groupExecutor.verifierPunishmentRatio(address(token), proposalId) == 9e17, "punishment ratio forwarded");
        (string[] memory savedKeys, string[] memory savedDescriptions) =
            groupExecutor.verificationSchema(address(token), proposalId);
        require(
            keccak256(abi.encode(savedKeys, savedDescriptions)) == keccak256(abi.encode(keys, descriptions)),
            "verification schema forwarded"
        );
    }

    function _createGroupActionProposal(
        GroupActionExecutor groupExecutor,
        uint256 activationStake,
        string[] memory keys,
        string[] memory descriptions
    ) internal returns (uint256) {
        bytes memory creationData = abi.encodePacked(address(groupExecutor), abi.encode(GroupActionCreationParams({
            joinTokenAddress: address(token),
            activationStakeAmount: activationStake,
            maxJoinAmountRatio: 1e18,
            activationMinGovRatio: 0,
            verifierStakeAmount: 40,
            verifierPunishmentRatio: 9e17,
            verificationKeys: keys,
            verificationDescriptions: descriptions
        })));
        return _submitActionProposal(1, "Group action", creationData);
    }

    function _createServiceActionProposal(GroupServiceExecutor service) internal returns (uint256) {
        bytes memory creationData =
            abi.encodePacked(address(service), abi.encode(GroupServiceCreationParams(address(token), 0, 5e17, 0)));
        return _submitActionProposal(2, "Group service", creationData);
    }

    function _createBelowThresholdProposal() internal returns (uint256) {
        vm.startPrank(member1);
        (uint256 proposerId,) = memberNFT.mint("Carol");
        stake.stakeLiquidity(address(token), 100, 100, PROMISED_WAITING_PHASES, proposerId, type(uint256).max);
        uint256 proposalId = submit.submitNewProposal(
            address(token),
            proposerId,
            ProposalBody({
                title: "Below-threshold proposal",
                details: "",
                target: member1,
                targetMode: TargetMode.NoCallback,
                creationData: ""
            }),
            ""
        );
        vm.stopPrank();
        return proposalId;
    }

    function testRealIntegration_OwnerClaimsHistoricalRewardAfterDeactivation() external {
        GroupActionExecutor group = new GroupActionExecutor(address(actionTarget));
        GroupServiceExecutor service = new GroupServiceExecutor(address(group));
        uint256 sourceActionId = _createGroupActionProposal(group, 100, new string[](0), new string[](0));
        uint256 serviceActionId = _createServiceActionProposal(service);
        uint256 belowThresholdProposalId = _createBelowThresholdProposal();
        uint256 round = phase.currentPhase();

        vm.startPrank(member2);
        token.approve(address(group), type(uint256).max);
        group.submitVerifierApplication(address(token), sourceActionId, 2, "verifier");
        vm.stopPrank();
        bytes memory verifierVote = abi.encode(uint256(2));
        _voteOne(1, sourceActionId, MEMBER1_VOTES, verifierVote);
        _voteOne(2, serviceActionId, MEMBER2_VOTES, "");
        _voteOne(1, belowThresholdProposalId, BELOW_THRESHOLD_VOTES, "");

        vm.roll(block.number + BLOCKS_PER_PHASE);
        vm.startPrank(member1);
        token.approve(address(group), 100);
        group.activateGroup(address(token), sourceActionId, 1, GroupConfig({
            description: "Alice's group", maxCapacity: 0, minJoinAmount: 1, maxJoinAmount: 0, maxAccounts: 0
        }));
        service.join(address(token), serviceActionId, 1);
        vm.stopPrank();
        vm.startPrank(member2);
        group.join(address(token), sourceActionId, 1, 2, 100, 0, new string[](0));
        service.join(address(token), serviceActionId, 2);
        vm.stopPrank();

        vm.roll(block.number + BLOCKS_PER_PHASE);
        vm.prank(member1);
        group.deactivateGroup(address(token), sourceActionId, 1);
        require(!group.hasActiveGroups(address(token), 1), "activation list is empty");
        require(group.totalGeneratedActionReward(address(token), round) == 0, "no verified action yet");
        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;
        vm.prank(member2);
        group.submitOriginScores(address(token), sourceActionId, 2, 1, 0, scores);

        uint256 pool = mint.proposalReward(address(token), round);
        uint256 totalVotes = MEMBER1_VOTES + MEMBER2_VOTES + BELOW_THRESHOLD_VOTES;
        uint256 sourceReward = pool * MEMBER1_VOTES / totalVotes;
        require(sourceReward > 0 && group.totalGeneratedActionReward(address(token), round) == sourceReward, "round total");
        require(
            group.totalGeneratedActionRewardByGroupId(address(token), round, 1) == sourceReward,
            "group weight is available after verification"
        );
        require(
            group.totalGeneratedActionRewardByVerifierId(address(token), round, 2) == sourceReward,
            "elected verifier's action total"
        );
        {
            (uint256 unqualifiedReward,) = mint.proposalRewardSettlement(address(token), round, belowThresholdProposalId);
            require(unqualifiedReward == 0, "below-threshold proposal cannot mint");
            (uint256[] memory actionIds, uint256 totalCount) =
                group.joinedActionIdsByGroupId(address(token), 1, round, 0, 10, false);
            require(totalCount == 1 && actionIds[0] == sourceActionId, "historical participation remains");
        }

        vm.roll(block.number + BLOCKS_PER_PHASE);
        (uint256 serviceReward,) = actionTarget.actionReward(address(token), round, serviceActionId);
        require(serviceReward == pool * MEMBER2_VOTES / totalVotes, "service uses total round votes");
        _assertServiceClaims(service, round, serviceActionId, serviceReward);
        require(group.totalGeneratedActionReward(address(token), round) == sourceReward, "round total stays fixed");
    }

    function _assertServiceClaims(
        GroupServiceExecutor service,
        uint256 round,
        uint256 serviceActionId,
        uint256 serviceReward
    )
        internal
    {
        IMemberRewardExecutor rewards = IMemberRewardExecutor(address(service));
        (uint256 preview,, MemberRewardStatus status) = rewards.memberReward(address(token), round, serviceActionId, 1);
        require(status == MemberRewardStatus.Pending && preview == serviceReward / 2 && preview > 0, "owner preview after deactivation");
        uint256 balanceBefore = token.balanceOf(member1);
        vm.prank(member1);
        uint256 paid = rewards.mintMemberReward(address(token), round, serviceActionId, 1);
        require(paid == preview && token.balanceOf(member1) - balanceBefore == paid, "owner paid");

        vm.prank(member2);
        paid = rewards.mintMemberReward(address(token), round, serviceActionId, 2);
        require(paid == serviceReward / 2, "verifier paid from recorded weight");
    }

    function testRealIntegration_CustomExecutorWithoutMemberRewardCanMintActionReward() external {
        uint256 proposalId = _createActionProposal(1);
        require(proposalId == 1, "first proposal");
        _assertCreationCallbacks(proposalId);

        uint256 round = phase.currentPhase();
        _voteWithBusinessData(round, proposalId);
        _assertVoteCallbackFailureRollsBack(proposalId);
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
                == keccak256(""),
            "creation data forwarded verbatim"
        );
        require(
            executor.lastSubmittedTargetDataHash()
                == keccak256(""),
            "submission data forwarded verbatim"
        );
    }

    function _voteWithBusinessData(uint256 round, uint256 proposalId) internal {
        bytes memory voteData = abi.encode(uint256(42));
        _voteOne(1, proposalId, MEMBER1_VOTES, voteData);
        require(executor.votedCalls() == 1, "vote callback forwarded");
        require(executor.lastVotedRound() == round, "vote round forwarded");
        require(executor.lastVotedProposalId() == proposalId, "proposal id forwarded");
        require(executor.lastVotedVoterId() == 1, "voter id forwarded");
        require(executor.lastVotedVotes() == MEMBER1_VOTES, "vote amount forwarded");
        require(executor.lastVotedTargetDataHash() == keccak256(voteData), "vote data forwarded");
    }

    function _assertVoteCallbackFailureRollsBack(uint256 proposalId) internal {
        executor.setRevertVoted(true);
        uint256 beforeAmount = vote.voteAmountByProposalId(address(token), vote.currentRound(), proposalId);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.VotedCallbackReverted.selector));
        _voteOne(1, proposalId, 1, abi.encode(uint256(42)));
        require(executor.votedCalls() == 1, "failed callback rolled back");
        require(
            vote.voteAmountByProposalId(address(token), vote.currentRound(), proposalId) == beforeAmount, "vote rolled back"
        );
        executor.setRevertVoted(false);
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
                creationData: ""
            }),
            ""
        );
        _voteOne(1, plainId, 10, "");

        (uint256[] memory actionIds, address[] memory executors, uint256 total) =
            actionTarget.votedActionIds(address(token), round, 0, 10, false);
        require(total == 1 && actionIds.length == 1, "only bound voted actions");
        require(actionIds[0] == 1, "bound action id");
        require(executors[0] == address(executor), "executor aligned");
        require(executor.votedCalls() == 1, "plain proposal does not call the executor");
    }

    function _assertMint(uint256 round, uint256 proposalId) internal {
        (uint256 expectedAmount,) = mint.proposalRewardSettlement(address(token), round, proposalId);
        require(expectedAmount > 0, "reward available");
        (uint256 quotedAmount, bool mintedBefore) = actionTarget.actionReward(address(token), round, proposalId);
        require(quotedAmount == expectedAmount && mintedBefore == false, "expected amount before mint");
        uint256 amount = executor.mintActionBudget(address(token), round, proposalId);
        require(amount == expectedAmount, "minted amount matches quote");
        require(token.balanceOf(address(executor)) == amount, "executor received the full reward");
        require(mint.totalRewardMinted(address(token)) == amount, "mint ledger matches");
        (uint256 recorded, bool mintedFlag) = actionTarget.actionReward(address(token), round, proposalId);
        require(recorded == amount && mintedFlag, "action reward query");

        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), round, proposalId)
        );
        executor.mintActionBudget(address(token), round, proposalId);
    }

    function testRealIntegration_JoinWindowAndForceClearJoinState() external {
        bytes memory badData = _executorTargetData(address(0xdead));
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
                creationData: badData
            }),
            ""
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
            actionTarget.isJoinedByRound(address(token), createdRound, proposalId, 1),
            "snapshot lands on the first join round"
        );
        (uint256[] memory memberIds, uint256 total) =
            actionTarget.memberIdsByActionId(address(token), createdRound, proposalId, 0, 10, false);
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
        _voteOne(1, proposalId, MEMBER1_VOTES, "");
        vm.roll(block.number + BLOCKS_PER_PHASE);
        require(vote.isRoundEnded(round), "round ended");

        uint256 supplyBefore = token.totalSupply();
        (uint256 expectedShare, bool settledBefore) = actionTarget.actionReward(address(token), round, proposalId);
        require(expectedShare > 0 && !settledBefore, "expected share before settlement");

        vm.prank(address(executor));
        uint256 settled = actionTarget.mintActionReward(address(token), round, proposalId);
        require(settled == expectedShare, "settled share");
        require(token.balanceOf(address(executor)) == settled, "reward minted straight to the executor");
        require(token.totalSupply() == supplyBefore + settled, "supply grew by the reward");

        (uint256 recorded, bool settledAfter) = actionTarget.actionReward(address(token), round, proposalId);
        require(recorded == settled && settledAfter, "settled query");

        // ActionTarget holds no void path any more: a repeat settlement is rejected by Mint, and no
        // protocol path burns an unallocatable reward (ADR-004). The burn below only probes the
        // token ledger.
        vm.prank(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), round, proposalId)
        );
        actionTarget.mintActionReward(address(token), round, proposalId);

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
        actionTarget.mintActionReward(address(token), round, proposalId);
    }
}
