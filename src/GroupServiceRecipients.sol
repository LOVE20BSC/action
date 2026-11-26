// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {IGroupRecipientsEvents, IGroupRecipientsErrors} from "./interfaces/IGroupRecipients.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {OrderedHistoryIndex} from "@libs/OrderedHistoryIndex.sol";
import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";

library GroupServiceRecipients {
    using OrderedHistoryIndex for OrderedHistoryIndex.Index;
    using RoundHistoryStringArray for RoundHistoryStringArray.History;
    using RoundHistoryUint256Array for RoundHistoryUint256Array.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;

    struct RecipientTable {
        uint256[] recipientIds;
        uint256[] ratios;
        string[] remarks;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setRecipients(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external {
        _setRecipients(
            self,
            protocol,
            tokenAddress,
            round,
            actionId,
            groupId,
            RecipientTable({recipientIds: recipientIds, ratios: ratios, remarks: remarks})
        );
    }

    function recipients(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) external view returns (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory remarks) {
        recipientIds = self.recipientIdsHistory[tokenAddress][actionId][groupId].values(round);
        ratios = self.ratiosHistory[tokenAddress][actionId][groupId].values(round);
        remarks = self.remarksHistory[tokenAddress][actionId][groupId].values(round);
    }

    function actionIdsWithRecipients(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) internal view returns (uint256[] memory actionIds, uint256 totalCount) {
        return self.actionIdsWithRecipients[tokenAddress][groupId].valuesByRound(round, offset, limit, reverse);
    }

    function groupIdsByRecipientId(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) internal view returns (uint256[] memory groupIds, uint256 totalCount) {
        return self.recipientGroupIdsByRecipientId[tokenAddress][recipientId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function actionIdsByGroupIdByRecipientId(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) internal view returns (uint256[] memory actionIds, uint256 totalCount) {
        return self.recipientActionIdsByGroupIdByRecipientId[tokenAddress][recipientId][groupId]
            .valuesByRound(round, offset, limit, reverse);
    }

    function recipientRatios(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) internal view returns (uint256[] memory ratios) {
        return self.ratiosHistory[tokenAddress][actionId][groupId].values(round);
    }

    function recipientRatio(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 recipientId
    ) internal view returns (uint256) {
        RoundHistoryUint256Array.History storage history = self.recipientIdsHistory[tokenAddress][actionId][groupId];
        if (!history.index.contains(round)) {
            (bool found, uint256 recordedRound) = history.index.nearest(round);
            if (!found) return 0;
            round = recordedRound;
        }

        uint256[] storage recipientIds = history.valueByRound[round];
        uint256 count = recipientIds.length;
        for (uint256 i = 0; i < count; ++i) {
            if (recipientIds[i] == recipientId) {
                // Load-bearing: setRecipients checkpoints recipient IDs and ratios together in the same order.
                return self.ratiosHistory[tokenAddress][actionId][groupId].valueByRound[round][i];
            }
        }
        return 0;
    }

    function _setRecipients(
        GroupServiceStorage.Layout storage self,
        GroupServiceStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        RecipientTable memory table
    ) private {
        _checkRecipients(protocol, table, groupId);

        // Load-bearing: settlement only reads configs for actions this executor created, so any other
        // key is silently ignored and the owner keeps the whole slice.
        if (IGroupActionExecutor(protocol.groupActionExecutorAddress).joinTokenAddress(tokenAddress, actionId) == address(0)) {
            revert IGroupRecipientsErrors.UnknownSourceAction(tokenAddress, actionId);
        }

        uint256[] memory prevRecipientIds = self.recipientIdsHistory[tokenAddress][actionId][groupId].values(round);
        _updateRecipientIndexes(self, tokenAddress, round, actionId, groupId, prevRecipientIds, table.recipientIds);

        uint256[] memory prevRatios = self.ratiosHistory[tokenAddress][actionId][groupId].values(round);
        string[] memory prevRemarks = self.remarksHistory[tokenAddress][actionId][groupId].values(round);

        self.recipientIdsHistory[tokenAddress][actionId][groupId].record(round, table.recipientIds);
        self.ratiosHistory[tokenAddress][actionId][groupId].record(round, table.ratios);
        self.remarksHistory[tokenAddress][actionId][groupId].record(round, table.remarks);

        if (table.recipientIds.length != 0) {
            RoundHistoryUint256Set.Storage storage actionSet = self.actionIdsWithRecipients[tokenAddress][groupId];
            uint256 actual = actionSet.count();
            if (!actionSet.contains(actionId) && actual >= GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP) {
                revert IGroupRecipientsErrors.RecipientActionsLimitExceeded(
                    tokenAddress, groupId, actual, GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP
                );
            }
            actionSet.add(round, actionId);
        } else {
            self.actionIdsWithRecipients[tokenAddress][groupId].remove(round, actionId);
        }

        emit IGroupRecipientsEvents.RecipientsChanged({
            sourceTokenAddress: tokenAddress,
            sourceActionId: actionId,
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

    function _updateRecipientIndexes(
        GroupServiceStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256[] memory previousIds,
        uint256[] memory currentIds
    ) private {
        if (previousIds.length == 0 && currentIds.length == 0) return;

        for (uint256 i = 0; i < previousIds.length; ++i) {
            uint256 recipientId = previousIds[i];
            if (!_containsRecipient(currentIds, recipientId)) {
                RoundHistoryUint256Set.Storage storage actionIds =
                    self.recipientActionIdsByGroupIdByRecipientId[tokenAddress][recipientId][groupId];
                actionIds.remove(round, actionId);
                if (actionIds.count() == 0) {
                    self.recipientGroupIdsByRecipientId[tokenAddress][recipientId].remove(round, groupId);
                }
            }
        }
        for (uint256 i = 0; i < currentIds.length; ++i) {
            uint256 recipientId = currentIds[i];
            if (!_containsRecipient(previousIds, recipientId)) {
                RoundHistoryUint256Set.Storage storage actionIds =
                    self.recipientActionIdsByGroupIdByRecipientId[tokenAddress][recipientId][groupId];
                if (actionIds.count() == 0) {
                    self.recipientGroupIdsByRecipientId[tokenAddress][recipientId].add(round, groupId);
                }
                actionIds.add(round, actionId);
            }
        }
    }

    function _containsRecipient(
        uint256[] memory recipientIds,
        uint256 recipientId
    ) private pure returns (bool) {
        for (uint256 i = 0; i < recipientIds.length; ++i) {
            if (recipientIds[i] == recipientId) return true;
        }
        return false;
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkRecipients(
        GroupServiceStorage.Protocol memory protocol,
        RecipientTable memory table,
        uint256 groupId
    ) private view {
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
