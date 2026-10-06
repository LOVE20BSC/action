// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IGroupJoinEvents {
    /// @notice Emitted when an account joins a group
    /// @param provider If non-zero, indicates this is a trial join sponsored by the provider
    event Join(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        uint256 indexed groupId,
        address account,
        address provider,
        uint256 amount,
        uint256 accountCountByGroupId,
        uint256 accountCountByActionId,
        uint256 accountCountByTokenAddress
    );

    /// @notice Emitted when an account exits from a group
    /// @param provider If non-zero, indicates this was a trial user; funds are refunded to provider
    event Exit(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        uint256 indexed groupId,
        address account,
        address provider,
        uint256 amount,
        uint256 accountCountByGroupId,
        uint256 accountCountByActionId,
        uint256 accountCountByTokenAddress
    );

    event TrialAccountsWaitingUpdated(
        address indexed tokenAddress,
        uint256 actionId,
        uint256 indexed groupId,
        address indexed provider,
        address account,
        uint256 trialAmount,
        bool enabled
    );
}

interface IGroupJoinErrors {
    error JoinAmountZero();
    error AlreadyInOtherGroup();
    error NotJoinedAction();
    error AmountBelowMinimum();
    error ExceedsActionMaxJoinAmount();
    error ExceedsGroupMaxJoinAmount();
    error GroupCapacityExceeded();
    error GroupAccountsFull();
    error CannotJoinInactiveGroup();
    error NotRegisteredExtensionInFactory();
    error ExtensionNotInitialized();
    error InvalidGroupId();
    error AlreadyJoined();
    error TrialAlreadyJoined();
    error TrialArrayLengthMismatch();
    error TrialAccountIsProvider();
    error TrialAccountZero();
    error TrialAmountZero();
    error TrialAccountAlreadyAdded();
    error TrialAccountNotInWaitingList(address account);
    error TrialProviderMismatch();
    error AlreadyInitialized();
    error InvalidFactoryAddress();
}

interface IGroupJoin is IGroupJoinEvents, IGroupJoinErrors {
    function initialize(address factory_) external;

    function FACTORY_ADDRESS() external view returns (address);

    function join(
        address extension,
        uint256 groupId,
        uint256 amount,
        string[] memory verificationInfos
    ) external;

    function trialJoin(
        address extension,
        uint256 groupId,
        address provider,
        string[] memory verificationInfos
    ) external;

    function exit(address extension) external;

    function trialExit(address extension, address account) external;

    function joinInfo(
        address extension,
        uint256 round,
        address account
    )
        external
        view
        returns (
            uint256 joinedRound,
            uint256 amount,
            uint256 groupId,
            address provider
        );

    function groupIdByAccount(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256);

    function totalJoinedAmountByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function joinedAmount(
        address extension,
        uint256 round
    ) external view returns (uint256);

    function accountsByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address[] memory);

    function accountsByGroupIdCount(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function accountsByGroupIdAtIndex(
        address extension,
        uint256 round,
        uint256 groupId,
        uint256 index
    ) external view returns (address);

    function joinedAmountByAccount(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256);

    function totalJoinedAmountByGroupOwner(
        address extension,
        address owner
    ) external view returns (uint256);

    function accountIndexByGroupId(
        address extension,
        uint256 groupId,
        address account,
        uint256 round
    ) external view returns (bool found, uint256 index);

    function trialAccountsWaitingAdd(
        address extension,
        uint256 groupId,
        address[] memory trialAccounts,
        uint256[] memory trialAmounts
    ) external;

    function trialAccountsWaitingRemove(
        address extension,
        uint256 groupId,
        address[] memory trialAccounts
    ) external;

    function trialAccountsWaitingRemoveAll(
        address extension,
        uint256 groupId
    ) external;

    function trialAccountsWaiting(
        address extension,
        uint256 groupId,
        address provider
    )
        external
        view
        returns (
            address[] memory accounts,
            uint256[] memory trialAmounts,
            uint256[] memory blockNumbers
        );

    function trialAccountsWaitingCount(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (uint256);

    function trialAccountsWaitingAtIndex(
        address extension,
        uint256 groupId,
        address provider,
        uint256 index
    )
        external
        view
        returns (address account, uint256 trialAmount, uint256 blockNumber);

    function trialAccountsJoined(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (address[] memory);

    function trialAccountsJoinedCount(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (uint256);

    function trialAccountsJoinedAtIndex(
        address extension,
        uint256 groupId,
        address provider,
        uint256 index
    ) external view returns (address);

    // ------ global view functions (no extension parameter) ------

    // gGroupIds functions
    function gGroupIds() external view returns (uint256[] memory);
    function gGroupIdsCount() external view returns (uint256);
    function gGroupIdsAtIndex(uint256 index) external view returns (uint256);

    // gGroupIdsByAccount functions
    function gGroupIdsByAccount(
        address account
    ) external view returns (uint256[] memory);

    function gGroupIdsByAccountCount(
        address account
    ) external view returns (uint256);

    function gGroupIdsByAccountAtIndex(
        address account,
        uint256 index
    ) external view returns (uint256);

    // gGroupIdsByTokenAddress functions
    function gGroupIdsByTokenAddress(
        address tokenAddress
    ) external view returns (uint256[] memory);

    function gGroupIdsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256);

    function gGroupIdsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256);

    // gGroupIdsByTokenAddressByAccount functions
    function gGroupIdsByTokenAddressByAccount(
        address tokenAddress,
        address account
    ) external view returns (uint256[] memory);

    function gGroupIdsByTokenAddressByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256);

    function gGroupIdsByTokenAddressByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256);

    function gGroupIdsByTokenAddressByActionId(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256[] memory);

    function gGroupIdsByTokenAddressByActionIdCount(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256);

    function gGroupIdsByTokenAddressByActionIdAtIndex(
        address tokenAddress,
        uint256 actionId,
        uint256 index
    ) external view returns (uint256);

    // gTokenAddresses functions
    function gTokenAddresses() external view returns (address[] memory);

    function gTokenAddressesCount() external view returns (uint256);

    function gTokenAddressesAtIndex(
        uint256 index
    ) external view returns (address);

    // gTokenAddressesByAccount functions
    function gTokenAddressesByAccount(
        address account
    ) external view returns (address[] memory);

    function gTokenAddressesByAccountCount(
        address account
    ) external view returns (uint256);

    function gTokenAddressesByAccountAtIndex(
        address account,
        uint256 index
    ) external view returns (address);

    // gTokenAddressesByGroupId functions
    function gTokenAddressesByGroupId(
        uint256 groupId
    ) external view returns (address[] memory);

    function gTokenAddressesByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256);

    function gTokenAddressesByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address);

    // gTokenAddressesByGroupIdByAccount functions
    function gTokenAddressesByGroupIdByAccount(
        uint256 groupId,
        address account
    ) external view returns (address[] memory);

    function gTokenAddressesByGroupIdByAccountCount(
        uint256 groupId,
        address account
    ) external view returns (uint256);

    function gTokenAddressesByGroupIdByAccountAtIndex(
        uint256 groupId,
        address account,
        uint256 index
    ) external view returns (address);

    // gActionIdsByTokenAddress functions
    function gActionIdsByTokenAddress(
        address tokenAddress
    ) external view returns (uint256[] memory);

    function gActionIdsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256);

    function gActionIdsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256);

    // gActionIdsByTokenAddressByAccount functions
    function gActionIdsByTokenAddressByAccount(
        address tokenAddress,
        address account
    ) external view returns (uint256[] memory);

    function gActionIdsByTokenAddressByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256);

    function gActionIdsByTokenAddressByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256);

    // gActionIdsByTokenAddressByGroupId functions
    function gActionIdsByTokenAddressByGroupId(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256[] memory);

    function gActionIdsByTokenAddressByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256);

    function gActionIdsByTokenAddressByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (uint256);

    // gActionIdsByTokenAddressByGroupIdByAccount functions
    function gActionIdsByTokenAddressByGroupIdByAccount(
        address tokenAddress,
        uint256 groupId,
        address account
    ) external view returns (uint256[] memory);

    function gActionIdsByTokenAddressByGroupIdByAccountCount(
        address tokenAddress,
        uint256 groupId,
        address account
    ) external view returns (uint256);

    function gActionIdsByTokenAddressByGroupIdByAccountAtIndex(
        address tokenAddress,
        uint256 groupId,
        address account,
        uint256 index
    ) external view returns (uint256);

    // gAccounts functions
    function gAccounts() external view returns (address[] memory);

    function gAccountsCount() external view returns (uint256);

    function gAccountsAtIndex(uint256 index) external view returns (address);

    // gAccountsByGroupId functions
    function gAccountsByGroupId(
        uint256 groupId
    ) external view returns (address[] memory);

    function gAccountsByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256);

    function gAccountsByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address);

    // gAccountsByTokenAddress functions
    function gAccountsByTokenAddress(
        address tokenAddress
    ) external view returns (address[] memory);

    function gAccountsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256);

    function gAccountsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (address);

    // gAccountsByTokenAddressByGroupId functions
    function gAccountsByTokenAddressByGroupId(
        address tokenAddress,
        uint256 groupId
    ) external view returns (address[] memory);

    function gAccountsByTokenAddressByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256);

    function gAccountsByTokenAddressByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (address);
}
