// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ActionTargetIntegrationFixture} from "../integration/ActionTargetRealIntegration.t.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupActionCreationParams} from "../../src/interfaces/IGroupActionExecutor.sol";
import {GroupServiceCreationParams} from "../../src/interfaces/IGroupServiceExecutor.sol";
import {GroupConfig} from "../../src/interfaces/IGroupActionManager.sol";

contract GroupServiceProviderMintGasTest is ActionTargetIntegrationFixture {
    uint256 private constant OWNER_ID = 1;
    uint256 private constant TARGET_PROVIDER_ID = 2;
    uint256 private constant EXTRA_COUNT = 16;
    uint256 private constant TARGET_AMOUNT = 200;
    uint256 private constant EXTRA_AMOUNT = 320;
    uint256 private constant OWNER_AMOUNT = 480;

    event log_named_uint(
        string key,
        uint256 value
    );

    GroupActionExecutor private group;
    GroupServiceExecutor private service;
    uint256 private round;
    uint256 private sourceAction;
    uint256 private serviceAction;
    uint256 private targetActor;
    uint256[EXTRA_COUNT] private extraActors;
    uint256[EXTRA_COUNT] private extraProviders;

    function setUp() public {
        _setUpProtocol(1, 0);
        group = new GroupActionExecutor(address(actionTarget));
        service = new GroupServiceExecutor(address(group));
        round = phase.currentPhase();

        vm.startPrank(member1);
        token.approve(address(group), type(uint256).max);
        (targetActor,) = memberNFT.mint("GasTargetActor");
        for (uint256 i; i < EXTRA_COUNT; ++i) {
            (extraActors[i],) = memberNFT.mint(string.concat("GasActor", vm.toString(i)));
            (extraProviders[i],) = memberNFT.mint(string.concat("GasProvider", vm.toString(i)));
        }
        vm.stopPrank();
        vm.prank(member2);
        token.approve(address(group), type(uint256).max);
        _createActions();
        vm.roll(block.number + BLOCKS_PER_PHASE);
    }

    function testSingleProviderMintHasConstantGasAsActorAndProviderCountsGrow() external {
        uint256 start = vm.snapshotState();
        (uint256 firstPaid, uint256 smallGas) = _verifyAndMint(1, false);
        require(vm.revertToState(start), "restore before joins");
        (uint256 moreActorsPaid, uint256 moreActorsGas) = _verifyAndMint(EXTRA_COUNT, false);
        require(vm.revertToStateAndDelete(start), "restore same starts for more providers");
        (uint256 moreProvidersPaid, uint256 moreProvidersGas) = _verifyAndMint(EXTRA_COUNT, true);

        emit log_named_uint("Provider mint gas with three actors", smallGas);
        emit log_named_uint("Provider mint gas with eighteen actors", moreActorsGas);
        emit log_named_uint("Provider mint gas with seventeen Providers", moreProvidersGas);
        require(firstPaid == moreActorsPaid && firstPaid == moreProvidersPaid, "equivalent weights pay equally");
        require(
            smallGas == moreActorsGas && smallGas == moreProvidersGas, "one share must not scan actors or Providers"
        );
    }

    function _createActions() private {
        bytes memory groupData = abi.encodePacked(
            address(group),
            abi.encode(
                GroupActionCreationParams(address(token), 0, 1e18, 0, 0, 0.9e18, new string[](0), new string[](0))
            )
        );
        sourceAction = _submitActionProposal(OWNER_ID, "One source", groupData);
        bytes memory serviceData =
            abi.encodePacked(address(service), abi.encode(GroupServiceCreationParams(address(token), 0, 0.5e18, 0.5e18)));
        serviceAction = _submitActionProposal(TARGET_PROVIDER_ID, "One service", serviceData);

        vm.prank(member2);
        group.submitVerifierApplication(address(token), sourceAction, TARGET_PROVIDER_ID, "Verifier");
        _voteOne(OWNER_ID, sourceAction, 60, abi.encode(TARGET_PROVIDER_ID));
        _voteOne(OWNER_ID, serviceAction, 90, "");
    }

    function _verifyAndMint(uint256 count, bool distinctProviders) private returns (uint256 paid, uint256 gasUsed) {
        _join(count, distinctProviders);
        vm.roll(block.number + BLOCKS_PER_PHASE);
        _score(count + 2);
        _configureRecipient();
        vm.roll(block.number + BLOCKS_PER_PHASE);

        {
            (uint256 targetScore, uint256 groupScore) =
                group.providerScore(address(token), round, sourceAction, OWNER_ID, TARGET_PROVIDER_ID);
            (uint256 ownerScore, uint256 ownerGroupScore) =
                group.providerScore(address(token), round, sourceAction, OWNER_ID, OWNER_ID);
            require(groupScore == 100_000 && ownerGroupScore == groupScore, "group score held constant");
            require(ownerScore == 48_000 && targetScore == 20_000, "Provider scores held constant");
        }
        if (distinctProviders) {
            for (uint256 i; i < count; ++i) {
                (uint256 score,) =
                    group.providerScore(address(token), round, sourceAction, OWNER_ID, extraProviders[i]);
                require(score == 2_000, "each extra Provider has a score");
            }
        }
        (uint256 budget,) = actionTarget.actionReward(address(token), round, serviceAction);
        (uint256 expected, bool minted) =
            service.providerRewardBySourceActionIdByGroupId(address(token), round, serviceAction, sourceAction, OWNER_ID, TARGET_PROVIDER_ID);
        require(expected == budget / 20 && expected > 0 && !minted, "quote matches manual share");
        uint256 balanceBefore = token.balanceOf(member2);
        _coolContracts();
        vm.prank(member2);
        paid = service.mintProviderRewardBySourceActionIdByGroupId(
            address(token), round, serviceAction, sourceAction, OWNER_ID, TARGET_PROVIDER_ID
        );
        gasUsed = vm.lastCallGas().gasTotalUsed;
        require(paid == expected && token.balanceOf(member2) - balanceBefore == expected, "known share paid");
    }

    function _join(uint256 count, bool distinctProviders) private {
        vm.startPrank(member1);
        group.activateGroup(address(token), sourceAction, OWNER_ID, GroupConfig("Group", 0, 1, 0, 0));
        group.join(address(token), sourceAction, OWNER_ID, OWNER_ID, OWNER_AMOUNT, 0, new string[](0));
        vm.stopPrank();
        vm.prank(member2);
        group.addProviderQuota(
            address(token), sourceAction, OWNER_ID, TARGET_PROVIDER_ID, _single(targetActor), _single(TARGET_AMOUNT)
        );

        vm.startPrank(member1);
        group.join(
            address(token), sourceAction, OWNER_ID, targetActor, TARGET_AMOUNT, TARGET_PROVIDER_ID, new string[](0)
        );
        uint256 amount = EXTRA_AMOUNT / count;
        for (uint256 i; i < count; ++i) {
            uint256 providerId = distinctProviders ? extraProviders[i] : extraProviders[0];
            uint256 actorId = extraActors[i];
            group.addProviderQuota(
                address(token), sourceAction, OWNER_ID, providerId, _single(actorId), _single(amount)
            );
            group.join(address(token), sourceAction, OWNER_ID, actorId, amount, providerId, new string[](0));
        }
        vm.stopPrank();
    }

    function _score(uint256 count) private {
        uint256[] memory scores = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            scores[i] = 100;
        }
        _coolContracts();
        vm.prank(member2);
        group.submitOriginScores(address(token), sourceAction, TARGET_PROVIDER_ID, OWNER_ID, 0, scores);
        emit log_named_uint("verify one batch gas", vm.lastCallGas().gasTotalUsed);
    }

    function _configureRecipient() private {
        uint256[] memory ids = _single(TARGET_PROVIDER_ID);
        uint256[] memory ratios = _single(0.5e18);
        _coolContracts();
        vm.prank(member1);
        service.setRecipients(address(token), sourceAction, OWNER_ID, ids, ratios, new string[](1));
        emit log_named_uint("configure one recipient gas", vm.lastCallGas().gasTotalUsed);
    }

    function _coolContracts() private {
        vm.cool(address(service));
        vm.cool(address(group));
        vm.cool(address(actionTarget));
        vm.cool(address(mint));
        vm.cool(address(vote));
        vm.cool(address(submit));
        vm.cool(address(launch));
        vm.cool(address(phase));
        vm.cool(address(memberNFT));
        vm.cool(address(token));
    }

    function _single(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
