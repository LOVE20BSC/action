// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";
import {GroupRewardKey} from "../src/interfaces/IGroupActionVerify.sol";
import {IGroupActionJoinErrors} from "../src/interfaces/IGroupActionJoin.sol";
import {MockGroupActionToken} from "./mocks/GroupActionExecutorMocks.sol";

contract GroupActionProviderIncentivesTest is GroupActionExecutorTestBase {
    function testPositiveProviderWeightRegistersRewardKeyAndCandidateAction() external {
        _prepareRound();
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);

        _submitScores(_ids(100));
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(50));

        (uint256 groupScore, uint256 externalScore, uint256 providerScore) =
            executor.providerWeights(address(token), 2, ACTION_ID, GROUP_ID, PROVIDER_ID);
        require(groupScore == 17500e18, "all verified scores contribute to the group weight");
        require(externalScore == 7500e18 && providerScore == 7500e18, "Provider weight comes from verified scores");

        (GroupRewardKey[] memory keys, uint256 providerKeyCount) =
            executor.providerRewardKeys(address(token), 2, PROVIDER_ID, 0, 1, false);
        require(providerKeyCount == 1 && keys[0].sourceActionId == ACTION_ID, "positive Provider score adds a key");
        (uint256[] memory actions, uint256 totalActionCount) =
            executor.actionIdsWithProviderWeight(address(token), 2, GROUP_ID, 0, 1, false);
        require(totalActionCount == 1 && actions.length == 1 && actions[0] == ACTION_ID, "positive weight adds action");
    }

    function testProviderRewardKeyIsRegisteredOnceAcrossPositiveBatches() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 2 * PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER1_ID, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, PROVIDER_QUOTA);
        _join(MEMBER1_ID, 10e18, PROVIDER_ID);
        _join(MEMBER2_ID, 15e18, PROVIDER_ID);
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);

        (, uint256 count) = executor.providerRewardKeys(address(token), 2, PROVIDER_ID, 0, 0, false);
        require(count == 0, "members must first be verified");
        _submitScores(_ids(100));
        (, count) = executor.providerRewardKeys(address(token), 2, PROVIDER_ID, 0, 0, false);
        require(count == 1, "first positive weight adds key");
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(50));

        (GroupRewardKey[] memory keys, uint256 total) =
            executor.providerRewardKeys(address(token), 2, PROVIDER_ID, 0, 1, true);
        require(total == 1 && keys.length == 1, "two scored members share one key");
        require(keys[0].sourceActionId == ACTION_ID && keys[0].groupId == GROUP_ID, "scope");
        (keys, total) = executor.providerRewardKeys(address(token), 2, PROVIDER_ID, 1, 1, false);
        require(total == 1 && keys.length == 0, "out-of-range page preserves count");
    }

    function testVerificationCountsWholeScoreUnderFirstProvider() external {
        _prepareRound();
        _fundJoinTokenFor(MEMBER2, 25e18);
        _join(MEMBER2_ID, 25e18, 0);
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _ids(100));
        (uint256 groupScore,,) = executor.providerWeights(address(token), 2, ACTION_ID, GROUP_ID, PROVIDER_ID);
        require(groupScore == 0, "incomplete verification");
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(20));
        uint256 externalScore;
        uint256 providerScore;
        (groupScore, externalScore, providerScore) =
            executor.providerWeights(address(token), 2, ACTION_ID, GROUP_ID, PROVIDER_ID);
        require(groupScore == 13500e18 && externalScore == 3500e18 && providerScore == 3500e18, "verified weights");
        (,, uint256 ownerScore) = executor.providerWeights(address(token), 2, ACTION_ID, GROUP_ID, GROUP_ID);
        require(ownerScore == 0, "owner provider score");
    }

    function testFirstSuccessfulJoinKeepsItsProviderAfterExit() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER1_ID, PROVIDER_QUOTA);
        (uint256 providerId, uint256 joinedBlock) = executor.providerAttribution(GROUP_ID, MEMBER1_ID);
        require(providerId == 0 && joinedBlock == 0, "quota is not attribution");

        uint256 firstBlock = block.number;
        _join(MEMBER1_ID, 100e18, PROVIDER_ID);
        _exit(MEMBER1_ID);
        vm.roll(firstBlock + 1);
        _fundJoinTokenFor(MEMBER1, 100e18);
        _join(MEMBER1_ID, 100e18, 0);
        _assertAttribution(GROUP_ID, MEMBER1_ID, PROVIDER_ID, firstBlock);
    }

    function testOwnerQuotaFirstJoinSetsAttributionAfterRevertedSelfFundedJoin() external {
        _openJoinPhase();
        _fundJoinTokenFor(MEMBER1, 100e18);
        joinToken.setTransferFeeBps(1000);
        vm.prank(MEMBER1);
        vm.expectRevert(abi.encodeWithSelector(IGroupActionJoinErrors.InexactJoinTokenTransfer.selector, 100e18, 90e18));
        executor.join(address(token), ACTION_ID, GROUP_ID, MEMBER1_ID, 100e18, 0, new string[](0));
        _assertAttribution(GROUP_ID, MEMBER1_ID, 0, 0);

        joinToken.setTransferFeeBps(0);
        _fundJoinTokenFor(GROUP_OWNER, PROVIDER_QUOTA);
        _grantQuota(GROUP_OWNER_ID, MEMBER1_ID, PROVIDER_QUOTA);
        _join(MEMBER1_ID, 100e18, GROUP_OWNER_ID);
        _assertAttribution(GROUP_ID, MEMBER1_ID, GROUP_ID, block.number);
        _join(MEMBER1_ID, 2e18, 0);
        _assertAttribution(GROUP_ID, MEMBER1_ID, GROUP_ID, block.number);
    }

    function testFirstAttributionSurvivesDifferentActionAndCommunityForSameGroup() external {
        uint256 otherActionId = ACTION_ID + 1;
        MockGroupActionToken otherToken = new MockGroupActionToken();
        vote.setVotesNum(address(otherToken), 2, 1000e18);
        vote.setVotesNumByProposalId(address(otherToken), 2, otherActionId, 1000e18);
        _createActionOn(address(otherToken), otherActionId, _targetData());

        _openJoinPhase();
        memberNFT.setOwner(GROUP_B_ID, GROUP_OWNER);
        otherToken.mint(GROUP_OWNER, 2 * ACTIVATION_STAKE);
        vm.prank(GROUP_OWNER);
        otherToken.approve(address(executor), type(uint256).max);
        _activateGroupOn(address(otherToken), otherActionId, GROUP_ID);
        _activateGroupOn(address(otherToken), otherActionId, GROUP_B_ID);

        // A wallet can hold the group NFT and a different Provider NFT.
        _fundJoinTokenFor(GROUP_OWNER, PROVIDER_QUOTA);
        vm.prank(GROUP_OWNER);
        executor.addProviderQuota(
            address(token), ACTION_ID, GROUP_ID, GROUP_B_ID, _ids(MEMBER1_ID), _ids(PROVIDER_QUOTA)
        );
        uint256 firstBlock = block.number;
        _join(MEMBER1_ID, 100e18, GROUP_B_ID);
        _quotaRemoveFromSameWallet();
        _assertAttribution(GROUP_ID, MEMBER1_ID, GROUP_B_ID, firstBlock);

        uint256 nextBlock = firstBlock + 1;
        vm.roll(nextBlock);
        _fundJoinTokenFor(MEMBER1, 2e18);
        _joinOn(address(otherToken), otherActionId, GROUP_ID, MEMBER1_ID, 1e18);
        _assertAttribution(GROUP_ID, MEMBER1_ID, GROUP_B_ID, firstBlock);

        _exitOn(address(otherToken), otherActionId, MEMBER1_ID);
        _joinOn(address(otherToken), otherActionId, GROUP_B_ID, MEMBER1_ID, 1e18);
        _assertAttribution(GROUP_B_ID, MEMBER1_ID, GROUP_B_ID, nextBlock);
        memberNFT.setOwner(MEMBER1_ID, MEMBER2);
        _assertAttribution(GROUP_ID, MEMBER1_ID, GROUP_B_ID, firstBlock);
    }

    function _quotaRemoveFromSameWallet() private {
        vm.prank(GROUP_OWNER);
        executor.removeProviderQuota(address(token), ACTION_ID, GROUP_ID, GROUP_B_ID, _ids(MEMBER1_ID));
    }

    function _assertAttribution(uint256 groupId, uint256 memberId, uint256 expectedProvider, uint256 expectedBlock)
        private
        view
    {
        (uint256 providerId, uint256 joinedBlock) = executor.providerAttribution(groupId, memberId);
        require(providerId == expectedProvider && joinedBlock == expectedBlock, "first join attribution");
    }
}
