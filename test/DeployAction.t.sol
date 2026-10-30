// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {DeployAction} from "../script/deploy/DeployAction.s.sol";

contract DeployActionHarness is DeployAction {
    function validateConfigForTest(ActionConfig memory config) external view {
        _validateConfig(config);
    }

    function deployForTest(address mint, address stake, uint256[] memory splits)
        external
        returns (DeploymentAddresses memory addrs)
    {
        addrs = _deployContracts(mint, stake, splits);
        _validateDeployment(mint, splits, addrs);
    }
}

contract MockMint {
    address public memberNFTAddress;
    address public phaseAddress;
    address public voteAddress;
    address public submitAddress;
    address public launchAddress;

    function set(address memberNFT_, address phase_, address vote_, address submit_) external {
        memberNFTAddress = memberNFT_;
        phaseAddress = phase_;
        voteAddress = vote_;
        submitAddress = submit_;
    }

    function setLaunchAddress(address launch_) external {
        launchAddress = launch_;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }

    function VOTE_ADDRESS() external view returns (address) {
        return voteAddress;
    }

    function SUBMIT_ADDRESS() external view returns (address) {
        return submitAddress;
    }

    function LAUNCH_ADDRESS() external view returns (address) {
        return launchAddress;
    }
}

contract MockLaunch {
    address public pairFactoryAddress;

    constructor(address pairFactory_) {
        pairFactoryAddress = pairFactory_;
    }

    function PAIR_FACTORY_ADDRESS() external view returns (address) {
        return pairFactoryAddress;
    }
}

contract MockStake {
    address public memberNFTAddress;
    address public phaseAddress;
    address public voteAddress;
    address public launchAddress;
    address public pairFactoryAddress;
    address public routerAddress;

    function set(
        address memberNFT_,
        address phase_,
        address vote_,
        address launch_,
        address pairFactory_,
        address router_
    ) external {
        memberNFTAddress = memberNFT_;
        phaseAddress = phase_;
        voteAddress = vote_;
        launchAddress = launch_;
        pairFactoryAddress = pairFactory_;
        routerAddress = router_;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }

    function VOTE_ADDRESS() external view returns (address) {
        return voteAddress;
    }

    function LAUNCH_ADDRESS() external view returns (address) {
        return launchAddress;
    }

    function PAIR_FACTORY_ADDRESS() external view returns (address) {
        return pairFactoryAddress;
    }

    function ROUTER_ADDRESS() external view returns (address) {
        return routerAddress;
    }
}

contract MockVote {
    address public stakeAddress;
    address public submitAddress;
    address public memberNFTAddress;
    address public phaseAddress;

    function set(address stake_, address submit_, address memberNFT_, address phase_) external {
        stakeAddress = stake_;
        submitAddress = submit_;
        memberNFTAddress = memberNFT_;
        phaseAddress = phase_;
    }

    function STAKE_ADDRESS() external view returns (address) {
        return stakeAddress;
    }

    function SUBMIT_ADDRESS() external view returns (address) {
        return submitAddress;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }
}

contract MockSubmit {
    address public stakeAddress;
    address public memberNFTAddress;
    address public phaseAddress;

    function set(address stake_, address memberNFT_, address phase_) external {
        stakeAddress = stake_;
        memberNFTAddress = memberNFT_;
        phaseAddress = phase_;
    }

    function STAKE_ADDRESS() external view returns (address) {
        return stakeAddress;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }
}

contract DeployActionTest is Test {
    DeployActionHarness internal deployer;
    address internal memberNFT;
    address internal phase;
    address internal vote;
    address internal submit;
    address internal launch;
    address internal pairFactory;
    address internal router;
    address internal mint;
    address internal stake;

    function setUp() public {
        deployer = new DeployActionHarness();
        memberNFT = makeAddr("memberNFT");
        phase = makeAddr("phase");
        pairFactory = makeAddr("pairFactory");
        router = makeAddr("router");
        launch = address(new MockLaunch(pairFactory));
        vm.etch(memberNFT, hex"00");
        vm.etch(phase, hex"00");
        vm.etch(pairFactory, hex"00");
        vm.etch(router, hex"00");

        vote = address(new MockVote());
        submit = address(new MockSubmit());
        mint = address(new MockMint());
        stake = address(new MockStake());
        MockMint(mint).set(memberNFT, phase, vote, submit);
        MockMint(mint).setLaunchAddress(launch);
        MockStake(stake).set(memberNFT, phase, vote, launch, pairFactory, router);
        MockVote(vote).set(stake, submit, memberNFT, phase);
        MockSubmit(submit).set(stake, memberNFT, phase);
    }

    function testAcceptsValidConfig() public view {
        deployer.validateConfigForTest(_validConfig());
    }

    function testDeploymentBindingGraph() public {
        DeployAction.ActionConfig memory config = _validConfig();
        DeployAction.DeploymentAddresses memory addrs =
            deployer.deployForTest(config.mint, config.stake, config.splits);
        require(addrs.actionTarget != address(0), "action target deployed");
        require(addrs.lpExecutor != address(0), "lp executor deployed");
        require(addrs.groupActionExecutor != address(0), "group action executor deployed");
        require(addrs.groupServiceExecutor != address(0), "group service executor deployed");
    }

    function testRejectsZeroSplit() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.splits = new uint256[](1);
        config.splits[0] = 0;
        vm.expectRevert("Invalid GroupAction splits");
        deployer.validateConfigForTest(config);
    }

    function testRejectsSplitAtPrecision() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.splits = new uint256[](1);
        config.splits[0] = 1e18;
        vm.expectRevert("Invalid GroupAction splits");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonIncreasingSplits() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.splits = new uint256[](2);
        config.splits[0] = 4e17;
        config.splits[1] = 3e17;
        vm.expectRevert("Invalid GroupAction splits");
        deployer.validateConfigForTest(config);
    }

    function testAcceptsEmptySplits() public view {
        DeployAction.ActionConfig memory config = _validConfig();
        config.splits = new uint256[](0);
        deployer.validateConfigForTest(config);
    }

    function testDeploymentWithEmptySplits() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.splits = new uint256[](0);
        DeployAction.DeploymentAddresses memory addrs =
            deployer.deployForTest(config.mint, config.stake, config.splits);
        require(addrs.groupActionExecutor != address(0), "group action executor deployed");
    }

    function testRejectsInvalidChainId() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.chainId = block.chainid + 1;
        vm.expectRevert("Chain ID mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractMint() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.mint = address(0x1234);
        vm.expectRevert("Mint must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractStake() public {
        DeployAction.ActionConfig memory config = _validConfig();
        config.stake = address(0x1234);
        vm.expectRevert("Stake must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsStakeMemberNFTMismatch() public {
        MockStake(stake).set(makeAddr("otherMemberNFT"), phase, vote, launch, pairFactory, router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake memberNFTAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsStakePhaseMismatch() public {
        MockStake(stake).set(memberNFT, makeAddr("otherPhase"), vote, launch, pairFactory, router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake phaseAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsStakeVoteMismatch() public {
        MockStake(stake).set(memberNFT, phase, makeAddr("otherVote"), launch, pairFactory, router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake voteAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractStakeLaunch() public {
        MockStake(stake).set(memberNFT, phase, vote, makeAddr("eoaLaunch"), pairFactory, router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake launchAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsStakeLaunchMismatch() public {
        MockStake(stake).set(memberNFT, phase, vote, address(new MockLaunch(pairFactory)), pairFactory, router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake launchAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsStakePairFactoryMismatch() public {
        MockStake(stake).set(memberNFT, phase, vote, launch, address(new MockLaunch(makeAddr("otherFactory"))), router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake pairFactoryAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractStakePairFactory() public {
        MockStake(stake).set(memberNFT, phase, vote, launch, makeAddr("eoaFactory"), router);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake pairFactoryAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractStakeRouter() public {
        MockStake(stake).set(memberNFT, phase, vote, launch, pairFactory, makeAddr("eoaRouter"));
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Stake routerAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsVoteStakeMismatch() public {
        MockVote(vote).set(makeAddr("otherStake"), submit, memberNFT, phase);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Vote stakeAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsSubmitStakeMismatch() public {
        MockSubmit(submit).set(makeAddr("otherStake"), memberNFT, phase);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Submit stakeAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractMintMemberNFT() public {
        MockMint(mint).set(makeAddr("eoa"), phase, vote, submit);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Mint memberNFTAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractMintPhase() public {
        MockMint(mint).set(memberNFT, makeAddr("eoa"), vote, submit);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Mint phaseAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractMintVote() public {
        MockMint(mint).set(memberNFT, phase, makeAddr("eoa"), submit);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Mint voteAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractMintSubmit() public {
        MockMint(mint).set(memberNFT, phase, vote, makeAddr("eoa"));
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Mint submitAddress must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsVoteSubmitMismatch() public {
        MockVote(vote).set(stake, makeAddr("otherSubmit"), memberNFT, phase);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Vote submitAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsVoteMemberNFTMismatch() public {
        MockVote(vote).set(stake, submit, makeAddr("otherMemberNFT"), phase);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Vote memberNFTAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsVotePhaseMismatch() public {
        MockVote(vote).set(stake, submit, memberNFT, makeAddr("otherPhase"));
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Vote phaseAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsSubmitMemberNFTMismatch() public {
        MockSubmit(submit).set(stake, makeAddr("otherMemberNFT"), phase);
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Submit memberNFTAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsSubmitPhaseMismatch() public {
        MockSubmit(submit).set(stake, memberNFT, makeAddr("otherPhase"));
        DeployAction.ActionConfig memory config = _validConfig();
        vm.expectRevert("Submit phaseAddress mismatch");
        deployer.validateConfigForTest(config);
    }

    function _validConfig() internal view returns (DeployAction.ActionConfig memory config) {
        config.chainId = block.chainid;
        config.mint = mint;
        config.stake = stake;
        config.splits = new uint256[](3);
        config.splits[0] = 1e17;
        config.splits[1] = 4e17;
        config.splits[2] = 7e17;
    }
}
