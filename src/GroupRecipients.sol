// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {IGroupRecipientsEvents, IGroupRecipientsErrors} from "./interfaces/IGroupRecipients.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IGroupServiceExecutorEvents} from "./interfaces/IGroupServiceExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {RoundHistoryStringArray} from "@libs/RoundHistoryStringArray.sol";
import {RoundHistoryUint256Array} from "@libs/RoundHistoryUint256Array.sol";
import {RoundHistoryUint256Set} from "@libs/RoundHistoryUint256Set.sol";

library GroupRecipients {
    using GroupServiceStorage for GroupServiceStorage.Layout;
    using RoundHistoryUint256Array for RoundHistoryUint256Array.History;
    using RoundHistoryStringArray for RoundHistoryStringArray.History;
    using RoundHistoryUint256Set for RoundHistoryUint256Set.Storage;
    using SafeERC20 for IERC20;

    struct Distribution {
        uint256[] recipientIds;
        uint256[] ratios;
        uint256[] amounts;
        uint256 ownerAmount;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setRecipients(
        GroupServiceStorage.Layout storage s,
        uint256 round,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external {
        _setRecipients(s, round, sourceTokenAddress, sourceActionId, groupId, recipientIds, ratios, remarks);
    }

    function _setRecipients(
        GroupServiceStorage.Layout storage s,
        uint256 round,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) private {

        // Load-bearing: settlement only reads configs for actions this executor created, so any other
        // key is silently ignored and the owner keeps the whole slice.
        if (
            IGroupActionExecutor(s.groupActionExecutorAddress).JOIN_TOKEN_ADDRESS(sourceTokenAddress, sourceActionId)
                == address(0)
        ) {
            revert IGroupRecipientsErrors.UnknownSourceAction(sourceTokenAddress, sourceActionId);
        }

        _validateRecipients(s, recipientIds, ratios, remarks, groupId);

        s.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].record(round, recipientIds);
        s.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].record(round, ratios);
        s.remarksHistory[sourceTokenAddress][sourceActionId][groupId].record(round, remarks);

        if (recipientIds.length != 0) {
            s.actionIdsWithRecipients[sourceTokenAddress][groupId].add(round, sourceActionId);
        } else {
            s.actionIdsWithRecipients[sourceTokenAddress][groupId].remove(round, sourceActionId);
        }

        emit IGroupRecipientsEvents.SetRecipients({
            sourceTokenAddress: sourceTokenAddress,
            round: round,
            sourceActionId: sourceActionId,
            groupId: groupId,
            recipientIds: recipientIds,
            ratios: ratios
        });
    }

    function recipients(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 round
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            string[] memory remarks
        )
    {
        recipientIds = s.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        ratios = s.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        remarks = s.remarksHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
    }

    function actionIdsWithRecipients(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total) {
        return s.actionIdsWithRecipients[sourceTokenAddress][groupId].valuesByRound(round, offset, limit, reverse);
    }

    function getDistribution(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 groupReward,
        uint256 round
    ) external view returns (Distribution memory distribution) {
        distribution.recipientIds = s.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        distribution.ratios = s.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        uint256 distributed;
        (distribution.amounts, distributed) =
            _calculateRecipientAmounts(groupReward, distribution.recipientIds, distribution.ratios);
        distribution.ownerAmount = groupReward - distributed;
    }

    function distribute(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) external returns (uint256 distributed) {
        if (ownerReward == 0 || ownerWeight == 0) {
            return 0;
        }

        (uint256[] memory sourceActionIds, ) =
            s.actionIdsWithRecipients[sourceTokenAddress][groupId].valuesByRound(round, 0, type(uint256).max, false);
        for (uint256 i = 0; i < sourceActionIds.length; i++) {
            uint256 sourceActionId = sourceActionIds[i];
            uint256 slice = ownerSlice(s, sourceTokenAddress, sourceActionId, round, groupId, ownerReward, ownerWeight);
            if (slice == 0) {
                continue;
            }
            distributed +=
                _distributeToRecipients(s, slice, sourceTokenAddress, serviceTokenAddress, serviceActionId, round, groupId, sourceActionId);
        }
    }

    function projectedDistribution(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 round,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) external view returns (uint256 distributed) {
        if (ownerReward == 0 || ownerWeight == 0) {
            return 0;
        }

        (uint256[] memory sourceActionIds, ) =
            s.actionIdsWithRecipients[sourceTokenAddress][groupId].valuesByRound(round, 0, type(uint256).max, false);
        for (uint256 i = 0; i < sourceActionIds.length; i++) {
            distributed +=
                _projectedForAction(s, sourceTokenAddress, sourceActionIds[i], round, groupId, ownerReward, ownerWeight);
        }
    }

    function _distributeToRecipients(
        GroupServiceStorage.Layout storage s,
        uint256 slice,
        address sourceTokenAddress,
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 groupId,
        uint256 sourceActionId
    ) internal returns (uint256 distributed) {
        uint256[] memory recipientIds =
            s.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        uint256[] memory ratios = s.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round);
        uint256[] memory amounts;
        (amounts, distributed) = _calculateRecipientAmounts(slice, recipientIds, ratios);
        for (uint256 j = 0; j < amounts.length; j++) {
            uint256 amount = amounts[j];
            if (amount == 0) {
                continue;
            }
            IERC20(serviceTokenAddress).safeTransfer(IMemberNFT(s.memberNFTAddress).ownerOf(recipientIds[j]), amount);
            emit IGroupServiceExecutorEvents.DistributeRecipient(
                serviceTokenAddress, round, serviceActionId, groupId, sourceActionId, recipientIds[j], amount
            );
        }
    }

    function _projectedForAction(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 round,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) internal view returns (uint256 distributed) {
        uint256 slice = ownerSlice(s, sourceTokenAddress, sourceActionId, round, groupId, ownerReward, ownerWeight);
        if (slice == 0) {
            return 0;
        }
        (, distributed) = _calculateRecipientAmounts(
            slice,
            s.recipientIdsHistory[sourceTokenAddress][sourceActionId][groupId].values(round),
            s.ratiosHistory[sourceTokenAddress][sourceActionId][groupId].values(round)
        );
    }

    function ownerSlice(
        GroupServiceStorage.Layout storage s,
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 round,
        uint256 groupId,
        uint256 ownerReward,
        uint256 ownerWeight
    ) internal view returns (uint256) {
        uint256 groupReward = s.groupReward(sourceTokenAddress, sourceActionId, round, groupId);
        if (groupReward == 0) {
            return 0;
        }
        return Math.mulDiv(ownerReward, groupReward, ownerWeight);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _validateRecipients(
        GroupServiceStorage.Layout storage s,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks,
        uint256 groupId
    ) internal view {
        uint256 length = recipientIds.length;
        if (length != ratios.length || length != remarks.length) {
            revert IGroupRecipientsErrors.ArrayLengthMismatch();
        }
        if (length > GroupServiceStorage.DEFAULT_MAX_RECIPIENTS) {
            revert IGroupRecipientsErrors.TooManyRecipients();
        }

        uint256 totalRatios = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 recipientId = recipientIds[i];
            if (recipientId == groupId) {
                revert IGroupRecipientsErrors.RecipientIsGroupId(groupId, recipientId);
            }
            if (ratios[i] == 0) {
                revert IGroupRecipientsErrors.ZeroRatio();
            }
            for (uint256 j = 0; j < i; j++) {
                if (recipientIds[j] == recipientId) {
                    revert IGroupRecipientsErrors.DuplicateMemberId(recipientId);
                }
            }
            IMemberNFT(s.memberNFTAddress).ownerOf(recipientId);
            totalRatios += ratios[i];
        }
        if (totalRatios > GroupServiceStorage.PRECISION) {
            revert IGroupRecipientsErrors.DistributionOverflow(totalRatios, GroupServiceStorage.PRECISION);
        }
    }

    function _calculateRecipientAmounts(
        uint256 groupReward,
        uint256[] memory recipientIds,
        uint256[] memory ratios
    ) internal pure returns (uint256[] memory amounts, uint256 distributed) {
        uint256 length = recipientIds.length;
        amounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            amounts[i] = Math.mulDiv(groupReward, ratios[i], GroupServiceStorage.PRECISION);
            distributed += amounts[i];
        }
    }
}
