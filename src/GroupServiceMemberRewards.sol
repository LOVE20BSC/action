// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {GroupServiceRecipients} from "./GroupServiceRecipients.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {
    MemberRewardSummary,
    IGroupServiceExecutorEvents,
    IGroupServiceExecutorErrors
} from "./interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IActionExecutorErrors, IActionExecutorEvents} from "./interfaces/IActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library GroupServiceMemberRewards {
    using SafeERC20 for IERC20;

    struct MemberRewardDetails {
        MemberRewardSummary verifier;
        MemberRewardSummary groupOwner;
        MemberRewardSummary recipient;
        MemberRewardSummary provider;
        uint256 ownerBudgetAmount;
        uint256 ownerBudgetAmountBeforeCap;
    }

    struct MemberRewardBatch {
        address tokenAddress;
        uint256 memberId;
        uint256[] rounds;
        uint256[] actionIds;
    }

    struct ServiceBudget {
        address sourceTokenAddress;
        uint256 totalSourceReward;
        uint256 rewardAmount;
        uint256 publicVerifierRatio;
        uint256 providerIncentiveRatio;
        uint256 govRatioMultiplier;
        bool isMinted;
        uint256 cachedGroupId;
        GroupBudget cachedGroupBudget;
    }

    struct GroupBudget {
        uint256 totalSourceReward;
        uint256 ownerBudget;
        uint256 ownerBurn;
    }

    struct OwnerClaim {
        GroupBudget budget;
        uint256 mintAmount;
        uint256 burnAmount;
    }

    struct ClaimResult {
        uint256 mintAmount;
        bool previouslyMinted;
        bool hasEligibleSource;
    }

    function recipientRewardForSource(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 mintRound
    ) external view returns (uint256 rewardAmount, bool isMinted) {
        rewardAmount = _mintedRecipientRewards(self, key, sourceActionId, groupId)[key.memberId];
        // forge-lint: disable-next-line(boolean-cst)
        if (rewardAmount != 0) return (rewardAmount, true);
        if (key.memberId == groupId || !_isSettleableRound(self, key, mintRound)) return (0, isMinted);

        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        GroupBudget memory group = _groupBudget(self, protocol, _groupKey(key, groupId), service);
        rewardAmount = _recipientRewardAmount(self, protocol, service, group, key, sourceActionId, groupId);
    }

    function providerRewardForSource(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 mintRound
    ) external view returns (uint256 rewardAmount, bool isMinted) {
        rewardAmount = _mintedProviderRewards(self, key, sourceActionId, groupId)[key.memberId];
        // forge-lint: disable-next-line(boolean-cst)
        if (rewardAmount != 0) return (rewardAmount, true);
        if (key.memberId == groupId || !_isSettleableRound(self, key, mintRound)) return (0, isMinted);

        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        GroupBudget memory group = _groupBudget(self, protocol, _groupKey(key, groupId), service);
        rewardAmount = _providerRewardAmount(protocol, service, group, key, sourceActionId, groupId);
    }

    function recipientReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 mintRound
    ) external view returns (MemberRewardSummary memory summary) {
        if (key.round > mintRound) return summary;
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        return _recipientSummary(self, protocol, key, service);
    }

    function providerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 mintRound
    ) external view returns (MemberRewardSummary memory summary) {
        if (key.round > mintRound || self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] == 0) {
            return summary;
        }
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        return _providerSummary(self, protocol, key, service);
    }

    function groupOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        mintedAmount = _ownerPaid(self, key);
        if (mintedAmount != 0) return (0, mintedAmount, MemberRewardStatus.Settled);

        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        (pendingAmount, status) =
            _pendingOwnerSummary(self, protocol, key, service, _groupBudget(self, protocol, key, service));
    }

    function groupOwnerRewardBudget(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key
    ) external view returns (uint256 ownerBudgetAmount, uint256 ownerBudgetAmountBeforeCap) {
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        GroupBudget memory group = _groupBudget(self, protocol, key, service);
        ownerBudgetAmount = group.ownerBudget;
        ownerBudgetAmountBeforeCap = ownerBudgetAmount + group.ownerBurn;
    }

    function verifierReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        mintedAmount = _verifierPaid(self, key);
        if (mintedAmount != 0) return (0, mintedAmount, MemberRewardStatus.Settled);

        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        pendingAmount = _verifierRewardAmount(service, _verifierSourceReward(protocol, key, service));
        status = _status(pendingAmount != 0, false);
    }

    function memberRewardDetail(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key
    ) external view returns (MemberRewardDetails memory details) {
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        GroupBudget memory group = _groupBudget(self, protocol, key, service);
        details.ownerBudgetAmount = group.ownerBudget;
        details.ownerBudgetAmountBeforeCap = group.ownerBudget + group.ownerBurn;

        details.groupOwner.mintedAmount = _ownerPaid(self, key);
        if (details.groupOwner.mintedAmount == 0) {
            (details.groupOwner.pendingAmount, details.groupOwner.status) =
                _pendingOwnerSummary(self, protocol, key, service, group);
        } else {
            details.groupOwner.status = MemberRewardStatus.Settled;
        }

        details.verifier.mintedAmount = _verifierPaid(self, key);
        if (details.verifier.mintedAmount == 0) {
            details.verifier.pendingAmount =
                _verifierRewardAmount(service, _verifierSourceReward(protocol, key, service));
        }
        details.verifier.status = _status(details.verifier.pendingAmount != 0, details.verifier.mintedAmount != 0);

        details.recipient = _recipientSummary(self, protocol, key, service);
        if (service.providerIncentiveRatio != 0) {
            details.provider = _providerSummary(self, protocol, key, service);
        }
    }

    function mintRecipientRewardForSource(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 mintRound
    ) external returns (uint256 mintAmount) {
        _checkCreatedRound(self, key.tokenAddress, key.round, key.actionId);
        _checkMintRound(key.round, mintRound);
        ServiceBudget memory service;
        return _mintRequiredRecipientReward(self, protocol, key, sourceActionId, groupId, service);
    }

    function mintProviderRewardForSource(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 mintRound
    ) external returns (uint256 mintAmount) {
        _checkCreatedRound(self, key.tokenAddress, key.round, key.actionId);
        _checkMintRound(key.round, mintRound);
        ServiceBudget memory service;
        return _mintRequiredProviderReward(self, protocol, key, sourceActionId, groupId, service);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function mintRecipientRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256[] calldata sourceActionIds,
        uint256[] calldata groupIds,
        uint256 mintRound
    ) external returns (uint256[] memory mintAmounts) {
        mintAmounts = new uint256[](sourceActionIds.length);
        if (sourceActionIds.length == 0) return mintAmounts;
        _checkCreatedRound(self, key.tokenAddress, key.round, key.actionId);
        _checkMintRound(key.round, mintRound);
        ServiceBudget memory service;
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            mintAmounts[i] = _mintRequiredRecipientReward(
                self, protocol, key, sourceActionIds[i], groupIds[i], service
            );
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function mintProviderRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256[] calldata sourceActionIds,
        uint256[] calldata groupIds,
        uint256 mintRound
    ) external returns (uint256[] memory mintAmounts) {
        mintAmounts = new uint256[](sourceActionIds.length);
        if (sourceActionIds.length == 0) return mintAmounts;
        _checkCreatedRound(self, key.tokenAddress, key.round, key.actionId);
        _checkMintRound(key.round, mintRound);
        ServiceBudget memory service;
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            mintAmounts[i] = _mintRequiredProviderReward(
                self, protocol, key, sourceActionIds[i], groupIds[i], service
            );
        }
    }

    function mintRecipientReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) external returns (uint256 mintAmount) {
        _checkMintWindow(self, key, phaseAddress);
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);
        ClaimResult memory result = _mintRemainingRecipientRewards(self, protocol, key, service);
        if (result.mintAmount == 0) _revertEmptyClaim(key, result);
        return result.mintAmount;
    }

    function mintProviderReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) external returns (uint256 mintAmount) {
        _checkMintWindow(self, key, phaseAddress);
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);
        ClaimResult memory result = _mintRemainingProviderRewards(self, protocol, key, service);
        if (result.mintAmount == 0) _revertEmptyClaim(key, result);
        return result.mintAmount;
    }

    function mintGroupOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) external returns (uint256 mintAmount) {
        _checkMintWindow(self, key, phaseAddress);
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);

        OwnerClaim memory owner = _mintOwnerReward(self, protocol, key, service);
        _checkSourceReward(owner.budget.totalSourceReward, key);
        if (owner.mintAmount == 0 && owner.burnAmount == 0) _revertEmptyOwnerReward(self, key, owner.budget);

        _burnOwnerReward(self, key, owner.burnAmount);
        _transferReward(key.tokenAddress, owner.mintAmount);
        _emitServiceRewardsDistributed(key, service.sourceTokenAddress, 0, owner.budget.ownerBudget, owner.mintAmount);
        return owner.mintAmount;
    }

    function mintVerifierReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) external returns (uint256 mintAmount) {
        _checkMintWindow(self, key, phaseAddress);
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);

        uint256 verifierSourceReward;
        (mintAmount, verifierSourceReward) = _mintVerifierReward(self, protocol, key, service);
        _checkSourceReward(verifierSourceReward, key);
        if (mintAmount == 0) {
            _checkVerifierRewardNotMinted(self, key);
            revert IActionExecutorErrors.MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);
        }

        _transferReward(key.tokenAddress, mintAmount);
        _emitServiceRewardsDistributed(key, service.sourceTokenAddress, mintAmount, 0, 0);
    }

    function mintMemberReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) external returns (uint256 mintAmount, uint256 burnAmount) {
        return _mintMemberReward(self, protocol, key, phaseAddress);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function mintMemberRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        MemberRewardBatch memory batch,
        address phaseAddress
    ) external returns (uint256[] memory mintAmounts) {
        uint256 length = batch.actionIds.length;
        mintAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            GroupServiceStorage.MemberRewardKey memory key = GroupServiceStorage.MemberRewardKey(
                batch.tokenAddress, batch.rounds[i], batch.actionIds[i], batch.memberId
            );
            (mintAmounts[i],) = _mintMemberReward(self, protocol, key, phaseAddress);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkMintWindow(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) private view {
        _checkCreatedRound(self, key.tokenAddress, key.round, key.actionId);
        _checkMintRound(key.round, GroupActionRoundAxis.mintRound(phaseAddress));
    }

    function _emitServiceRewardsDistributed(
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress,
        uint256 verifierRewardAmount,
        uint256 ownerBudget,
        uint256 ownerMintAmount
    ) private {
        emit IGroupServiceExecutorEvents.ServiceRewardsDistributed({
            serviceTokenAddress: key.tokenAddress,
            serviceActionId: key.actionId,
            round: key.round,
            actionTokenAddress: sourceTokenAddress,
            memberId: key.memberId,
            verifierReward: verifierRewardAmount,
            ownerReward: ownerBudget,
            ownerRemaining: ownerMintAmount
        });
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintMemberReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address phaseAddress
    ) private returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(self, key, phaseAddress);
        ServiceBudget memory service;
        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);

        OwnerClaim memory owner = _mintOwnerReward(self, protocol, key, service);
        (uint256 verifierMintAmount, uint256 verifierSourceReward) = _mintVerifierReward(self, protocol, key, service);
        _burnOwnerReward(self, key, owner.burnAmount);
        _transferReward(key.tokenAddress, owner.mintAmount + verifierMintAmount);

        ClaimResult memory recipient = _mintRemainingRecipientRewards(self, protocol, key, service);
        ClaimResult memory provider = _mintRemainingProviderRewards(self, protocol, key, service);
        mintAmount = owner.mintAmount + verifierMintAmount + recipient.mintAmount + provider.mintAmount;
        burnAmount = owner.burnAmount;
        if (mintAmount + burnAmount == 0) {
            _revertEmptyMemberReward(self, key, owner.budget, verifierSourceReward, recipient, provider);
        }
        emit IActionExecutorEvents.MemberRewardMinted({
            tokenAddress: key.tokenAddress,
            actionId: key.actionId,
            memberId: key.memberId,
            round: key.round,
            mintAmount: mintAmount,
            burnAmount: burnAmount
        });
        if (owner.mintAmount + verifierMintAmount + burnAmount != 0) {
            uint256 ownerBudget = owner.mintAmount != 0 || burnAmount != 0 ? owner.budget.ownerBudget : 0;
            _emitServiceRewardsDistributed(
                key, service.sourceTokenAddress, verifierMintAmount, ownerBudget, owner.mintAmount
            );
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private returns (OwnerClaim memory claim) {
        claim.budget = _groupBudgetForMint(self, protocol, key, service);
        if (claim.budget.totalSourceReward == 0 || _ownerPaid(self, key) != 0) return claim;

        claim.mintAmount = _ownerRewardAfterDistribution(self, protocol, key, service, claim.budget);
        claim.burnAmount = _pendingOwnerBurn(self, key, claim.budget.ownerBurn);
        if (claim.mintAmount != 0 || claim.burnAmount != 0) {
            _rememberSourceReward(
                self, service.sourceTokenAddress, key.round, key.memberId, claim.budget.totalSourceReward
            );
            self.ownerRemainingByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId] = claim.mintAmount;
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintVerifierReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private returns (uint256 amount, uint256 sourceReward) {
        sourceReward = _verifierSourceReward(protocol, key, service);
        if (sourceReward == 0 || _verifierPaid(self, key) != 0) return (0, sourceReward);

        _mintServiceRewardIfNeeded(protocol.actionTargetAddress, key, service);
        amount = _verifierRewardAmount(service, sourceReward);
        if (amount != 0) {
            self.verifierRewardByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId] = amount;
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertEmptyMemberReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupBudget memory group,
        uint256 verifierSourceReward,
        ClaimResult memory recipient,
        ClaimResult memory provider
    ) private view {
        if (recipient.previouslyMinted || provider.previouslyMinted) {
            _revertAlreadyMinted(key);
        }
        if (group.totalSourceReward == 0 && verifierSourceReward == 0) {
            if (recipient.hasEligibleSource || provider.hasEligibleSource) {
                revert IActionExecutorErrors.MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);
            }
            revert IActionExecutorErrors.ZeroRewardWeight(key.tokenAddress, key.actionId, key.memberId);
        }
        _checkVerifierRewardNotMinted(self, key);
        _revertEmptyOwnerReward(self, key, group);
    }

    function _pendingOwnerSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service,
        GroupBudget memory group
    ) private view returns (uint256 pendingAmount, MemberRewardStatus status) {
        pendingAmount = _ownerRewardAfterDistribution(self, protocol, key, service, group);
        bool hasPending = pendingAmount != 0 || _pendingOwnerBurn(self, key, group.ownerBurn) != 0;
        status = _status(hasPending, group.ownerBurn != 0);
    }

    function _ownerRewardAfterDistribution(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service,
        GroupBudget memory group
    ) private view returns (uint256 ownerAmount) {
        if (group.ownerBudget == 0) return 0;

        uint256 providerBudget = _providerBudget(service, group);
        ownerAmount = group.ownerBudget - providerBudget;
        if (providerBudget != 0) {
            uint256 ownerProviderReward = IGroupActionExecutor(protocol.groupActionExecutorAddress)
                .totalGeneratedActionRewardByGroupIdByProviderId(
                    service.sourceTokenAddress, key.round, key.memberId, key.memberId
                );
            ownerAmount += Math.mulDiv(providerBudget, ownerProviderReward, group.totalSourceReward);
        }

        (uint256[] memory sourceActionIds,) = GroupServiceRecipients.actionIdsWithRecipients(
            self, service.sourceTokenAddress, key.memberId, key.round, 0, type(uint256).max, false
        );
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            ownerAmount -= _recipientRewardsForAction(self, protocol, key, service, group, sourceActionIds[i]);
        }
    }

    function _recipientRewardsForAction(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service,
        GroupBudget memory group,
        uint256 sourceActionId
    ) private view returns (uint256 distributed) {
        uint256 sourceReward = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .generatedActionRewardByGroupId(service.sourceTokenAddress, key.round, sourceActionId, key.memberId);
        uint256 partnershipBudget = _actionPartnershipBudget(
            protocol, service, group, key.round, sourceActionId, key.memberId, sourceReward
        );
        if (partnershipBudget == 0) return 0;

        uint256[] memory ratios = GroupServiceRecipients.recipientRatios(
            self, service.sourceTokenAddress, key.round, sourceActionId, key.memberId
        );
        for (uint256 i = 0; i < ratios.length; ++i) {
            distributed += _recipientRewardAmountFromBudget(partnershipBudget, ratios[i]);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertEmptyOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupBudget memory group
    ) private view {
        if (_ownerPaid(self, key) != 0 || (group.ownerBurn != 0 && _pendingOwnerBurn(self, key, group.ownerBurn) == 0))
        {
            _revertAlreadyMinted(key);
        }
        if (group.ownerBudget != 0) {
            revert IGroupServiceExecutorErrors.ZeroOwnerRewardRemaining(key.memberId);
        }
        revert IActionExecutorErrors.MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkVerifierRewardNotMinted(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key
    ) private view {
        if (_verifierPaid(self, key) != 0) _revertAlreadyMinted(key);
    }

    function _pendingOwnerBurn(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 ownerOverflow
    ) private view returns (uint256) {
        if (ownerOverflow == 0) return 0;
        return self.ownerBurnByGroupId[key.tokenAddress][key.actionId][key.round][key.memberId] == 0 ? ownerOverflow : 0;
    }

    function _transferReward(
        address tokenAddress,
        uint256 amount
    ) private {
        if (amount != 0) IERC20(tokenAddress).safeTransfer(msg.sender, amount);
    }

    function _burnOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 amount
    ) private {
        if (amount == 0) return;
        self.ownerBurnByGroupId[key.tokenAddress][key.actionId][key.round][key.memberId] = amount;
        ILOVE20Token(key.tokenAddress).burn(amount);
        emit IGroupServiceExecutorEvents.ServiceOwnerRewardBurned({
            serviceTokenAddress: key.tokenAddress,
            serviceActionId: key.actionId,
            round: key.round,
            groupId: key.memberId,
            amount: amount
        });
    }

    function _ownerPaid(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key
    ) private view returns (uint256) {
        return self.ownerRemainingByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId];
    }

    function _verifierPaid(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key
    ) private view returns (uint256) {
        return self.verifierRewardByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId];
    }

    function _recipientGroupIds(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress
    ) private view returns (uint256[] memory groupIds) {
        (groupIds,) = GroupServiceRecipients.groupIdsByRecipientId(
            self, sourceTokenAddress, key.round, key.memberId, 0, type(uint256).max, false
        );
    }

    function _providerGroupIds(
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress
    ) private view returns (uint256[] memory groupIds) {
        (groupIds,) = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .groupIdsWithProviderRewardByProviderId(
                sourceTokenAddress, key.round, key.memberId, 0, type(uint256).max, false
            );
    }

    function _recipientSourceActionIds(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress,
        uint256 groupId
    ) private view returns (uint256[] memory actionIds) {
        (actionIds,) = GroupServiceRecipients.actionIdsByGroupIdByRecipientId(
            self, sourceTokenAddress, key.round, groupId, key.memberId, 0, type(uint256).max, false
        );
    }

    function _providerSourceActionIds(
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress,
        uint256 groupId
    ) private view returns (uint256[] memory actionIds) {
        (actionIds,) = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .actionIdsWithProviderRewardByGroupIdByProviderId(
                sourceTokenAddress, key.round, groupId, key.memberId, 0, type(uint256).max, false
            );
    }

    function _recipientSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private view returns (MemberRewardSummary memory summary) {
        if (service.sourceTokenAddress == address(0)) return summary;
        uint256[] memory groupIds = _recipientGroupIds(self, key, service.sourceTokenAddress);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            _addRecipientGroupSummary(self, protocol, key, groupIds[i], service, summary);
        }
        summary.status = _status(summary.pendingAmount != 0, summary.mintedAmount != 0);
    }

    function _addRecipientGroupSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        ServiceBudget memory service,
        MemberRewardSummary memory summary
    ) private view {
        GroupBudget memory group = _groupBudget(self, protocol, _groupKey(key, groupId), service);
        uint256[] memory sourceActionIds = _recipientSourceActionIds(self, key, service.sourceTokenAddress, groupId);
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            uint256 sourceActionId = sourceActionIds[i];
            uint256 mintedAmount = _mintedRecipientRewards(self, key, sourceActionId, groupId)[key.memberId];
            if (mintedAmount != 0) {
                summary.mintedAmount += mintedAmount;
            } else {
                summary.pendingAmount += _recipientRewardAmount(self, protocol, service, group, key, sourceActionId, groupId);
            }
        }
    }

    function _providerSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private view returns (MemberRewardSummary memory summary) {
        if (service.sourceTokenAddress == address(0)) return summary;
        uint256[] memory groupIds = _providerGroupIds(protocol, key, service.sourceTokenAddress);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            _addProviderGroupSummary(self, protocol, key, groupIds[i], service, summary);
        }
        summary.status = _status(summary.pendingAmount != 0, summary.mintedAmount != 0);
    }

    function _addProviderGroupSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        ServiceBudget memory service,
        MemberRewardSummary memory summary
    ) private view {
        GroupBudget memory group = _groupBudget(self, protocol, _groupKey(key, groupId), service);
        uint256[] memory sourceActionIds = _providerSourceActionIds(protocol, key, service.sourceTokenAddress, groupId);
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            uint256 sourceActionId = sourceActionIds[i];
            uint256 mintedAmount = _mintedProviderRewards(self, key, sourceActionId, groupId)[key.memberId];
            if (mintedAmount != 0) {
                summary.mintedAmount += mintedAmount;
            } else {
                summary.pendingAmount += _providerRewardAmount(protocol, service, group, key, sourceActionId, groupId);
            }
        }
    }

    function _mintRemainingRecipientRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private returns (ClaimResult memory result) {
        uint256[] memory groupIds = _recipientGroupIds(self, key, service.sourceTokenAddress);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            _mintRecipientRewardsInGroup(self, protocol, key, groupIds[i], service, result);
        }
    }

    function _mintRecipientRewardsInGroup(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        ServiceBudget memory service,
        ClaimResult memory result
    ) private {
        uint256[] memory sourceActionIds = _recipientSourceActionIds(self, key, service.sourceTokenAddress, groupId);
        GroupBudget memory group;
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            uint256 sourceActionId = sourceActionIds[i];
            if (_mintedRecipientRewards(self, key, sourceActionId, groupId)[key.memberId] != 0) {
                result.previouslyMinted = true;
                continue;
            }

            uint256 sourceReward = _recipientSourceReward(protocol, service.sourceTokenAddress, key, sourceActionId, groupId);
            if (sourceReward == 0) continue;
            result.hasEligibleSource = true;
            if (group.totalSourceReward == 0) group = _groupBudgetForMint(self, protocol, _groupKey(key, groupId), service);

            uint256 amount = _recipientRewardFromSource(
                self, protocol, service, group, key, sourceActionId, groupId, sourceReward
            );
            if (amount != 0) {
                _payRecipientReward(
                    self, service.sourceTokenAddress, key, sourceActionId, groupId, group.totalSourceReward, amount
                );
                result.mintAmount += amount;
            }
        }
    }

    function _mintRemainingProviderRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private returns (ClaimResult memory result) {
        if (service.providerIncentiveRatio == 0) return result;
        uint256[] memory groupIds = _providerGroupIds(protocol, key, service.sourceTokenAddress);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            _mintProviderRewardsInGroup(self, protocol, key, groupIds[i], service, result);
        }
    }

    function _mintProviderRewardsInGroup(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        ServiceBudget memory service,
        ClaimResult memory result
    ) private {
        uint256[] memory sourceActionIds = _providerSourceActionIds(protocol, key, service.sourceTokenAddress, groupId);
        GroupBudget memory group;
        uint256 providerBudget = 0;
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            uint256 sourceActionId = sourceActionIds[i];
            if (_mintedProviderRewards(self, key, sourceActionId, groupId)[key.memberId] != 0) {
                result.previouslyMinted = true;
                continue;
            }

            uint256 sourceReward = _providerSourceReward(protocol, service.sourceTokenAddress, key, sourceActionId, groupId);
            if (sourceReward == 0) continue;
            result.hasEligibleSource = true;
            if (group.totalSourceReward == 0) {
                group = _groupBudgetForMint(self, protocol, _groupKey(key, groupId), service);
                providerBudget = _providerBudget(service, group);
            }

            if (providerBudget == 0) continue;
            uint256 amount = Math.mulDiv(providerBudget, sourceReward, group.totalSourceReward);
            if (amount != 0) {
                _payProviderReward(
                    self, service.sourceTokenAddress, key, sourceActionId, groupId, group.totalSourceReward, amount
                );
                result.mintAmount += amount;
            }
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintRequiredRecipientReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        ServiceBudget memory service
    ) private returns (uint256 amount) {
        if (_mintedRecipientRewards(self, key, sourceActionId, groupId)[key.memberId] != 0) {
            revert IGroupServiceExecutorErrors.RecipientRewardAlreadyMinted(
                key.tokenAddress,
                key.actionId,
                key.round,
                sourceActionId,
                groupId,
                key.memberId
            );
        }

        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);

        GroupServiceStorage.MemberRewardKey memory groupKey = _groupKey(key, groupId);
        GroupBudget memory group = _groupBudgetForMint(self, protocol, groupKey, service);
        _checkSourceReward(group.totalSourceReward, groupKey);
        amount = _recipientRewardAmount(self, protocol, service, group, key, sourceActionId, groupId);
        if (amount == 0) {
            revert IGroupServiceExecutorErrors.ZeroRecipientReward(sourceActionId, groupId, key.memberId);
        }
        _payRecipientReward(self, service.sourceTokenAddress, key, sourceActionId, groupId, group.totalSourceReward, amount);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintRequiredProviderReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        ServiceBudget memory service
    ) private returns (uint256 amount) {
        if (_mintedProviderRewards(self, key, sourceActionId, groupId)[key.memberId] != 0) {
            revert IGroupServiceExecutorErrors.ProviderRewardAlreadyMinted(
                key.tokenAddress,
                key.actionId,
                key.round,
                sourceActionId,
                groupId,
                key.memberId
            );
        }

        _loadServiceBudget(self, protocol, key, service);
        _checkServiceBudget(service, key);

        GroupServiceStorage.MemberRewardKey memory groupKey = _groupKey(key, groupId);
        GroupBudget memory group = _groupBudgetForMint(self, protocol, groupKey, service);
        _checkSourceReward(group.totalSourceReward, groupKey);
        amount = _providerRewardAmount(protocol, service, group, key, sourceActionId, groupId);
        if (amount == 0) {
            revert IGroupServiceExecutorErrors.ZeroProviderReward(sourceActionId, groupId, key.memberId);
        }
        _payProviderReward(self, service.sourceTokenAddress, key, sourceActionId, groupId, group.totalSourceReward, amount);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertEmptyClaim(
        GroupServiceStorage.MemberRewardKey memory key,
        ClaimResult memory result
    ) private pure {
        if (result.previouslyMinted) _revertAlreadyMinted(key);
        if (!result.hasEligibleSource) {
            revert IActionExecutorErrors.ZeroRewardWeight(key.tokenAddress, key.actionId, key.memberId);
        }
        revert IActionExecutorErrors.MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);
    }

    function _payRecipientReward(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 totalSourceReward,
        uint256 amount
    ) private {
        _mintedRecipientRewards(self, key, sourceActionId, groupId)[key.memberId] = amount;
        _rememberSourceReward(self, sourceTokenAddress, key.round, groupId, totalSourceReward);
        _transferReward(key.tokenAddress, amount);
        emit IGroupServiceExecutorEvents.RecipientPaid({
            serviceTokenAddress: key.tokenAddress,
            serviceActionId: key.actionId,
            round: key.round,
            groupId: groupId,
            sourceTokenAddress: sourceTokenAddress,
            sourceActionId: sourceActionId,
            recipientId: key.memberId,
            amount: amount
        });
    }

    function _payProviderReward(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 totalSourceReward,
        uint256 amount
    ) private {
        _mintedProviderRewards(self, key, sourceActionId, groupId)[key.memberId] = amount;
        _rememberSourceReward(self, sourceTokenAddress, key.round, groupId, totalSourceReward);
        _transferReward(key.tokenAddress, amount);
        emit IGroupServiceExecutorEvents.ProviderPaid({
            serviceTokenAddress: key.tokenAddress,
            serviceActionId: key.actionId,
            round: key.round,
            groupId: groupId,
            sourceTokenAddress: sourceTokenAddress,
            sourceActionId: sourceActionId,
            providerId: key.memberId,
            amount: amount
        });
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkCreatedRound(
        GroupServiceStorage.Layout storage self,
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId
    ) private view {
        uint256 createdRound = self.createdRoundByActionId[serviceTokenAddress][serviceActionId];
        if (createdRound == 0) {
            revert IActionExecutorErrors.ActionNotCreated(serviceTokenAddress, serviceActionId);
        }
        if (round < createdRound) {
            revert IActionExecutorErrors.RoundBeforeActionCreated(round, createdRound);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkMintRound(
        uint256 round,
        uint256 mintRound
    ) private pure {
        if (mintRound == 0) revert IActionExecutorErrors.RoundNotStarted(1, 0);
        if (round > mintRound) revert IActionExecutorErrors.RoundAfterMintWindow(round, mintRound);
    }

    function _mintedRecipientRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (mapping(uint256 => uint256) storage) {
        return self.mintedRecipientRewardByMemberId[key.tokenAddress][key.actionId][key.round][groupId][sourceActionId];
    }

    function _mintedProviderRewards(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (mapping(uint256 => uint256) storage) {
        return self.mintedProviderRewardByMemberId[key.tokenAddress][key.actionId][key.round][groupId][sourceActionId];
    }

    function _groupKey(
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId
    ) private pure returns (GroupServiceStorage.MemberRewardKey memory) {
        return GroupServiceStorage.MemberRewardKey(key.tokenAddress, key.round, key.actionId, groupId);
    }

    function _isSettleableRound(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 mintRound
    ) private view returns (bool) {
        uint256 createdRound = self.createdRoundByActionId[key.tokenAddress][key.actionId];
        return createdRound != 0 && key.round >= createdRound && key.round <= mintRound;
    }

    function _recipientRewardAmount(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        ServiceBudget memory service,
        GroupBudget memory group,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (uint256) {
        if (group.ownerBudget == 0) return 0;
        uint256 sourceReward = _recipientSourceReward(protocol, service.sourceTokenAddress, key, sourceActionId, groupId);
        return _recipientRewardFromSource(self, protocol, service, group, key, sourceActionId, groupId, sourceReward);
    }

    function _providerRewardAmount(
        GroupServiceStorage.Protocol memory protocol,
        ServiceBudget memory service,
        GroupBudget memory group,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (uint256) {
        uint256 providerBudget = _providerBudget(service, group);
        if (providerBudget == 0) return 0;
        uint256 sourceReward = _providerSourceReward(protocol, service.sourceTokenAddress, key, sourceActionId, groupId);
        return Math.mulDiv(providerBudget, sourceReward, group.totalSourceReward);
    }

    function _recipientSourceReward(
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (uint256) {
        if (key.memberId == 0 || key.memberId == groupId) return 0;
        return IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .generatedActionRewardByGroupId(sourceTokenAddress, key.round, sourceActionId, groupId);
    }

    function _providerSourceReward(
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private view returns (uint256) {
        if (key.memberId == 0 || key.memberId == groupId) return 0;
        return IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .generatedActionRewardByGroupIdByProviderId(
                sourceTokenAddress, key.round, sourceActionId, groupId, key.memberId
            );
    }

    function _recipientRewardFromSource(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        ServiceBudget memory service,
        GroupBudget memory group,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 sourceReward
    ) private view returns (uint256) {
        uint256 partnershipBudget = _actionPartnershipBudget(
            protocol, service, group, key.round, sourceActionId, groupId, sourceReward
        );
        if (partnershipBudget == 0) return 0;
        uint256 ratio = GroupServiceRecipients.recipientRatio(
            self, service.sourceTokenAddress, key.round, sourceActionId, groupId, key.memberId
        );
        return _recipientRewardAmountFromBudget(partnershipBudget, ratio);
    }

    function _status(
        bool hasPending,
        bool hasSettled
    ) private pure returns (MemberRewardStatus) {
        if (hasPending) return MemberRewardStatus.Pending;
        return hasSettled ? MemberRewardStatus.Settled : MemberRewardStatus.Unavailable;
    }

    function _sourceGroupReward(
        GroupServiceStorage.Layout storage self,
        address groupActionExecutorAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        address sourceTokenAddress
    ) private view returns (uint256 amount) {
        amount = self.totalSourceRewardByGroupId[sourceTokenAddress][key.round][key.memberId];
        if (amount != 0) return amount;
        return IGroupActionExecutor(groupActionExecutorAddress)
            .totalGeneratedActionRewardByGroupId(sourceTokenAddress, key.round, key.memberId);
    }

    function _rememberSourceReward(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 amount
    ) private {
        // Load-bearing: source totals are final only after the source verification window closes.
        if (self.totalSourceRewardByGroupId[sourceTokenAddress][round][groupId] == 0) {
            self.totalSourceRewardByGroupId[sourceTokenAddress][round][groupId] = amount;
        }
    }

    function _groupBudget(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private view returns (GroupBudget memory group) {
        if (service.rewardAmount == 0) return group;
        group.totalSourceReward =
            _sourceGroupReward(self, protocol.groupActionExecutorAddress, key, service.sourceTokenAddress);
        _calculateGroupBudget(protocol.stakeAddress, key, service, group);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _groupBudgetForMint(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private returns (GroupBudget memory group) {
        // Load-bearing: each ServiceBudget is scoped to one service token, proposal, and round.
        if (service.cachedGroupId == key.memberId && service.cachedGroupBudget.totalSourceReward != 0) {
            return service.cachedGroupBudget;
        }

        group.totalSourceReward =
            _sourceGroupReward(self, protocol.groupActionExecutorAddress, key, service.sourceTokenAddress);
        if (group.totalSourceReward == 0) return group;

        _mintServiceRewardIfNeeded(protocol.actionTargetAddress, key, service);
        _calculateGroupBudget(protocol.stakeAddress, key, service, group);
        service.cachedGroupId = key.memberId;
        service.cachedGroupBudget = group;
    }

    function _verifierSourceReward(
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private view returns (uint256) {
        if (service.rewardAmount == 0) return 0;
        return IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .totalGeneratedActionRewardByVerifierId(service.sourceTokenAddress, key.round, key.memberId);
    }

    function _loadServiceBudget(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private view {
        if (service.sourceTokenAddress != address(0)) return;
        service.sourceTokenAddress =
            GroupServiceStorage.sourceTokenAddressForRound(self, key.tokenAddress, key.round, key.actionId);
        if (service.sourceTokenAddress == address(0)) return;

        service.providerIncentiveRatio = self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId];
        service.totalSourceReward = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .totalGeneratedActionReward(service.sourceTokenAddress, key.round);
        if (service.totalSourceReward == 0) return;

        (service.rewardAmount, service.isMinted) =
            IActionTarget(protocol.actionTargetAddress).actionReward(key.tokenAddress, key.round, key.actionId);
        service.publicVerifierRatio = self.publicVerifierRatioByActionId[key.tokenAddress][key.actionId];
        service.govRatioMultiplier = self.govRatioMultiplierByActionId[key.tokenAddress][key.actionId];
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintServiceRewardIfNeeded(
        address actionTargetAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service
    ) private {
        if (service.isMinted) return;
        service.rewardAmount =
            IActionTarget(actionTargetAddress).mintActionReward(key.tokenAddress, key.round, key.actionId);
        service.isMinted = true;
        _checkServiceBudget(service, key);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkServiceBudget(
        ServiceBudget memory service,
        GroupServiceStorage.MemberRewardKey memory key
    ) private pure {
        if (service.rewardAmount == 0) {
            revert IActionExecutorErrors.MemberRewardPoolEmpty(key.tokenAddress, key.round);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkSourceReward(
        uint256 sourceReward,
        GroupServiceStorage.MemberRewardKey memory key
    ) private pure {
        if (sourceReward == 0) {
            revert IActionExecutorErrors.ZeroRewardWeight(key.tokenAddress, key.actionId, key.memberId);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertAlreadyMinted(GroupServiceStorage.MemberRewardKey memory key) private pure {
        revert IActionExecutorErrors.RewardAlreadyMinted(key.tokenAddress, key.actionId, key.memberId, key.round);
    }

    function _verifierRewardAmount(
        ServiceBudget memory service,
        uint256 sourceReward
    ) private pure returns (uint256) {
        if (sourceReward == 0) return 0;
        return Math.mulDiv(
            service.rewardAmount,
            service.publicVerifierRatio * sourceReward,
            service.totalSourceReward * GroupServiceStorage.PRECISION
        );
    }

    function _calculateGroupBudget(
        address stakeAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        ServiceBudget memory service,
        GroupBudget memory group
    ) private view {
        if (group.totalSourceReward == 0) return;
        uint256 ownerRatioWeight =
            (GroupServiceStorage.PRECISION - service.publicVerifierRatio) * group.totalSourceReward;
        uint256 theoreticalOwnerReward = Math.mulDiv(
            service.rewardAmount, ownerRatioWeight, service.totalSourceReward * GroupServiceStorage.PRECISION
        );

        if (service.govRatioMultiplier == 0) {
            group.ownerBudget = theoreticalOwnerReward;
            return;
        }

        uint256 cap = 0;
        uint256 verifyPhase = key.round + 2;
        uint256 totalGovVotes = IStake(stakeAddress).totalGovVotes(service.sourceTokenAddress, verifyPhase);
        if (totalGovVotes != 0) {
            uint256 govRatio = Math.mulDiv(
                IStake(stakeAddress).govVotes(service.sourceTokenAddress, verifyPhase, key.memberId),
                GroupServiceStorage.PRECISION,
                totalGovVotes
            );
            cap = Math.mulDiv(govRatio, service.govRatioMultiplier, GroupServiceStorage.PRECISION);
        }

        uint256 capForTheoreticalOwnerReward = Math.ceilDiv(ownerRatioWeight, service.totalSourceReward);
        if (cap >= capForTheoreticalOwnerReward) {
            group.ownerBudget = theoreticalOwnerReward;
        } else {
            group.ownerBudget = Math.mulDiv(service.rewardAmount, cap, GroupServiceStorage.PRECISION);
            group.ownerBurn = theoreticalOwnerReward - group.ownerBudget;
        }
    }

    function _providerBudget(
        ServiceBudget memory service,
        GroupBudget memory group
    ) private pure returns (uint256) {
        return Math.mulDiv(group.ownerBudget, service.providerIncentiveRatio, GroupServiceStorage.PRECISION);
    }

    function _recipientRewardAmountFromBudget(
        uint256 partnershipBudget,
        uint256 ratio
    ) private pure returns (uint256) {
        return Math.mulDiv(partnershipBudget, ratio, GroupServiceStorage.PRECISION);
    }

    function _actionPartnershipBudget(
        GroupServiceStorage.Protocol memory protocol,
        ServiceBudget memory service,
        GroupBudget memory group,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 sourceReward
    ) private view returns (uint256 partnershipBudget) {
        if (sourceReward == 0 || group.ownerBudget == 0) return 0;
        uint256 providerBudget = _providerBudget(service, group);
        partnershipBudget = Math.mulDiv(group.ownerBudget - providerBudget, sourceReward, group.totalSourceReward);
        if (providerBudget == 0) return partnershipBudget;

        uint256 ownerProviderReward = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .generatedActionRewardByGroupIdByProviderId(
                service.sourceTokenAddress, round, sourceActionId, groupId, groupId
            );
        partnershipBudget += Math.mulDiv(providerBudget, ownerProviderReward, group.totalSourceReward);
    }
}
