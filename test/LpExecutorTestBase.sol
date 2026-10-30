// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LpExecutor} from "../src/LpExecutor.sol";
import {
    MockERC20,
    MockLpActionTarget,
    MockLpMemberNFT,
    MockLpPhase,
    MockLpStake
} from "./mocks/LpExecutorMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair} from "./mocks/UniswapV2Mocks.sol";

interface LpExecutorVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function assume(bool condition) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function roll(uint256 blockNumber) external;
}

abstract contract LpExecutorTestBase {
    LpExecutorVm internal constant vm = LpExecutorVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant ACTION_ID = 11;
    uint256 internal constant SECOND_ACTION_ID = 12;
    uint256 internal constant PHASE_BLOCKS = 1000;
    uint256 internal constant CREATION_PHASE = 2;
    uint256 internal constant PROPOSAL_REWARD = 1000e18;
    uint256 internal constant GOV_RATIO_MULTIPLIER = 2e18;
    uint256 internal constant MIN_GOV_RATIO = 1e17;
    uint256 internal constant JOIN_BALANCE = 1e36;

    address internal constant MEMBER1 = address(0x1001);
    address internal constant MEMBER2 = address(0x1002);
    address internal constant MEMBER3 = address(0x1003);
    address internal constant OUTSIDER = address(0x2001);

    LpExecutor internal lpExecutor;
    MockLpPhase internal phase;
    MockLpStake internal stake;
    MockLpMemberNFT internal memberNFT;
    MockLpActionTarget internal actionTarget;
    MockERC20 internal token;
    MockERC20 internal lpBaseToken;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Pair internal joinToken;

    function setUp() public virtual {
        _deployMocks();
        lpExecutor = new LpExecutor();
        lpExecutor.init(address(actionTarget), address(stake));
        _configurePhase();
        _createAction(ACTION_ID);
        _atPhase(3);
        _fundMembers();
    }

    function _deployMocks() internal {
        phase = new MockLpPhase();
        stake = new MockLpStake();
        memberNFT = new MockLpMemberNFT();
        memberNFT.setOwner(1, MEMBER1);
        memberNFT.setOwner(2, MEMBER2);
        memberNFT.setOwner(3, MEMBER3);
        actionTarget = new MockLpActionTarget();
        token = new MockERC20();
        lpBaseToken = new MockERC20();
        factory = new MockUniswapV2Factory();
        joinToken = MockUniswapV2Pair(factory.createPair(address(token), address(lpBaseToken)));
        stake.setMemberNFTAddress(address(memberNFT));
        stake.setPhaseAddress(address(phase));
        stake.setPairFactoryAddress(address(factory));
        stake.setTotalValidGovVotes(address(token), 1000e18);
        stake.setValidGovVotes(address(token), 1, 100e18);
        stake.setValidGovVotes(address(token), 2, 200e18);
        stake.setValidGovVotes(address(token), 3, 300e18);
    }

    function _configurePhase() internal {
        for (uint256 i = 1; i <= 12; i++) {
            phase.setPhaseInfo(i, i * PHASE_BLOCKS, PHASE_BLOCKS);
        }
        phase.setCurrentPhase(CREATION_PHASE);
        vm.roll(CREATION_PHASE * PHASE_BLOCKS);
    }

    function _fundMembers() internal {
        address[3] memory members = [MEMBER1, MEMBER2, MEMBER3];
        for (uint256 i = 0; i < members.length; i++) {
            joinToken.mintTo(members[i], JOIN_BALANCE);
            vm.prank(members[i]);
            joinToken.approve(address(lpExecutor), type(uint256).max);
        }
    }

    function _memberAddress(uint256 memberId) internal pure returns (address) {
        if (memberId == 1) return MEMBER1;
        if (memberId == 2) return MEMBER2;
        return MEMBER3;
    }

    function _targetData() internal view returns (bytes[] memory targetData) {
        return _targetDataWithConfig(GOV_RATIO_MULTIPLIER, MIN_GOV_RATIO, address(joinToken));
    }

    function _targetDataWithConfig(
        uint256 govRatioMultiplier,
        uint256 minGovRatio,
        address joinTokenAddress
    ) internal view returns (bytes[] memory targetData) {
        targetData = new bytes[](4);
        targetData[0] = abi.encode(address(lpExecutor));
        targetData[1] = abi.encode(joinTokenAddress);
        targetData[2] = abi.encode(govRatioMultiplier);
        targetData[3] = abi.encode(minGovRatio);
    }

    function _createAction(uint256 actionId) internal {
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(address(token), actionId, _targetData());
    }

    function _createActionWithConfig(uint256 actionId, uint256 govRatioMultiplier, uint256 minGovRatio) internal {
        uint256 savedPhase = phase.currentPhase();
        uint256 savedBlock = block.number;
        phase.setCurrentPhase(CREATION_PHASE);
        vm.roll(CREATION_PHASE * PHASE_BLOCKS);
        vm.prank(address(actionTarget));
        lpExecutor.onProposalCreated(
            address(token),
            actionId,
            _targetDataWithConfig(govRatioMultiplier, minGovRatio, address(joinToken))
        );
        phase.setCurrentPhase(savedPhase);
        vm.roll(savedBlock);
    }

    function _atPhase(uint256 currentPhase) internal {
        phase.setCurrentPhase(currentPhase);
        vm.roll(currentPhase * PHASE_BLOCKS);
    }

    function _atPhaseBlock(uint256 currentPhase, uint256 blockNumber) internal {
        phase.setCurrentPhase(currentPhase);
        vm.roll(blockNumber);
    }

    function _join(uint256 actionId, uint256 memberId, uint256 amount) internal {
        vm.prank(_memberAddress(memberId));
        lpExecutor.join(address(token), actionId, memberId, amount);
    }

    function _join(uint256 memberId, uint256 amount) internal {
        _join(ACTION_ID, memberId, amount);
    }

    function _withdraw(uint256 actionId, uint256 memberId, uint256 amount) internal {
        vm.prank(_memberAddress(memberId));
        lpExecutor.withdraw(address(token), actionId, memberId, amount);
    }

    function _withdraw(uint256 memberId, uint256 amount) internal {
        _withdraw(ACTION_ID, memberId, amount);
    }

    function _exit(uint256 actionId, uint256 memberId) internal {
        vm.prank(_memberAddress(memberId));
        lpExecutor.exit(address(token), actionId, memberId);
    }

    function _exit(uint256 memberId) internal {
        _exit(ACTION_ID, memberId);
    }

    function _setActionReward(uint256 actionId, uint256 round, uint256 amount, bool minted) internal {
        actionTarget.setActionReward(address(token), actionId, round, amount, minted);
    }

    function _setActionReward(uint256 round, uint256 amount, bool minted) internal {
        _setActionReward(ACTION_ID, round, amount, minted);
    }

    function _mintMemberReward(uint256 actionId, uint256 round, uint256 memberId)
        internal
        returns (uint256 mintAmount, uint256 burnAmount)
    {
        vm.prank(_memberAddress(memberId));
        return lpExecutor.mintMemberReward(address(token), actionId, round, memberId);
    }

    function _mintMemberReward(uint256 round, uint256 memberId)
        internal
        returns (uint256 mintAmount, uint256 burnAmount)
    {
        return _mintMemberReward(ACTION_ID, round, memberId);
    }

    function _fundExecutor(uint256 amount) internal {
        token.mint(address(lpExecutor), amount);
    }

}
