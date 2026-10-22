// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionManager} from "./GroupActionManager.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {IGroupActionJoinEvents, IGroupActionJoinErrors} from "./interfaces/IGroupActionJoin.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";
import {AddressSet} from "libs/AddressSet.sol";
import {RoundHistoryUint256} from "libs/RoundHistoryUint256.sol";
import {RoundHistoryUint256Set} from "libs/RoundHistoryUint256Set.sol";
import {Uint256Set} from "libs/Uint256Set.sol";
import {RoundHistoryString} from "libs/RoundHistoryString.sol";

library GroupActionJoin {
    using AddressSet for AddressSet.Storage;
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using RoundHistoryString for RoundHistoryString.History;
    using SafeERC20 for IERC20;
    using Uint256Set for Uint256Set.Storage;

    modifier onlyMemberOwner(
        GroupActionStorage.Layout storage s,
        uint256 memberId
    ) {
        if (IMemberNFT(s.memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationInfos
    ) external onlyMemberOwner(s, memberId) {
        _join(s, tokenAddress, actionId, groupId, memberId, amount, providerId, verificationInfos);
    }

    function _join(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationInfos
    ) private {
        if (amount == 0) {
            revert IGroupActionJoinErrors.InvalidParticipationAmount();
        }
        if (groupId == 0) {
            revert IGroupActionJoinErrors.InvalidGroupId();
        }

        uint256 joinedGroupId = s.groupHistory[tokenAddress][actionId][memberId].latestValue();
        if (joinedGroupId != 0 && joinedGroupId != groupId) {
            revert IGroupActionJoinErrors.AlreadyInOtherGroup();
        }

        _validateGroupConstraints(s, tokenAddress, actionId, groupId, memberId, amount, joinedGroupId == 0);

        uint256 round = s.currentJoinRound();

        if (joinedGroupId == 0) {
            _registerMembership(s, tokenAddress, actionId, groupId, memberId, round);
        }
        if (!IActionTarget(s.actionTarget).isJoined(tokenAddress, actionId, memberId)) {
            IActionTarget(s.actionTarget).registerJoinState(tokenAddress, actionId, memberId);
        }
        _applyVerificationInfos(s, tokenAddress, actionId, memberId, verificationInfos, round, joinedGroupId == 0);
        _increaseAmount(s, tokenAddress, actionId, round, groupId, memberId, amount, providerId);

        if (providerId == 0) {
            _pullJoinToken(s, tokenAddress, actionId, amount);
        }

        emit IGroupActionJoinEvents.Joined({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            amount: amount,
            providerId: providerId,
            groupId: groupId
        });
    }

    function _pullJoinToken(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 amount
    ) internal {
        IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), amount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdraw(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external onlyMemberOwner(s, memberId) {
        if (amount == 0) {
            revert IGroupActionJoinErrors.InvalidParticipationAmount();
        }

        uint256 round = s.currentJoinRound();
        uint256 ownAmount = s.ownAmountHistory[tokenAddress][actionId][memberId].latestValue();
        if (amount > ownAmount) {
            revert IGroupActionJoinErrors.InvalidParticipationAmount();
        }
        uint256 groupId = s.groupHistory[tokenAddress][actionId][memberId].latestValue();

        _decreaseOwnAmount(s, tokenAddress, actionId, round, groupId, memberId, ownAmount, amount);

        IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        emit IGroupActionJoinEvents.Withdrawn({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            amount: amount,
            providerId: 0,
            groupId: groupId
        });

        if (ownAmount - amount == 0 && s.providerAmountHistory[tokenAddress][actionId][memberId].latestValue() == 0) {
            _finalizeExit(s, tokenAddress, actionId, round, groupId, memberId);
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function providerWithdraw(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) external onlyMemberOwner(s, providerId) {
        if (amount == 0) {
            revert IGroupActionJoinErrors.InvalidParticipationAmount();
        }

        uint256 round = s.currentJoinRound();
        uint256 invested = s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].latestValue();
        if (amount > invested) {
            revert IGroupActionJoinErrors.InvalidParticipationAmount();
        }
        uint256 groupId = s.groupHistory[tokenAddress][actionId][memberId].latestValue();

        _decreaseProviderAmount(s, tokenAddress, actionId, round, groupId, memberId, providerId, amount);

        IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        emit IGroupActionJoinEvents.Withdrawn({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            amount: amount,
            providerId: providerId,
            groupId: groupId
        });

        if (
            s.ownAmountHistory[tokenAddress][actionId][memberId].latestValue() == 0
                && s.providerAmountHistory[tokenAddress][actionId][memberId].latestValue() == 0
        ) {
            _finalizeExit(s, tokenAddress, actionId, round, groupId, memberId);
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external onlyMemberOwner(s, memberId) {
        uint256 round = s.currentJoinRound();
        uint256 groupId = s.groupHistory[tokenAddress][actionId][memberId].latestValue();
        uint256 ownAmount = s.ownAmountHistory[tokenAddress][actionId][memberId].latestValue();
        if (ownAmount == 0 && s.providerAmountHistory[tokenAddress][actionId][memberId].latestValue() == 0) {
            revert IGroupActionJoinErrors.NotJoinedAction();
        }

        if (ownAmount != 0) {
            _decreaseOwnAmount(s, tokenAddress, actionId, round, groupId, memberId, ownAmount, ownAmount);
            IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, ownAmount);
            emit IGroupActionJoinEvents.Withdrawn({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                amount: ownAmount,
                providerId: 0,
                groupId: groupId
            });
        }

        _refundProviders(s, tokenAddress, actionId, round, groupId, memberId);

        _finalizeExit(s, tokenAddress, actionId, round, groupId, memberId);
    }

    function _refundProviders(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId
    ) private {
        uint256 providerCount = s.providerIdsByMemberId[tokenAddress][actionId][memberId].count();
        if (providerCount == 0) {
            return;
        }

        (uint256[] memory providerIds, ) =
            s.providerIdsByMemberId[tokenAddress][actionId][memberId].values(0, providerCount, false);
        for (uint256 i = 0; i < providerIds.length; i++) {
            uint256 invested =
                s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerIds[i]].latestValue();
            if (invested == 0) {
                continue;
            }
            _decreaseProviderAmount(s, tokenAddress, actionId, round, groupId, memberId, providerIds[i], invested);
            s.quotaAmount[tokenAddress][actionId][groupId][providerIds[i]][memberId] += invested;
            s.quotaMemberIds[tokenAddress][actionId][groupId][providerIds[i]].add(memberId);
            s.quotaBlockNumber[tokenAddress][actionId][groupId][providerIds[i]][memberId] = block.number;

            emit IGroupActionJoinEvents.Withdrawn({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: round,
                amount: invested,
                providerId: providerIds[i],
                groupId: groupId
            });
        }
    }

    function joinInfo(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 joinedRound,
            uint256 amount,
            uint256 groupId,
            uint256 ownAmount,
            uint256 providerAmount
        )
    {
        ownAmount = s.ownAmountHistory[tokenAddress][actionId][memberId].value(round);
        providerAmount = s.providerAmountHistory[tokenAddress][actionId][memberId].value(round);
        amount = ownAmount + providerAmount;
        if (amount == 0) {
            return (0, 0, 0, 0, 0);
        }
        joinedRound = s.joinedRoundHistory[tokenAddress][actionId][memberId].value(round);
        groupId = s.groupHistory[tokenAddress][actionId][memberId].value(round);
    }

    function totalJoinedAmountByGroupId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return s.totalJoinedAmountByGroupId[tokenAddress][actionId][groupId].value(round);
    }

    function groupIds(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return s.groupIdsByRound[tokenAddress][actionId].valuesByRound(round, offset, limit, reverse);
    }

    function memberIdsByGroupId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return s.memberIdsByGroupId[tokenAddress][actionId][groupId].valuesByRound(round, offset, limit, reverse);
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function providerQuotaAdd(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) external onlyMemberOwner(s, providerId) {
        _providerQuotaAdd(s, tokenAddress, actionId, groupId, providerId, memberIds, amounts);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _providerQuotaAdd(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) private {
        if (groupId == 0) {
            revert IGroupActionJoinErrors.InvalidGroupId();
        }
        if (!s.groupInfo[tokenAddress][actionId][groupId].active) {
            revert IGroupActionJoinErrors.CannotJoinInactiveGroup();
        }
        if (memberIds.length != amounts.length) {
            revert IGroupActionJoinErrors.QuotaArrayLengthMismatch();
        }
        if (memberIds.length == 0) {
            return;
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < memberIds.length; i++) {
            uint256 memberId = memberIds[i];
            if (memberId == 0) {
                revert IGroupActionJoinErrors.QuotaMemberZero();
            }
            if (memberId == providerId) {
                revert IGroupActionJoinErrors.QuotaMemberIsProvider();
            }
            if (amounts[i] == 0) {
                revert IGroupActionJoinErrors.QuotaAmountZero();
            }
            IMemberNFT(s.memberNFTAddress).ownerOf(memberId);

            s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId] += amounts[i];
            s.quotaMemberIds[tokenAddress][actionId][groupId][providerId].add(memberId);
            s.quotaBlockNumber[tokenAddress][actionId][groupId][providerId][memberId] = block.number;
            totalAmount += amounts[i];

            emit IGroupActionJoinEvents.ProviderQuotaAdded({
                tokenAddress: tokenAddress,
                actionId: actionId,
                groupId: groupId,
                providerId: providerId,
                memberId: memberId,
                amount: amounts[i]
            });
        }

        IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), totalAmount);
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function providerQuotaRemove(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds
    ) external onlyMemberOwner(s, providerId) {
        if (groupId == 0) {
            revert IGroupActionJoinErrors.InvalidGroupId();
        }
        if (memberIds.length == 0) {
            return;
        }

        uint256 totalRefund = 0;
        for (uint256 i = 0; i < memberIds.length; i++) {
            uint256 memberId = memberIds[i];
            uint256 quota = s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId];
            if (quota == 0) {
                revert IGroupActionJoinErrors.QuotaNotGranted(memberId);
            }

            s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId] = 0;
            s.quotaMemberIds[tokenAddress][actionId][groupId][providerId].remove(memberId);
            totalRefund += quota;

            emit IGroupActionJoinEvents.ProviderQuotaRemoved({
                tokenAddress: tokenAddress,
                actionId: actionId,
                groupId: groupId,
                providerId: providerId,
                memberId: memberId,
                amount: quota
            });
        }

        if (totalRefund != 0) {
            IERC20(s.joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, totalRefund);
        }
    }

    function providerQuota(
        GroupActionStorage.Layout storage s,
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
            uint256[] memory amounts,
            uint256[] memory blockNumbers,
            uint256 total
        )
    {
        Uint256Set.Storage storage quotaSet = s.quotaMemberIds[tokenAddress][actionId][groupId][providerId];
        (memberIds, total) = quotaSet.values(offset, limit, reverse);
        amounts = new uint256[](memberIds.length);
        blockNumbers = new uint256[](memberIds.length);
        for (uint256 i = 0; i < memberIds.length; i++) {
            amounts[i] = _quotaAmountAt(s, tokenAddress, actionId, groupId, providerId, memberIds[i]);
            blockNumbers[i] = _quotaBlockNumberAt(s, tokenAddress, actionId, groupId, providerId, memberIds[i]);
        }
    }

    function _quotaAmountAt(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 memberId
    ) internal view returns (uint256) {
        return s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId];
    }

    function _quotaBlockNumberAt(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 memberId
    ) internal view returns (uint256) {
        return s.quotaBlockNumber[tokenAddress][actionId][groupId][providerId][memberId];
    }

    function providerAmountsByMemberId(
        GroupActionStorage.Layout storage s,
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
            _pageProviderIds(s, tokenAddress, actionId, round, memberId, offset, limit, reverse);
        amounts = new uint256[](providerIds.length);
        for (uint256 i = 0; i < providerIds.length; i++) {
            amounts[i] = _providerAmountAt(s, tokenAddress, actionId, round, memberId, providerIds[i]);
        }
    }

    function _pageProviderIds(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) internal view returns (uint256[] memory providerIds, uint256 total) {
        RoundHistoryUint256Set.Storage storage providerSet = s.providerIdsByMemberId[tokenAddress][actionId][memberId];
        return providerSet.valuesByRound(round, offset, limit, reverse);
    }

    function _providerAmountAt(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 providerId
    ) internal view returns (uint256) {
        return s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].value(round);
    }

    function gGroupIds(
        GroupActionStorage.Layout storage s,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return s.gGroupIds.values(offset, limit, reverse);
    }

    function gGroupIdsByMemberId(
        GroupActionStorage.Layout storage s,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds_, uint256 total) {
        return s.gGroupIdsByMemberId[memberId].values(offset, limit, reverse);
    }

    function gTokenAddressesByGroupIdByMemberId(
        GroupActionStorage.Layout storage s,
        uint256 groupId,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 total) {
        return s.gTokenAddressesByGroupIdByMemberId[groupId][memberId].values(offset, limit, reverse);
    }

    function gMemberIds(
        GroupActionStorage.Layout storage s,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return s.gMemberIds.values(offset, limit, reverse);
    }

    function gMemberIdsByGroupId(
        GroupActionStorage.Layout storage s,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory memberIds, uint256 total) {
        return s.gMemberIdsByGroupId[groupId].values(offset, limit, reverse);
    }

    function _decreaseProviderAmount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) internal {
        uint256 invested = s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].latestValue();
        uint256 remaining = invested - amount;
        s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].record(round, remaining);
        if (remaining == 0) {
            s.providerIdsByMemberId[tokenAddress][actionId][memberId].remove(round, providerId);
        }
        s.providerAmountHistory[tokenAddress][actionId][memberId].decrease(round, amount);
        s.totalJoinedAmountByGroupId[tokenAddress][actionId][groupId].decrease(round, amount);
        s.totalJoinedAmount[tokenAddress][actionId].decrease(round, amount);
    }

    function _validateGroupConstraints(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        bool isFirstJoin
    ) internal view {
        GroupActionStorage.GroupInfo storage group = s.groupInfo[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionJoinErrors.CannotJoinInactiveGroup();
        }

        uint256 newTotal = s.ownAmountHistory[tokenAddress][actionId][memberId].latestValue()
            + s.providerAmountHistory[tokenAddress][actionId][memberId].latestValue() + amount;

        if (group.config.maxJoinAmount != 0 && newTotal > group.config.maxJoinAmount) {
            revert IGroupActionJoinErrors.ExceedsGroupMaxJoinAmount();
        }

        if (isFirstJoin) {
            if (group.config.maxAccounts != 0 && s.memberIdsByGroupId[tokenAddress][actionId][groupId].count() >= group.config.maxAccounts) {
                revert IGroupActionJoinErrors.GroupAccountsFull();
            }
            if (amount < group.config.minJoinAmount) {
                revert IGroupActionJoinErrors.InvalidParticipationAmount();
            }
        }

        if (group.config.maxCapacity != 0) {
            uint256 groupTotal = s.totalJoinedAmountByGroupId[tokenAddress][actionId][groupId].latestValue();
            if (groupTotal + amount > group.config.maxCapacity) {
                revert IGroupActionJoinErrors.GroupCapacityExceeded();
            }
        }

        uint256 actionMaxJoinAmount = GroupActionManager._maxJoinAmount(s, tokenAddress, actionId);
        if (newTotal > actionMaxJoinAmount) {
            revert IGroupActionJoinErrors.ExceedsActionMaxJoinAmount();
        }
    }

    function _registerMembership(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 round
    ) internal {
        s.joinedRoundHistory[tokenAddress][actionId][memberId].record(round, round);
        s.groupHistory[tokenAddress][actionId][memberId].record(round, groupId);
        s.memberIdsByGroupId[tokenAddress][actionId][groupId].add(round, memberId);
        s.groupIdsByRound[tokenAddress][actionId].add(round, groupId);

        uint256 membershipCount = ++s.membershipCountByGroupIdByMemberId[groupId][memberId];
        if (membershipCount == 1) {
            s.gMemberIdsByGroupId[groupId].add(memberId);
            s.gGroupIdsByMemberId[memberId].add(groupId);
            s.gMemberIds.add(memberId);
            s.gGroupIds.add(groupId);
        }
        uint256 tokenCount = ++s.membershipCountByToken[groupId][memberId][tokenAddress];
        if (tokenCount == 1) {
            s.gTokenAddressesByGroupIdByMemberId[groupId][memberId].add(tokenAddress);
        }
    }

    function _applyVerificationInfos(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string[] calldata verificationInfos,
        uint256 round,
        bool isFirstJoin
    ) internal {
        string[] storage keys = s.verificationKeys[tokenAddress][actionId];
        if (!isFirstJoin && verificationInfos.length == 0) {
            return;
        }
        if (verificationInfos.length != keys.length) {
            revert IGroupActionExecutorErrors.VerificationInfoLengthMismatch();
        }
        for (uint256 i = 0; i < verificationInfos.length; i++) {
            s.verificationValueHistory[tokenAddress][actionId][memberId][i].record(round, verificationInfos[i]);
        }
    }

    function _increaseAmount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId
    ) internal {
        if (providerId == 0) {
            s.ownAmountHistory[tokenAddress][actionId][memberId].increase(round, amount);
        } else {
            uint256 quota = s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId];
            if (amount > quota) {
                revert IGroupActionJoinErrors.InsufficientProviderQuota(providerId, amount, quota);
            }
            quota -= amount;
            s.quotaAmount[tokenAddress][actionId][groupId][providerId][memberId] = quota;
            if (quota == 0) {
                s.quotaMemberIds[tokenAddress][actionId][groupId][providerId].remove(memberId);
            }

            if (s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].latestValue() == 0) {
                s.providerIdsByMemberId[tokenAddress][actionId][memberId].add(round, providerId);
            }
            s.providerAmountByProviderId[tokenAddress][actionId][memberId][providerId].increase(round, amount);
            s.providerAmountHistory[tokenAddress][actionId][memberId].increase(round, amount);
        }

        s.totalJoinedAmountByGroupId[tokenAddress][actionId][groupId].increase(round, amount);
        s.totalJoinedAmount[tokenAddress][actionId].increase(round, amount);
    }

    function _decreaseOwnAmount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId,
        uint256 ownAmount,
        uint256 amount
    ) internal {
        s.ownAmountHistory[tokenAddress][actionId][memberId].record(round, ownAmount - amount);
        s.totalJoinedAmountByGroupId[tokenAddress][actionId][groupId].decrease(round, amount);
        s.totalJoinedAmount[tokenAddress][actionId].decrease(round, amount);
    }

    function _finalizeExit(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 memberId
    ) internal {
        s.joinedRoundHistory[tokenAddress][actionId][memberId].record(round, 0);
        s.groupHistory[tokenAddress][actionId][memberId].record(round, 0);
        s.memberIdsByGroupId[tokenAddress][actionId][groupId].remove(round, memberId);
        if (s.memberIdsByGroupId[tokenAddress][actionId][groupId].count() == 0) {
            s.groupIdsByRound[tokenAddress][actionId].remove(round, groupId);
        }

        uint256 membershipCount = --s.membershipCountByGroupIdByMemberId[groupId][memberId];
        if (membershipCount == 0) {
            s.gMemberIdsByGroupId[groupId].remove(memberId);
            s.gGroupIdsByMemberId[memberId].remove(groupId);
            if (s.gMemberIdsByGroupId[groupId].count() == 0) {
                s.gGroupIds.remove(groupId);
            }
            if (s.gGroupIdsByMemberId[memberId].count() == 0) {
                s.gMemberIds.remove(memberId);
            }
        }
        uint256 tokenCount = --s.membershipCountByToken[groupId][memberId][tokenAddress];
        if (tokenCount == 0) {
            s.gTokenAddressesByGroupIdByMemberId[groupId][memberId].remove(tokenAddress);
        }

        IActionTarget(s.actionTarget).clearJoinState(tokenAddress, actionId, memberId);

        emit IGroupActionJoinEvents.Exited({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            groupId: groupId
        });
    }
}
