// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupRecipientsEvents {
    event SetRecipients(
        address indexed sourceTokenAddress,
        uint256 round,
        uint256 indexed sourceActionId,
        uint256 indexed groupId,
        uint256[] recipientIds,
        uint256[] ratios
    );
}

interface IGroupRecipientsErrors {
    error DistributionOverflow(uint256 configured, uint256 available);
    error UnknownSourceAction(address sourceTokenAddress, uint256 sourceActionId);
    error TooManyRecipients(uint256 count, uint256 max);
    error ZeroRecipientRatio(uint256 recipientId);
    error RecipientArrayLengthMismatch(uint256 recipientIdsLength, uint256 ratiosLength, uint256 remarksLength);
    error DuplicateMemberId(uint256 memberId);
    error RecipientIsGroupId(uint256 groupId, uint256 recipientId);
}

interface IGroupRecipients is IGroupRecipientsEvents, IGroupRecipientsErrors {
    function PRECISION() external view returns (uint256);
    function DEFAULT_MAX_RECIPIENTS() external view returns (uint256);

    function setRecipients(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external;

    function recipients(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 round
    ) external view returns (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory remarks);

    function actionIdsWithRecipients(
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total);

    function getDistribution(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 groupReward,
        uint256 round
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            uint256[] memory amounts,
            uint256 ownerAmount
        );
}
