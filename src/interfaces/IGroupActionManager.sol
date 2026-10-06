// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IGroupManagerEvents {
    event ActivateGroup(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        address owner,
        uint256 stakeAmount
    );
    event DeactivateGroup(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        address owner,
        uint256 stakeAmount
    );
    event UpdateGroupInfo(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        string description,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount,
        uint256 maxAccounts
    );
}

interface IGroupManagerErrors {
    error GroupAlreadyActivated();
    error GroupNotActive();
    error InvalidMinMaxJoinAmount();
    error CannotDeactivateInActivatedRound();
    error OnlyGroupOwner();
    error NotRegisteredExtensionInFactory();
    error InsufficientActivationMinGovRatio();
    error NoGovVotes();
}

interface IGroupManager is IGroupManagerEvents, IGroupManagerErrors {
    struct GroupInfo {
        uint256 groupId;
        string description;
        uint256 maxCapacity; // 0 = use owner's theoretical max capacity
        uint256 minJoinAmount;
        uint256 maxJoinAmount; // 0 = no limit
        uint256 maxAccounts; // 0 = no limit
        bool isActive;
        uint256 activatedRound; // 0 = not activated
        uint256 deactivatedRound; // 0 = not deactivated
    }

    function FACTORY_ADDRESS() external view returns (address);

    /// @notice Returns the precision constant (1e18) used for ratio and factor calculations
    function PRECISION() external view returns (uint256);

    function initialize(address factory_) external;

    function activateGroup(
        address extension,
        uint256 groupId,
        string memory description,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount,
        uint256 maxAccounts_
    ) external;

    function deactivateGroup(address extension, uint256 groupId) external;

    function updateGroupInfo(
        address extension,
        uint256 groupId,
        string memory newDescription,
        uint256 newMaxCapacity,
        uint256 newMinJoinAmount,
        uint256 newMaxJoinAmount,
        uint256 newMaxAccounts
    ) external;

    function groupInfo(
        address extension,
        uint256 groupId
    ) external view returns (GroupInfo memory);

    function descriptionByRound(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory);

    function activeGroupIdsByOwner(
        address extension,
        address owner
    ) external view returns (uint256[] memory);

    function activeGroupIds(
        address extension
    ) external view returns (uint256[] memory);

    function activeGroupIdsCount(
        address extension
    ) external view returns (uint256);

    function activeGroupIdsAtIndex(
        address extension,
        uint256 index
    ) external view returns (uint256 groupId);

    function isGroupActive(
        address extension,
        uint256 groupId
    ) external view returns (bool);

    function maxJoinAmount(address extension) external view returns (uint256);

    function stakedByOwner(
        address extension,
        address owner
    ) external view returns (uint256);

    function staked(address extension) external view returns (uint256);

    function totalStaked(address tokenAddress) external view returns (uint256);
    function totalStakedByOwner(
        address tokenAddress,
        address owner
    ) external view returns (uint256);

    function tokenAddressesByGroupId(
        uint256 groupId
    ) external view returns (address[] memory);

    function tokenAddressesByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256);

    function tokenAddressesByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address);

    function actionIdsByGroupId(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256[] memory);

    function actionIdsByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256);

    function actionIdsByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (uint256);

    function actionIds(
        address tokenAddress
    ) external view returns (uint256[] memory);

    function actionIdsCount(
        address tokenAddress
    ) external view returns (uint256);

    function actionIdsAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256);

    function hasActiveGroups(
        address tokenAddress,
        address owner
    ) external view returns (bool);
}
