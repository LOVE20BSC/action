// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupManager} from "./interface/IGroupManager.sol";
import {IGroupAction} from "./interface/IGroupAction.sol";
import {IGroupVerify} from "./interface/IGroupVerify.sol";
import {
    IExtensionGroupActionFactory
} from "./interface/IExtensionGroupActionFactory.sol";
import {
    IExtensionGroupServiceFactory
} from "./interface/IExtensionGroupServiceFactory.sol";
import {IGroupService} from "./interface/IGroupService.sol";
import {IGroupRecipients} from "./interface/IGroupRecipients.sol";
import {
    ExtensionBaseRewardJoin
} from "@extension/src/ExtensionBaseRewardJoin.sol";
import {ExtensionBase} from "@extension/src/ExtensionBase.sol";
import {IReward} from "@extension/src/interface/IReward.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {ILOVE20Stake} from "@core/interfaces/ILOVE20Stake.sol";

contract ExtensionGroupService is ExtensionBaseRewardJoin, IGroupService {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;

    address public immutable GROUP_ACTION_TOKEN_ADDRESS;
    address public immutable GROUP_ACTION_FACTORY_ADDRESS;
    uint256 public immutable GOV_RATIO_MULTIPLIER;

    IGroupRecipients internal immutable _groupRecipients;
    IGroupManager internal immutable _groupManager;
    IERC721Enumerable internal immutable _group;
    IGroupVerify internal immutable _groupVerify;
    IExtensionGroupActionFactory internal immutable _actionFactory;
    ILOVE20Stake internal immutable _stake;

    /// @dev round => account => gov ratio at claim time
    mapping(uint256 => mapping(address => uint256)) internal _govRatio;

    constructor(
        address factory_,
        address groupActionFactoryAddress_,
        address tokenAddress_,
        address groupActionTokenAddress_,
        uint256 govRatioMultiplier_
    ) ExtensionBaseRewardJoin(factory_, tokenAddress_) {
        GROUP_ACTION_TOKEN_ADDRESS = groupActionTokenAddress_;
        GROUP_ACTION_FACTORY_ADDRESS = groupActionFactoryAddress_;
        GOV_RATIO_MULTIPLIER = govRatioMultiplier_;
        _groupRecipients = IGroupRecipients(
            IExtensionGroupServiceFactory(factory_).GROUP_RECIPIENTS_ADDRESS()
        );

        _actionFactory = IExtensionGroupActionFactory(
            groupActionFactoryAddress_
        );
        _groupManager = IGroupManager(_actionFactory.GROUP_MANAGER_ADDRESS());
        _group = IERC721Enumerable(_actionFactory.GROUP_ADDRESS());
        _groupVerify = IGroupVerify(_actionFactory.GROUP_VERIFY_ADDRESS());
        _stake = ILOVE20Stake(_center.stakeAddress());
    }

    function join(
        string[] memory verificationInfos
    ) public override(ExtensionBaseRewardJoin) {
        if (
            !_groupManager.hasActiveGroups(
                GROUP_ACTION_TOKEN_ADDRESS,
                msg.sender
            )
        ) revert NoActiveGroups();
        super.join(verificationInfos);
    }

    function _checkActionId(
        uint256 actionId_
    ) internal view returns (address extension) {
        extension = _center.extension(GROUP_ACTION_TOKEN_ADDRESS, actionId_);
        if (!_actionFactory.exists(extension)) revert InvalidExtension();
        return extension;
    }

    function rewardByRecipient(
        address verifier,
        uint256 round,
        uint256 actionId_,
        uint256 groupId,
        address recipient
    ) external view returns (uint256) {
        uint256 groupReward = _scaledGroupReward(
            verifier,
            round,
            actionId_,
            groupId
        );
        if (groupReward == 0) return 0;

        (address[] memory addrs, uint256[] memory ratios, ) = _groupRecipients
            .recipients(
                verifier,
                GROUP_ACTION_TOKEN_ADDRESS,
                actionId_,
                groupId,
                round
            );

        if (recipient == verifier) {
            uint256 distributed;
            for (uint256 i; i < addrs.length; ) {
                distributed += (groupReward * ratios[i]) / PRECISION;
                unchecked {
                    ++i;
                }
            }
            return groupReward - distributed;
        }

        for (uint256 i; i < addrs.length; ) {
            if (addrs[i] == recipient) {
                return (groupReward * ratios[i]) / PRECISION;
            }
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    function rewardDistribution(
        address verifier,
        uint256 round,
        uint256 actionId_,
        uint256 groupId
    )
        external
        view
        returns (
            address[] memory addrs,
            uint256[] memory ratios,
            uint256[] memory amounts,
            uint256 ownerAmount
        )
    {
        uint256 groupReward = _scaledGroupReward(
            verifier,
            round,
            actionId_,
            groupId
        );
        (addrs, ratios, amounts, ownerAmount) = _groupRecipients
            .getDistribution(
                verifier,
                GROUP_ACTION_TOKEN_ADDRESS,
                actionId_,
                groupId,
                groupReward,
                round
            );
    }

    function joinedAmountTokenAddress()
        external
        view
        override(ExtensionBase)
        returns (address)
    {
        return GROUP_ACTION_TOKEN_ADDRESS;
    }

    function joinedAmount()
        external
        view
        override(ExtensionBase)
        returns (uint256)
    {
        return _groupManager.totalStaked(GROUP_ACTION_TOKEN_ADDRESS);
    }

    function joinedAmountByAccount(
        address account
    ) external view override(ExtensionBase) returns (uint256) {
        return
            _groupManager.totalStakedByOwner(
                GROUP_ACTION_TOKEN_ADDRESS,
                account
            );
    }

    function hasActiveGroups(address owner) public view returns (bool) {
        return _groupManager.hasActiveGroups(GROUP_ACTION_TOKEN_ADDRESS, owner);
    }

    function govRatio(
        uint256 round,
        address account
    ) external view returns (uint256 ratio, bool claimed) {
        claimed = _claimedByAccount[round][account];
        if (claimed) {
            ratio = _govRatio[round][account];
        } else {
            ratio = _calculateGovRatio(account);
        }
    }

    function generatedActionRewardByVerifier(
        address verifier,
        uint256 round
    ) public view override returns (uint256 amount) {
        uint256[] memory actionIds_ = _groupVerify.actionIdsByVerifier(
            GROUP_ACTION_TOKEN_ADDRESS,
            round,
            verifier
        );
        for (uint256 i; i < actionIds_.length; ) {
            address ext = _center.extension(
                GROUP_ACTION_TOKEN_ADDRESS,
                actionIds_[i]
            );
            amount += IGroupAction(ext).generatedActionRewardByVerifier(
                verifier,
                round
            );
            unchecked {
                ++i;
            }
        }
    }

    function generatedActionReward(
        uint256 round
    ) public view returns (uint256) {
        uint256[] memory actionIds_ = _groupVerify.actionIds(
            GROUP_ACTION_TOKEN_ADDRESS,
            round
        );
        uint256 totalReward;
        for (uint256 i; i < actionIds_.length; ) {
            address ext = _center.extension(
                GROUP_ACTION_TOKEN_ADDRESS,
                actionIds_[i]
            );
            totalReward += IReward(ext).reward(round);
            unchecked {
                ++i;
            }
        }
        return totalReward;
    }

    function _getRewardContext(
        uint256 round
    )
        internal
        view
        returns (uint256 totalServiceReward, uint256 totalActionReward)
    {
        totalServiceReward = reward(round);
        totalActionReward = generatedActionReward(round);
    }

    /// @return Account's gov ratio (1e18): govValid / govTotal; 0 if govTotal==0
    function _calculateGovRatio(
        address account
    ) internal view returns (uint256) {
        uint256 govTotal = _stake.govVotesNum(GROUP_ACTION_TOKEN_ADDRESS);
        if (govTotal == 0) return 0;
        uint256 govValid = _stake.validGovVotes(
            GROUP_ACTION_TOKEN_ADDRESS,
            account
        );
        return (govValid * PRECISION) / govTotal;
    }

    function _calculateReward(
        uint256 round,
        address account
    ) internal view override returns (uint256 mintReward, uint256 burnReward) {
        if (
            !_center.isAccountJoinedByRound(
                TOKEN_ADDRESS,
                actionId,
                account,
                round
            )
        ) return (0, 0);

        (
            uint256 totalServiceReward,
            uint256 totalActionReward
        ) = _getRewardContext(round);
        if (totalServiceReward == 0 || totalActionReward == 0) return (0, 0);

        uint256 generatedByVerifier = generatedActionRewardByVerifier(
            account,
            round
        );
        if (generatedByVerifier == 0) return (0, 0);

        uint256 rewardRatio = (generatedByVerifier * PRECISION) /
            totalActionReward;
        uint256 theoryReward = (totalServiceReward * rewardRatio) / PRECISION;
        uint256 govRatioCap = GOV_RATIO_MULTIPLIER == 0
            ? 0
            : _calculateGovRatio(account) * GOV_RATIO_MULTIPLIER;
        uint256 effectiveRatio = GOV_RATIO_MULTIPLIER == 0
            ? rewardRatio
            : (rewardRatio < govRatioCap ? rewardRatio : govRatioCap);
        mintReward = (totalServiceReward * effectiveRatio) / PRECISION;
        burnReward = theoryReward - mintReward;
        return (mintReward, burnReward);
    }

    /// @dev Group reward scaled by verifier's mintReward/theoryReward so distribution does not exceed mint.
    ///      Uses stored mint/burn when round already claimed by verifier.
    function _scaledGroupReward(
        address verifier,
        uint256 round,
        uint256 actionId_,
        uint256 groupId
    ) internal view returns (uint256) {
        (
            uint256 totalServiceReward,
            uint256 totalActionReward
        ) = _getRewardContext(round);
        return
            _scaledGroupRewardWithContext(
                verifier,
                round,
                actionId_,
                groupId,
                totalServiceReward,
                totalActionReward
            );
    }

    function _scaledGroupRewardWithContext(
        address verifier,
        uint256 round,
        uint256 actionId_,
        uint256 groupId,
        uint256 totalServiceReward,
        uint256 totalActionReward
    ) internal view returns (uint256) {
        // Theory-based group share (no gov cap): totalServiceReward * groupActionReward / totalActionReward
        if (totalServiceReward == 0 || totalActionReward == 0) return 0;

        address extension = _checkActionId(actionId_);
        if (
            _groupVerify.verifierByGroupId(extension, round, groupId) !=
            verifier
        ) return 0;
        uint256 groupActionReward = IGroupAction(extension)
            .generatedActionRewardByGroupId(round, groupId);
        if (groupActionReward == 0) return 0;
        uint256 theoryGroupReward = (totalServiceReward * groupActionReward) /
            totalActionReward;
        if (theoryGroupReward == 0) return 0;

        // Verifier's mint vs theory (use stored if already claimed)
        uint256 mintReward;
        uint256 burnReward;
        if (_claimedByAccount[round][verifier]) {
            mintReward = _mintedRewardByAccount[round][verifier];
            burnReward = _burnedRewardByAccount[round][verifier];
        } else {
            (mintReward, burnReward) = _calculateReward(round, verifier);
        }
        uint256 theoryReward = mintReward + burnReward;
        if (theoryReward == 0) return 0;

        return (theoryGroupReward * mintReward) / theoryReward;
    }

    function _claimReward(
        uint256 round
    ) internal override returns (uint256 mintReward, uint256 burnReward) {
        if (_claimedByAccount[round][msg.sender]) {
            revert AlreadyClaimed();
        }

        (mintReward, burnReward) = _calculateReward(round, msg.sender);

        _claimedByAccount[round][msg.sender] = true;
        _mintedRewardByAccount[round][msg.sender] = mintReward;
        _burnedRewardByAccount[round][msg.sender] = burnReward;
        _govRatio[round][msg.sender] = _calculateGovRatio(msg.sender);

        // Burn overflow reward first
        if (burnReward > 0) {
            ILOVE20Token(TOKEN_ADDRESS).burn(burnReward);
        }

        uint256 distributed;
        uint256 remaining;
        if (mintReward > 0) {
            distributed = _distributeToRecipients(round);
            remaining = mintReward - distributed;
            if (remaining > 0)
                IERC20(TOKEN_ADDRESS).safeTransfer(msg.sender, remaining);
        }

        emit ClaimReward({
            tokenAddress: TOKEN_ADDRESS,
            round: round,
            actionId: actionId,
            account: msg.sender,
            mintAmount: mintReward,
            burnAmount: burnReward
        });
        emit ClaimRewardDistribution({
            tokenAddress: TOKEN_ADDRESS,
            round: round,
            actionId: actionId,
            account: msg.sender,
            mintAmount: mintReward,
            burnAmount: burnReward,
            distributed: distributed,
            remaining: remaining
        });
        return (mintReward, burnReward);
    }

    /// @notice Distributes rewards to all configured recipients for the caller
    /// @dev Iterates through all actionIds and groupIds where caller has set recipients,
    ///      calculates each group's reward share, and transfers to recipients based on ratios
    /// @param round The round to distribute rewards for
    /// @return distributed Total amount distributed to recipients
    function _distributeToRecipients(
        uint256 round
    ) internal returns (uint256 distributed) {
        (
            uint256 totalServiceReward,
            uint256 totalActionReward
        ) = _getRewardContext(round);
        if (totalServiceReward == 0 || totalActionReward == 0) return 0;

        address account = msg.sender;
        address actionToken = GROUP_ACTION_TOKEN_ADDRESS;

        uint256[] memory aids = _groupRecipients.actionIdsWithRecipients(
            account,
            actionToken,
            round
        );
        uint256 aidsLength = aids.length;
        for (uint256 i; i < aidsLength; ) {
            uint256[] memory gids = _groupRecipients
                .groupIdsByActionIdWithRecipients(
                    account,
                    actionToken,
                    aids[i],
                    round
                );
            uint256 gidsLength = gids.length;
            for (uint256 j; j < gidsLength; ) {
                distributed += _distributeForGroup(
                    round,
                    aids[i],
                    gids[j],
                    totalServiceReward,
                    totalActionReward
                );
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _distributeForGroup(
        uint256 round,
        uint256 actionId_,
        uint256 groupId,
        uint256 totalServiceReward,
        uint256 totalActionReward
    ) internal returns (uint256 distributed) {
        uint256 groupReward = _scaledGroupRewardWithContext(
            msg.sender,
            round,
            actionId_,
            groupId,
            totalServiceReward,
            totalActionReward
        );
        if (groupReward == 0) return 0;

        (
            address[] memory addrs,
            ,
            uint256[] memory amounts,

        ) = _groupRecipients.getDistribution(
                msg.sender,
                GROUP_ACTION_TOKEN_ADDRESS,
                actionId_,
                groupId,
                groupReward,
                round
            );

        uint256 len = addrs.length;
        IERC20 token = IERC20(TOKEN_ADDRESS);
        for (uint256 i; i < len; ) {
            if (amounts[i] > 0) {
                token.safeTransfer(addrs[i], amounts[i]);
                distributed += amounts[i];
                emit DistributeRecipient({
                    tokenAddress: TOKEN_ADDRESS,
                    round: round,
                    actionId: actionId_,
                    groupId: groupId,
                    account: msg.sender,
                    recipient: addrs[i],
                    amount: amounts[i]
                });
            }
            unchecked {
                ++i;
            }
        }
    }
}
