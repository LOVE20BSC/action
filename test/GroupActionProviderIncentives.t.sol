// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutorTestBase} from "./GroupActionExecutorTestBase.sol";
import {IGroupActionJoinErrors} from "../src/interfaces/IGroupActionJoin.sol";
import {MockGroupActionToken} from "./mocks/GroupActionExecutorMocks.sol";

contract GroupActionProviderIncentivesTest is GroupActionExecutorTestBase {
    function testPositiveProviderScoreRegistersGroupAndActionIndexes() external {
        _prepareRound();
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);

        _submitScores(_ids(100));
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(50));

        _assertProviderScores(7500e18, 7500e18, 17500e18);

        (uint256[] memory groupIds, uint256 groupCount) =
            executor.groupIdsWithProviderRewardByProviderId(address(token), 2, PROVIDER_ID, 0, 1, false);
        require(groupCount == 1 && groupIds[0] == GROUP_ID, "positive Provider score adds a group");
        (uint256[] memory actionIds, uint256 actionCount) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), 2, GROUP_ID, PROVIDER_ID, 0, 1, false
        );
        require(actionCount == 1 && actionIds[0] == ACTION_ID, "positive Provider score adds an action");

        (uint256[] memory providerIds, uint256 providerCount) = executor.providerIdsWithPositiveScoreByActionIdByGroupId(
            address(token), 2, ACTION_ID, GROUP_ID, 0, 1, true
        );
        require(providerCount == 2 && providerIds[0] == PROVIDER_ID, "reverse provider page includes the external provider");
        uint256 attributed = PROPOSAL_REWARD * 3 / 7;
        require(
            executor.generatedActionRewardByGroupIdByProviderId(address(token), 2, ACTION_ID, GROUP_ID, PROVIDER_ID)
                == attributed,
            "source attribution uses the total action score"
        );
        require(
            executor.totalGeneratedActionRewardByProviderId(address(token), 2, PROVIDER_ID) == attributed,
            "aggregated attribution matches the indexed source"
        );
        require(
            executor.totalGeneratedActionRewardByGroupIdByProviderId(address(token), 2, GROUP_ID, GROUP_ID)
                == PROPOSAL_REWARD * 4 / 7,
            "owner attribution is tracked separately"
        );
    }

    function testProviderRoundTotalIncludesOwnAndOtherGroups() external {
        _openJoinPhase();
        _fundTokenFor(PROVIDER, ACTIVATION_STAKE);
        vm.prank(PROVIDER);
        executor.activateGroup(address(token), ACTION_ID, PROVIDER_ID, _defaultConfig());
        _fundJoinTokenFor(MEMBER1, 100e18);
        _fundJoinTokenFor(PROVIDER, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, PROVIDER_QUOTA);
        _joinAt(PROVIDER_ID, MEMBER1_ID, 100e18, 0);
        _join(MEMBER2_ID, PROVIDER_QUOTA, PROVIDER_ID);

        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        _submitScores(_ids(100));
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, PROVIDER_ID, 0, _ids(100));

        uint256 ownGroupAttribution =
            executor.totalGeneratedActionRewardByGroupIdByProviderId(address(token), 2, PROVIDER_ID, PROVIDER_ID);
        uint256 otherGroupAttribution =
            executor.totalGeneratedActionRewardByGroupIdByProviderId(address(token), 2, GROUP_ID, PROVIDER_ID);
        require(ownGroupAttribution == PROPOSAL_REWARD * 2 / 5, "own group attribution");
        require(otherGroupAttribution == PROPOSAL_REWARD * 3 / 5, "external provider attribution");
        require(
            executor.totalGeneratedActionRewardByProviderId(address(token), 2, PROVIDER_ID)
                == ownGroupAttribution + otherGroupAttribution,
            "round total counts both groups once"
        );
    }

    function testProviderGroupAndActionIndexesAreRegisteredOnceAcrossPositiveBatches() external {
        _openJoinPhase();
        _fundJoinTokenFor(PROVIDER, 2 * PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER1_ID, PROVIDER_QUOTA);
        _grantQuota(PROVIDER_ID, MEMBER2_ID, PROVIDER_QUOTA);
        _join(MEMBER1_ID, 10e18, PROVIDER_ID);
        _join(MEMBER2_ID, 15e18, PROVIDER_ID);
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);

        (, uint256 count) = executor.groupIdsWithProviderRewardByProviderId(address(token), 2, PROVIDER_ID, 0, 0, false);
        require(count == 0, "members must first be verified");
        _submitScores(_ids(100));
        (, count) = executor.groupIdsWithProviderRewardByProviderId(address(token), 2, PROVIDER_ID, 0, 0, false);
        require(count == 1, "first positive score adds group");
        (, count) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), 2, GROUP_ID, PROVIDER_ID, 0, 0, false
        );
        require(count == 1, "first positive score adds action");
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(50));

        (uint256[] memory groupIds, uint256 total) =
            executor.groupIdsWithProviderRewardByProviderId(address(token), 2, PROVIDER_ID, 0, 1, true);
        require(total == 1 && groupIds.length == 1 && groupIds[0] == GROUP_ID, "two scored members share one group");
        (uint256[] memory actionIds, uint256 actionTotal) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), 2, GROUP_ID, PROVIDER_ID, 0, 1, false
        );
        require(actionTotal == 1 && actionIds.length == 1 && actionIds[0] == ACTION_ID, "one action index");
        (groupIds, total) = executor.groupIdsWithProviderRewardByProviderId(address(token), 2, PROVIDER_ID, 1, 1, false);
        require(total == 1 && groupIds.length == 0, "out-of-range group page preserves count");
        (actionIds, actionTotal) = executor.actionIdsWithProviderRewardByGroupIdByProviderId(
            address(token), 2, GROUP_ID, PROVIDER_ID, 1, 1, false
        );
        require(actionTotal == 1 && actionIds.length == 0, "out-of-range action page preserves count");
    }

    function testScoreQueriesExposeWholeScoreUnderFirstProviderAfterVerification() external {
        _prepareRound();
        _fundJoinTokenFor(MEMBER2, 25e18);
        _join(MEMBER2_ID, 25e18, 0);
        _atPhase(4);
        actionTarget.setActionReward(address(token), 2, ACTION_ID, PROPOSAL_REWARD, false);
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 0, _ids(100));
        _assertProviderScores(0, 0, 0);
        vm.prank(VERIFIER);
        executor.submitOriginScores(address(token), ACTION_ID, VERIFIER_ID, GROUP_ID, 1, _ids(20));
        _assertProviderScores(3500e18, 3500e18, 13500e18);
        (uint256 ownerScore, uint256 groupScore) = executor.providerScore(address(token), 2, ACTION_ID, GROUP_ID, GROUP_ID);
        require(ownerScore == 10000e18 && groupScore == 13500e18, "owner score is included");
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

    function _assertProviderScores(uint256 provider, uint256 externalTotal, uint256 groupTotal) private view {
        (uint256 score, uint256 groupScore) = executor.providerScore(address(token), 2, ACTION_ID, GROUP_ID, PROVIDER_ID);
        require(score == provider && groupScore == groupTotal, "individual score and group final score");
        (score, groupScore) = executor.providerScore(address(token), 2, ACTION_ID, GROUP_ID, GROUP_ID);
        require(score == groupTotal - externalTotal && groupScore == groupTotal, "owner score and group final score");
    }
}
