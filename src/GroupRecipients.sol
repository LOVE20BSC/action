// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IGroupRecipientsEvents, IGroupRecipientsErrors} from "./interfaces/IGroupRecipients.sol";
import {
    IGroupServiceExecutorErrors,
    IGroupServiceExecutorEvents,
    MemberRewardSummary
} from "./interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {OrderedHistoryIndex} from "@libs/OrderedHistoryIndex.sol";
import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";

library GroupRecipients {
    using GroupServiceStorage for GroupServiceStorage.Layout;
    using OrderedHistoryIndex for OrderedHistoryIndex.Index;
    using RoundHistoryUint256Array for RoundHistoryUint256Array.History;
    using RoundHistoryStringArray for RoundHistoryStringArray.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using SafeERC20 for IERC20;

    function settlement(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryRole role
    ) external view returns (GroupServiceStorage.Settlement memory) {
        return _settlement(self, protocol, key, role, true);
    }

    function _settlement(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryRole role,
        bool includeOwnerProviderWeight
    ) private view returns (GroupServiceStorage.Settlement memory settlementInfo) {
        IGroupActionExecutor source = IGroupActionExecutor(protocol.groupActionExecutorAddress);
        settlementInfo.actionTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        settlementInfo.denominator = source.totalGeneratedActionReward(settlementInfo.actionTokenAddress, key.round);
        if (settlementInfo.denominator == 0) {
            settlementInfo.cause = GroupServiceStorage.SettlementCause.PoolEmpty;
            return settlementInfo;
        }

        settlementInfo.providerIncentiveRatio = self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId];
        if (role != GroupServiceStorage.PrimaryRole.Owner) {
            settlementInfo.verifierWeight = source
                .totalGeneratedActionRewardByVerifierId(settlementInfo.actionTokenAddress, key.round, key.memberId);
        }
        if (role != GroupServiceStorage.PrimaryRole.Verifier) {
            settlementInfo.ownerWeight =
                source.totalGeneratedActionRewardByGroupId(settlementInfo.actionTokenAddress, key.round, key.memberId);
            if (includeOwnerProviderWeight && settlementInfo.providerIncentiveRatio != 0) {
                settlementInfo.ownerProviderWeight = source.totalGeneratedActionRewardAttributionByGroupOwnerId(
                    settlementInfo.actionTokenAddress, key.round, key.memberId
                );
            }
        }
        if (settlementInfo.verifierWeight == 0 && settlementInfo.ownerWeight == 0) {
            settlementInfo.cause = GroupServiceStorage.SettlementCause.NoEligibleWeight;
            return settlementInfo;
        }

        settlementInfo.publicVerifierRatio = self.publicVerifierRatioByActionId[key.tokenAddress][key.actionId];
        settlementInfo.govRatioMultiplier = self.govRatioMultiplierByActionId[key.tokenAddress][key.actionId];
        (settlementInfo.serviceReward, settlementInfo.actionMinted) =
            IActionTarget(protocol.actionTargetAddress).actionReward(key.tokenAddress, key.round, key.actionId);
        if (settlementInfo.serviceReward == 0) {
            settlementInfo.cause = GroupServiceStorage.SettlementCause.PoolEmpty;
            return settlementInfo;
        }

        _applyFormulas(settlementInfo, protocol.stakeAddress, key.round, key.memberId);
    }

    function _applyFormulas(
        GroupServiceStorage.Settlement memory settlementInfo,
        address stakeAddress,
        uint256 round,
        uint256 memberId
    ) private view {
        settlementInfo.ownerBurned = 0;
        settlementInfo.verifierReward = Math.mulDiv(
            settlementInfo.serviceReward,
            settlementInfo.publicVerifierRatio * settlementInfo.verifierWeight,
            settlementInfo.denominator * GroupServiceStorage.PRECISION
        );

        uint256 ownerRatioWeight =
            (GroupServiceStorage.PRECISION - settlementInfo.publicVerifierRatio) * settlementInfo.ownerWeight;
        uint256 theoreticalOwnerReward = Math.mulDiv(
            settlementInfo.serviceReward, ownerRatioWeight, settlementInfo.denominator * GroupServiceStorage.PRECISION
        );

        if (settlementInfo.govRatioMultiplier == 0 || settlementInfo.ownerWeight == 0) {
            settlementInfo.ownerReward = theoreticalOwnerReward;
            return;
        }

        uint256 cap = 0;
        uint256 verifyPhase = round + 2;
        uint256 totalGovVotes = IStake(stakeAddress).totalGovVotes(settlementInfo.actionTokenAddress, verifyPhase);
        if (totalGovVotes != 0) {
            uint256 govRatio = Math.mulDiv(
                IStake(stakeAddress).govVotes(settlementInfo.actionTokenAddress, verifyPhase, memberId),
                GroupServiceStorage.PRECISION,
                totalGovVotes
            );
            cap = Math.mulDiv(govRatio, settlementInfo.govRatioMultiplier, GroupServiceStorage.PRECISION);
        }

        uint256 capForTheoreticalOwnerReward =
            Math.mulDiv(ownerRatioWeight, 1, settlementInfo.denominator, Math.Rounding.Ceil);
        if (cap >= capForTheoreticalOwnerReward) {
            settlementInfo.ownerReward = theoreticalOwnerReward;
        } else {
            settlementInfo.ownerReward = Math.mulDiv(settlementInfo.serviceReward, cap, GroupServiceStorage.PRECISION);
            settlementInfo.ownerBurned = theoreticalOwnerReward - settlementInfo.ownerReward;
        }
    }

    function applyFormulas(
        GroupServiceStorage.Settlement memory settlementInfo,
        address stakeAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (GroupServiceStorage.Settlement memory) {
        _applyFormulas(settlementInfo, stakeAddress, round, memberId);
        return settlementInfo;
    }

    function groupIdsWithProviderRewardByProviderId(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        if (!_isValidRewardIndexKey(self, key)) return (new uint256[](0), 0);
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        return IGroupActionExecutor(protocol.groupActionExecutorAddress).groupIdsWithProviderRewardByProviderId(
            sourceTokenAddress, key.round, key.memberId, offset, limit, reverse
        );
    }

    function actionIdsWithProviderRewardByGroupIdByProviderId(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        if (!_isValidRewardIndexKey(self, key)) return (new uint256[](0), 0);
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        return IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .actionIdsWithProviderRewardByGroupIdByProviderId(
                sourceTokenAddress, key.round, groupId, key.memberId, offset, limit, reverse
            );
    }

    function groupIdsWithRecipientRewardByRecipientId(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        if (!_isValidRewardIndexKey(self, key)) return (new uint256[](0), 0);
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        return self.recipientGroupIdsByRecipientId[sourceTokenAddress][key.memberId]
            .valuesByRound(key.round, offset, limit, reverse);
    }

    function actionIdsWithRecipientRewardByGroupIdByRecipientId(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        if (!_isValidRewardIndexKey(self, key)) return (new uint256[](0), 0);
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        return self.recipientActionIdsByGroupIdByRecipientId[sourceTokenAddress][key.memberId][groupId]
            .valuesByRound(key.round, offset, limit, reverse);
    }

    function _isValidRewardIndexKey(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.MemberRewardKey memory key
    ) private view returns (bool) {
        return self.actionTokenAddressByActionId[key.tokenAddress][key.actionId] != address(0)
            && key.round >= self.createdRoundByActionId[key.tokenAddress][key.actionId];
    }

    function _rewardGroupIds(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider
    ) private view returns (uint256[] memory groupIds) {
        if (!_isValidRewardIndexKey(self, key)) return new uint256[](0);
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        if (provider) {
            (groupIds,) = IGroupActionExecutor(protocol.groupActionExecutorAddress).groupIdsWithProviderRewardByProviderId(
                sourceTokenAddress, key.round, key.memberId, 0, type(uint256).max, false
            );
        } else {
            (groupIds,) = self.recipientGroupIdsByRecipientId[sourceTokenAddress][key.memberId]
                .valuesByRound(key.round, 0, type(uint256).max, false);
        }
    }

    function _sourceActionIds(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        GroupServiceStorage.Settlement memory settlementInfo,
        bool provider
    ) private view returns (uint256[] memory actionIds) {
        address sourceTokenAddress = settlementInfo.actionTokenAddress;
        if (provider) {
            (actionIds,) = IGroupActionExecutor(protocol.groupActionExecutorAddress)
                .actionIdsWithProviderRewardByGroupIdByProviderId(
                    sourceTokenAddress, share.round, share.groupId, share.memberId, 0, type(uint256).max, false
                );
        } else {
            (actionIds,) = self.recipientActionIdsByGroupIdByRecipientId[sourceTokenAddress][share.memberId][share.groupId]
                .valuesByRound(share.round, 0, type(uint256).max, false);
        }
    }

    function shareReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        uint256 mintRound
    ) external view returns (uint256 rewardAmount, bool isMinted) {
        GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
        rewardAmount = provider ? paid.provider : paid.recipient;
        // forge-lint: disable-next-line(boolean-cst)
        if (rewardAmount != 0) return (rewardAmount, true);
        if (share.memberId == share.groupId || !_isSettleableRound(self, share, mintRound)) return (0, isMinted);

        rewardAmount = _shareAmount(self, protocol, _shareSettlement(self, protocol, share), share, provider);
    }

    function shareSummaries(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 mintRound
    ) external view returns (MemberRewardSummary memory recipient, MemberRewardSummary memory provider) {
        recipient = _shareSummary(self, protocol, key, false, mintRound);
        if (self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] != 0) {
            provider = _shareSummary(self, protocol, key, true, mintRound);
        }
    }

    function shareSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 mintRound
    ) external view returns (MemberRewardSummary memory summary) {
        if (provider && self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] == 0) return summary;
        return _shareSummary(self, protocol, key, provider, mintRound);
    }

    function _shareSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 mintRound
    ) private view returns (MemberRewardSummary memory summary) {
        if (key.round > mintRound) return summary;
        uint256[] memory groupIds = _rewardGroupIds(self, protocol, key, provider);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            _addGroupSummary(self, protocol, _share(key, 0, groupIds[i]), provider, summary);
        }
        if (summary.pendingAmount != 0) {
            summary.status = MemberRewardStatus.Pending;
        } else if (summary.mintedAmount != 0) {
            summary.status = MemberRewardStatus.Settled;
        }
    }

    function _addGroupSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        MemberRewardSummary memory summary
    ) private view {
        GroupServiceStorage.Settlement memory settlementInfo = _shareSettlement(self, protocol, share);
        uint256[] memory sourceActionIds = _sourceActionIds(self, protocol, share, settlementInfo, provider);
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            share.sourceActionId = sourceActionIds[i];
            GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
            uint256 mintedAmount = provider ? paid.provider : paid.recipient;
            if (mintedAmount != 0) {
                summary.mintedAmount += mintedAmount;
            } else {
                summary.pendingAmount += _shareAmount(self, protocol, settlementInfo, share, provider);
            }
        }
    }

    function mintShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        uint256 mintRound
    ) external returns (uint256 mintAmount) {
        return _mintRequiredShare(self, protocol, share, provider, mintRound);
    }

    function mintShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256[] calldata sourceActionIds,
        uint256[] calldata groupIds,
        bool provider,
        uint256 mintRound
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](sourceActionIds.length);
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            GroupServiceStorage.Share memory share = GroupServiceStorage.Share(
                key.tokenAddress, key.round, key.actionId, sourceActionIds[i], groupIds[i], key.memberId
            );
            amounts[i] = _mintRequiredShare(self, protocol, share, provider, mintRound);
        }
    }

    function mintMemberShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key
    ) external returns (uint256 mintAmount, bool previouslyMinted) {
        (mintAmount, previouslyMinted) = _mintRemainingShares(self, protocol, key, false);
        if (self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] != 0) {
            (uint256 amount, bool providerPreviouslyMinted) = _mintRemainingShares(self, protocol, key, true);
            mintAmount += amount;
            previouslyMinted = previouslyMinted || providerPreviouslyMinted;
        }
    }

    function mintRoleShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider
    ) external returns (uint256 mintAmount, bool previouslyMinted) {
        if (provider && self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] == 0) {
            return (mintAmount, previouslyMinted);
        }
        return _mintRemainingShares(self, protocol, key, provider);
    }

    function _mintRemainingShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider
    ) private returns (uint256 mintAmount, bool previouslyMinted) {
        uint256[] memory groupIds = _rewardGroupIds(self, protocol, key, provider);
        for (uint256 i = 0; i < groupIds.length; ++i) {
            (uint256 amount, bool groupPreviouslyMinted) =
                _mintGroupShares(self, protocol, _share(key, 0, groupIds[i]), provider);
            mintAmount += amount;
            previouslyMinted = previouslyMinted || groupPreviouslyMinted;
        }
    }

    function _mintGroupShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider
    ) private returns (uint256 mintAmount, bool previouslyMinted) {
        GroupServiceStorage.Settlement memory settlementInfo = _shareSettlement(self, protocol, share);
        if (settlementInfo.cause != GroupServiceStorage.SettlementCause.RoundedToZero) return (0, previouslyMinted);

        uint256[] memory sourceActionIds = _sourceActionIds(self, protocol, share, settlementInfo, provider);
        for (uint256 i = 0; i < sourceActionIds.length; ++i) {
            share.sourceActionId = sourceActionIds[i];
            GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
            if ((provider ? paid.provider : paid.recipient) != 0) {
                previouslyMinted = true;
            } else {
                mintAmount += _mintUnclaimedShare(self, protocol, share, settlementInfo, paid, provider);
            }
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintRequiredShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        uint256 mintRound
    ) private returns (uint256 mintAmount) {
        _checkMintWindow(self, share, mintRound);

        GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
        if (provider && paid.provider != 0) {
            revert IGroupServiceExecutorErrors.ProviderRewardAlreadyMinted(
                share.tokenAddress, share.serviceActionId, share.round, share.sourceActionId, share.groupId, share.memberId
            );
        }
        if (!provider && paid.recipient != 0) {
            revert IGroupServiceExecutorErrors.RecipientRewardAlreadyMinted(
                share.tokenAddress, share.serviceActionId, share.round, share.sourceActionId, share.groupId, share.memberId
            );
        }

        GroupServiceStorage.Settlement memory settlementInfo = _shareSettlement(self, protocol, share);
        _checkSettlementPool(settlementInfo, share.tokenAddress, share.round, share.serviceActionId, share.groupId);
        mintAmount = _mintUnclaimedShare(self, protocol, share, settlementInfo, paid, provider);
        if (mintAmount == 0) _revertZeroShare(share, provider);
    }

    function _mintUnclaimedShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        GroupServiceStorage.Settlement memory settlementInfo,
        GroupServiceStorage.PaidShare storage paid,
        bool provider
    ) private returns (uint256 amount) {
        amount = _shareAmount(self, protocol, settlementInfo, share, provider);
        if (_mintServiceRewardIfNeeded(protocol, settlementInfo, share)) {
            amount = _shareAmount(self, protocol, settlementInfo, share, provider);
        }
        if (amount != 0) _payShare(share, provider, paid, settlementInfo, amount);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkMintWindow(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share,
        uint256 mintRound
    ) private view {
        uint256 createdRound = self.createdRoundByActionId[share.tokenAddress][share.serviceActionId];
        if (createdRound == 0) {
            revert IActionExecutorErrors.ActionNotCreated(share.tokenAddress, share.serviceActionId);
        }
        if (share.round < createdRound) {
            revert IActionExecutorErrors.RoundBeforeActionCreated(share.round, createdRound);
        }
        if (mintRound == 0) revert IActionExecutorErrors.RoundNotStarted(1, 0);
        if (share.round > mintRound) revert IActionExecutorErrors.RoundAfterMintWindow(share.round, mintRound);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkSettlementPool(
        GroupServiceStorage.Settlement memory settlementInfo,
        address tokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) private pure {
        if (settlementInfo.cause == GroupServiceStorage.SettlementCause.NoEligibleWeight) {
            revert IActionExecutorErrors.ZeroRewardWeight(tokenAddress, serviceActionId, groupId);
        }
        if (settlementInfo.cause == GroupServiceStorage.SettlementCause.PoolEmpty) {
            revert IActionExecutorErrors.MemberRewardPoolEmpty(tokenAddress, round);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintServiceRewardIfNeeded(
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Settlement memory settlementInfo,
        GroupServiceStorage.Share memory share
    ) private returns (bool rewardChanged) {
        if (settlementInfo.actionMinted) return false;

        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 reward = IActionTarget(protocol.actionTargetAddress)
            .mintActionReward(share.tokenAddress, share.round, share.serviceActionId);
        settlementInfo.actionMinted = true;
        if (reward == settlementInfo.serviceReward) return false;
        if (reward == 0) revert IActionExecutorErrors.MemberRewardPoolEmpty(share.tokenAddress, share.round);
        settlementInfo.serviceReward = reward;
        _applyFormulas(settlementInfo, protocol.stakeAddress, share.round, share.groupId);
        return true;
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertZeroShare(GroupServiceStorage.Share memory share, bool provider) private pure {
        if (provider) revert IGroupServiceExecutorErrors.ZeroProviderReward(share.sourceActionId, share.groupId, share.memberId);
        revert IGroupServiceExecutorErrors.ZeroRecipientReward(share.sourceActionId, share.groupId, share.memberId);
    }

    function _payShare(
        GroupServiceStorage.Share memory share,
        bool provider,
        GroupServiceStorage.PaidShare storage paid,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 amount
    ) private {
        if (provider) paid.provider = amount;
        else paid.recipient = amount;
        IERC20(share.tokenAddress).safeTransfer(msg.sender, amount);
        if (provider) {
            emit IGroupServiceExecutorEvents.ProviderPaid({
                serviceTokenAddress: share.tokenAddress,
                serviceActionId: share.serviceActionId,
                round: share.round,
                groupId: share.groupId,
                sourceTokenAddress: settlementInfo.actionTokenAddress,
                sourceActionId: share.sourceActionId,
                providerId: share.memberId,
                amount: amount
            });
        } else {
            emit IGroupServiceExecutorEvents.RecipientPaid({
                serviceTokenAddress: share.tokenAddress,
                serviceActionId: share.serviceActionId,
                round: share.round,
                groupId: share.groupId,
                sourceTokenAddress: settlementInfo.actionTokenAddress,
                sourceActionId: share.sourceActionId,
                recipientId: share.memberId,
                amount: amount
            });
        }
    }

    function _paidShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share
    ) private view returns (GroupServiceStorage.PaidShare storage) {
        return self.paidShares[share.tokenAddress][share.serviceActionId][share.round][share.groupId]
            [share.sourceActionId][share.memberId];
    }

    function _share(
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId,
        uint256 groupId
    ) private pure returns (GroupServiceStorage.Share memory) {
        return GroupServiceStorage.Share(key.tokenAddress, key.round, key.actionId, sourceActionId, groupId, key.memberId);
    }

    function _settlementKey(GroupServiceStorage.Share memory share)
        private
        pure
        returns (GroupServiceStorage.MemberRewardKey memory)
    {
        return GroupServiceStorage.MemberRewardKey(share.tokenAddress, share.round, share.serviceActionId, share.groupId);
    }

    function _shareSettlement(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share
    ) private view returns (GroupServiceStorage.Settlement memory) {
        return _settlement(self, protocol, _settlementKey(share), GroupServiceStorage.PrimaryRole.Owner, false);
    }

    function _isSettleableRound(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share,
        uint256 mintRound
    ) private view returns (bool) {
        uint256 createdRound = self.createdRoundByActionId[share.tokenAddress][share.serviceActionId];
        return createdRound != 0 && share.round >= createdRound && share.round <= mintRound;
    }

    function _shareAmount(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Settlement memory settlementInfo,
        GroupServiceStorage.Share memory share,
        bool provider
    ) private view returns (uint256) {
        if (share.memberId == 0 || share.memberId == share.groupId || settlementInfo.ownerReward == 0) return 0;
        if (provider) return _providerAmount(protocol.groupActionExecutorAddress, settlementInfo, share);
        uint256 partnershipBudget = _actionPartnershipBudget(
            protocol.groupActionExecutorAddress, _settlementKey(share), settlementInfo, share.sourceActionId
        );
        return recipientAmount(
            self,
            settlementInfo.actionTokenAddress,
            share.round,
            share.sourceActionId,
            share.groupId,
            share.memberId,
            partnershipBudget
        );
    }

    function _providerAmount(
        address groupActionExecutorAddress,
        GroupServiceStorage.Settlement memory settlementInfo,
        GroupServiceStorage.Share memory share
    ) private view returns (uint256) {
        uint256 marketBudget = _marketBudget(settlementInfo);
        if (marketBudget == 0) return 0;
        uint256 attribution = IGroupActionExecutor(groupActionExecutorAddress).generatedActionRewardAttributionByProviderId(
            settlementInfo.actionTokenAddress, share.round, share.sourceActionId, share.groupId, share.memberId
        );
        return Math.mulDiv(marketBudget, attribution, settlementInfo.ownerWeight);
    }

    function _actionPartnershipBudget(
        address groupActionExecutorAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 sourceActionId
    ) private view returns (uint256 partnershipBudget) {
        if (settlementInfo.ownerReward == 0) return 0;
        IGroupActionExecutor source = IGroupActionExecutor(groupActionExecutorAddress);
        uint256 groupWeight = source.generatedActionRewardByGroupId(
            settlementInfo.actionTokenAddress, key.round, sourceActionId, key.memberId
        );
        if (groupWeight == 0) return 0;
        uint256 marketBudget = _marketBudget(settlementInfo);
        if (marketBudget == 0) {
            return Math.mulDiv(settlementInfo.ownerReward, groupWeight, settlementInfo.ownerWeight);
        }

        uint256 ownerAttribution = source.generatedActionRewardAttributionByProviderId(
            settlementInfo.actionTokenAddress, key.round, sourceActionId, key.memberId, key.memberId
        );
        partnershipBudget = Math.mulDiv(settlementInfo.ownerReward - marketBudget, groupWeight, settlementInfo.ownerWeight);
        partnershipBudget += Math.mulDiv(marketBudget, ownerAttribution, settlementInfo.ownerWeight);
    }

    function _marketBudget(GroupServiceStorage.Settlement memory settlementInfo) private pure returns (uint256) {
        return Math.mulDiv(settlementInfo.ownerReward, settlementInfo.providerIncentiveRatio, GroupServiceStorage.PRECISION);
    }

    struct RecipientTable {
        uint256[] recipientIds;
        uint256[] ratios;
        string[] remarks;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setRecipients(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external {
        _setRecipients(
            self,
            protocol,
            sourceTokenAddress,
            round,
            sourceActionId,
            groupId,
            RecipientTable({recipientIds: recipientIds, ratios: ratios, remarks: remarks})
        );
    }

    function _setRecipients(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        RecipientTable memory table
    ) private {
        _checkRecipients(protocol, table, groupId);

        // Load-bearing: settlement only reads configs for actions this executor created, so any other
        // key is silently ignored and the owner keeps the whole slice.
        if (
            IGroupActionExecutor(protocol.groupActionExecutorAddress)
                    .joinTokenAddress(sourceTokenAddress, sourceActionId) == address(0)
        ) {
            revert IGroupRecipientsErrors.UnknownSourceAction(sourceTokenAddress, sourceActionId);
        }

        uint256[] memory prevRecipientIds =
            self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        _updateRecipientRewardKeys(
            self, sourceTokenAddress, round, sourceActionId, groupId, prevRecipientIds, table.recipientIds
        );

        uint256[] memory prevRatios = self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        string[] memory prevRemarks = self.remarksHistory[sourceTokenAddress][sourceActionId][groupId].values(round);

        self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].record(round, table.recipientIds);
        self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].record(round, table.ratios);
        self.remarksHistory[sourceTokenAddress][sourceActionId][groupId].record(round, table.remarks);

        if (table.recipientIds.length != 0) {
            RoundHistoryUint256Set.Storage storage actionSet = self.actionIdsWithRecipients[sourceTokenAddress][groupId];
            uint256 actual = actionSet.count();
            if (
                !actionSet.contains(sourceActionId)
                    && actual >= GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP
            ) {
                revert IGroupRecipientsErrors.RecipientActionsLimitExceeded(
                    sourceTokenAddress, groupId, actual, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP
                );
            }
            actionSet.add(round, sourceActionId);
        } else {
            self.actionIdsWithRecipients[sourceTokenAddress][groupId].remove(round, sourceActionId);
        }

        emit IGroupRecipientsEvents.RecipientsChanged({
            sourceTokenAddress: sourceTokenAddress,
            sourceActionId: sourceActionId,
            round: round,
            groupId: groupId,
            recipientIds: table.recipientIds,
            ratios: table.ratios,
            remarks: table.remarks,
            prevRecipientIds: prevRecipientIds,
            prevRatios: prevRatios,
            prevRemarks: prevRemarks
        });
    }

    function _updateRecipientRewardKeys(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] memory previousIds,
        uint256[] memory currentIds
    ) private {
        if (previousIds.length == 0 && currentIds.length == 0) return;

        for (uint256 i = 0; i < previousIds.length; ++i) {
            uint256 recipientId = previousIds[i];
            if (!_containsRecipient(currentIds, recipientId)) {
                RoundHistoryUint256Set.Storage storage actionIds =
                    self.recipientActionIdsByGroupIdByRecipientId[sourceTokenAddress][recipientId][groupId];
                actionIds.remove(round, sourceActionId);
                if (actionIds.count() == 0) {
                    self.recipientGroupIdsByRecipientId[sourceTokenAddress][recipientId].remove(round, groupId);
                }
            }
        }
        for (uint256 i = 0; i < currentIds.length; ++i) {
            uint256 recipientId = currentIds[i];
            if (!_containsRecipient(previousIds, recipientId)) {
                RoundHistoryUint256Set.Storage storage actionIds =
                    self.recipientActionIdsByGroupIdByRecipientId[sourceTokenAddress][recipientId][groupId];
                if (actionIds.count() == 0) {
                    self.recipientGroupIdsByRecipientId[sourceTokenAddress][recipientId].add(round, groupId);
                }
                actionIds.add(round, sourceActionId);
            }
        }
    }

    function _containsRecipient(uint256[] memory recipientIds, uint256 recipientId) private pure returns (bool) {
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            if (recipientIds[i] == recipientId) return true;
        }
        return false;
    }

    function recipients(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) external view returns (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory remarks) {
        recipientIds = self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        ratios = self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        remarks = self.remarksHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
    }

    function actionIdsWithRecipients(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return self.actionIdsWithRecipients[sourceTokenAddress][groupId].valuesByRound(round, offset, limit, reverse);
    }

    function recipientRatio(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 ratio) {
        uint256[] memory recipientIds = self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        uint256[] memory ratios = self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            if (recipientIds[i] == recipientId) return ratios[i];
        }
    }

    function currentRecipientGroupIdsByRecipientId(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return self.recipientGroupIdsByRecipientId[sourceTokenAddress][recipientId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function currentRecipientSourceActionIdsByRecipientIdByGroupId(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 recipientId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory sourceActionIds, uint256 totalCount) {
        return self.recipientActionIdsByGroupIdByRecipientId[sourceTokenAddress][recipientId][groupId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function recipientAmount(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId,
        uint256 slice
    ) internal view returns (uint256) {
        if (slice == 0) return 0;

        RoundHistoryUint256Array.History storage history =
            self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId];
        if (!history.index.contains(round)) {
            (bool found, uint256 recordedRound) = history.index.nearest(round);
            if (!found) return 0;
            round = recordedRound;
        }

        uint256[] storage recipientIds = history.valueByRound[round];
        uint256 count = recipientIds.length;
        for (uint256 i = 0; i < count; ++i) {
            if (recipientIds[i] == recipientId) {
                // IDs and ratios are checkpointed together by setRecipients.
                uint256 ratio = self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].valueByRound[round][i];
                return Math.mulDiv(slice, ratio, GroupServiceStorage.PRECISION);
            }
        }
        return 0;
    }

    function ownerRewardAfterDistribution(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo
    ) external view returns (uint256 ownerAmount) {
        if (settlementInfo.ownerReward == 0) return 0;

        uint256 marketBudget = _marketBudget(settlementInfo);
        ownerAmount = settlementInfo.ownerReward - marketBudget;
        if (marketBudget != 0) {
            ownerAmount += Math.mulDiv(marketBudget, settlementInfo.ownerProviderWeight, settlementInfo.ownerWeight);
        }

        (uint256[] memory sourceActionIds,) =
            self.actionIdsWithRecipients[settlementInfo.actionTokenAddress][key.memberId]
                .valuesByRound(key.round, 0, type(uint256).max, false);
        for (uint256 i = 0; i < sourceActionIds.length; i++) {
            ownerAmount -= _projectedForAction(self, protocol, key, settlementInfo, sourceActionIds[i]);
        }
    }

    function _projectedForAction(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 sourceActionId
    ) private view returns (uint256 distributed) {
        uint256 partnershipBudget =
            _actionPartnershipBudget(protocol.groupActionExecutorAddress, key, settlementInfo, sourceActionId);
        if (partnershipBudget == 0) return 0;
        uint256[] memory ratios =
            self.ratiosHistory[settlementInfo.actionTokenAddress][sourceActionId][key.memberId].values(key.round);
        for (uint256 i = 0; i < ratios.length; ++i) {
            distributed += Math.mulDiv(partnershipBudget, ratios[i], GroupServiceStorage.PRECISION);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkRecipients(
        GroupServiceStorage.Protocol memory protocol,
        RecipientTable memory table,
        uint256 groupId
    ) internal view {
        uint256 length = table.recipientIds.length;
        if (length != table.ratios.length || length != table.remarks.length) {
            revert IGroupRecipientsErrors.RecipientArrayLengthMismatch(
                length, table.ratios.length, table.remarks.length
            );
        }
        if (length > GroupServiceStorage.MAX_RECIPIENTS_PER_ACTION) {
            revert IGroupRecipientsErrors.TooManyRecipients(length, GroupServiceStorage.MAX_RECIPIENTS_PER_ACTION);
        }

        uint256 totalRatios = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 recipientId = table.recipientIds[i];
            if (recipientId == groupId) {
                revert IGroupRecipientsErrors.RecipientIsGroupId(groupId, recipientId);
            }
            if (table.ratios[i] == 0) {
                revert IGroupRecipientsErrors.ZeroRecipientRatio(recipientId);
            }
            uint256 remarkLength = bytes(table.remarks[i]).length;
            if (remarkLength > GroupServiceStorage.MAX_REMARK_BYTES) {
                revert IGroupRecipientsErrors.RemarkTooLong(i, remarkLength, GroupServiceStorage.MAX_REMARK_BYTES);
            }
            for (uint256 j = 0; j < i; j++) {
                if (table.recipientIds[j] == recipientId) {
                    revert IGroupRecipientsErrors.DuplicateMemberId(recipientId);
                }
            }
            IMemberNFT(protocol.memberNFTAddress).ownerOf(recipientId);
            uint256 ratio = table.ratios[i];
            if (ratio > GroupServiceStorage.PRECISION) {
                revert IGroupRecipientsErrors.DistributionOverflow(ratio, GroupServiceStorage.PRECISION);
            }
            if (totalRatios > GroupServiceStorage.PRECISION - ratio) {
                revert IGroupRecipientsErrors.DistributionOverflow(totalRatios + ratio, GroupServiceStorage.PRECISION);
            }
            totalRatios += ratio;
        }
    }

}
