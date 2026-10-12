// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupRecipients} from "./interface/IGroupRecipients.sol";
import {
    RoundHistoryAddressArray
} from "@extension/src/lib/RoundHistoryAddressArray.sol";
import {
    RoundHistoryUint256Array
} from "@extension/src/lib/RoundHistoryUint256Array.sol";
import {
    RoundHistoryStringArray
} from "@extension/src/lib/RoundHistoryStringArray.sol";
import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ILOVE20Verify} from "@core/interfaces/ILOVE20Verify.sol";
import {IGroupActionFactory} from "./interface/IGroupActionFactory.sol";
import {
    IExtensionFactory
} from "@extension/src/interface/IExtensionFactory.sol";
import {IExtensionCenter} from "@extension/src/interface/IExtensionCenter.sol";

contract GroupRecipients is IGroupRecipients {
    using RoundHistoryAddressArray for RoundHistoryAddressArray.History;
    using RoundHistoryUint256Array for RoundHistoryUint256Array.History;
    using RoundHistoryStringArray for RoundHistoryStringArray.History;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant DEFAULT_MAX_RECIPIENTS = 10;

    IERC721Enumerable internal immutable _group;
    ILOVE20Verify internal immutable _verify;

    // groupOwner => tokenAddress => actionId => groupId => recipients
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryAddressArray.History))))
        internal _recipientsHistory;
    // groupOwner => tokenAddress => actionId => groupId => ratios
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256Array.History))))
        internal _ratiosHistory;
    // groupOwner => tokenAddress => actionId => groupId => remarks
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryStringArray.History))))
        internal _remarksHistory;
    // groupOwner => tokenAddress => actionIds
    mapping(address => mapping(address => RoundHistoryUint256Array.History))
        internal _actionIdsWithRecipients;
    // groupOwner => tokenAddress => actionId => groupIds
    mapping(address => mapping(address => mapping(uint256 => RoundHistoryUint256Array.History)))
        internal _groupIdsByActionIdWithRecipients;

    constructor(address groupActionFactoryAddress_) {
        if (groupActionFactoryAddress_ == address(0)) revert ZeroAddress();
        IGroupActionFactory factory = IGroupActionFactory(
            groupActionFactoryAddress_
        );
        address groupAddress = factory.GROUP_ADDRESS();
        if (groupAddress == address(0)) revert ZeroAddress();
        _group = IERC721Enumerable(groupAddress);

        address verifyAddress = IExtensionCenter(
            IExtensionFactory(groupActionFactoryAddress_).CENTER_ADDRESS()
        ).verifyAddress();
        if (verifyAddress == address(0)) revert ZeroAddress();
        _verify = ILOVE20Verify(verifyAddress);
    }

    modifier onlyGroupOwner(uint256 groupId) {
        if (_group.ownerOf(groupId) != msg.sender) revert OnlyGroupOwner();
        _;
    }

    function setRecipients(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        address[] calldata addrs,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external onlyGroupOwner(groupId) {
        address owner = msg.sender;
        uint256 round = _verify.currentRound();
        _validateRecipients(owner, addrs, ratios, remarks);
        _recordRecipients(owner, tokenAddress, actionId, groupId, round, addrs, ratios, remarks);
        _updateTrackingAndEmit(
            owner,
            tokenAddress,
            actionId,
            groupId,
            round,
            addrs,
            ratios,
            remarks
        );
    }

    function _updateTrackingAndEmit(
        address owner,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 round,
        address[] calldata addrs,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) internal {
        if (addrs.length > 0) {
            _actionIdsWithRecipients[owner][tokenAddress].add(round, actionId);
            _groupIdsByActionIdWithRecipients[owner][tokenAddress][actionId]
                .add(round, groupId);
        } else if (
            _groupIdsByActionIdWithRecipients[owner][tokenAddress][actionId]
                .remove(round, groupId)
        ) {
            if (
                _groupIdsByActionIdWithRecipients[owner][tokenAddress][actionId]
                    .values(round)
                    .length == 0
            ) {
                _actionIdsWithRecipients[owner][tokenAddress].remove(
                    round,
                    actionId
                );
            }
        }
        emit SetRecipients({
            tokenAddress: tokenAddress,
            round: round,
            actionId: actionId,
            groupId: groupId,
            account: owner,
            recipients: addrs,
            ratios: ratios,
            remarks: remarks
        });
    }

    function _recordRecipients(
        address owner,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 round,
        address[] calldata addrs,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) internal {
        _recipientsHistory[owner][tokenAddress][actionId][groupId].record(
            round,
            addrs
        );
        _ratiosHistory[owner][tokenAddress][actionId][groupId].record(
            round,
            ratios
        );
        _remarksHistory[owner][tokenAddress][actionId][groupId].record(
            round,
            remarks
        );
    }

    function recipients(
        address groupOwner,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 round
    )
        external
        view
        returns (
            address[] memory addrs,
            uint256[] memory ratios,
            string[] memory remarks
        )
    {
        addrs = _recipientsHistory[groupOwner][tokenAddress][actionId][groupId]
            .values(round);
        ratios = _ratiosHistory[groupOwner][tokenAddress][actionId][groupId]
            .values(round);
        remarks = _remarksHistory[groupOwner][tokenAddress][actionId][groupId]
            .values(round);
    }

    function actionIdsWithRecipients(
        address groupOwner,
        address tokenAddress,
        uint256 round
    ) external view returns (uint256[] memory) {
        return _actionIdsWithRecipients[groupOwner][tokenAddress].values(round);
    }

    function groupIdsByActionIdWithRecipients(
        address groupOwner,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory) {
        return
            _groupIdsByActionIdWithRecipients[groupOwner][tokenAddress][
                actionId
            ].values(round);
    }

    function getDistribution(
        address groupOwner,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 groupReward,
        uint256 round
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
        addrs = _recipientsHistory[groupOwner][tokenAddress][actionId][groupId]
            .values(round);
        ratios = _ratiosHistory[groupOwner][tokenAddress][actionId][groupId]
            .values(round);
        uint256 distributed;
        (amounts, distributed) = _calculateRecipientAmounts(
            groupReward,
            addrs,
            ratios
        );
        ownerAmount = groupReward - distributed;
    }

    function _validateRecipients(
        address account,
        address[] calldata addrs,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) internal pure {
        uint256 len = addrs.length;
        if (len != ratios.length || len != remarks.length)
            revert ArrayLengthMismatch();
        if (len > DEFAULT_MAX_RECIPIENTS) revert TooManyRecipients();

        uint256 totalRatios;
        for (uint256 i; i < len; ) {
            if (addrs[i] == address(0)) revert ZeroAddress();
            if (addrs[i] == account) revert RecipientCannotBeSelf();
            if (ratios[i] == 0) revert ZeroRatio();
            totalRatios += ratios[i];

            if (i > 0) {
                address addr = addrs[i];
                for (uint256 j; j < i; ) {
                    if (addrs[j] == addr) revert DuplicateAddress();
                    unchecked {
                        ++j;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }
        if (totalRatios > PRECISION) revert InvalidRatio();
    }

    function _calculateRecipientAmounts(
        uint256 groupReward,
        address[] memory addrs,
        uint256[] memory ratios
    ) internal pure returns (uint256[] memory amounts, uint256 distributed) {
        uint256 len = addrs.length;
        amounts = new uint256[](len);
        for (uint256 i; i < len; ) {
            amounts[i] = (groupReward * ratios[i]) / PRECISION;
            distributed += amounts[i];
            unchecked {
                ++i;
            }
        }
    }
}
