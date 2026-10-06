// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupManager} from "./interface/IGroupManager.sol";
import {
    IExtensionGroupActionFactory
} from "./interface/IExtensionGroupActionFactory.sol";
import {IGroupAction} from "./interface/IGroupAction.sol";
import {ILOVE20Stake} from "@core/interfaces/ILOVE20Stake.sol";
import {ILOVE20Join} from "@core/interfaces/ILOVE20Join.sol";
import {ILOVE20Vote} from "@core/interfaces/ILOVE20Vote.sol";
import {IExtension} from "@extension/src/interface/IExtension.sol";
import {IExtensionCenter} from "@extension/src/interface/IExtensionCenter.sol";
import {RoundHistoryString} from "@extension/src/lib/RoundHistoryString.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract GroupManager is IGroupManager {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using RoundHistoryString for RoundHistoryString.History;

    uint256 public constant PRECISION = 1e18;

    IExtensionGroupActionFactory internal _factory;
    IExtensionCenter internal _center;
    IERC721Enumerable internal _group;
    ILOVE20Stake internal _stake;
    ILOVE20Vote internal _vote;
    ILOVE20Join internal _join;

    address public FACTORY_ADDRESS;
    bool internal _initialized;
    // extension => groupId => GroupInfo
    mapping(address => mapping(uint256 => GroupInfo)) internal _groupInfo;
    // extension => groupId => descriptionHistory
    mapping(address => mapping(uint256 => RoundHistoryString.History))
        internal _descriptionHistory;
    // extension => activeGroupIds
    mapping(address => EnumerableSet.UintSet) internal _activeGroupIds;
    // extension => staked
    mapping(address => uint256) internal _staked;
    // tokenAddress => totalStaked
    mapping(address => uint256) internal _totalStaked;
    // tokenAddress => groupId => extensions
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet))
        internal _extensionsByActivatedGroupId;
    // tokenAddress => extensions
    mapping(address => EnumerableSet.AddressSet)
        internal _extensionsWithGroupActivation;
    // groupId => tokenAddresses
    mapping(uint256 => EnumerableSet.AddressSet)
        internal _tokenAddressesByGroupId;

    constructor() {}

    modifier onlyGroupOwner(uint256 groupId) {
        if (_group.ownerOf(groupId) != msg.sender) revert OnlyGroupOwner();
        _;
    }

    modifier onlyValidExtension(address extension) {
        if (!_factory.exists(extension)) {
            revert NotRegisteredExtensionInFactory();
        }
        _;
    }

    function initialize(address factory_) external {
        require(_initialized == false, "Already initialized");
        require(factory_ != address(0), "Invalid factory");

        FACTORY_ADDRESS = factory_;
        _factory = IExtensionGroupActionFactory(factory_);
        _center = IExtensionCenter(_factory.CENTER_ADDRESS());
        _group = IERC721Enumerable(_factory.GROUP_ADDRESS());
        _stake = ILOVE20Stake(_center.stakeAddress());
        _vote = ILOVE20Vote(_center.voteAddress());
        _join = ILOVE20Join(_center.joinAddress());

        _initialized = true;
    }

    function activateGroup(
        address extension,
        uint256 groupId,
        string memory description,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount_,
        uint256 maxAccounts_
    ) external onlyGroupOwner(groupId) onlyValidExtension(extension) {
        IExtension(extension).initializeIfNeeded();

        // Check min gov ratio for activation
        _validateActivationMinGovRatio(extension);

        uint256 currentRound = _join.currentRound();

        _activateGroup(
            extension,
            groupId,
            description,
            maxCapacity,
            minJoinAmount,
            maxJoinAmount_,
            maxAccounts_,
            currentRound
        );

        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 stakeAmount = IGroupAction(extension).ACTIVATION_STAKE_AMOUNT();

        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            stakeAmount
        );

        emit ActivateGroup({
            tokenAddress: tokenAddress,
            actionId: IExtension(extension).actionId(),
            round: currentRound,
            groupId: groupId,
            owner: msg.sender,
            stakeAmount: stakeAmount
        });
    }

    function deactivateGroup(
        address extension,
        uint256 groupId
    ) external onlyGroupOwner(groupId) onlyValidExtension(extension) {
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();

        GroupInfo storage group = _groupInfo[extension][groupId];

        if (!group.isActive) revert GroupNotActive();

        uint256 currentRound = _join.currentRound();
        if (currentRound == group.activatedRound)
            revert CannotDeactivateInActivatedRound();

        group.isActive = false;
        group.deactivatedRound = currentRound;

        _activeGroupIds[extension].remove(groupId);

        _extensionsByActivatedGroupId[tokenAddress][groupId].remove(extension);
        if (
            _extensionsByActivatedGroupId[tokenAddress][groupId].length() == 0
        ) {
            _tokenAddressesByGroupId[groupId].remove(tokenAddress);
        }
        if (_activeGroupIds[extension].length() == 0) {
            _extensionsWithGroupActivation[tokenAddress].remove(extension);
        }

        IGroupAction ext = IGroupAction(extension);
        uint256 stakedAmount = ext.ACTIVATION_STAKE_AMOUNT();
        _staked[extension] -= stakedAmount;
        _totalStaked[tokenAddress] -= stakedAmount;
        IERC20(IExtension(extension).TOKEN_ADDRESS()).safeTransfer(
            msg.sender,
            stakedAmount
        );

        emit DeactivateGroup({
            tokenAddress: tokenAddress,
            actionId: actionId,
            round: currentRound,
            groupId: groupId,
            owner: msg.sender,
            stakeAmount: stakedAmount
        });
    }

    function updateGroupInfo(
        address extension,
        uint256 groupId,
        string memory newDescription,
        uint256 newMaxCapacity,
        uint256 newMinJoinAmount,
        uint256 newMaxJoinAmount,
        uint256 newMaxAccounts
    ) external onlyGroupOwner(groupId) onlyValidExtension(extension) {
        GroupInfo storage group = _groupInfo[extension][groupId];
        if (!group.isActive) revert GroupNotActive();

        uint256 currentRound = _join.currentRound();
        _updateGroupInfoFields(
            extension,
            groupId,
            newDescription,
            newMaxCapacity,
            newMinJoinAmount,
            newMaxJoinAmount,
            newMaxAccounts,
            currentRound
        );
    }

    function groupInfo(
        address extension,
        uint256 groupId
    ) external view returns (GroupInfo memory) {
        return _groupInfo[extension][groupId];
    }

    function descriptionByRound(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory) {
        return _descriptionHistory[extension][groupId].value(round);
    }

    function activeGroupIdsByOwner(
        address extension,
        address owner
    ) public view returns (uint256[] memory) {
        uint256 nftBalance = _group.balanceOf(owner);
        uint256[] memory result = new uint256[](nftBalance);
        uint256 count;

        for (uint256 i; i < nftBalance; ) {
            uint256 gId = _group.tokenOfOwnerByIndex(owner, i);
            if (_groupInfo[extension][gId].isActive) {
                result[count] = gId;
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (count == 0) return new uint256[](0);

        assembly {
            mstore(result, count)
        }
        return result;
    }

    function activeGroupIds(
        address extension
    ) external view returns (uint256[] memory) {
        return _activeGroupIds[extension].values();
    }

    function activeGroupIdsCount(
        address extension
    ) external view returns (uint256) {
        return _activeGroupIds[extension].length();
    }

    function activeGroupIdsAtIndex(
        address extension,
        uint256 index
    ) external view returns (uint256 groupId) {
        return _activeGroupIds[extension].at(index);
    }

    function isGroupActive(
        address extension,
        uint256 groupId
    ) external view returns (bool) {
        return _groupInfo[extension][groupId].isActive;
    }

    function hasActiveGroups(
        address tokenAddress,
        address owner
    ) external view returns (bool) {
        uint256 balance = _group.balanceOf(owner);

        for (uint256 i = 0; i < balance; ) {
            uint256 groupId = _group.tokenOfOwnerByIndex(owner, i);
            if (
                _extensionsByActivatedGroupId[tokenAddress][groupId].length() >
                0
            ) {
                return true;
            }
            unchecked {
                ++i;
            }
        }

        return false;
    }

    function actionIdsByGroupId(
        address tokenAddress,
        uint256 groupId
    ) public view returns (uint256[] memory) {
        address[] memory extensions = _extensionsByActivatedGroupId[
            tokenAddress
        ][groupId].values();
        return _actionIdsFromExtensions(extensions);
    }

    function actionIdsByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256) {
        return _extensionsByActivatedGroupId[tokenAddress][groupId].length();
    }

    function actionIdsByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (uint256) {
        address extension = _extensionsByActivatedGroupId[tokenAddress][groupId]
            .at(index);
        return IExtension(extension).actionId();
    }

    function actionIds(
        address tokenAddress
    ) public view returns (uint256[] memory) {
        address[] memory extensions = _extensionsWithGroupActivation[
            tokenAddress
        ].values();
        return _actionIdsFromExtensions(extensions);
    }

    function actionIdsCount(
        address tokenAddress
    ) external view returns (uint256) {
        return _extensionsWithGroupActivation[tokenAddress].length();
    }

    function actionIdsAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256) {
        address extension = _extensionsWithGroupActivation[tokenAddress].at(
            index
        );
        return IExtension(extension).actionId();
    }

    function maxJoinAmount(address extension) public view returns (uint256) {
        IGroupAction ext = IGroupAction(extension);
        address joinTokenAddress = ext.JOIN_TOKEN_ADDRESS();
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 actionId = IExtension(extension).actionId();
        uint256 round = _join.currentRound();

        uint256 totalVotes = _vote.votesNum(tokenAddress, round);
        if (totalVotes == 0) return 0;

        uint256 actionVotes = _vote.votesNumByActionId(
            tokenAddress,
            round,
            actionId
        );
        if (actionVotes == 0) return 0;

        uint256 voteRate = (actionVotes * PRECISION) / totalVotes;

        uint256 totalMinted = IERC20(joinTokenAddress).totalSupply();
        uint256 baseAmount = (totalMinted * ext.MAX_JOIN_AMOUNT_RATIO()) /
            PRECISION;
        return (baseAmount * voteRate) / PRECISION;
    }

    function stakedByOwner(
        address extension,
        address owner
    ) public view returns (uint256 amount) {
        uint256[] memory activeIds = activeGroupIdsByOwner(extension, owner);
        if (activeIds.length == 0) return 0;

        uint256 stakeAmount = IGroupAction(extension).ACTIVATION_STAKE_AMOUNT();
        return activeIds.length * stakeAmount;
    }

    function staked(address extension) public view returns (uint256) {
        return _staked[extension];
    }

    function totalStaked(address tokenAddress) public view returns (uint256) {
        return _totalStaked[tokenAddress];
    }

    function totalStakedByOwner(
        address tokenAddress,
        address owner
    ) public view returns (uint256 total) {
        uint256 nftBalance = _group.balanceOf(owner);
        if (nftBalance == 0) return 0;

        for (uint256 i; i < nftBalance; ) {
            uint256 groupId = _group.tokenOfOwnerByIndex(owner, i);
            EnumerableSet.AddressSet
                storage extensions = _extensionsByActivatedGroupId[
                    tokenAddress
                ][groupId];
            uint256 extCount = extensions.length();

            for (uint256 j; j < extCount; ) {
                total += IGroupAction(extensions.at(j))
                    .ACTIVATION_STAKE_AMOUNT();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        return total;
    }

    function tokenAddressesByGroupId(
        uint256 groupId
    ) external view returns (address[] memory) {
        return _tokenAddressesByGroupId[groupId].values();
    }

    function tokenAddressesByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256) {
        return _tokenAddressesByGroupId[groupId].length();
    }

    function tokenAddressesByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address) {
        return _tokenAddressesByGroupId[groupId].at(index);
    }

    function _actionIdsFromExtensions(
        address[] memory extensions
    ) internal view returns (uint256[] memory) {
        uint256[] memory actionIds_ = new uint256[](extensions.length);

        for (uint256 i; i < extensions.length; ) {
            actionIds_[i] = IExtension(extensions[i]).actionId();
            unchecked {
                ++i;
            }
        }

        return actionIds_;
    }

    function _updateGroupInfoFields(
        address extension,
        uint256 groupId,
        string memory description,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount_,
        uint256 maxAccounts_,
        uint256 currentRound
    ) internal {
        if (minJoinAmount == 0) {
            revert InvalidMinMaxJoinAmount();
        }
        if (maxJoinAmount_ != 0 && maxJoinAmount_ < minJoinAmount) {
            revert InvalidMinMaxJoinAmount();
        }

        GroupInfo storage group = _groupInfo[extension][groupId];
        group.description = description;
        group.maxCapacity = maxCapacity;
        group.minJoinAmount = minJoinAmount;
        group.maxJoinAmount = maxJoinAmount_;
        group.maxAccounts = maxAccounts_;

        _descriptionHistory[extension][groupId].record(
            currentRound,
            description
        );

        emit UpdateGroupInfo({
            tokenAddress: IExtension(extension).TOKEN_ADDRESS(),
            actionId: IExtension(extension).actionId(),
            round: currentRound,
            groupId: groupId,
            description: description,
            maxCapacity: maxCapacity,
            minJoinAmount: minJoinAmount,
            maxJoinAmount: maxJoinAmount_,
            maxAccounts: maxAccounts_
        });
    }

    function _activateGroup(
        address extension,
        uint256 groupId,
        string memory description,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount_,
        uint256 maxAccounts_,
        uint256 currentRound
    ) internal {
        GroupInfo storage group = _groupInfo[extension][groupId];
        if (group.isActive) revert GroupAlreadyActivated();

        _updateGroupInfoFields(
            extension,
            groupId,
            description,
            maxCapacity,
            minJoinAmount,
            maxJoinAmount_,
            maxAccounts_,
            currentRound
        );

        group.groupId = groupId;
        group.activatedRound = currentRound;
        group.isActive = true;
        group.deactivatedRound = 0;

        IGroupAction ext = IGroupAction(extension);
        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 stakeAmount = ext.ACTIVATION_STAKE_AMOUNT();

        _activeGroupIds[extension].add(groupId);
        _staked[extension] += stakeAmount;
        _totalStaked[tokenAddress] += stakeAmount;
        _extensionsByActivatedGroupId[tokenAddress][groupId].add(extension);
        _extensionsWithGroupActivation[tokenAddress].add(extension);
        _tokenAddressesByGroupId[groupId].add(tokenAddress);
    }

    function _validateActivationMinGovRatio(address extension) internal view {
        uint256 minGovRatio = IGroupAction(extension)
            .ACTIVATION_MIN_GOV_RATIO();
        if (minGovRatio == 0) return; // Skip check if no minimum required

        address tokenAddress = IExtension(extension).TOKEN_ADDRESS();
        uint256 totalGovVotes = _stake.govVotesNum(tokenAddress);
        if (totalGovVotes == 0) revert NoGovVotes();

        uint256 ownerGovVotes = _stake.validGovVotes(tokenAddress, msg.sender);
        uint256 ownerGovRatio = (ownerGovVotes * PRECISION) / totalGovVotes;

        if (ownerGovRatio < minGovRatio)
            revert InsufficientActivationMinGovRatio();
    }
}
