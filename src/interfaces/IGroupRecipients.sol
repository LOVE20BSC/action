// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IGroupRecipientsEvents {
    event SetRecipients(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        uint256 indexed groupId,
        address account,
        address[] recipients,
        uint256[] ratios,
        string[] remarks
    );
}

interface IGroupRecipientsErrors {
    error InvalidRatio();
    error TooManyRecipients();
    error ZeroAddress();
    error ZeroRatio();
    error ArrayLengthMismatch();
    error DuplicateAddress();
    error RecipientCannotBeSelf();
    error OnlyGroupOwner();
}

interface IGroupRecipients is IGroupRecipientsEvents, IGroupRecipientsErrors {
    function PRECISION() external view returns (uint256);
    function DEFAULT_MAX_RECIPIENTS() external view returns (uint256);

    function setRecipients(
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        address[] calldata addrs,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external;

    function recipients(
        address groupOwner,
        address tokenAddress,
        uint256 actionId,
        uint256 groupId,
        uint256 round
    ) external view returns (address[] memory addrs, uint256[] memory ratios, string[] memory remarks);

    function actionIdsWithRecipients(
        address groupOwner,
        address tokenAddress,
        uint256 round
    ) external view returns (uint256[] memory);

    function groupIdsByActionIdWithRecipients(
        address groupOwner,
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256[] memory);

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
        );
}
