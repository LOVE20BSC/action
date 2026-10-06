// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupJoin} from "./interface/IGroupJoin.sol";
import {
    IExtensionGroupActionFactory
} from "./interface/IExtensionGroupActionFactory.sol";
import {IGroupAction} from "./interface/IGroupAction.sol";
import {IGroupManager} from "./interface/IGroupManager.sol";
import {ILOVE20Join} from "@core/interfaces/ILOVE20Join.sol";
import {IExtension} from "@extension/src/interface/IExtension.sol";
import {IExtensionCenter} from "@extension/src/interface/IExtensionCenter.sol";
import {RoundHistoryUint256} from "@extension/src/lib/RoundHistoryUint256.sol";
import {
    RoundHistoryAddressSet
} from "@extension/src/lib/RoundHistoryAddressSet.sol";
import {RoundHistoryAddress} from "@extension/src/lib/RoundHistoryAddress.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

using RoundHistoryUint256 for RoundHistoryUint256.History;
using RoundHistoryAddressSet for RoundHistoryAddressSet.Storage;
using RoundHistoryAddress for RoundHistoryAddress.History;
using EnumerableSet for EnumerableSet.UintSet;
using EnumerableSet for EnumerableSet.AddressSet;
using SafeERC20 for IERC20;

contract GroupJoin is IGroupJoin, ReentrancyGuard {
    address public FACTORY_ADDRESS;

    IExtensionGroupActionFactory internal _factory;
    IExtensionCenter internal _center;
    IGroupManager internal _groupManager;
    IERC721Enumerable internal _group;
    ILOVE20Join internal _join;

    bool internal _initialized;
    // extension => account => joinedRound history
    mapping(address => mapping(address => RoundHistoryUint256.History))
        internal _joinedRoundHistoryByAccount;
    // extension => account => groupId
    mapping(address => mapping(address => RoundHistoryUint256.History))
        internal _groupIdHistoryByAccount;
    // extension => account => amount
    mapping(address => mapping(address => RoundHistoryUint256.History))
        internal _amountHistoryByAccount;
    // extension => groupId => account list history
    mapping(address => mapping(uint256 => RoundHistoryAddressSet.Storage))
        internal _accountsHistory;
    // extension => groupId => totalJoinedAmount
    mapping(address => mapping(uint256 => RoundHistoryUint256.History))
        internal _totalJoinedAmountHistoryByGroupId;
    // extension => totalJoinedAmount
    mapping(address => RoundHistoryUint256.History)
        internal _totalJoinedAmountHistory;

    // extension => groupId => provider => account => trialAmount
    mapping(address => mapping(uint256 => mapping(address => mapping(address => uint256))))
        internal _trialAccountsWaitingAmount;
    // extension => groupId => provider => account => block number when added
    mapping(address => mapping(uint256 => mapping(address => mapping(address => uint256))))
        internal _trialAccountsWaitingBlockNumber;
    // extension => groupId => provider => trial accounts
    mapping(address => mapping(uint256 => mapping(address => EnumerableSet.AddressSet)))
        internal _trialAccountsWaiting;
    // extension => groupId => provider => trial accounts in use
    mapping(address => mapping(uint256 => mapping(address => EnumerableSet.AddressSet)))
        internal _trialAccountsJoined;
    // extension => account => provider history (queryable by round)
    mapping(address => mapping(address => RoundHistoryAddress.History))
        internal _trialProviderByAccount;

    // Global state variables
    // groupId[]
    EnumerableSet.UintSet internal _gGroupIds;
    // account => groupId[]
    mapping(address => EnumerableSet.UintSet) internal _gGroupIdsByAccount;
    // tokenAddress => groupId[]
    mapping(address => EnumerableSet.UintSet) internal _gGroupIdsByTokenAddress;
    // tokenAddress => account => groupId[]
    mapping(address => mapping(address => EnumerableSet.UintSet))
        internal _gGroupIdsByTokenAddressByAccount;
    // tokenAddress => actionId => groupId[]
    mapping(address => mapping(uint256 => EnumerableSet.UintSet))
        internal _gGroupIdsByTokenAddressByActionId;

    // tokenAddress[]
    EnumerableSet.AddressSet internal _gTokenAddresses;
    // account => tokenAddress[]
    mapping(address => EnumerableSet.AddressSet)
        internal _gTokenAddressesByAccount;
    // groupId => tokenAddress[]
    mapping(uint256 => EnumerableSet.AddressSet)
        internal _gTokenAddressesByGroupId;
    // groupId => account => tokenAddress[]
    mapping(uint256 => mapping(address => EnumerableSet.AddressSet))
        internal _gTokenAddressesByGroupIdByAccount;

    // tokenAddress => actionId[]
    mapping(address => EnumerableSet.UintSet)
        internal _gActionIdsByTokenAddress;
    // tokenAddress => account => actionId[]
    mapping(address => mapping(address => EnumerableSet.UintSet))
        internal _gActionIdsByTokenAddressByAccount;
    // tokenAddress => groupId => actionId[]
    mapping(address => mapping(uint256 => EnumerableSet.UintSet))
        internal _gActionIdsByTokenAddressByGroupId;
    // tokenAddress => groupId => account => actionId[]
    mapping(address => mapping(uint256 => mapping(address => EnumerableSet.UintSet)))
        internal _gActionIdsByTokenAddressByGroupIdByAccount;

    // account[]
    EnumerableSet.AddressSet internal _gAccounts;
    // groupId => account[]
    mapping(uint256 => EnumerableSet.AddressSet) internal _gAccountsByGroupId;
    // tokenAddress => account[]
    mapping(address => EnumerableSet.AddressSet)
        internal _gAccountsByTokenAddress;
    // tokenAddress => groupId => account
    mapping(address => mapping(uint256 => EnumerableSet.AddressSet))
        internal _gAccountsByTokenAddressByGroupId;

    modifier onlyValidExtension(address extension) {
        if (!_factory.exists(extension)) {
            revert NotRegisteredExtensionInFactory();
        }
        if (!IExtension(extension).initialized()) {
            revert ExtensionNotInitialized();
        }
        _;
    }
    constructor() {}

    function initialize(address factory_) external {
        if (_initialized) revert AlreadyInitialized();
        if (factory_ == address(0)) revert InvalidFactoryAddress();

        FACTORY_ADDRESS = factory_;
        _factory = IExtensionGroupActionFactory(factory_);
        _center = IExtensionCenter(_factory.CENTER_ADDRESS());
        _groupManager = IGroupManager(_factory.GROUP_MANAGER_ADDRESS());
        _group = IERC721Enumerable(_factory.GROUP_ADDRESS());
        _join = ILOVE20Join(_center.joinAddress());

        _initialized = true;
    }

    function join(
        address extension,
        uint256 groupId,
        uint256 amount,
        string[] memory verificationInfos
    ) external nonReentrant onlyValidExtension(extension) {
        _validateJoin(extension, groupId, amount);
        uint256 currentRound = _join.currentRound();
        _joinInternal(
            extension,
            groupId,
            amount,
            verificationInfos,
            currentRound
        );
        _transferJoinToken(extension, msg.sender, amount);
        _emitJoin(
            extension,
            groupId,
            msg.sender,
            address(0),
            amount,
            currentRound
        );
    }

    function trialJoin(
        address extension,
        uint256 groupId,
        address provider,
        string[] memory verificationInfos
    ) external nonReentrant onlyValidExtension(extension) {
        uint256 trialAmount = _validateTrialJoin(extension, groupId, provider);
        _validateJoin(extension, groupId, trialAmount);
        uint256 currentRound = _join.currentRound();
        _joinInternal(
            extension,
            groupId,
            trialAmount,
            verificationInfos,
            currentRound
        );
        _updateTrialJoinState(
            extension,
            groupId,
            provider,
            msg.sender,
            trialAmount,
            currentRound
        );

        _emitJoin(
            extension,
            groupId,
            msg.sender,
            provider,
            trialAmount,
            currentRound
        );
    }

    function exit(
        address extension
    ) external nonReentrant onlyValidExtension(extension) {
        _validateExit(extension, msg.sender);
        uint256 currentRound = _join.currentRound();
        (uint256 groupId, uint256 amount) = _exitInternal(
            extension,
            msg.sender,
            currentRound
        );
        address provider = _trialProviderByAccount[extension][msg.sender]
            .latestValue();
        _updateTrialExitState(
            extension,
            groupId,
            provider,
            msg.sender,
            currentRound
        );
        _transferExitToken(extension, msg.sender, amount, provider);
        _emitExit(
            extension,
            groupId,
            msg.sender,
            provider,
            amount,
            currentRound
        );
    }

    function trialExit(
        address extension,
        address account
    ) external nonReentrant onlyValidExtension(extension) {
        _validateTrialExit(extension, account, msg.sender);
        uint256 currentRound = _join.currentRound();
        (uint256 groupId, uint256 amount) = _exitInternal(
            extension,
            account,
            currentRound
        );
        address provider = _trialProviderByAccount[extension][account]
            .latestValue();
        _updateTrialExitState(
            extension,
            groupId,
            provider,
            account,
            currentRound
        );
        _transferExitToken(extension, account, amount, provider);
        _emitExit(extension, groupId, account, provider, amount, currentRound);
    }

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
        )
    {
        amount = _amountHistoryByAccount[extension][account].value(round);
        if (amount == 0) {
            return (0, 0, 0, address(0));
        }
        joinedRound = _joinedRoundHistoryByAccount[extension][account].value(
            round
        );
        groupId = _groupIdHistoryByAccount[extension][account].value(round);
        provider = _trialProviderByAccount[extension][account].value(round);
    }

    function groupIdByAccount(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256) {
        return _groupIdHistoryByAccount[extension][account].value(round);
    }

    function totalJoinedAmountByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return
            _totalJoinedAmountHistoryByGroupId[extension][groupId].value(round);
    }

    function joinedAmount(
        address extension,
        uint256 round
    ) external view returns (uint256) {
        return _totalJoinedAmountHistory[extension].value(round);
    }

    function accountsByGroupId(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (address[] memory) {
        return _accountsHistory[extension][groupId].valuesByRound(round);
    }

    function accountsByGroupIdCount(
        address extension,
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _accountsHistory[extension][groupId].countByRound(round);
    }

    function accountsByGroupIdAtIndex(
        address extension,
        uint256 round,
        uint256 groupId,
        uint256 index
    ) external view returns (address) {
        return
            _accountsHistory[extension][groupId].atIndexByRound(index, round);
    }

    function joinedAmountByAccount(
        address extension,
        uint256 round,
        address account
    ) external view returns (uint256) {
        return _amountHistoryByAccount[extension][account].value(round);
    }

    function accountIndexByGroupId(
        address extension,
        uint256 groupId,
        address account,
        uint256 round
    ) external view returns (bool found, uint256 index) {
        RoundHistoryAddressSet.Storage storage accounts = _accountsHistory[
            extension
        ][groupId];
        index = accounts.accountsIndexHistory[account].value(round);
        address accountAtIndex = accounts.accountsAtIndexHistory[index].value(
            round
        );
        found = accountAtIndex == account;
    }

    function trialAccountsWaitingAdd(
        address extension,
        uint256 groupId,
        address[] memory trialAccounts,
        uint256[] memory trialAmounts
    ) external nonReentrant onlyValidExtension(extension) {
        if (!_groupManager.isGroupActive(extension, groupId)) {
            revert CannotJoinInactiveGroup();
        }
        if (trialAccounts.length != trialAmounts.length) {
            revert TrialArrayLengthMismatch();
        }

        uint256 length = trialAccounts.length;
        if (length == 0) return;

        uint256 totalAmount;
        for (uint256 i; i < length; ) {
            _addTrialAccountToWaitingList(
                extension,
                groupId,
                trialAccounts[i],
                trialAmounts[i]
            );
            totalAmount += trialAmounts[i];

            unchecked {
                ++i;
            }
        }

        address joinTokenAddress = IGroupAction(extension).JOIN_TOKEN_ADDRESS();
        IERC20(joinTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            totalAmount
        );
    }

    function trialAccountsWaitingRemove(
        address extension,
        uint256 groupId,
        address[] memory trialAccounts
    ) external nonReentrant onlyValidExtension(extension) {
        if (trialAccounts.length == 0) return;
        _removeTrialAccountsFromWaitingList(
            extension,
            groupId,
            trialAccounts,
            msg.sender
        );
    }

    function trialAccountsWaitingRemoveAll(
        address extension,
        uint256 groupId
    ) external nonReentrant onlyValidExtension(extension) {
        address[] memory accounts = _trialAccountsWaiting[extension][groupId][
            msg.sender
        ].values();
        _removeTrialAccountsFromWaitingList(
            extension,
            groupId,
            accounts,
            msg.sender
        );
    }

    function _removeTrialAccountsFromWaitingList(
        address extension,
        uint256 groupId,
        address[] memory accounts,
        address provider
    ) internal {
        uint256 totalRefund;
        for (uint256 i; i < accounts.length; ) {
            totalRefund += _removeTrialAccountFromWaitingList(
                extension,
                groupId,
                accounts[i],
                provider
            );
            unchecked {
                ++i;
            }
        }
        _refundTrialAmount(extension, provider, totalRefund);
    }

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
        )
    {
        accounts = _trialAccountsWaiting[extension][groupId][provider].values();
        uint256 len = accounts.length;
        trialAmounts = new uint256[](len);
        blockNumbers = new uint256[](len);
        for (uint256 i; i < len; ) {
            trialAmounts[i] = _trialAccountsWaitingAmount[extension][groupId][
                provider
            ][accounts[i]];
            blockNumbers[i] = _trialAccountsWaitingBlockNumber[extension][
                groupId
            ][provider][accounts[i]];
            unchecked {
                ++i;
            }
        }
        return (accounts, trialAmounts, blockNumbers);
    }

    function trialAccountsWaitingCount(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (uint256) {
        return _trialAccountsWaiting[extension][groupId][provider].length();
    }

    function trialAccountsWaitingAtIndex(
        address extension,
        uint256 groupId,
        address provider,
        uint256 index
    )
        external
        view
        returns (address account, uint256 trialAmount, uint256 blockNumber)
    {
        account = _trialAccountsWaiting[extension][groupId][provider].at(index);
        return (
            account,
            _trialAccountsWaitingAmount[extension][groupId][provider][account],
            _trialAccountsWaitingBlockNumber[extension][groupId][provider][
                account
            ]
        );
    }

    function trialAccountsJoined(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (address[] memory) {
        return _trialAccountsJoined[extension][groupId][provider].values();
    }

    function trialAccountsJoinedCount(
        address extension,
        uint256 groupId,
        address provider
    ) external view returns (uint256) {
        return _trialAccountsJoined[extension][groupId][provider].length();
    }

    function trialAccountsJoinedAtIndex(
        address extension,
        uint256 groupId,
        address provider,
        uint256 index
    ) external view returns (address) {
        return _trialAccountsJoined[extension][groupId][provider].at(index);
    }

    function _validateExit(address extension, address account) internal view {
        uint256 groupId = _groupIdHistoryByAccount[extension][account]
            .latestValue();
        if (groupId == 0) revert NotJoinedAction();
    }

    function _validateTrialExit(
        address extension,
        address account,
        address expectedProvider
    ) internal view {
        address provider = _trialProviderByAccount[extension][account]
            .latestValue();
        if (provider != expectedProvider) revert TrialProviderMismatch();
    }

    function _exitInternal(
        address extension,
        address account,
        uint256 currentRound
    ) internal returns (uint256 groupId, uint256 amount) {
        IExtension ext = IExtension(extension);
        address tokenAddress = ext.TOKEN_ADDRESS();
        uint256 actionId = ext.actionId();
        groupId = _groupIdHistoryByAccount[extension][account].latestValue();
        amount = _amountHistoryByAccount[extension][account].latestValue();

        // 1. Update account participation info
        _joinedRoundHistoryByAccount[extension][account].record(
            currentRound,
            0
        );
        _amountHistoryByAccount[extension][account].record(currentRound, 0);
        _groupIdHistoryByAccount[extension][account].record(currentRound, 0);

        // 2. Update token amounts
        _totalJoinedAmountHistoryByGroupId[extension][groupId].decrease(
            currentRound,
            amount
        );
        _totalJoinedAmountHistory[extension].decrease(currentRound, amount);

        // 3. Update account list
        _accountsHistory[extension][groupId].remove(currentRound, account);
        _center.removeAccount(tokenAddress, actionId, account);

        // 4. Update global state
        _updateGlobalStateOnExit(
            extension,
            tokenAddress,
            actionId,
            groupId,
            account
        );

        return (groupId, amount);
    }

    function _transferJoinToken(
        address extension,
        address account,
        uint256 amount
    ) internal {
        address joinTokenAddress = IGroupAction(extension).JOIN_TOKEN_ADDRESS();
        IERC20(joinTokenAddress).safeTransferFrom(
            account,
            address(this),
            amount
        );
    }

    function _joinInternal(
        address extension,
        uint256 groupId,
        uint256 amount,
        string[] memory verificationInfos,
        uint256 currentRound
    ) internal {
        uint256 joinedGroupId = _groupIdHistoryByAccount[extension][msg.sender]
            .latestValue();
        bool isFirstJoin = joinedGroupId == 0;

        if (isFirstJoin) {
            _handleFirstJoin(
                extension,
                groupId,
                amount,
                verificationInfos,
                currentRound
            );
        } else {
            _handleNonFirstJoin(
                extension,
                groupId,
                amount,
                verificationInfos,
                currentRound
            );
        }
    }

    function _handleFirstJoin(
        address extension,
        uint256 groupId,
        uint256 amount,
        string[] memory verificationInfos,
        uint256 currentRound
    ) internal {
        IExtension ext = IExtension(extension);
        address tokenAddress = ext.TOKEN_ADDRESS();
        uint256 actionId = ext.actionId();

        // 1. Update account participation info
        _joinedRoundHistoryByAccount[extension][msg.sender].record(
            currentRound,
            currentRound
        );
        _groupIdHistoryByAccount[extension][msg.sender].record(
            currentRound,
            groupId
        );
        _amountHistoryByAccount[extension][msg.sender].increase(
            currentRound,
            amount
        );

        // 2. Update token amounts
        _totalJoinedAmountHistoryByGroupId[extension][groupId].increase(
            currentRound,
            amount
        );
        _totalJoinedAmountHistory[extension].increase(currentRound, amount);

        // 3. Update account list
        _accountsHistory[extension][groupId].add(currentRound, msg.sender);
        _center.addAccount(
            tokenAddress,
            actionId,
            msg.sender,
            verificationInfos
        );

        // 4. Update global state
        _updateGlobalStateOnJoin(tokenAddress, actionId, groupId, msg.sender);
    }

    function _handleNonFirstJoin(
        address extension,
        uint256 groupId,
        uint256 amount,
        string[] memory verificationInfos,
        uint256 currentRound
    ) internal {
        IExtension ext = IExtension(extension);
        address tokenAddress = ext.TOKEN_ADDRESS();
        uint256 actionId = ext.actionId();

        // 1. Update account participation info
        if (verificationInfos.length > 0) {
            _center.updateVerificationInfo(
                tokenAddress,
                actionId,
                msg.sender,
                verificationInfos
            );
        }
        _amountHistoryByAccount[extension][msg.sender].increase(
            currentRound,
            amount
        );

        // 2. Update token amounts
        _totalJoinedAmountHistoryByGroupId[extension][groupId].increase(
            currentRound,
            amount
        );
        _totalJoinedAmountHistory[extension].increase(currentRound, amount);
    }

    function _validateTrialJoin(
        address extension,
        uint256 groupId,
        address provider
    ) internal view returns (uint256 trialAmount) {
        uint256 joinedGroupId = _groupIdHistoryByAccount[extension][msg.sender]
            .latestValue();
        if (joinedGroupId != 0) revert AlreadyJoined();
        if (provider == address(0)) revert TrialProviderMismatch();

        trialAmount = _trialAccountsWaitingAmount[extension][groupId][provider][
            msg.sender
        ];
        if (trialAmount == 0) revert TrialAmountZero();
    }

    function _addTrialAccountToWaitingList(
        address extension,
        uint256 groupId,
        address account,
        uint256 trialAmount
    ) internal {
        if (account == address(0)) revert TrialAccountZero();
        if (account == msg.sender) revert TrialAccountIsProvider();
        if (trialAmount == 0) revert TrialAmountZero();
        if (
            _trialAccountsWaiting[extension][groupId][msg.sender].contains(
                account
            )
        ) {
            revert TrialAccountAlreadyAdded();
        }

        _trialAccountsWaitingAmount[extension][groupId][msg.sender][
            account
        ] = trialAmount;
        _trialAccountsWaitingBlockNumber[extension][groupId][msg.sender][
            account
        ] = block.number;
        _trialAccountsWaiting[extension][groupId][msg.sender].add(account);
        _emitTrialAccountsWaitingUpdated(
            extension,
            groupId,
            msg.sender,
            account,
            true,
            trialAmount
        );
    }

    function _removeTrialAccountFromWaitingList(
        address extension,
        uint256 groupId,
        address account,
        address provider
    ) internal returns (uint256) {
        if (
            !_trialAccountsWaiting[extension][groupId][provider].contains(
                account
            )
        ) {
            revert TrialAccountNotInWaitingList(account);
        }

        _trialAccountsWaiting[extension][groupId][provider].remove(account);
        uint256 trialAmount = _trialAccountsWaitingAmount[extension][groupId][
            provider
        ][account];
        delete _trialAccountsWaitingAmount[extension][groupId][provider][
            account
        ];
        delete _trialAccountsWaitingBlockNumber[extension][groupId][provider][
            account
        ];
        _emitTrialAccountsWaitingUpdated(
            extension,
            groupId,
            provider,
            account,
            false,
            trialAmount
        );

        return trialAmount;
    }

    function _refundTrialAmount(
        address extension,
        address provider,
        uint256 totalRefund
    ) internal {
        if (totalRefund > 0) {
            address joinTokenAddress = IGroupAction(extension)
                .JOIN_TOKEN_ADDRESS();
            IERC20(joinTokenAddress).safeTransfer(provider, totalRefund);
        }
    }

    function _getEventData(
        address extension,
        uint256 groupId
    )
        internal
        view
        returns (
            address tokenAddress,
            uint256 actionId,
            uint256 accountCountByGroupId,
            uint256 accountCountByActionId,
            uint256 accountCountByTokenAddress
        )
    {
        IExtension ext = IExtension(extension);
        tokenAddress = ext.TOKEN_ADDRESS();
        actionId = ext.actionId();
        accountCountByGroupId = _accountsHistory[extension][groupId].count();
        accountCountByActionId = _center.accountsCount(tokenAddress, actionId);
        accountCountByTokenAddress = _gAccountsByTokenAddress[tokenAddress]
            .length();
    }

    function _emitJoin(
        address extension,
        uint256 groupId,
        address account,
        address provider,
        uint256 amount,
        uint256 currentRound
    ) internal {
        (
            address tokenAddress,
            uint256 actionId,
            uint256 accountCountByGroupId,
            uint256 accountCountByActionId,
            uint256 accountCountByTokenAddress
        ) = _getEventData(extension, groupId);

        emit Join({
            tokenAddress: tokenAddress,
            round: currentRound,
            actionId: actionId,
            groupId: groupId,
            account: account,
            provider: provider,
            amount: amount,
            accountCountByGroupId: accountCountByGroupId,
            accountCountByActionId: accountCountByActionId,
            accountCountByTokenAddress: accountCountByTokenAddress
        });
    }

    function _transferExitToken(
        address extension,
        address account,
        uint256 amount,
        address provider
    ) internal {
        address refundTo = provider == address(0) ? account : provider;
        address joinTokenAddress = IGroupAction(extension).JOIN_TOKEN_ADDRESS();
        IERC20(joinTokenAddress).safeTransfer(refundTo, amount);
    }

    function _emitExit(
        address extension,
        uint256 groupId,
        address account,
        address provider,
        uint256 amount,
        uint256 currentRound
    ) internal {
        (
            address tokenAddress,
            uint256 actionId,
            uint256 accountCountByGroupId,
            uint256 accountCountByActionId,
            uint256 accountCountByTokenAddress
        ) = _getEventData(extension, groupId);

        emit Exit({
            tokenAddress: tokenAddress,
            round: currentRound,
            actionId: actionId,
            groupId: groupId,
            account: account,
            provider: provider,
            amount: amount,
            accountCountByGroupId: accountCountByGroupId,
            accountCountByActionId: accountCountByActionId,
            accountCountByTokenAddress: accountCountByTokenAddress
        });
    }

    function _updateTrialExitState(
        address extension,
        uint256 groupId,
        address provider,
        address account,
        uint256 currentRound
    ) internal {
        if (provider == address(0)) {
            return;
        }
        _trialProviderByAccount[extension][account].record(
            currentRound,
            address(0)
        );
        _trialAccountsJoined[extension][groupId][provider].remove(account);
    }

    function _updateTrialJoinState(
        address extension,
        uint256 groupId,
        address provider,
        address account,
        uint256 trialAmount,
        uint256 currentRound
    ) internal {
        _trialProviderByAccount[extension][account].record(
            currentRound,
            provider
        );
        _trialAccountsJoined[extension][groupId][provider].add(account);
        _trialAccountsWaiting[extension][groupId][provider].remove(account);
        delete _trialAccountsWaitingAmount[extension][groupId][provider][
            account
        ];
        delete _trialAccountsWaitingBlockNumber[extension][groupId][provider][
            account
        ];

        _emitTrialAccountsWaitingUpdated(
            extension,
            groupId,
            provider,
            account,
            false,
            trialAmount
        );
    }

    function _emitTrialAccountsWaitingUpdated(
        address extension,
        uint256 groupId,
        address provider,
        address account,
        bool enabled,
        uint256 trialAmount
    ) internal {
        IExtension ext = IExtension(extension);
        address tokenAddress = ext.TOKEN_ADDRESS();
        uint256 actionId = ext.actionId();
        emit TrialAccountsWaitingUpdated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            groupId: groupId,
            provider: provider,
            account: account,
            trialAmount: trialAmount,
            enabled: enabled
        });
    }

    function _validateJoin(
        address extension,
        uint256 groupId,
        uint256 amount
    ) internal view {
        if (amount == 0) revert JoinAmountZero();
        if (
            _trialProviderByAccount[extension][msg.sender].latestValue() !=
            address(0)
        ) {
            revert TrialAlreadyJoined();
        }

        uint256 joinedGroupId = _groupIdHistoryByAccount[extension][msg.sender]
            .latestValue();
        bool isFirstJoin = joinedGroupId == 0;

        // Check account's group membership (not based on GroupInfo)
        if (!isFirstJoin && joinedGroupId != groupId) {
            revert AlreadyInOtherGroup();
        }

        uint256 newTotal = _amountHistoryByAccount[extension][msg.sender]
            .latestValue() + amount;

        // All validations based on GroupInfo
        _validateGroupConstraints(
            extension,
            groupId,
            amount,
            isFirstJoin,
            newTotal
        );

        // Check extension-wide account limit
        uint256 extensionMaxJoinAmount = _groupManager.maxJoinAmount(extension);
        if (newTotal > extensionMaxJoinAmount) {
            revert ExceedsActionMaxJoinAmount();
        }
    }

    // All validations based on GroupInfo: fetch once and validate all constraints
    function _validateGroupConstraints(
        address extension,
        uint256 groupId,
        uint256 amount,
        bool isFirstJoin,
        uint256 newTotal
    ) internal view {
        // Fetch group info once
        IGroupManager.GroupInfo memory groupInfo = _groupManager.groupInfo(
            extension,
            groupId
        );

        // Validate group status
        if (!groupInfo.isActive) {
            revert CannotJoinInactiveGroup();
        }

        // Check group-specific account limit
        if (groupInfo.maxJoinAmount > 0 && newTotal > groupInfo.maxJoinAmount) {
            revert ExceedsGroupMaxJoinAmount();
        }

        // Validate first join specific rules
        if (isFirstJoin) {
            // Check if group has reached max accounts
            if (groupInfo.maxAccounts > 0) {
                uint256 currentAccountCount = _accountsHistory[extension][
                    groupId
                ].count();
                if (currentAccountCount >= groupInfo.maxAccounts) {
                    revert GroupAccountsFull();
                }
            }

            // Check minimum join amount
            if (amount < groupInfo.minJoinAmount) {
                revert AmountBelowMinimum();
            }
        }

        // Validate group capacity
        if (groupInfo.maxCapacity > 0) {
            uint256 currentGroupTotal = _totalJoinedAmountHistoryByGroupId[
                extension
            ][groupId].latestValue();
            if (currentGroupTotal + amount > groupInfo.maxCapacity) {
                revert GroupCapacityExceeded();
            }
        }
    }

    function totalJoinedAmountByGroupOwner(
        address extension,
        address owner
    ) external view returns (uint256) {
        return _totalJoinedAmountByGroupOwner(extension, owner);
    }

    function _totalJoinedAmountByGroupOwner(
        address extension,
        address owner
    ) internal view returns (uint256 total) {
        uint256[] memory ownerGroupIds = _groupManager.activeGroupIdsByOwner(
            extension,
            owner
        );
        for (uint256 i = 0; i < ownerGroupIds.length; ) {
            total += _totalJoinedAmountHistoryByGroupId[extension][
                ownerGroupIds[i]
            ].latestValue();
            unchecked {
                ++i;
            }
        }
        return total;
    }

    function _updateGlobalStateOnJoin(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        address account
    ) internal {
        _gGroupIds.add(groupId);
        _gGroupIdsByAccount[account].add(groupId);
        _gGroupIdsByTokenAddress[tokenAddress].add(groupId);
        _gGroupIdsByTokenAddressByAccount[tokenAddress][account].add(groupId);
        _gGroupIdsByTokenAddressByActionId[tokenAddress][actionId].add(groupId);

        _gTokenAddresses.add(tokenAddress);
        _gTokenAddressesByAccount[account].add(tokenAddress);
        _gTokenAddressesByGroupId[groupId].add(tokenAddress);
        _gTokenAddressesByGroupIdByAccount[groupId][account].add(tokenAddress);

        _gActionIdsByTokenAddress[tokenAddress].add(actionId);
        _gActionIdsByTokenAddressByAccount[tokenAddress][account].add(actionId);
        _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId].add(actionId);
        _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
            account
        ].add(actionId);

        _gAccounts.add(account);
        _gAccountsByGroupId[groupId].add(account);
        _gAccountsByTokenAddress[tokenAddress].add(account);
        _gAccountsByTokenAddressByGroupId[tokenAddress][groupId].add(account);
    }

    function _updateGlobalStateOnExit(
        address extension,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        address account
    ) internal {
        _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
            account
        ].remove(actionId);

        _gActionIdsByTokenAddressByAccount[tokenAddress][account].remove(
            actionId
        );

        // check accountsByGroupIdCount if it is 0, then remove the groupId from the tokenAddress
        if (_accountsHistory[extension][groupId].count() == 0) {
            _gGroupIdsByTokenAddressByActionId[tokenAddress][actionId].remove(
                groupId
            );
            _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId].remove(
                actionId
            );
            if (
                _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId]
                    .length() == 0
            ) {
                _gTokenAddressesByGroupId[groupId].remove(tokenAddress);
                if (_gTokenAddressesByGroupId[groupId].length() == 0) {
                    _gGroupIds.remove(groupId);
                }
            }
        }

        if (
            _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
                account
            ].length() == 0
        ) {
            _gTokenAddressesByGroupIdByAccount[groupId][account].remove(
                tokenAddress
            );
            if (
                _gTokenAddressesByGroupIdByAccount[groupId][account].length() ==
                0
            ) {
                _gGroupIdsByAccount[account].remove(groupId);
                _gAccountsByGroupId[groupId].remove(account);

                if (_gGroupIdsByAccount[account].length() == 0) {
                    _gAccounts.remove(account);
                }
            }

            _gAccountsByTokenAddressByGroupId[tokenAddress][groupId].remove(
                account
            );
            if (
                _gAccountsByTokenAddressByGroupId[tokenAddress][groupId]
                    .length() == 0
            ) {
                _gGroupIdsByTokenAddress[tokenAddress].remove(groupId);
                if (_gGroupIdsByTokenAddress[tokenAddress].length() == 0) {
                    _gTokenAddresses.remove(tokenAddress);
                }
            }

            _gGroupIdsByTokenAddressByAccount[tokenAddress][account].remove(
                groupId
            );
            if (
                _gGroupIdsByTokenAddressByAccount[tokenAddress][account]
                    .length() == 0
            ) {
                _gAccountsByTokenAddress[tokenAddress].remove(account);
                _gTokenAddressesByAccount[account].remove(tokenAddress);
            }
        }

        if (_center.accountsCount(tokenAddress, actionId) == 0) {
            _gActionIdsByTokenAddress[tokenAddress].remove(actionId);
        }
    }

    // gGroupIds functions
    function gGroupIds() external view returns (uint256[] memory) {
        return _gGroupIds.values();
    }

    function gGroupIdsCount() external view returns (uint256) {
        return _gGroupIds.length();
    }

    function gGroupIdsAtIndex(uint256 index) external view returns (uint256) {
        return _gGroupIds.at(index);
    }

    // gGroupIdsByAccount functions
    function gGroupIdsByAccount(
        address account
    ) external view returns (uint256[] memory) {
        return _gGroupIdsByAccount[account].values();
    }

    function gGroupIdsByAccountCount(
        address account
    ) external view returns (uint256) {
        return _gGroupIdsByAccount[account].length();
    }

    function gGroupIdsByAccountAtIndex(
        address account,
        uint256 index
    ) external view returns (uint256) {
        return _gGroupIdsByAccount[account].at(index);
    }

    // gGroupIdsByTokenAddress functions
    function gGroupIdsByTokenAddress(
        address tokenAddress
    ) external view returns (uint256[] memory) {
        return _gGroupIdsByTokenAddress[tokenAddress].values();
    }

    function gGroupIdsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256) {
        return _gGroupIdsByTokenAddress[tokenAddress].length();
    }

    function gGroupIdsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256) {
        return _gGroupIdsByTokenAddress[tokenAddress].at(index);
    }

    // gGroupIdsByTokenAddressByAccount functions
    function gGroupIdsByTokenAddressByAccount(
        address tokenAddress,
        address account
    ) external view returns (uint256[] memory) {
        return
            _gGroupIdsByTokenAddressByAccount[tokenAddress][account].values();
    }

    function gGroupIdsByTokenAddressByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256) {
        return
            _gGroupIdsByTokenAddressByAccount[tokenAddress][account].length();
    }

    function gGroupIdsByTokenAddressByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256) {
        return
            _gGroupIdsByTokenAddressByAccount[tokenAddress][account].at(index);
    }

    function gGroupIdsByTokenAddressByActionId(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256[] memory) {
        return
            _gGroupIdsByTokenAddressByActionId[tokenAddress][actionId].values();
    }

    function gGroupIdsByTokenAddressByActionIdCount(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return
            _gGroupIdsByTokenAddressByActionId[tokenAddress][actionId].length();
    }

    function gGroupIdsByTokenAddressByActionIdAtIndex(
        address tokenAddress,
        uint256 actionId,
        uint256 index
    ) external view returns (uint256) {
        return
            _gGroupIdsByTokenAddressByActionId[tokenAddress][actionId].at(
                index
            );
    }

    // gTokenAddresses functions
    function gTokenAddresses() external view returns (address[] memory) {
        return _gTokenAddresses.values();
    }

    function gTokenAddressesCount() external view returns (uint256) {
        return _gTokenAddresses.length();
    }

    function gTokenAddressesAtIndex(
        uint256 index
    ) external view returns (address) {
        return _gTokenAddresses.at(index);
    }

    // gTokenAddressesByAccount functions
    function gTokenAddressesByAccount(
        address account
    ) external view returns (address[] memory) {
        return _gTokenAddressesByAccount[account].values();
    }

    function gTokenAddressesByAccountCount(
        address account
    ) external view returns (uint256) {
        return _gTokenAddressesByAccount[account].length();
    }

    function gTokenAddressesByAccountAtIndex(
        address account,
        uint256 index
    ) external view returns (address) {
        return _gTokenAddressesByAccount[account].at(index);
    }

    // gTokenAddressesByGroupId functions
    function gTokenAddressesByGroupId(
        uint256 groupId
    ) external view returns (address[] memory) {
        return _gTokenAddressesByGroupId[groupId].values();
    }

    function gTokenAddressesByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256) {
        return _gTokenAddressesByGroupId[groupId].length();
    }

    function gTokenAddressesByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address) {
        return _gTokenAddressesByGroupId[groupId].at(index);
    }

    // gTokenAddressesByGroupIdByAccount functions
    function gTokenAddressesByGroupIdByAccount(
        uint256 groupId,
        address account
    ) external view returns (address[] memory) {
        return _gTokenAddressesByGroupIdByAccount[groupId][account].values();
    }

    function gTokenAddressesByGroupIdByAccountCount(
        uint256 groupId,
        address account
    ) external view returns (uint256) {
        return _gTokenAddressesByGroupIdByAccount[groupId][account].length();
    }

    function gTokenAddressesByGroupIdByAccountAtIndex(
        uint256 groupId,
        address account,
        uint256 index
    ) external view returns (address) {
        return _gTokenAddressesByGroupIdByAccount[groupId][account].at(index);
    }

    // gActionIdsByTokenAddress functions
    function gActionIdsByTokenAddress(
        address tokenAddress
    ) external view returns (uint256[] memory) {
        return _gActionIdsByTokenAddress[tokenAddress].values();
    }

    function gActionIdsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256) {
        return _gActionIdsByTokenAddress[tokenAddress].length();
    }

    function gActionIdsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256) {
        return _gActionIdsByTokenAddress[tokenAddress].at(index);
    }

    // gActionIdsByTokenAddressByAccount functions
    function gActionIdsByTokenAddressByAccount(
        address tokenAddress,
        address account
    ) external view returns (uint256[] memory) {
        return
            _gActionIdsByTokenAddressByAccount[tokenAddress][account].values();
    }

    function gActionIdsByTokenAddressByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByAccount[tokenAddress][account].length();
    }

    function gActionIdsByTokenAddressByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByAccount[tokenAddress][account].at(index);
    }

    // gActionIdsByTokenAddressByGroupId functions
    function gActionIdsByTokenAddressByGroupId(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256[] memory) {
        return
            _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId].values();
    }

    function gActionIdsByTokenAddressByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId].length();
    }

    function gActionIdsByTokenAddressByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByGroupId[tokenAddress][groupId].at(index);
    }

    // gActionIdsByTokenAddressByGroupIdByAccount functions
    function gActionIdsByTokenAddressByGroupIdByAccount(
        address tokenAddress,
        uint256 groupId,
        address account
    ) external view returns (uint256[] memory) {
        return
            _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
                account
            ].values();
    }

    function gActionIdsByTokenAddressByGroupIdByAccountCount(
        address tokenAddress,
        uint256 groupId,
        address account
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
                account
            ].length();
    }

    function gActionIdsByTokenAddressByGroupIdByAccountAtIndex(
        address tokenAddress,
        uint256 groupId,
        address account,
        uint256 index
    ) external view returns (uint256) {
        return
            _gActionIdsByTokenAddressByGroupIdByAccount[tokenAddress][groupId][
                account
            ].at(index);
    }

    // gAccounts functions
    function gAccounts() external view returns (address[] memory) {
        return _gAccounts.values();
    }

    function gAccountsCount() external view returns (uint256) {
        return _gAccounts.length();
    }

    function gAccountsAtIndex(uint256 index) external view returns (address) {
        return _gAccounts.at(index);
    }

    // gAccountsByGroupId functions
    function gAccountsByGroupId(
        uint256 groupId
    ) external view returns (address[] memory) {
        return _gAccountsByGroupId[groupId].values();
    }

    function gAccountsByGroupIdCount(
        uint256 groupId
    ) external view returns (uint256) {
        return _gAccountsByGroupId[groupId].length();
    }

    function gAccountsByGroupIdAtIndex(
        uint256 groupId,
        uint256 index
    ) external view returns (address) {
        return _gAccountsByGroupId[groupId].at(index);
    }

    // gAccountsByTokenAddress functions
    function gAccountsByTokenAddress(
        address tokenAddress
    ) external view returns (address[] memory) {
        return _gAccountsByTokenAddress[tokenAddress].values();
    }

    function gAccountsByTokenAddressCount(
        address tokenAddress
    ) external view returns (uint256) {
        return _gAccountsByTokenAddress[tokenAddress].length();
    }

    function gAccountsByTokenAddressAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (address) {
        return _gAccountsByTokenAddress[tokenAddress].at(index);
    }

    // gAccountsByTokenAddressByGroupId functions
    function gAccountsByTokenAddressByGroupId(
        address tokenAddress,
        uint256 groupId
    ) external view returns (address[] memory) {
        return
            _gAccountsByTokenAddressByGroupId[tokenAddress][groupId].values();
    }

    function gAccountsByTokenAddressByGroupIdCount(
        address tokenAddress,
        uint256 groupId
    ) external view returns (uint256) {
        return
            _gAccountsByTokenAddressByGroupId[tokenAddress][groupId].length();
    }

    function gAccountsByTokenAddressByGroupIdAtIndex(
        address tokenAddress,
        uint256 groupId,
        uint256 index
    ) external view returns (address) {
        return
            _gAccountsByTokenAddressByGroupId[tokenAddress][groupId].at(index);
    }
}
