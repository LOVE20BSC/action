// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutor} from "../src/GroupActionExecutor.sol";
import {IActionExecutorErrors} from "../src/interfaces/IActionExecutor.sol";
import {IGroupActionExecutorErrors} from "../src/interfaces/IGroupActionExecutor.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";

contract GroupActionExecutorTest is GroupActionExecutorTestBase {
    function testInitDerivesDependenciesAndValidates() external {
        require(executor.initialized(), "initialized");
        require(executor.actionTarget() == address(actionTarget), "action target");
        require(executor.JOIN_TOKEN_ADDRESS(address(token), ACTION_ID) == address(joinToken), "join token stored");
        require(executor.ACTIVATION_STAKE_AMOUNT(address(token), ACTION_ID) == ACTIVATION_STAKE, "stake stored");
        require(executor.MAX_JOIN_AMOUNT_RATIO(address(token), ACTION_ID) == PRECISION, "ratio stored");
        require(executor.ACTIVATION_MIN_GOV_RATIO(address(token), ACTION_ID) == 0, "min gov ratio stored");
        uint256[] memory splits = executor.SPLITS();
        require(splits.length == 1 && splits[0] == 5e17, "splits stored");

        _atPhase(3);
        require(executor.currentJoinRound() == 2, "join round derived from stake phase");
        require(executor.currentVerifyRound() == 1, "verify round derived from stake phase");

        uint256[] memory again = new uint256[](1);
        again[0] = 5e17;
        vm.expectRevert(abi.encodeWithSelector(IActionExecutorErrors.AlreadyInitialized.selector));
        executor.init(address(actionTarget), address(stake), again);

        GroupActionExecutor fresh = new GroupActionExecutor();
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidAddress.selector));
        fresh.init(address(0), address(stake), again);

        GroupActionExecutor badSplits = new GroupActionExecutor();
        uint256[] memory zeroSplits = new uint256[](1);
        zeroSplits[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(IGroupActionExecutorErrors.InvalidSplits.selector));
        badSplits.init(address(actionTarget), address(stake), zeroSplits);
    }

    function testFullRoundSettleMatchesFinalScore() external {
        _prepareRound();

        _atPhase(4);
        _submitScores(_scores(100, 60));

        require(executor.isRoundVerified(address(token), ACTION_ID, 2), "round verified");
        require(executor.lockedVerifierId(address(token), ACTION_ID, 2) == VERIFIER_ID, "verifier locked");
        require(executor.verifiedMemberCount(address(token), ACTION_ID, 2, GROUP_ID) == 2, "cursor complete");

        uint256 memberFinal1 = 100e18 * 100;
        uint256 memberFinal2 = PROVIDER_QUOTA * 60;
        uint256 totalFinal = memberFinal1 + memberFinal2;
        require(executor.totalFinalScore(address(token), ACTION_ID, 2) == totalFinal, "total final score");
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID) == PROVIDER_QUOTA,
            "provider quota counted as join amount"
        );

        _atPhase(5);
        _fundExecutor(PROPOSAL_REWARD);
        actionTarget.setActionReward(address(token), ACTION_ID, 2, PROPOSAL_REWARD, false);
        actionTarget.setMintReturnAmount(PROPOSAL_REWARD);

        uint256 expected1 = Math.mulDiv(PROPOSAL_REWARD, memberFinal1, totalFinal);
        uint256 expected2 = Math.mulDiv(PROPOSAL_REWARD, memberFinal2, totalFinal);
        require(expected1 + expected2 == PROPOSAL_REWARD - 1, "dust sanity");

        (uint256 viewAmount, uint256 viewBurn, bool viewMinted) =
            executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == expected1 && viewBurn == 0 && !viewMinted, "member reward preview");

        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == PROPOSAL_REWARD,
            "group reward"
        );
        require(!executor.needBurnReward(address(token), ACTION_ID, 2), "no burn after verification");

        uint256 balanceBefore = token.balanceOf(MEMBER1);
        (uint256 mint1, uint256 burn1) = _settle(MEMBER1_ID, 2);
        require(mint1 == expected1 && burn1 == 0, "member 1 minted");
        require(token.balanceOf(MEMBER1) - balanceBefore == expected1, "member 1 paid");

        balanceBefore = token.balanceOf(MEMBER2);
        (uint256 mint2, uint256 burn2) = _settle(MEMBER2_ID, 2);
        require(mint2 == expected2 && burn2 == 0, "member 2 minted");
        require(token.balanceOf(MEMBER2) - balanceBefore == expected2, "member 2 paid");

        require(actionTarget.mintRewardCalls() == 1, "single reward pull");
        require(actionTarget.registerCalls() == 2, "join state registered");
        (viewAmount, viewBurn, viewMinted) = executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == expected1 && viewBurn == 0 && viewMinted, "minted flag recorded");
    }

    function testUnverifiedRoundBlocksSettle() external {
        _prepareRound();

        _atPhase(5);
        require(executor.needBurnReward(address(token), ACTION_ID, 2), "burn flagged");
        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 0,
            "no group reward"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settle(MEMBER1_ID, 2);
        require(mintAmount == 0 && burnAmount == 0, "zero settle");

        (uint256 viewAmount, uint256 viewBurn, bool viewMinted) =
            executor.memberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
        require(viewAmount == 0 && viewBurn == 0 && viewMinted, "settled zero recorded");

        vm.prank(MEMBER1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IActionExecutorErrors.RewardAlreadyMinted.selector, address(token), ACTION_ID, MEMBER1_ID, 2
            )
        );
        executor.mintMemberReward(address(token), ACTION_ID, MEMBER1_ID, 2);
    }

    function testPartialVerificationBlocksSettle() external {
        _prepareRound();

        _atPhase(4);
        _submitScores(_scores(100));

        require(
            executor.totalFinalScore(address(token), ACTION_ID, 2) == 100e18 * 100,
            "scored member counted"
        );
        require(!executor.isRoundVerified(address(token), ACTION_ID, 2), "round not complete");

        _atPhase(5);
        require(executor.needBurnReward(address(token), ACTION_ID, 2), "burn flagged on partial");
        require(
            executor.generatedActionRewardByGroupId(address(token), ACTION_ID, 2, GROUP_ID) == 0,
            "partial batches unlock nothing"
        );

        (uint256 mintAmount, uint256 burnAmount) = _settle(MEMBER1_ID, 2);
        require(mintAmount == 0 && burnAmount == 0, "partial round settles zero");
    }

    function _scores(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _scores(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }
}
