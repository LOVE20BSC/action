// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {IGroupRecipientsEvents, IGroupRecipientsErrors} from "./interfaces/IGroupRecipients.sol";
import {
    IGroupServiceExecutorErrors,
    IGroupServiceExecutorEvents,
    MemberRewardSummary,
    ServiceRewardDetails
} from "./interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {GroupRewardKey} from "./interfaces/IGroupActionVerify.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
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

    struct Distribution {
        uint256[] recipientIds;
        uint256[] ratios;
        uint256[] amounts;
        uint256 totalRecipientAmount;
        uint256 ownerAmount;
        uint256 providerReserve;
    }

    function settlement(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryRole role
    ) external view returns (GroupServiceStorage.Settlement memory) {
        return _settlement(self, protocol, key, role);
    }

    function _settlement(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryRole role
    ) private view returns (GroupServiceStorage.Settlement memory settlementInfo) {
        settlementInfo.actionTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        settlementInfo.denominator = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .totalGeneratedActionReward(settlementInfo.actionTokenAddress, key.round);
        if (settlementInfo.denominator == 0) {
            settlementInfo.cause = GroupServiceStorage.SettlementCause.PoolEmpty;
            return settlementInfo;
        }

        if (role != GroupServiceStorage.PrimaryRole.Owner) {
            settlementInfo.verifierWeight = IGroupActionExecutor(protocol.groupActionExecutorAddress)
                .totalGeneratedActionRewardByVerifierId(settlementInfo.actionTokenAddress, key.round, key.memberId);
        }
        if (role != GroupServiceStorage.PrimaryRole.Verifier) {
            settlementInfo.ownerWeight = IGroupActionExecutor(protocol.groupActionExecutorAddress)
                .totalGeneratedActionRewardByGroupId(settlementInfo.actionTokenAddress, key.round, key.memberId);
        }
        if (settlementInfo.verifierWeight == 0 && settlementInfo.ownerWeight == 0) {
            settlementInfo.cause = GroupServiceStorage.SettlementCause.NoEligibleWeight;
            return settlementInfo;
        }

        settlementInfo.publicVerifierRatio = self.publicVerifierRatioByActionId[key.tokenAddress][key.actionId];
        settlementInfo.providerIncentiveRatio = self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId];
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

        // Ceiling keeps the cap boundary continuous with the theoretical reward.
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

    function rewardKeys(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        return _rewardKeys(self, protocol, key, provider, offset, limit, reverse);
    }

    function _rewardKeys(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) private view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        address sourceTokenAddress = self.actionTokenAddressByActionId[key.tokenAddress][key.actionId];
        if (
            sourceTokenAddress == address(0)
                || key.round < self.createdRoundByActionId[key.tokenAddress][key.actionId]
        ) return (new GroupRewardKey[](0), 0);

        if (provider) {
            return IGroupActionExecutor(protocol.groupActionExecutorAddress)
                .providerRewardKeys(sourceTokenAddress, key.round, key.memberId, offset, limit, reverse);
        }
        return _recipientRewardKeys(self, sourceTokenAddress, key.round, key.memberId, offset, limit, reverse);
    }

    function shareReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        uint256 mintRound
    ) external view returns (uint256 amount, bool isMinted) {
        return _shareReward(self, protocol, share, provider, mintRound);
    }

    function _shareReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        uint256 mintRound
    ) private view returns (uint256 amount, bool isMinted) {
        GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
        amount = provider ? paid.provider : paid.recipient;
        // forge-lint: disable-next-line(boolean-cst)
        if (amount != 0) return (amount, true);
        if (share.memberId == share.groupId || !_isSettleableRound(self, share, mintRound)) return (0, isMinted);

        GroupServiceStorage.Settlement memory settlementInfo =
            _settlement(self, protocol, _settlementKey(share), GroupServiceStorage.PrimaryRole.Owner);
        amount = _shareAmount(self, protocol, settlementInfo, share, provider);
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

    function _shareSummary(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 mintRound
    ) private view returns (MemberRewardSummary memory summary) {
        (GroupRewardKey[] memory keys,) = _rewardKeys(self, protocol, key, provider, 0, type(uint256).max, false);
        for (uint256 i = 0; i < keys.length; ++i) {
            GroupServiceStorage.Share memory share = _shareKey(key, keys[i]);
            (uint256 amount, bool minted) = _shareReward(self, protocol, share, provider, mintRound);
            if (minted) summary.mintedAmount += amount;
            else summary.pendingAmount += amount;
        }
        summary.status = _status(summary.pendingAmount != 0, summary.mintedAmount != 0);
    }

    function distributionForAction(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 sourceActionId
    ) external view returns (Distribution memory info) {
        GroupServiceStorage.Settlement memory settlementInfo =
            _settlement(self, protocol, key, GroupServiceStorage.PrimaryRole.Owner);
        uint256 slice = _ownerSlice(
            protocol,
            settlementInfo.actionTokenAddress,
            key.round,
            sourceActionId,
            key.memberId,
            settlementInfo.ownerReward,
            settlementInfo.ownerWeight
        );
        (uint256 reserve,) = marketAmounts(
            protocol.groupActionExecutorAddress,
            settlementInfo.providerIncentiveRatio,
            settlementInfo.actionTokenAddress,
            key.round,
            sourceActionId,
            key.memberId,
            0,
            slice
        );
        info = _distribution(
            self,
            settlementInfo.actionTokenAddress,
            key.round,
            sourceActionId,
            key.memberId,
            slice - reserve
        );
        info.providerReserve = reserve;
    }

    function mintShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        bool required,
        uint256 mintRound
    ) external returns (uint256 amount, uint256 burnAmount) {
        return _mintShare(self, protocol, share, provider, required, mintRound);
    }

    function mintShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupRewardKey[] calldata keys,
        bool provider,
        uint256 mintRound
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            (amounts[i],) = _mintShare(self, protocol, _shareKey(key, keys[i]), provider, true, mintRound);
        }
    }

    function mintMemberShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        uint256 mintRound
    ) external returns (uint256 mintAmount, uint256 burnAmount, bool previouslySettled) {
        (mintAmount, burnAmount, previouslySettled) = _mintRemainingShares(self, protocol, key, false, mintRound);
        if (self.providerIncentiveRatioByActionId[key.tokenAddress][key.actionId] != 0) {
            (uint256 amount, uint256 burn, bool settled) = _mintRemainingShares(self, protocol, key, true, mintRound);
            mintAmount += amount;
            burnAmount += burn;
            previouslySettled = previouslySettled || settled;
        }
    }

    function _mintRemainingShares(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        bool provider,
        uint256 mintRound
    ) private returns (uint256 mintAmount, uint256 burnAmount, bool previouslySettled) {
        (GroupRewardKey[] memory keys,) = _rewardKeys(self, protocol, key, provider, 0, type(uint256).max, false);
        for (uint256 i = 0; i < keys.length; ++i) {
            GroupServiceStorage.Share memory share = _shareKey(key, keys[i]);
            GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
            if ((provider ? paid.provider : paid.recipient) != 0) {
                previouslySettled = true;
                continue;
            }
            (uint256 amount, uint256 burn) = _mintShare(self, protocol, share, provider, false, mintRound);
            mintAmount += amount;
            burnAmount += burn;
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.Share memory share,
        bool provider,
        bool required,
        uint256 mintRound
    ) private returns (uint256 amount, uint256 burnAmount) {
        if (required) _checkMintWindow(self, share, mintRound);

        GroupServiceStorage.PaidShare storage paid = _paidShare(self, share);
        if (!required && (provider ? paid.provider : paid.recipient) != 0) return (0, 0);
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

        GroupServiceStorage.Settlement memory settlementInfo =
            _settlement(self, protocol, _settlementKey(share), GroupServiceStorage.PrimaryRole.Owner);
        if (required) _checkSettlementPool(settlementInfo, share.tokenAddress, share.round, share.serviceActionId, share.groupId);
        amount = _shareAmount(self, protocol, settlementInfo, share, provider);
        if (amount == 0 && !settlementInfo.actionMinted) {
            _mintServiceRewardIfNeeded(
                protocol, settlementInfo, share.tokenAddress, share.round, share.serviceActionId, share.groupId
            );
            amount = _shareAmount(self, protocol, settlementInfo, share, provider);
        }
        if (amount == 0) {
            if (required) _revertZeroShare(share, provider);
            return (0, 0);
        }

        if (_mintServiceRewardIfNeeded(protocol, settlementInfo, share.tokenAddress, share.round, share.serviceActionId, share.groupId)) {
            amount = _shareAmount(self, protocol, settlementInfo, share, provider);
            if (amount == 0) {
                if (required) _revertZeroShare(share, provider);
                return (0, 0);
            }
        }
        return _payShare(self, share, provider, paid, settlementInfo, amount);
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
        address tokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) private returns (bool rewardChanged) {
        if (settlementInfo.actionMinted) return false;

        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 reward = IActionTarget(protocol.actionTargetAddress).mintActionReward(tokenAddress, round, serviceActionId);
        settlementInfo.actionMinted = true;
        if (reward == settlementInfo.serviceReward) return false;
        if (reward == 0) revert IActionExecutorErrors.MemberRewardPoolEmpty(tokenAddress, round);
        settlementInfo.serviceReward = reward;
        _applyFormulas(settlementInfo, protocol.stakeAddress, round, groupId);
        return true;
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _revertZeroShare(GroupServiceStorage.Share memory share, bool provider) private pure {
        if (provider) revert IGroupServiceExecutorErrors.ZeroProviderReward(share.sourceActionId, share.groupId, share.memberId);
        revert IGroupServiceExecutorErrors.ZeroRecipientReward(share.sourceActionId, share.groupId, share.memberId);
    }

    function _payShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share,
        bool provider,
        GroupServiceStorage.PaidShare storage paid,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 amount
    ) private returns (uint256, uint256 burnAmount) {
        if (provider) paid.provider = amount;
        else paid.recipient = amount;
        burnAmount = _pendingOwnerBurn(self, share, settlementInfo.ownerBurned);
        _burnOwnerReward(self, share, burnAmount);
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
        return (amount, burnAmount);
    }

    function _pendingOwnerBurn(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share,
        uint256 ownerOverflow
    ) private view returns (uint256) {
        if (ownerOverflow == 0) return 0;
        return self.ownerBurnByGroupId[share.tokenAddress][share.serviceActionId][share.round][share.groupId] == 0
            ? ownerOverflow
            : 0;
    }

    function _burnOwnerReward(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share,
        uint256 amount
    ) private {
        if (amount == 0) return;
        self.ownerBurnByGroupId[share.tokenAddress][share.serviceActionId][share.round][share.groupId] = amount;
        ILOVE20Token(share.tokenAddress).burn(amount);
        emit IGroupServiceExecutorEvents.ServiceOwnerRewardBurned({
            serviceTokenAddress: share.tokenAddress,
            serviceActionId: share.serviceActionId,
            round: share.round,
            groupId: share.groupId,
            amount: amount
        });
    }

    function _paidShare(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Share memory share
    ) private view returns (GroupServiceStorage.PaidShare storage) {
        return self.paidShares[share.tokenAddress][share.serviceActionId][share.round][share.groupId]
            [share.sourceActionId][share.memberId];
    }

    function _shareKey(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupRewardKey memory source
    ) private pure returns (GroupServiceStorage.Share memory) {
        return GroupServiceStorage.Share(key.tokenAddress, key.round, key.actionId, source.sourceActionId, source.groupId, key.memberId);
    }

    function _settlementKey(GroupServiceStorage.Share memory share)
        private
        pure
        returns (GroupServiceStorage.MemberRewardKey memory)
    {
        return GroupServiceStorage.MemberRewardKey(share.tokenAddress, share.round, share.serviceActionId, share.groupId);
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
        if (share.memberId == share.groupId) return 0;
        uint256 slice = _ownerSlice(
            protocol,
            settlementInfo.actionTokenAddress,
            share.round,
            share.sourceActionId,
            share.groupId,
            settlementInfo.ownerReward,
            settlementInfo.ownerWeight
        );
        (uint256 reserve, uint256 providerAmount) = marketAmounts(
            protocol.groupActionExecutorAddress,
            settlementInfo.providerIncentiveRatio,
            settlementInfo.actionTokenAddress,
            share.round,
            share.sourceActionId,
            share.groupId,
            provider ? share.memberId : 0,
            slice
        );
        if (provider) return providerAmount;
        return recipientAmount(
            self,
            settlementInfo.actionTokenAddress,
            share.round,
            share.sourceActionId,
            share.groupId,
            share.memberId,
            slice - reserve
        );
    }

    function _ownerSlice(
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) private view returns (uint256) {
        if (ownerReward == 0 || ownerWeight == 0) return 0;
        uint256 groupReward = GroupServiceStorage.groupReward(
            protocol.groupActionExecutorAddress, sourceTokenAddress, round, sourceActionId, groupId
        );
        if (groupReward == 0) return 0;
        return Math.mulDiv(ownerReward, groupReward, ownerWeight);
    }

    function _status(bool hasPending, bool hasSettled) private pure returns (MemberRewardStatus) {
        if (hasPending) return hasSettled ? MemberRewardStatus.Partial : MemberRewardStatus.Pending;
        return hasSettled ? MemberRewardStatus.Settled : MemberRewardStatus.Unavailable;
    }

    struct RecipientTable {
        uint256[] recipientIds;
        uint256[] ratios;
        string[] remarks;
    }

    struct ProviderReserveRequest {
        address groupActionExecutorAddress;
        address sourceTokenAddress;
        uint256 round;
        uint256 groupId;
        uint256 ownerReward;
        uint256 ownerWeight;
        uint256 providerIncentiveRatio;
        uint256 pageSize;
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

        uint256 keyId = uint256(keccak256(abi.encode(sourceActionId, groupId)));
        if (currentIds.length != 0 && self.recipientRewardKeyById[keyId].groupId == 0) {
            self.recipientRewardKeyById[keyId] = GroupRewardKey({sourceActionId: sourceActionId, groupId: groupId});
        }

        for (uint256 i = 0; i < previousIds.length; ++i) {
            uint256 recipientId = previousIds[i];
            if (!_containsRecipient(currentIds, recipientId)) {
                self.rewardKeysByRecipientId[sourceTokenAddress][recipientId].remove(round, keyId);
            }
        }
        for (uint256 i = 0; i < currentIds.length; ++i) {
            uint256 recipientId = currentIds[i];
            if (!_containsRecipient(previousIds, recipientId)) {
                self.rewardKeysByRecipientId[sourceTokenAddress][recipientId].add(round, keyId);
            }
        }
    }

    function _containsRecipient(uint256[] memory recipientIds, uint256 recipientId) private pure returns (bool) {
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            if (recipientIds[i] == recipientId) return true;
        }
        return false;
    }

    function recipientRewardKeys(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        return _recipientRewardKeys(self, sourceTokenAddress, round, recipientId, offset, limit, reverse);
    }

    function _recipientRewardKeys(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) private view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        uint256[] memory keyIds;
        (keyIds, totalCount) =
            self.rewardKeysByRecipientId[sourceTokenAddress][recipientId].valuesByRound(round, offset, limit, reverse);
        keys = new GroupRewardKey[](keyIds.length);
        for (uint256 i = 0; i < keyIds.length; ++i) {
            keys[i] = self.recipientRewardKeyById[keyIds[i]];
        }
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

    function distribution(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 groupReward
    ) external view returns (Distribution memory distributionInfo) {
        return _distribution(self, sourceTokenAddress, round, sourceActionId, groupId, groupReward);
    }

    function _distribution(
        GroupServiceStorage.Layout storage self,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 groupReward
    ) private view returns (Distribution memory distributionInfo) {
        distributionInfo.recipientIds =
            self.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        distributionInfo.ratios = self.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        (distributionInfo.amounts, distributionInfo.totalRecipientAmount) =
            _calculateRecipientAmounts(groupReward, distributionInfo.recipientIds, distributionInfo.ratios);
        distributionInfo.ownerAmount = groupReward - distributionInfo.totalRecipientAmount;
    }

    function marketAmounts(
        address groupActionExecutorAddress,
        uint256 providerIncentiveRatio,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId,
        uint256 slice
    ) internal view returns (uint256 reserve, uint256 amount) {
        if (slice == 0) return (0, 0);
        IGroupActionExecutor source = IGroupActionExecutor(groupActionExecutorAddress);
        if (providerIncentiveRatio == 0) return (0, 0);
        (uint256 groupScore, uint256 externalScore, uint256 providerScore) =
            source.providerWeights(sourceTokenAddress, round, sourceActionId, groupId, providerId);
        if (groupScore == 0 || externalScore == 0) return (0, 0);
        uint256 market = Math.mulDiv(slice, providerIncentiveRatio, GroupServiceStorage.PRECISION);
        return (Math.mulDiv(market, externalScore, groupScore), Math.mulDiv(market, providerScore, groupScore));
    }

    function prepareProviderReserve(
        GroupServiceStorage.Layout storage self,
        address groupActionExecutorAddress,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 limit
    ) external returns (uint256 processedActionCount, uint256 totalActionCount, uint256 providerReserve) {
        if (
            settlementInfo.providerIncentiveRatio == 0 || settlementInfo.ownerReward == 0
                || settlementInfo.ownerWeight == 0
        ) {
            return (0, 0, 0);
        }

        GroupServiceStorage.ProviderReservePreparation storage preparation =
            self.providerReservePreparation[key.tokenAddress][key.actionId][key.round][key.memberId][settlementInfo.ownerReward];
        if (
            preparation.ownerWeight == settlementInfo.ownerWeight
                && preparation.processedActionCount == preparation.totalActionCount
        )
        {
            return (preparation.processedActionCount, preparation.totalActionCount, preparation.providerReserve);
        }

        ProviderReserveRequest memory request = ProviderReserveRequest({
            groupActionExecutorAddress: groupActionExecutorAddress,
            sourceTokenAddress: settlementInfo.actionTokenAddress,
            round: key.round,
            groupId: key.memberId,
            ownerReward: settlementInfo.ownerReward,
            ownerWeight: settlementInfo.ownerWeight,
            providerIncentiveRatio: settlementInfo.providerIncentiveRatio,
            pageSize: Math.min(limit, GroupServiceStorage.MAX_PROVIDER_RESERVE_PREPARATION_PAGE_SIZE)
        });
        return _prepareProviderReservePage(preparation, request);
    }

    function _prepareProviderReservePage(
        GroupServiceStorage.ProviderReservePreparation storage preparation,
        ProviderReserveRequest memory request
    ) private returns (uint256 processedActionCount, uint256 totalActionCount, uint256 providerReserve) {
        IGroupActionExecutor groupAction = IGroupActionExecutor(request.groupActionExecutorAddress);
        uint256 start = preparation.processedActionCount;
        uint256[] memory actionIds;
        (actionIds, totalActionCount) = groupAction.actionIdsWithProviderWeight(
            request.sourceTokenAddress, request.round, request.groupId, start, request.pageSize, false
        );

        if (preparation.ownerWeight != request.ownerWeight || preparation.totalActionCount != totalActionCount) {
            start = 0;
            preparation.ownerWeight = request.ownerWeight;
            preparation.processedActionCount = 0;
            preparation.totalActionCount = totalActionCount;
            preparation.providerReserve = 0;
            (actionIds, totalActionCount) = groupAction.actionIdsWithProviderWeight(
                request.sourceTokenAddress, request.round, request.groupId, 0, request.pageSize, false
            );
            preparation.totalActionCount = totalActionCount;
        }

        for (uint256 i = 0; i < actionIds.length; ++i) {
            preparation.providerReserve += _providerReserveForAction(groupAction, request, actionIds[i]);
        }

        processedActionCount = start + actionIds.length;
        preparation.processedActionCount = processedActionCount;
        providerReserve = preparation.providerReserve;
    }

    function _providerReserveForAction(
        IGroupActionExecutor groupAction,
        ProviderReserveRequest memory request,
        uint256 sourceActionId
    ) private view returns (uint256 reserve) {
        uint256 groupReward = groupAction.generatedActionRewardByGroupId(
            request.sourceTokenAddress, request.round, sourceActionId, request.groupId
        );
        uint256 slice = Math.mulDiv(request.ownerReward, groupReward, request.ownerWeight);
        (reserve,) = marketAmounts(
            request.groupActionExecutorAddress,
            request.providerIncentiveRatio,
            request.sourceTokenAddress,
            request.round,
            sourceActionId,
            request.groupId,
            0,
            slice
        );
    }

    function providerReservePreparation(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo
    )
        external
        view
        returns (uint256 processedActionCount, uint256 totalActionCount, uint256 reserve)
    {
        if (settlementInfo.providerIncentiveRatio == 0 || settlementInfo.ownerWeight == 0) return (0, 0, 0);

        IGroupActionExecutor groupAction = IGroupActionExecutor(protocol.groupActionExecutorAddress);
        (, totalActionCount) =
            groupAction.actionIdsWithProviderWeight(
                settlementInfo.actionTokenAddress, key.round, key.memberId, 0, 0, false
            );
        if (totalActionCount <= GroupServiceStorage.MAX_PROVIDER_RESERVE_PREPARATION_PAGE_SIZE) {
            reserve = _projectedProviderReserve(self, protocol, key, settlementInfo);
            return (totalActionCount, totalActionCount, reserve);
        }
        if (!settlementInfo.actionMinted) return (0, totalActionCount, 0);
        if (settlementInfo.ownerReward == 0) return (totalActionCount, totalActionCount, 0);

        GroupServiceStorage.ProviderReservePreparation storage preparation =
            self.providerReservePreparation[key.tokenAddress][key.actionId][key.round][key.memberId][settlementInfo.ownerReward];
        if (preparation.ownerWeight != settlementInfo.ownerWeight || preparation.totalActionCount != totalActionCount) {
            return (0, totalActionCount, 0);
        }
        return (preparation.processedActionCount, totalActionCount, preparation.providerReserve);
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

    function projectedDistribution(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo
    ) external view returns (uint256 distributed) {
        if (settlementInfo.ownerReward == 0 || settlementInfo.ownerWeight == 0) {
            return 0;
        }

        (uint256[] memory sourceActionIds,) =
            self.actionIdsWithRecipients[settlementInfo.actionTokenAddress][key.memberId]
                .valuesByRound(key.round, 0, type(uint256).max, false);
        for (uint256 i = 0; i < sourceActionIds.length; i++) {
            distributed += _projectedForAction(self, protocol, key, settlementInfo, sourceActionIds[i]);
        }
        distributed += _projectedProviderReserve(self, protocol, key, settlementInfo);
    }

    function _projectedProviderReserve(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo
    ) private view returns (uint256 total) {
        if (settlementInfo.providerIncentiveRatio == 0) return 0;
        GroupServiceStorage.ProviderReservePreparation storage preparation =
            self.providerReservePreparation[key.tokenAddress][key.actionId][key.round][key.memberId][settlementInfo.ownerReward];
        if (
            preparation.ownerWeight == settlementInfo.ownerWeight
                && preparation.processedActionCount == preparation.totalActionCount
        )
        {
            return preparation.providerReserve;
        }

        (uint256[] memory actionIds,) = IGroupActionExecutor(protocol.groupActionExecutorAddress)
            .actionIdsWithProviderWeight(
                settlementInfo.actionTokenAddress, key.round, key.memberId, 0, type(uint256).max, false
            );
        for (uint256 i = 0; i < actionIds.length; i++) {
            uint256 slice =
                ownerSlice(
                    protocol,
                    settlementInfo.actionTokenAddress,
                    key.round,
                    actionIds[i],
                    key.memberId,
                    settlementInfo.ownerReward,
                    settlementInfo.ownerWeight
                );
            (uint256 reserve,) = marketAmounts(
                protocol.groupActionExecutorAddress,
                settlementInfo.providerIncentiveRatio,
                settlementInfo.actionTokenAddress,
                key.round,
                actionIds[i],
                key.memberId,
                0,
                slice
            );
            total += reserve;
        }
    }

    function _projectedForAction(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlementInfo,
        uint256 sourceActionId
    ) internal view returns (uint256 distributed) {
        uint256 slice = ownerSlice(
            protocol,
            settlementInfo.actionTokenAddress,
            key.round,
            sourceActionId,
            key.memberId,
            settlementInfo.ownerReward,
            settlementInfo.ownerWeight
        );
        if (slice == 0) {
            return 0;
        }
        (uint256 reserve,) = marketAmounts(
            protocol.groupActionExecutorAddress,
            settlementInfo.providerIncentiveRatio,
            settlementInfo.actionTokenAddress,
            key.round,
            sourceActionId,
            key.memberId,
            0,
            slice
        );
        (, distributed) = _calculateRecipientAmounts(
            slice - reserve,
            self.recipientIdsHistory[settlementInfo.actionTokenAddress][sourceActionId][key.memberId].values(key.round),
            self.ratiosHistory[settlementInfo.actionTokenAddress][sourceActionId][key.memberId].values(key.round)
        );
    }

    function ownerSlice(
        GroupServiceStorage.Protocol memory protocol,
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) internal view returns (uint256) {
        uint256 groupReward = GroupServiceStorage.groupReward(
            protocol.groupActionExecutorAddress, sourceTokenAddress, round, sourceActionId, groupId
        );
        if (groupReward == 0) {
            return 0;
        }
        return Math.mulDiv(ownerReward, groupReward, ownerWeight);
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

    function _calculateRecipientAmounts(uint256 groupReward, uint256[] memory recipientIds, uint256[] memory ratios)
        internal
        pure
        returns (uint256[] memory amounts, uint256 distributed)
    {
        uint256 length = recipientIds.length;
        amounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            amounts[i] = Math.mulDiv(groupReward, ratios[i], GroupServiceStorage.PRECISION);
            distributed += amounts[i];
        }
    }
}
