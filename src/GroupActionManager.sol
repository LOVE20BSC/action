// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {AddressSet} from "libs/AddressSet.sol";
import {RoundHistoryString} from "libs/RoundHistoryString.sol";
import {Uint256Set} from "libs/Uint256Set.sol";
import {IGroupActionExecutorErrors} from "./interfaces/IGroupActionExecutor.sol";
import {GroupConfig, IGroupActionManagerEvents, IGroupActionManagerErrors} from "./interfaces/IGroupActionManager.sol";
import {IStake} from "core/src/interfaces/IStake.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IVote} from "core/src/interfaces/IVote.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

library GroupActionManager {
    using AddressSet for AddressSet.Storage;
    using GroupActionStorage for GroupActionStorage.Layout;
    using RoundHistoryString for RoundHistoryString.History;
    using SafeERC20 for IERC20;
    using Uint256Set for Uint256Set.Storage;

    modifier onlyGroupOwner(
        GroupActionStorage.Layout storage s,
        uint256 groupId
    ) {
        if (IMemberNFT(s.memberNFTAddress).ownerOf(groupId) != msg.sender) {
            revert IGroupActionManagerErrors.OnlyGroupOwner();
        }
        _;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        bytes[] calldata targetData
    ) external {
        if (targetData.length != 6 && targetData.length != 7) {
            revert IGroupActionExecutorErrors.InvalidTargetDataLength();
        }
        for (uint256 i = 1; i < 6; i++) {
            if (targetData[i].length != 32) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert IGroupActionExecutorErrors.InvalidTargetDataLength();
            }
        }

        address joinTokenAddress = abi.decode(targetData[1], (address));
        uint256 activationStakeAmount = abi.decode(targetData[2], (uint256));
        uint256 maxJoinAmountRatio = abi.decode(targetData[3], (uint256));
        uint256 activationMinGovRatio = abi.decode(targetData[4], (uint256));
        uint256 verifierStakeAmount = abi.decode(targetData[5], (uint256));
        if (joinTokenAddress == address(0)) {
            revert IGroupActionExecutorErrors.InvalidAddress();
        }
        if (maxJoinAmountRatio > GroupActionStorage.PRECISION || activationMinGovRatio > GroupActionStorage.PRECISION) {
            revert IGroupActionExecutorErrors.InvalidRatio();
        }

        s.joinTokenAddress[tokenAddress][actionId] = joinTokenAddress;
        // Load-bearing: written only here. Refunds read this value instead of a per-group ledger, so a
        // later write while groups are active would over-refund out of the other groups' stake.
        s.activationStakeAmount[tokenAddress][actionId] = activationStakeAmount;
        s.maxJoinAmountRatio[tokenAddress][actionId] = maxJoinAmountRatio;
        s.activationMinGovRatio[tokenAddress][actionId] = activationMinGovRatio;
        s.verifierStakeAmount[tokenAddress][actionId] = verifierStakeAmount;

        if (targetData.length == 7) {
            (string[] memory keys, string[] memory descriptions) = abi.decode(targetData[6], (string[], string[]));
            if (keys.length != descriptions.length) {
                revert IGroupActionExecutorErrors.VerificationInfoLengthMismatch();
            }
            s.verificationKeys[tokenAddress][actionId] = keys;
            s.verificationDescriptions[tokenAddress][actionId] = descriptions;
        }

        s.createdRound[tokenAddress][actionId] = IPhase(s.phaseAddress).currentPhase();
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function activateGroup(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external onlyGroupOwner(s, groupId) {
        if (s.createdRound[tokenAddress][actionId] == 0) {
            revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        }

        GroupActionStorage.GroupInfo storage group = s.groupInfo[tokenAddress][actionId][groupId];
        if (group.active) {
            revert IGroupActionManagerErrors.GroupAlreadyActivated();
        }

        _validateGroupConfig(config);
        _validateActivationMinGovRatio(s, tokenAddress, actionId, groupId);

        uint256 round = s.currentJoinRound();

        group.config = config;
        group.active = true;
        group.activatedRound = round;
        group.deactivatedRound = 0;
        s.descriptionHistory[tokenAddress][actionId][groupId].record(round, config.description);

        uint256 stakeAmount = s.activationStakeAmount[tokenAddress][actionId];
        s.activeGroupIds[tokenAddress][actionId].add(groupId);
        s.staked[tokenAddress][actionId] += stakeAmount;
        s.totalStaked[tokenAddress] += stakeAmount;
        s.totalStakedByMemberId[tokenAddress][groupId] += stakeAmount;
        s.tokenAddressesByGroupId[groupId].add(tokenAddress);
        s.actionIdsByGroupId[tokenAddress][groupId].add(actionId);
        s.actionIds[tokenAddress].add(actionId);

        if (stakeAmount != 0) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), stakeAmount);
        }

        emit IGroupActionManagerEvents.GroupActivated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            groupId: groupId,
            stakeAmount: stakeAmount
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function deactivateGroup(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external onlyGroupOwner(s, groupId) {
        GroupActionStorage.GroupInfo storage group = s.groupInfo[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionManagerErrors.GroupNotActive();
        }

        uint256 round = s.currentJoinRound();
        if (round == group.activatedRound) {
            revert IGroupActionManagerErrors.CannotDeactivateInActivatedRound();
        }

        uint256 stakeAmount = s.activationStakeAmount[tokenAddress][actionId];

        group.active = false;
        group.deactivatedRound = round;

        s.activeGroupIds[tokenAddress][actionId].remove(groupId);
        s.staked[tokenAddress][actionId] -= stakeAmount;
        s.totalStaked[tokenAddress] -= stakeAmount;
        s.totalStakedByMemberId[tokenAddress][groupId] -= stakeAmount;
        s.actionIdsByGroupId[tokenAddress][groupId].remove(actionId);
        if (s.actionIdsByGroupId[tokenAddress][groupId].count() == 0) {
            s.tokenAddressesByGroupId[groupId].remove(tokenAddress);
        }
        if (s.activeGroupIds[tokenAddress][actionId].count() == 0) {
            s.actionIds[tokenAddress].remove(actionId);
        }

        if (stakeAmount != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, stakeAmount);
        }

        emit IGroupActionManagerEvents.GroupDeactivated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            groupId: groupId,
            stakeAmount: stakeAmount
        });
    }

    function updateGroupConfig(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external onlyGroupOwner(s, groupId) {
        GroupActionStorage.GroupInfo storage group = s.groupInfo[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionManagerErrors.GroupNotActive();
        }

        _validateGroupConfig(config);

        uint256 round = s.currentJoinRound();
        group.config = config;
        s.descriptionHistory[tokenAddress][actionId][groupId].record(round, config.description);

        emit IGroupActionManagerEvents.GroupConfigUpdated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            groupId: groupId,
            description: config.description,
            maxCapacity: config.maxCapacity,
            minJoinAmount: config.minJoinAmount,
            maxJoinAmount: config.maxJoinAmount,
            maxAccounts: config.maxAccounts
        });
    }

    function groupInfo(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    )
        external
        view
        returns (
            GroupConfig memory config,
            bool active,
            uint256 activatedRound,
            uint256 deactivatedRound
        )
    {
        GroupActionStorage.GroupInfo storage group = s.groupInfo[tokenAddress][actionId][groupId];
        return (group.config, group.active, group.activatedRound, group.deactivatedRound);
    }

    function descriptionByRound(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory) {
        return s.descriptionHistory[tokenAddress][actionId][groupId].value(round);
    }

    function activeGroupIds(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 total) {
        return s.activeGroupIds[tokenAddress][actionId].values(offset, limit, reverse);
    }

    function isGroupActive(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external view returns (bool) {
        return s.groupInfo[tokenAddress][actionId][groupId].active;
    }

    function maxJoinAmount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _maxJoinAmount(s, tokenAddress, actionId);
    }

    function staked(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return s.staked[tokenAddress][actionId];
    }

    function totalStaked(
        GroupActionStorage.Layout storage s,
        address tokenAddress
    ) external view returns (uint256) {
        return s.totalStaked[tokenAddress];
    }

    function totalStakedByMemberId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 memberId
    ) external view returns (uint256) {
        return s.totalStakedByMemberId[tokenAddress][memberId];
    }

    function tokenAddressesByGroupId(
        GroupActionStorage.Layout storage s,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 total) {
        return s.tokenAddressesByGroupId[groupId].values(offset, limit, reverse);
    }

    function actionIdsByGroupId(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds_, uint256 total) {
        return s.actionIdsByGroupId[tokenAddress][groupId].values(offset, limit, reverse);
    }

    function actionIds(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds_, uint256 total) {
        return s.actionIds[tokenAddress].values(offset, limit, reverse);
    }

    function hasActiveGroups(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 memberId
    ) external view returns (bool) {
        return s.actionIdsByGroupId[tokenAddress][memberId].count() != 0;
    }

    function _maxJoinAmount(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId
    ) internal view returns (uint256) {
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        uint256 round = phase < 2 ? 0 : phase - 1;
        if (round == 0) {
            return 0;
        }
        uint256 totalVotes = IVote(s.voteAddress).votesNum(tokenAddress, round);
        if (totalVotes == 0) {
            return 0;
        }
        uint256 actionVotes = IVote(s.voteAddress).votesNumByProposalId(tokenAddress, round, actionId);
        if (actionVotes == 0) {
            return 0;
        }
        uint256 totalMinted = IERC20(s.joinTokenAddress[tokenAddress][actionId]).totalSupply();
        uint256 baseAmount = Math.mulDiv(
            totalMinted,
            s.maxJoinAmountRatio[tokenAddress][actionId],
            GroupActionStorage.PRECISION
        );
        return Math.mulDiv(baseAmount, actionVotes, totalVotes);
    }

    function _validateGroupConfig(GroupConfig calldata config) internal pure {
        if (config.minJoinAmount == 0) {
            revert IGroupActionManagerErrors.InvalidMinMaxJoinAmount();
        }
        if (config.maxJoinAmount != 0 && config.maxJoinAmount < config.minJoinAmount) {
            revert IGroupActionManagerErrors.InvalidMinMaxJoinAmount();
        }
        if (bytes(config.description).length > GroupActionStorage.MAX_DESCRIPTION_BYTES) {
            revert IGroupActionExecutorErrors.DescriptionTooLong();
        }
    }

    function _validateActivationMinGovRatio(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) internal view {
        uint256 minGovRatio = s.activationMinGovRatio[tokenAddress][actionId];
        if (minGovRatio == 0) {
            return;
        }

        IStake stake = IStake(s.stakeAddress);
        uint256 totalGovVotes = stake.globalGovVotes(tokenAddress);
        if (totalGovVotes == 0) {
            revert IGroupActionManagerErrors.NoGovVotes();
        }

        uint256 ownerGovVotes = stake.validGovVotes(tokenAddress, groupId);
        if ((ownerGovVotes * GroupActionStorage.PRECISION) / totalGovVotes < minGovRatio) {
            revert IGroupActionManagerErrors.InsufficientActivationMinGovRatio();
        }
    }
}
