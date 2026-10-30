// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionManager} from "./GroupActionManager.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {IGroupActionJoinEvents, IGroupActionJoinErrors} from "./interfaces/IGroupActionJoin.sol";
import {IGroupActionManagerErrors} from "./interfaces/IGroupActionManager.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {AddressSet} from "@libs/AddressSet.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {RoundHistoryString} from "@libs/RoundHistoryString.sol";

library GroupActionJoin {
    using AddressSet for AddressSet.Storage;
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using SafeERC20 for IERC20;
    using Uint256Set for Uint256Set.Storage;

    modifier onlyMemberOwner(
        GroupActionStorage.Layout storage self,
        uint256 memberId
    ) {
        if (IMemberNFT(self.MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationValues
    ) external onlyMemberOwner(self, memberId) {
        _join(self, tokenAddress, actionId, groupId, memberId, amount, providerId, verificationValues);
    }

    function _join(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationValues
    ) private {
        if (amount == 0) {
            revert IGroupActionJoinErrors.ZeroParticipationAmount();
        }
        if (groupId == 0) {
            revert IGroupActionManagerErrors.GroupNotExist(0);
        }
        GroupActionManager.groupOwnerOrRevert(self, groupId);

        uint256 joinedGroupId = self.groupHistoryByMemberId[tokenAddress][actionId][memberId].latestValue();
        if (joinedGroupId != 0 && joinedGroupId != groupId) {
            revert IGroupActionJoinErrors.AlreadyInOtherGroup(memberId, joinedGroupId, groupId);
        }

        _validateGroupConstraints(self, tokenAddress, actionId, groupId, memberId, amount, joinedGroupId == 0);

        uint256 round = self.currentJoinRound();

        if (joinedGroupId == 0) {
            _registerMembership(self, tokenAddress, actionId, groupId, memberId, round);
        }
        if (!IActionTarget(self.ACTION_TARGET_ADDRESS).isJoined(tokenAddress, actionId, memberId)) {
            IActionTarget(self.ACTION_TARGET_ADDRESS).registerJoinState(tokenAddress, actionId, memberId);
        }
        _applyVerificationInfos(self, tokenAddress, actionId, memberId, verificationValues, round, joinedGroupId == 0);
        _increaseAmount(self, tokenAddress, actionId, round, groupId, memberId, amount, providerId);

        if (providerId == 0) {
            _pullJoinToken(self, tokenAddress, actionId, amount);
        }

        emit IGroupActionJoinEvents.GroupActionJoined({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            groupId: groupId,
            providerId: providerId,
            amount: amount,
            verificationValues: verificationValues
        });
    }

    function _pullJoinToken(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 amount
    ) internal {
        IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), amount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdraw(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external onlyMemberOwner(self, memberId) {
        if (amount == 0) {
            revert IGroupActionJoinErrors.ZeroParticipationAmount();
        }

        uint256 round = self.currentJoinRound();
        uint256 ownAmount = self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue();
        if (amount > ownAmount) {
            revert IGroupActionJoinErrors.WithdrawAmountExceeded(amount, ownAmount);
        }
        uint256 groupId = self.groupHistoryByMemberId[tokenAddress][actionId][memberId].latestValue();

        _decreaseOwnAmount(self, tokenAddress, actionId, round, groupId, memberId, ownAmount, amount);

        IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        emit IGroupActionJoinEvents.GroupActionWithdrawn({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            groupId: groupId,
            providerId: 0,
            amount: amount
        });

        if (ownAmount - amount == 0 && self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() == 0) {
            _finalizeExit(self, tokenAddress, actionId, round, groupId, memberId);
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdrawProviderQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) external onlyMemberOwner(self, providerId) {
        if (amount == 0) {
            revert IGroupActionJoinErrors.ZeroQuotaAmount(memberId);
        }
        if (groupId == 0) {
            revert IGroupActionManagerErrors.GroupNotExist(0);
        }
        GroupActionManager.groupOwnerOrRevert(self, groupId);

        uint256 quota = self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId];
        uint256 available = quota - _quotaUsedAt(self, tokenAddress, actionId, groupId, providerId, memberId);
        if (amount > available) {
            revert IGroupActionJoinErrors.InsufficientProviderQuota(providerId, amount, available);
        }
        uint256 quotaAfter = quota - amount;
        self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId] = quotaAfter;
        if (quotaAfter == 0) {
            self.quotaMemberIdsByGroupIdByProviderId[tokenAddress][actionId][groupId][providerId].remove(memberId);
        }

        IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        emit IGroupActionJoinEvents.ProviderQuotaRemoved({
            tokenAddress: tokenAddress,
            actionId: actionId,
            groupId: groupId,
            providerId: providerId,
            memberId: memberId,
            amount: amount,
            quotaTotal: quotaAfter
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyMemberOwner(self, memberId) {
        uint256 round = self.currentJoinRound();
        uint256 groupId = self.groupHistoryByMemberId[tokenAddress][actionId][memberId].latestValue();
        uint256 ownAmount = self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue();
        if (ownAmount == 0 && self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() == 0) {
            revert IGroupActionJoinErrors.NotJoined(tokenAddress, actionId, memberId);
        }

        if (ownAmount != 0) {
            _decreaseOwnAmount(self, tokenAddress, actionId, round, groupId, memberId, ownAmount, ownAmount);
            IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, ownAmount);
            emit IGroupActionJoinEvents.GroupActionWithdrawn({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                groupId: groupId,
                providerId: 0,
                amount: ownAmount
            });
        }

        _restoreProviders(self, tokenAddress, actionId, round, groupId, memberId);

        _finalizeExit(self, tokenAddress, actionId, round, groupId, memberId);
    }

    function _restoreProviders(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId
    ) private {
        uint256 providerCount = self.providerIdsByMemberId[tokenAddress][actionId][memberId].count();
        if (providerCount == 0) {
            return;
        }

        (uint256[] memory providerIds, ) =
            self.providerIdsByMemberId[tokenAddress][actionId][memberId].values(0, providerCount, false);
        for (uint256 i = 0; i < providerIds.length; i++) {
            uint256 invested =
                self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerIds[i]].latestValue();
            if (invested == 0) {
                continue;
            }
            _decreaseProviderAmount(self, tokenAddress, actionId, round, groupId, memberId, providerIds[i], invested);

            emit IGroupActionJoinEvents.ProviderQuotaRestored({
                tokenAddress: tokenAddress,
                actionId: actionId,
                groupId: groupId,
                providerId: providerIds[i],
                memberId: memberId,
                amount: invested
            });
        }
    }

    function joinInfo(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 joinedRound,
            uint256 joinedAmount,
            uint256 groupId,
            uint256 ownAmount,
            uint256 providerAmount
        )
    {
        ownAmount = self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
        providerAmount = self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
        joinedAmount = ownAmount + providerAmount;
        if (joinedAmount == 0) {
            return (0, 0, 0, 0, 0);
        }
        joinedRound = self.joinedRoundHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
        groupId = self.groupHistoryByMemberId[tokenAddress][actionId][memberId].value(round);
    }

    function joinedAmountByGroupId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return self.joinedAmountByGroupId[tokenAddress][actionId][groupId].value(round);
    }

    function groupIdsByRound(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 total) {
        return self.groupIdsByRound[tokenAddress][actionId].valuesByRound(round, offset, limit, reverse);
    }

    function memberIdsByGroupId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return self.memberIdsByGroupId[tokenAddress][actionId][groupId].valuesByRound(round, offset, limit, reverse);
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function addProviderQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) external onlyMemberOwner(self, providerId) {
        _addProviderQuota(self, tokenAddress, actionId, groupId, providerId, memberIds, amounts);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _addProviderQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) private {
        if (memberIds.length != amounts.length) {
            revert IGroupActionJoinErrors.QuotaArrayLengthMismatch(memberIds.length, amounts.length);
        }
        if (groupId == 0) {
            revert IGroupActionManagerErrors.GroupNotExist(0);
        }
        GroupActionManager.groupOwnerOrRevert(self, groupId);
        if (!self.groupState[tokenAddress][actionId][groupId].active) {
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }
        if (memberIds.length == 0) {
            return;
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < memberIds.length; i++) {
            uint256 memberId = memberIds[i];
            if (memberId == providerId) {
                revert IGroupActionJoinErrors.QuotaMemberIsProvider(providerId);
            }
            if (amounts[i] == 0) {
                revert IGroupActionJoinErrors.ZeroQuotaAmount(memberId);
            }
            IMemberNFT(self.MEMBER_NFT_ADDRESS).ownerOf(memberId);

            uint256 quotaTotal = self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId] + amounts[i];
            self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId] = quotaTotal;
            self.quotaMemberIdsByGroupIdByProviderId[tokenAddress][actionId][groupId][providerId].add(memberId);
            totalAmount += amounts[i];

            emit IGroupActionJoinEvents.ProviderQuotaAdded({
                tokenAddress: tokenAddress,
                actionId: actionId,
                groupId: groupId,
                providerId: providerId,
                memberId: memberId,
                amount: amounts[i],
                quotaTotal: quotaTotal
            });
        }

        IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), totalAmount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function removeProviderQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds
    ) external onlyMemberOwner(self, providerId) {
        if (groupId == 0) {
            revert IGroupActionManagerErrors.GroupNotExist(0);
        }
        GroupActionManager.groupOwnerOrRevert(self, groupId);
        if (memberIds.length == 0) {
            return;
        }

        uint256 round = self.currentJoinRound();
        uint256 totalRefund = 0;
        for (uint256 i = 0; i < memberIds.length; i++) {
            totalRefund += _revokeQuota(self, tokenAddress, actionId, round, groupId, providerId, memberIds[i]);
        }

        IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, totalRefund);
    }

    function _revokeQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 memberId
    ) private returns (uint256 refundable) {
        uint256 used;
        (refundable, used) = _removeQuota(self, tokenAddress, actionId, round, groupId, providerId, memberId);

        if (used != 0) {
            emit IGroupActionJoinEvents.GroupActionWithdrawn({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                groupId: groupId,
                providerId: providerId,
                amount: used
            });
        }

        emit IGroupActionJoinEvents.ProviderQuotaRemoved({
            tokenAddress: tokenAddress,
            actionId: actionId,
            groupId: groupId,
            providerId: providerId,
            memberId: memberId,
            amount: refundable,
            quotaTotal: 0
        });

        if (
            used != 0 && self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() == 0
                && self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() == 0
        ) {
            _finalizeExit(self, tokenAddress, actionId, round, groupId, memberId);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _removeQuota(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 memberId
    ) private returns (uint256 refundable, uint256 used) {
        refundable = self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId];
        if (refundable == 0) {
            revert IGroupActionJoinErrors.QuotaNotGranted(groupId, providerId, memberId);
        }
        used = _quotaUsedAt(self, tokenAddress, actionId, groupId, providerId, memberId);
        if (used != 0) {
            _decreaseProviderAmount(self, tokenAddress, actionId, round, groupId, memberId, providerId, used);
        }
        self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId] = 0;
        self.quotaMemberIdsByGroupIdByProviderId[tokenAddress][actionId][groupId][providerId].remove(memberId);
    }

    function providerQuotas(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256[] memory quotaAmounts,
            uint256[] memory usedAmounts,
            uint256 total
        )
    {
        Uint256Set.Storage storage quotaSet = self.quotaMemberIdsByGroupIdByProviderId[tokenAddress][actionId][groupId][providerId];
        (memberIds, total) = quotaSet.values(offset, limit, reverse);
        quotaAmounts = new uint256[](memberIds.length);
        usedAmounts = new uint256[](memberIds.length);
        for (uint256 i = 0; i < memberIds.length; i++) {
            quotaAmounts[i] = self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberIds[i]];
            usedAmounts[i] = _quotaUsedAt(self, tokenAddress, actionId, groupId, providerId, memberIds[i]);
        }
    }

    // Invested amounts are tracked without a group, while grants are per group: a member who
    // left a group (their investment restored) and now uses the same provider elsewhere must
    // not report that usage against the old group's grant.
    function _quotaUsedAt(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 memberId
    ) private view returns (uint256) {
        if (self.groupHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() != groupId) {
            return 0;
        }
        return self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].latestValue();
    }

    function providerAmountsByMemberId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory providerIds,
            uint256[] memory amounts,
            uint256 total
        )
    {
        (providerIds, total) =
            _pageProviderIds(self, tokenAddress, actionId, round, memberId, offset, limit, reverse);
        amounts = new uint256[](providerIds.length);
        for (uint256 i = 0; i < providerIds.length; i++) {
            amounts[i] = _providerAmountAt(self, tokenAddress, actionId, round, memberId, providerIds[i]);
        }
    }

    function _pageProviderIds(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) internal view returns (uint256[] memory providerIds, uint256 total) {
        RoundHistoryUint256Set.Storage storage providerSet = self.providerIdsByMemberId[tokenAddress][actionId][memberId];
        return providerSet.valuesByRound(round, offset, limit, reverse);
    }

    function _providerAmountAt(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 providerId
    ) internal view returns (uint256) {
        return self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].value(round);
    }

    function joinedGroupIds(
        GroupActionStorage.Layout storage self,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 total) {
        return self.joinedGroupIds.values(offset, limit, reverse);
    }

    function joinedGroupIdsByMemberId(
        GroupActionStorage.Layout storage self,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 total) {
        return self.joinedGroupIdsByMemberId[memberId].values(offset, limit, reverse);
    }

    function joinedTokenAddressesByGroupIdByMemberId(
        GroupActionStorage.Layout storage self,
        uint256 groupId,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 total) {
        return self.joinedTokenAddressesByGroupIdByMemberId[groupId][memberId].values(offset, limit, reverse);
    }

    function joinedMemberIds(
        GroupActionStorage.Layout storage self,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return self.joinedMemberIds.values(offset, limit, reverse);
    }

    function joinedMemberIdsByGroupId(
        GroupActionStorage.Layout storage self,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return self.joinedMemberIdsByGroupId[groupId].values(offset, limit, reverse);
    }

    function _decreaseProviderAmount(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) internal {
        uint256 invested = self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].latestValue();
        uint256 remaining = invested - amount;
        self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].record(round, remaining);
        if (remaining == 0) {
            self.providerIdsByMemberId[tokenAddress][actionId][memberId].remove(round, providerId);
        }
        self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].decrease(round, amount);
        self.joinedAmountByGroupId[tokenAddress][actionId][groupId].decrease(round, amount);
        self.joinedAmountByActionId[tokenAddress][actionId].decrease(round, amount);
    }

    function _validateGroupConstraints(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        bool isFirstJoin
    ) internal view {
        GroupActionStorage.GroupState storage group = self.groupState[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }

        uint256 newTotal = self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue()
            + self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].latestValue() + amount;

        if (group.config.maxJoinAmount != 0 && newTotal > group.config.maxJoinAmount) {
            revert IGroupActionJoinErrors.GroupMaxJoinAmountExceeded(memberId, newTotal, group.config.maxJoinAmount);
        }

        if (isFirstJoin) {
            uint256 memberCount = self.memberIdsByGroupId[tokenAddress][actionId][groupId].count();
            if (group.config.maxAccounts != 0 && memberCount >= group.config.maxAccounts) {
                revert IGroupActionJoinErrors.GroupAccountsFull(groupId, memberCount, group.config.maxAccounts);
            }
            if (amount < group.config.minJoinAmount) {
                revert IGroupActionJoinErrors.BelowMinJoinAmount(amount, group.config.minJoinAmount);
            }
        }

        if (group.config.maxCapacity != 0) {
            uint256 groupTotal = self.joinedAmountByGroupId[tokenAddress][actionId][groupId].latestValue();
            uint256 newGroupTotal = groupTotal + amount;
            if (newGroupTotal > group.config.maxCapacity) {
                revert IGroupActionJoinErrors.GroupCapacityExceeded(groupId, newGroupTotal, group.config.maxCapacity);
            }
        }

        uint256 actionMaxJoinAmount = GroupActionManager._maxJoinAmount(self, tokenAddress, actionId);
        if (newTotal > actionMaxJoinAmount) {
            revert IGroupActionJoinErrors.ActionMaxJoinAmountExceeded(memberId, newTotal, actionMaxJoinAmount);
        }
    }

    function _registerMembership(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 round
    ) internal {
        self.joinedRoundHistoryByMemberId[tokenAddress][actionId][memberId].record(round, round);
        self.groupHistoryByMemberId[tokenAddress][actionId][memberId].record(round, groupId);
        self.memberIdsByGroupId[tokenAddress][actionId][groupId].add(round, memberId);
        self.groupIdsByRound[tokenAddress][actionId].add(round, groupId);

        uint256 membershipCount = ++self.membershipCountByGroupIdByMemberId[groupId][memberId];
        if (membershipCount == 1) {
            self.joinedMemberIdsByGroupId[groupId].add(memberId);
            self.joinedGroupIdsByMemberId[memberId].add(groupId);
            self.joinedMemberIds.add(memberId);
            self.joinedGroupIds.add(groupId);
        }
        uint256 tokenCount = ++self.membershipCountByTokenAddress[groupId][memberId][tokenAddress];
        if (tokenCount == 1) {
            self.joinedTokenAddressesByGroupIdByMemberId[groupId][memberId].add(tokenAddress);
        }
    }

    function _applyVerificationInfos(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string[] calldata verificationValues,
        uint256 round,
        bool isFirstJoin
    ) internal {
        string[] storage keys = self.verificationKeysByActionId[tokenAddress][actionId];
        if (!isFirstJoin && verificationValues.length == 0) {
            return;
        }
        if (verificationValues.length > GroupActionStorage.MAX_VERIFICATION_ENTRIES) {
            revert IGroupActionJoinErrors.TooManyVerificationValues(
                verificationValues.length, GroupActionStorage.MAX_VERIFICATION_ENTRIES
            );
        }
        if (verificationValues.length != keys.length) {
            revert IGroupActionExecutorErrors.VerificationInfoLengthMismatch(keys.length, verificationValues.length);
        }
        for (uint256 i = 0; i < verificationValues.length; i++) {
            uint256 valueLength = bytes(verificationValues[i]).length;
            if (valueLength > GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES) {
                // forge-lint: disable-next-item(require-revert-in-loop)
                revert IGroupActionJoinErrors.VerificationValueTooLong(
                    i, valueLength, GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES
                );
            }
            self.verificationValueHistory[tokenAddress][actionId][memberId][i].record(round, verificationValues[i]);
        }
    }

    function _increaseAmount(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId
    ) internal {
        if (providerId == 0) {
            self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].increase(round, amount);
        } else {
            uint256 invested = self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].latestValue();
            uint256 available = self.quotaAmountByGroupIdByProviderIdByMemberId[tokenAddress][actionId][groupId][providerId][memberId] - invested;
            if (amount > available) {
                revert IGroupActionJoinErrors.InsufficientProviderQuota(providerId, amount, available);
            }

            if (invested == 0) {
                self.providerIdsByMemberId[tokenAddress][actionId][memberId].add(round, providerId);
            }
            self.providerAmountByMemberIdByProviderId[tokenAddress][actionId][memberId][providerId].increase(round, amount);
            self.providerAmountHistoryByMemberId[tokenAddress][actionId][memberId].increase(round, amount);
        }

        self.joinedAmountByGroupId[tokenAddress][actionId][groupId].increase(round, amount);
        self.joinedAmountByActionId[tokenAddress][actionId].increase(round, amount);
    }

    function _decreaseOwnAmount(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 ownAmount,
        uint256 amount
    ) internal {
        self.ownAmountHistoryByMemberId[tokenAddress][actionId][memberId].record(round, ownAmount - amount);
        self.joinedAmountByGroupId[tokenAddress][actionId][groupId].decrease(round, amount);
        self.joinedAmountByActionId[tokenAddress][actionId].decrease(round, amount);
    }

    function _finalizeExit(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId
    ) internal {
        self.joinedRoundHistoryByMemberId[tokenAddress][actionId][memberId].record(round, 0);
        self.groupHistoryByMemberId[tokenAddress][actionId][memberId].record(round, 0);
        self.memberIdsByGroupId[tokenAddress][actionId][groupId].remove(round, memberId);
        if (self.memberIdsByGroupId[tokenAddress][actionId][groupId].count() == 0) {
            self.groupIdsByRound[tokenAddress][actionId].remove(round, groupId);
        }

        uint256 membershipCount = --self.membershipCountByGroupIdByMemberId[groupId][memberId];
        if (membershipCount == 0) {
            self.joinedMemberIdsByGroupId[groupId].remove(memberId);
            self.joinedGroupIdsByMemberId[memberId].remove(groupId);
            if (self.joinedMemberIdsByGroupId[groupId].count() == 0) {
                self.joinedGroupIds.remove(groupId);
            }
            if (self.joinedGroupIdsByMemberId[memberId].count() == 0) {
                self.joinedMemberIds.remove(memberId);
            }
        }
        uint256 tokenCount = --self.membershipCountByTokenAddress[groupId][memberId][tokenAddress];
        if (tokenCount == 0) {
            self.joinedTokenAddressesByGroupIdByMemberId[groupId][memberId].remove(tokenAddress);
        }

        IActionTarget(self.ACTION_TARGET_ADDRESS).clearJoinState(tokenAddress, actionId, memberId);

        emit IGroupActionJoinEvents.GroupActionExited({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            groupId: groupId
        });
    }
}
