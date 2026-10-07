// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

struct GroupConfig {
    string description;
    uint256 maxCapacity;
    uint256 minJoinAmount;
    uint256 maxJoinAmount;
    uint256 maxAccounts;
}

interface IGroupActionManagerEvents {
    event GroupActivated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 stakeAmount
    );
    event GroupDeactivated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 stakeAmount
    );
    event GroupConfigUpdated(
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

interface IGroupActionManagerErrors {
    error GroupAlreadyActivated();
    error GroupNotActive();
    error InvalidMinMaxJoinAmount();
    error CannotDeactivateInActivatedRound();
    error OnlyGroupOwner();
    error InsufficientActivationMinGovRatio();
    error NoGovVotes();
}

interface IGroupActionManager is IGroupActionManagerEvents, IGroupActionManagerErrors {
    function activateGroup(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external;

    function deactivateGroup(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external;

    function updateGroupConfig(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        GroupConfig calldata config
    ) external;

    function groupInfo(
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
        );

    function descriptionByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (string memory);

    function activeGroupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory groupIds,
            uint256 total
        );

    function isGroupActive(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId
    ) external view returns (bool);

    function maxJoinAmount(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256);

    function staked(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256);

    function totalStaked(address tokenAddress) external view returns (uint256);

    function totalStakedByMemberId(
        address tokenAddress,
        uint256 memberId
    ) external view returns (uint256);

    function tokenAddressesByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            address[] memory tokenAddresses,
            uint256 total
        );

    function actionIdsByGroupId(
        address tokenAddress,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            uint256 total
        );

    function actionIds(
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            uint256 total
        );

    function hasActiveGroups(
        address tokenAddress,
        uint256 memberId
    ) external view returns (bool);
}
