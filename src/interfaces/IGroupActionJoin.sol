// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupActionJoinEvents {
    event GroupActionJoined(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 amount,
        string[] verificationValues
    );
    event GroupActionWithdrawn(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        uint256 groupId,
        uint256 providerId,
        uint256 amount
    );
    event GroupActionExited(
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
        uint256 amount,
        uint256 quotaTotal
    );
    event ProviderQuotaRemoved(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 providerId,
        uint256 memberId,
        uint256 amount
    );
    event ProviderQuotaRefunded(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed groupId,
        uint256 providerId,
        uint256 memberId,
        uint256 amount
    );
}

interface IGroupActionJoinErrors {
    error ZeroParticipationAmount();
    error AlreadyInOtherGroup(uint256 memberId, uint256 existingGroupId, uint256 requestedGroupId);
    error NotJoined(address tokenAddress, uint256 actionId, uint256 memberId);
    error ActionMaxJoinAmountExceeded(uint256 memberId, uint256 actual, uint256 limit);
    error GroupMaxJoinAmountExceeded(uint256 memberId, uint256 actual, uint256 limit);
    error GroupCapacityExceeded(uint256 groupId, uint256 actual, uint256 limit);
    error GroupAccountsFull(uint256 groupId, uint256 count, uint256 maxCount);
    error BelowMinJoinAmount(uint256 actual, uint256 minAmount);
    error WithdrawAmountExceeded(uint256 amount, uint256 joined);
    error ProviderWithdrawAmountExceeded(uint256 amount, uint256 invested);
    error QuotaArrayLengthMismatch(uint256 memberIdsLength, uint256 amountsLength);
    error QuotaMemberIsProvider(uint256 providerId);
    error ZeroQuotaAmount(uint256 memberId);
    error QuotaNotGranted(uint256 groupId, uint256 providerId, uint256 memberId);
    error InsufficientProviderQuota(uint256 providerId, uint256 required, uint256 available);
    error TooManyVerificationValues(uint256 count, uint256 maxCount);
    error VerificationValueTooLong(uint256 index, uint256 length, uint256 maxLength);
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
