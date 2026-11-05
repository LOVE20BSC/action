// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {ActionRoundAxis} from "./ActionRoundAxis.sol";
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

    uint256 private constant ABI_WORD_BYTES = 32;

    uint256 private constant SLOT_PAYLOAD_START = 1;
    uint256 private constant SLOT_JOIN_TOKEN = 1;
    uint256 private constant SLOT_ACTIVATION_STAKE_AMOUNT = 2;
    uint256 private constant SLOT_MAX_JOIN_AMOUNT_RATIO = 3;
    uint256 private constant SLOT_ACTIVATION_MIN_GOV_RATIO = 4;
    uint256 private constant SLOT_VERIFIER_STAKE_AMOUNT = 5;
    uint256 private constant SLOT_VERIFICATION_INFO = 6;
    uint256 private constant TARGET_DATA_MIN_LENGTH = 6;
    uint256 private constant TARGET_DATA_MAX_LENGTH = 7;

    modifier onlyGroupOwner(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        uint256 groupId
    ) {
        if (groupOwnerOrRevert(protocol, groupId) != msg.sender) {
            revert IGroupActionManagerErrors.NotGroupOwner(groupId);
        }
        _;
    }

    function groupOwnerOrRevert(
        GroupActionStorage.Protocol memory protocol,
        uint256 groupId
    ) internal view returns (address) {
        address owner = MemberOwner.ownerOrZero(protocol.memberNFTAddress, groupId);
        if (owner == address(0)) {
            revert IGroupActionManagerErrors.GroupNotExist(groupId);
        }
        return owner;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        bytes[] calldata targetData
    ) external {
        if (targetData.length < TARGET_DATA_MIN_LENGTH) {
            revert IGroupActionExecutorErrors.InsufficientTargetDataItems(targetData.length, TARGET_DATA_MIN_LENGTH);
        }
        if (targetData.length > TARGET_DATA_MAX_LENGTH) {
            revert IGroupActionExecutorErrors.TooManyTargetDataItems(targetData.length, TARGET_DATA_MAX_LENGTH);
        }
        for (uint256 i = SLOT_PAYLOAD_START; i < TARGET_DATA_MIN_LENGTH; i++) {
            if (targetData[i].length != ABI_WORD_BYTES) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert IGroupActionExecutorErrors.InvalidTargetDataShape(i, targetData[i].length);
            }
        }

        address joinTokenAddress = abi.decode(targetData[SLOT_JOIN_TOKEN], (address));
        uint256 activationStakeAmount = abi.decode(targetData[SLOT_ACTIVATION_STAKE_AMOUNT], (uint256));
        uint256 maxJoinAmountRatio = abi.decode(targetData[SLOT_MAX_JOIN_AMOUNT_RATIO], (uint256));
        uint256 activationMinGovRatio = abi.decode(targetData[SLOT_ACTIVATION_MIN_GOV_RATIO], (uint256));
        uint256 verifierStakeAmount = abi.decode(targetData[SLOT_VERIFIER_STAKE_AMOUNT], (uint256));
        if (joinTokenAddress == address(0)) {
            revert IGroupActionExecutorErrors.ZeroJoinTokenAddress();
        }
        if (joinTokenAddress.code.length == 0) {
            revert IGroupActionExecutorErrors.InvalidJoinTokenAddress(joinTokenAddress);
        }
        try IERC20(joinTokenAddress).totalSupply() {
        } catch {
            revert IGroupActionExecutorErrors.InvalidJoinTokenAddress(joinTokenAddress);
        }
        if (maxJoinAmountRatio > GroupActionStorage.PRECISION) {
            revert IGroupActionExecutorErrors.InvalidMaxJoinAmountRatio(maxJoinAmountRatio);
        }
        if (activationMinGovRatio > GroupActionStorage.PRECISION) {
            revert IGroupActionExecutorErrors.InvalidActivationMinGovRatio(activationMinGovRatio);
        }

        self.joinTokenAddressByActionId[tokenAddress][actionId] = joinTokenAddress;
        // Load-bearing: written only here. Refunds read this value instead of a per-group ledger, so a
        // later write while groups are active would over-refund out of the other groups' stake.
        self.activationStakeAmountByActionId[tokenAddress][actionId] = activationStakeAmount;
        self.maxJoinAmountRatioByActionId[tokenAddress][actionId] = maxJoinAmountRatio;
        self.activationMinGovRatioByActionId[tokenAddress][actionId] = activationMinGovRatio;
        self.verifierStakeAmountByActionId[tokenAddress][actionId] = verifierStakeAmount;

        if (targetData.length == TARGET_DATA_MAX_LENGTH) {
            (string[] memory keys, string[] memory descriptions) =
                abi.decode(targetData[SLOT_VERIFICATION_INFO], (string[], string[]));
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
            self.verificationKeysByActionId[tokenAddress][actionId] = keys;
            self.verificationDescriptionsByActionId[tokenAddress][actionId] = descriptions;
        }

        self.createdRoundByActionId[tokenAddress][actionId] = IPhase(protocol.phaseAddress).currentPhase();

        _emitGroupActionCreated(self, tokenAddress, actionId);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function activateGroup(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external onlyGroupOwner(self, protocol, groupId) {
        _checkGroupConfig(config);

        if (self.createdRoundByActionId[tokenAddress][actionId] == 0) {
            revert IActionExecutorErrors.ActionNotCreated(tokenAddress, actionId);
        }

        GroupActionStorage.GroupState storage group = self.groupState[tokenAddress][actionId][groupId];
        if (group.active) {
            revert IGroupActionManagerErrors.GroupAlreadyActivated(groupId);
        }

        uint256 round = currentJoinRound(protocol.phaseAddress);
        _checkActivationMinGovRatio(self, protocol, tokenAddress, actionId, groupId);

        group.config = config;
        group.active = true;
        group.activatedRound = round;
        group.deactivatedRound = 0;
        self.descriptionHistoryByGroupId[tokenAddress][actionId][groupId].record(round, config.description);

        uint256 stakeAmount = self.activationStakeAmountByActionId[tokenAddress][actionId];
        self.activeGroupIdsByActionId[tokenAddress][actionId].add(groupId);
        self.stakedByActionId[tokenAddress][actionId] += stakeAmount;
        self.totalStaked[tokenAddress] += stakeAmount;
        self.stakedByMemberId[tokenAddress][groupId] += stakeAmount;
        self.tokenAddressesByGroupId[groupId].add(tokenAddress);
        self.actionIdsByGroupId[tokenAddress][groupId].add(actionId);
        self.activeActionIds[tokenAddress].add(actionId);

        if (stakeAmount != 0) {
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), stakeAmount);
        }

        _emitGroupActivated(tokenAddress, actionId, groupId, round, stakeAmount, config);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function deactivateGroup(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external onlyGroupOwner(self, protocol, groupId) {
        GroupActionStorage.GroupState storage group = self.groupState[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }

        uint256 round = currentJoinRound(protocol.phaseAddress);
        if (round == group.activatedRound) {
            revert IGroupActionManagerErrors.DeactivationLockedInActivatedRound(groupId, round);
        }

        uint256 stakeAmount = self.activationStakeAmountByActionId[tokenAddress][actionId];

        group.active = false;
        group.deactivatedRound = round;

        self.activeGroupIdsByActionId[tokenAddress][actionId].remove(groupId);
        self.stakedByActionId[tokenAddress][actionId] -= stakeAmount;
        self.totalStaked[tokenAddress] -= stakeAmount;
        self.stakedByMemberId[tokenAddress][groupId] -= stakeAmount;
        self.actionIdsByGroupId[tokenAddress][groupId].remove(actionId);
        if (self.actionIdsByGroupId[tokenAddress][groupId].count() == 0) {
            self.tokenAddressesByGroupId[groupId].remove(tokenAddress);
        }
        if (self.activeGroupIdsByActionId[tokenAddress][actionId].count() == 0) {
            self.activeActionIds[tokenAddress].remove(actionId);
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

    function setGroupConfig(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external onlyGroupOwner(self, protocol, groupId) {
        _checkGroupConfig(config);

        GroupActionStorage.GroupState storage group = self.groupState[tokenAddress][actionId][groupId];
        if (!group.active) {
            revert IGroupActionManagerErrors.GroupNotActive(groupId);
        }

        GroupConfig memory previousConfig = group.config;

        uint256 round = currentJoinRound(protocol.phaseAddress);
        group.config = config;
        self.descriptionHistoryByGroupId[tokenAddress][actionId][groupId].record(round, config.description);

        _emitGroupConfigChanged(tokenAddress, actionId, round, groupId, previousConfig, config);
    }

    function groupState(
        GroupActionStorage.Layout storage self,
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
        GroupActionStorage.GroupState storage group = self.groupState[tokenAddress][actionId][groupId];
        return (group.config, group.active, group.activatedRound, group.deactivatedRound);
    }

    function descriptionByRound(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory) {
        return self.descriptionHistoryByGroupId[tokenAddress][actionId][groupId].value(round);
    }

    function activeGroupIds(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount) {
        return self.activeGroupIdsByActionId[tokenAddress][actionId].values(offset, limit, reverse);
    }

    function isGroupActive(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external view returns (bool) {
        return self.groupState[tokenAddress][actionId][groupId].active;
    }

    function maxJoinAmount(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _maxJoinAmount(self, protocol, tokenAddress, actionId);
    }

    function staked(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return self.stakedByActionId[tokenAddress][actionId];
    }

    function totalStaked(
        GroupActionStorage.Layout storage self,
        address tokenAddress
    ) external view returns (uint256) {
        return self.totalStaked[tokenAddress];
    }

    function stakedByMemberId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 memberId
    ) external view returns (uint256) {
        return self.stakedByMemberId[tokenAddress][memberId];
    }

    function tokenAddressesByGroupId(
        GroupActionStorage.Layout storage self,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (address[] memory tokenAddresses, uint256 totalCount) {
        return self.tokenAddressesByGroupId[groupId].values(offset, limit, reverse);
    }

    function actionIdsByGroupId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return self.actionIdsByGroupId[tokenAddress][groupId].values(offset, limit, reverse);
    }

    function actionIdsWithActiveGroups(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return self.activeActionIds[tokenAddress].values(offset, limit, reverse);
    }

    function hasActiveGroups(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 memberId
    ) external view returns (bool) {
        return self.actionIdsByGroupId[tokenAddress][memberId].count() != 0;
    }

    function _maxJoinAmount(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId
    ) internal view returns (uint256) {
        uint256 round = ActionRoundAxis.joinRound(protocol.phaseAddress);
        if (round == 0) {
            return 0;
        }
        uint256 totalVoteAmount = IVote(protocol.voteAddress).totalVoteAmount(tokenAddress, round);
        if (totalVoteAmount == 0) {
            return 0;
        }
        uint256 actionVoteAmount = IVote(protocol.voteAddress).voteAmountByProposalId(tokenAddress, round, actionId);
        if (actionVoteAmount == 0) {
            return 0;
        }
        uint256 totalMinted = IERC20(self.joinTokenAddressByActionId[tokenAddress][actionId]).totalSupply();
        uint256 baseAmount = Math.mulDiv(
            totalMinted,
            self.maxJoinAmountRatioByActionId[tokenAddress][actionId],
            GroupActionStorage.PRECISION
        );
        return Math.mulDiv(baseAmount, actionVoteAmount, totalVoteAmount);
    }

    function _checkGroupConfig(GroupConfig calldata config) internal pure {
        if (config.minJoinAmount == 0) {
            revert IGroupActionManagerErrors.ZeroMinJoinAmount();
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

    function _checkActivationMinGovRatio(
        GroupActionStorage.Layout storage self,
        GroupActionStorage.Protocol memory protocol,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) internal view {
        uint256 minGovRatio = self.activationMinGovRatioByActionId[tokenAddress][actionId];
        if (minGovRatio == 0) {
            return;
        }

        IStake stake = IStake(protocol.stakeAddress);
        uint256 currentPhase = IPhase(protocol.phaseAddress).currentPhase();
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
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 actionId
    ) private {
        emit IGroupActionExecutorEvents.GroupActionCreated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            joinTokenAddress: self.joinTokenAddressByActionId[tokenAddress][actionId],
            activationStakeAmount: self.activationStakeAmountByActionId[tokenAddress][actionId],
            maxJoinAmountRatio: self.maxJoinAmountRatioByActionId[tokenAddress][actionId],
            activationMinGovRatio: self.activationMinGovRatioByActionId[tokenAddress][actionId],
            verifierStakeAmount: self.verifierStakeAmountByActionId[tokenAddress][actionId],
            verificationKeys: self.verificationKeysByActionId[tokenAddress][actionId],
            verificationDescriptions: self.verificationDescriptionsByActionId[tokenAddress][actionId]
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

    function currentJoinRound(address phaseAddress) internal view returns (uint256) {
        uint256 round = ActionRoundAxis.joinRound(phaseAddress);
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    function _emitGroupActivated(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 round,
        uint256 stakeAmount,
        GroupConfig calldata config
    ) private {
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
}
