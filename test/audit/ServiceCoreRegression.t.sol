// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;
import {Test} from "@forge-std/Test.sol";
import {ActionTarget} from "../../src/ActionTarget.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";
import {Mint} from "@core/Mint.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {TargetMode} from "@core/interfaces/ISubmit.sol";

/// @notice Real accounting contracts and tokens; only peripheral reads are mocked.
/// @dev Fixed Submit/Vote callbacks are impersonated to set up normal lifecycle state. The
///      regression case drives a real burn against the served community token to move its live
///      reward book after the service round's divisor was first read.
contract ServiceCoreRegressionTest is Test {
    ActionTarget target;
    GroupActionExecutor group;
    GroupServiceExecutor service;
    Mint mint;
    LOVE20Token parent;
    LOVE20Token child;
    address constant PHASE = address(0xA001);
    address constant STAKE = address(0xA002);
    address constant NFT = address(0xA003);
    address constant VOTE = address(0xA004);
    address constant SUBMIT = address(0xA005);
    address constant LAUNCH = address(0xA006);
    address constant ALICE = address(0xB001);
    address constant BOB = address(0xB002);
    function _mock(address where, bytes memory data, bytes memory result) internal {
        vm.mockCall(where, data, result);
    }
    function _phase(uint256 value) internal {
        _mock(PHASE, abi.encodeWithSignature("currentPhase()"), abi.encode(value));
    }
    function setUp() public {
        for (uint256 i = 1; i <= 6; i++) vm.etch(address(uint160(0xA000 + i)), hex"00");
        _phase(2);
        _mock(STAKE, abi.encodeWithSignature("memberNFTAddress()"), abi.encode(NFT));
        _mock(STAKE, abi.encodeWithSignature("phaseAddress()"), abi.encode(PHASE));
        _mock(STAKE, abi.encodeWithSignature("voteAddress()"), abi.encode(VOTE));
        _mock(STAKE, abi.encodeWithSignature("launchAddress()"), abi.encode(LAUNCH));
        _mock(STAKE, abi.encodeWithSignature("validGovVotes(address,uint256,uint256)"), abi.encode(uint256(1)));
        _mock(NFT, abi.encodeWithSignature("ownerOf(uint256)", 1), abi.encode(ALICE));
        _mock(NFT, abi.encodeWithSignature("ownerOf(uint256)", 2), abi.encode(BOB));
        _mock(NFT, abi.encodeWithSignature("ownerOf(uint256)", 3), abi.encode(ALICE));
        _mock(NFT, abi.encodeWithSignature("ownerOf(uint256)", 4), abi.encode(BOB));
        _mock(VOTE, abi.encodeWithSignature("phaseAddress()"), abi.encode(PHASE));
        _mock(VOTE, abi.encodeWithSignature("votesNum(address,uint256)"), abi.encode(uint256(100)));
        _mock(VOTE, abi.encodeWithSignature("votesNumByProposalId(address,uint256,uint256)"), abi.encode(uint256(100)));
        _mock(VOTE, abi.encodeWithSignature("isProposalIdVoted(address,uint256,uint256)"), abi.encode(true));
        _mock(VOTE, abi.encodeWithSignature("stakedAmountOfVoters(address,uint256)"), abi.encode(uint256(1)));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _mock(VOTE, abi.encodeWithSignature("votedProposalIds(address,uint256,uint256,uint256,bool)"), abi.encode(ids, uint256(1)));
        mint = new Mint();
        mint.init(VOTE, SUBMIT, LAUNCH, NFT, 0, 1e17, 1e17, 2);
        target = new ActionTarget();
        target.init(address(mint));
        _mock(SUBMIT, abi.encodeWithSignature("proposalTarget(address,uint256)"), abi.encode(address(target), TargetMode.Callback));
        parent = new LOVE20Token("Parent", "P", 100000, 1000000, address(this), address(mint), address(this));
        child = new LOVE20Token("Child", "C", 100000, 1000000, address(this), address(mint), address(parent));
        _mock(LAUNCH, abi.encodeWithSignature("parentTokenOf(address)"), abi.encode(address(parent)));
        group = new GroupActionExecutor();
        group.init(address(target), STAKE, new uint256[](0));
        service = new GroupServiceExecutor();
        service.init(address(target), STAKE, address(group));
        bytes[] memory data = new bytes[](6);
        data[0] = abi.encode(address(group));
        data[1] = abi.encode(address(child));
        data[2] = abi.encode(uint256(0));
        data[3] = abi.encode(uint256(1e18));
        data[4] = abi.encode(uint256(0));
        data[5] = abi.encode(uint256(0));
        vm.prank(SUBMIT);
        target.onProposalCreated(address(child), 1, data);
        data = new bytes[](4);
        data[0] = abi.encode(address(service));
        data[1] = abi.encode(address(child));
        data[2] = abi.encode(uint256(0));
        data[3] = abi.encode(uint256(0));
        vm.prank(SUBMIT);
        target.onProposalCreated(address(parent), 1, data);
        vm.prank(ALICE);
        group.submitVerifierApplication(address(child), 1, 1, "");
        data = new bytes[](2);
        data[0] = abi.encode(address(group));
        data[1] = abi.encode(uint256(1));
        vm.prank(VOTE);
        target.onProposalVoted(address(child), 2, 1, 1, 100, data);
        _phase(3);
        GroupConfig memory config = GroupConfig("", 0, 1, 0, 0);
        vm.prank(ALICE);
        group.activateGroup(address(child), 1, 1, config);
        vm.prank(BOB);
        group.activateGroup(address(child), 1, 2, config);
        child.transfer(ALICE, 100);
        child.transfer(BOB, 100);
        vm.startPrank(ALICE);
        child.approve(address(group), 100);
        group.join(address(child), 1, 1, 3, 100, 0, new string[](0));
        service.join(address(parent), 1, 1);
        vm.stopPrank();
        vm.startPrank(BOB);
        child.approve(address(group), 100);
        group.join(address(child), 1, 2, 4, 100, 0, new string[](0));
        service.join(address(parent), 1, 2);
        vm.stopPrank();
        _phase(4);
        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;
        vm.startPrank(ALICE);
        group.submitOriginScores(address(child), 1, 1, 1, 0, scores);
        group.submitOriginScores(address(child), 1, 1, 2, 0, scores);
        vm.stopPrank();
        _phase(5);
    }
    /// @notice Regression for the live-numerator / stale-divisor split: a real burn against the served
    ///         community token moves its live reward between the two owners' settlements, and the
    ///         second owner used to be paid off the moved number while the divisor stayed behind.
    /// @dev Both sides are read live now, so the move rescales them together and the two owners keep
    ///      the same share of the same minted budget.
    function testRegression_RealSourceBurnCannotOverpayServiceBudget() external {
        assertFalse(mint.isRewardPrepared(address(child), 2));
        vm.prank(ALICE);
        (uint256 first,) = service.mintMemberReward(address(parent), 1, 1, 2);
        assertEq(first, 45000);

        // Burning the community token frees supply headroom, so the served action's live reward grows.
        child.burn(90000);
        assertGt(service.totalGroupActionReward(address(child), 2), 90000);

        // The second owner divides by the same moved number, so the share is unchanged.
        (uint256 second,,) = service.memberReward(address(parent), 1, 2, 2);
        assertEq(second, 45000);

        (uint256 budget,) = target.actionReward(address(parent), 1, 2);
        assertEq(first + second, budget);

        // The claim is payable with no outside funding, and the budget is not exceeded.
        vm.prank(BOB);
        (uint256 paid,) = service.mintMemberReward(address(parent), 1, 2, 2);
        assertEq(paid, 45000);
        assertEq(first + paid, budget);
        assertEq(parent.balanceOf(address(service)), 0);
    }
}
