// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupActionJoinEvents {
    event Joined(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount,
        uint256 providerId,
        uint256 groupId
    );
    event Withdrawn(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 amount,
        uint256 providerId,
        uint256 groupId
    );
    event Exited(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 groupId
    );
    event ProviderQuotaAdded(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 providerId,
        uint256 memberId,
        uint256 amount
    );
    event ProviderQuotaRemoved(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 providerId,
        uint256 memberId,
        uint256 amount
    );
}

interface IGroupActionJoinErrors {
    error InvalidParticipationAmount();
    error AlreadyInOtherGroup();
    error NotJoinedAction();
    error ExceedsActionMaxJoinAmount();
    error ExceedsGroupMaxJoinAmount();
    error GroupCapacityExceeded();
    error GroupAccountsFull();
    error CannotJoinInactiveGroup();
    error InvalidGroupId();
    error QuotaArrayLengthMismatch();
    error QuotaMemberIsProvider();
    error QuotaMemberZero();
    error QuotaAmountZero();
    error QuotaNotGranted(uint256 memberId);
    error InsufficientProviderQuota(uint256 providerId, uint256 required, uint256 available);
}

interface IGroupActionJoin is IGroupActionJoinEvents, IGroupActionJoinErrors {
    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 memberId,
        uint256 amount,
        uint256 providerId,
        string[] calldata verificationInfos
    ) external;

    function withdraw(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external;

    function providerWithdraw(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 providerId,
        uint256 amount
    ) external;

    function joinInfo(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 joinedRound,
            uint256 amount,
            uint256 groupId,
            uint256 ownAmount,
            uint256 providerAmount
        );

    function totalJoinedAmountByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function groupIds(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
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

    function memberIdsByGroupId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256 total
        );

    function providerQuotaAdd(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds,
        uint256[] calldata amounts
    ) external;

    function providerQuotaRemove(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256[] calldata memberIds
    ) external;

    function providerQuota(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256[] memory amounts,
            uint256[] memory blockNumbers,
            uint256 total
        );

    function providerAmountsByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory providerIds,
            uint256[] memory amounts,
            uint256 total
        );
}
