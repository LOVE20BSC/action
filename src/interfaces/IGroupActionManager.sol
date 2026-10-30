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
        uint256 stakeAmount,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount,
        uint256 maxAccounts,
        string description
    );
    event GroupDeactivated(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 stakeAmount
    );
    event GroupConfigChanged(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 round,
        uint256 indexed groupId,
        uint256 maxCapacity,
        uint256 minJoinAmount,
        uint256 maxJoinAmount,
        uint256 maxAccounts,
        string description,
        uint256 prevMaxCapacity,
        uint256 prevMinJoinAmount,
        uint256 prevMaxJoinAmount,
        uint256 prevMaxAccounts,
        string prevDescription
    );
}

interface IGroupActionManagerErrors {
    error GroupAlreadyActivated(uint256 groupId);
    error GroupNotActive(uint256 groupId);
    error GroupNotExist(uint256 groupId);
    error InvalidMinJoinAmount(uint256 minAmount);
    error InvalidMaxJoinAmount(
        uint256 minAmount,
        uint256 maxAmount
    );
    error DeactivationLockedInActivatedRound(
        uint256 groupId,
        uint256 round
    );
    error NotGroupOwner(uint256 groupId);
    error InsufficientActivationMinGovRatio(
        uint256 groupId,
        uint256 required,
        uint256 actual
    );
    error NoGovVotes(address tokenAddress);
    error TooManyVerificationEntries(
        uint256 count,
        uint256 maxCount
    );
    error VerificationKeyTooLong(
        uint256 index,
        uint256 length,
        uint256 maxLength
    );
    error VerificationDescriptionTooLong(
        uint256 index,
        uint256 length,
        uint256 maxLength
    );
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

    function groupState(
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
            uint256 totalCount
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

    function stakedByMemberId(
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
            uint256 totalCount
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
            uint256 totalCount
        );

    function actionIdsWithActiveGroups(
        address tokenAddress,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            uint256 totalCount
        );

    function hasActiveGroups(
        address tokenAddress,
        uint256 memberId
    ) external view returns (bool);
}
