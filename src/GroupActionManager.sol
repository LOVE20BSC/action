// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {MemberOwner} from "./MemberOwner.sol";
import {AddressSet} from "@libs/AddressSet.sol";
import {RoundHistoryString} from "@libs/RoundHistoryString.sol";
import {Uint256Set} from "@libs/Uint256Set.sol";
import {IGroupActionExecutorErrors, IGroupActionExecutorEvents} from "./interfaces/IGroupActionExecutor.sol";
import {GroupConfig, IGroupActionManagerEvents, IGroupActionManagerErrors} from "./interfaces/IGroupActionManager.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IVote} from "@core/interfaces/IVote.sol";
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
        if (groupOwnerOrRevert(s, groupId) != msg.sender) {
            revert IGroupActionManagerErrors.NotGroupOwner(groupId);
        }
        _;
    }

    function groupOwnerOrRevert(GroupActionStorage.Layout storage s, uint256 groupId) internal view returns (address) {
        address owner = MemberOwner.ofOrZero(s.memberNFTAddress, groupId);
        if (owner == address(0)) {
            revert IGroupActionManagerErrors.GroupNotExist(groupId);
        }
        return owner;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId,
        bytes[] calldata targetData
    ) external {
        if (targetData.length < 6) {
            revert IGroupActionExecutorErrors.TargetDataLengthMismatch(6, targetData.length);
        }
        if (targetData.length > 7) {
            revert IGroupActionExecutorErrors.TargetDataLengthMismatch(7, targetData.length);
        }
        for (uint256 i = 1; i < 6; i++) {
            if (targetData[i].length != 32) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert IGroupActionExecutorErrors.InvalidTargetDataShape(i, targetData[i].length);
            }
        }

        address joinTokenAddress = abi.decode(targetData[1], (address));
        uint256 activationStakeAmount = abi.decode(targetData[2], (uint256));
        uint256 maxJoinAmountRatio = abi.decode(targetData[3], (uint256));
        uint256 activationMinGovRatio = abi.decode(targetData[4], (uint256));
        uint256 verifierStakeAmount = abi.decode(targetData[5], (uint256));
        if (joinTokenAddress == address(0)) {
            revert IGroupActionExecutorErrors.ZeroJoinTokenAddress();
        }
        if (maxJoinAmountRatio > GroupActionStorage.PRECISION) {
            revert IGroupActionExecutorErrors.InvalidMaxJoinAmountRatio(maxJoinAmountRatio);
        }
        if (activationMinGovRatio > GroupActionStorage.PRECISION) {
            revert IGroupActionExecutorErrors.InvalidActivationMinGovRatio(activationMinGovRatio);
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
                revert IGroupActionExecutorErrors.VerificationInfoLengthMismatch(keys.length, descriptions.length);
            }
            if (keys.length > GroupActionStorage.MAX_VERIFICATION_ENTRIES) {
                revert IGroupActionManagerErrors.TooManyVerificationEntries(
                    keys.length, GroupActionStorage.MAX_VERIFICATION_ENTRIES
                );
            }
            for (uint256 i = 0; i < keys.length; i++) {
                uint256 keyLength = bytes(keys[i]).length;
                if (keyLength > GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES) {
                    // forge-lint: disable-next-item(require-revert-in-loop)
                    revert IGroupActionManagerErrors.VerificationKeyTooLong(
                        i, keyLength, GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES
                    );
                }
                uint256 descriptionLength = bytes(descriptions[i]).length;
                if (descriptionLength > GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES) {
                    // forge-lint: disable-next-item(require-revert-in-loop)
                    revert IGroupActionManagerErrors.VerificationDescriptionTooLong(
                        i, descriptionLength, GroupActionStorage.MAX_VERIFICATION_TEXT_BYTES
                    );
                }
            }
            s.verificationKeys[tokenAddress][actionId] = keys;
            s.verificationDescriptions[tokenAddress][actionId] = descriptions;
        }

        s.createdRound[tokenAddress][actionId] = IPhase(s.phaseAddress).currentPhase();

        _emitGroupActionCreated(s, tokenAddress, actionId);
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
            revert IGroupActionManagerErrors.GroupAlreadyActivated(groupId);
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
            stakeAmount: stakeAmount,
            maxCapacity: config.maxCapacity,
            minJoinAmount: config.minJoinAmount,
            maxJoinAmount: config.maxJoinAmount,
            maxAccounts: config.maxAccounts,
            description: config.description
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
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }

        uint256 round = s.currentJoinRound();
        if (round == group.activatedRound) {
            revert IGroupActionManagerErrors.DeactivationLockedInActivatedRound(groupId, round);
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
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }

        _validateGroupConfig(config);

        GroupConfig memory previousConfig = group.config;

        uint256 round = s.currentJoinRound();
        group.config = config;
        s.descriptionHistory[tokenAddress][actionId][groupId].record(round, config.description);

        _emitGroupConfigChanged(tokenAddress, actionId, round, groupId, previousConfig, config);
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
        uint256 round = GroupActionRoundAxis.joinRound(s.phaseAddress);
        if (round == 0) {
            return 0;
        }
        uint256 totalVotes = IVote(s.voteAddress).totalVoteAmount(tokenAddress, round);
        if (totalVotes == 0) {
            return 0;
        }
        uint256 actionVotes = IVote(s.voteAddress).voteAmountByProposalId(tokenAddress, round, actionId);
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
            revert IGroupActionManagerErrors.InvalidMinJoinAmount(config.minJoinAmount);
        }
        if (config.maxJoinAmount != 0 && config.maxJoinAmount < config.minJoinAmount) {
            revert IGroupActionManagerErrors.InvalidMaxJoinAmount(config.minJoinAmount, config.maxJoinAmount);
        }
        uint256 descriptionLength = bytes(config.description).length;
        if (descriptionLength > GroupActionStorage.MAX_DESCRIPTION_BYTES) {
            revert IGroupActionExecutorErrors.DescriptionTooLong(
                descriptionLength, GroupActionStorage.MAX_DESCRIPTION_BYTES
            );
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
        uint256 currentPhase = IPhase(s.phaseAddress).currentPhase();
        uint256 totalGovVotes = stake.totalValidGovVotes(tokenAddress, currentPhase);
        if (totalGovVotes == 0) {
            revert IGroupActionManagerErrors.NoGovVotes(tokenAddress);
        }

        uint256 ownerGovVotes = stake.validGovVotes(tokenAddress, currentPhase, groupId);
        uint256 actualRatio = (ownerGovVotes * GroupActionStorage.PRECISION) / totalGovVotes;
        if (actualRatio < minGovRatio) {
            revert IGroupActionManagerErrors.InsufficientActivationMinGovRatio(groupId, minGovRatio, actualRatio);
        }
    }

    function _emitGroupActionCreated(
        GroupActionStorage.Layout storage s,
        address tokenAddress,
        uint256 actionId
    ) private {
        emit IGroupActionExecutorEvents.GroupActionCreated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            joinTokenAddress: s.joinTokenAddress[tokenAddress][actionId],
            activationStakeAmount: s.activationStakeAmount[tokenAddress][actionId],
            maxJoinAmountRatio: s.maxJoinAmountRatio[tokenAddress][actionId],
            activationMinGovRatio: s.activationMinGovRatio[tokenAddress][actionId],
            verifierStakeAmount: s.verifierStakeAmount[tokenAddress][actionId],
            verificationKeys: s.verificationKeys[tokenAddress][actionId],
            verificationDescriptions: s.verificationDescriptions[tokenAddress][actionId]
        });
    }

    function _emitGroupConfigChanged(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        GroupConfig memory previousConfig,
        GroupConfig memory config
    ) private {
        emit IGroupActionManagerEvents.GroupConfigChanged({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: round,
            groupId: groupId,
            maxCapacity: config.maxCapacity,
            minJoinAmount: config.minJoinAmount,
            maxJoinAmount: config.maxJoinAmount,
            maxAccounts: config.maxAccounts,
            description: config.description,
            prevMaxCapacity: previousConfig.maxCapacity,
            prevMinJoinAmount: previousConfig.minJoinAmount,
            prevMaxJoinAmount: previousConfig.maxJoinAmount,
            prevMaxAccounts: previousConfig.maxAccounts,
            prevDescription: previousConfig.description
        });
    }
}
