// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupRecipientsEvents {
    event RecipientsChanged(
        address indexed sourceTokenAddress,
        uint256 indexed sourceActionId,
        uint256 round,
        uint256 indexed groupId,
        uint256[] recipientIds,
        uint256[] ratios,
        string[] remarks,
        uint256[] prevRecipientIds,
        uint256[] prevRatios,
        string[] prevRemarks
    );
}

interface IGroupRecipientsErrors {
    error DistributionOverflow(
        uint256 configured,
        uint256 limit
    );
    error UnknownSourceAction(
        address sourceTokenAddress,
        uint256 sourceActionId
    );
    error TooManyRecipients(
        uint256 count,
        uint256 maxCount
    );
    error RecipientActionsLimitExceeded(
        address sourceTokenAddress,
        uint256 groupId,
        uint256 actual,
        uint256 limit
    );
    error ZeroRecipientRatio(uint256 recipientId);
    error RecipientArrayLengthMismatch(
        uint256 recipientIdsLength,
        uint256 ratiosLength,
        uint256 remarksLength
    );
    error DuplicateMemberId(uint256 memberId);
    error RecipientIsGroupId(
        uint256 groupId,
        uint256 recipientId
    );
    error RemarkTooLong(
        uint256 index,
        uint256 length,
        uint256 maxLength
    );
}

interface IGroupRecipients is IGroupRecipientsEvents, IGroupRecipientsErrors {
    function PRECISION() external view returns (uint256);
    function MAX_RECIPIENTS_PER_ACTION() external view returns (uint256);
    function MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP() external view returns (uint256);

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
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) external view returns (uint256[] memory recipientIds, uint256[] memory ratios, string[] memory remarks);

    function recipientRatio(
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 ratio);

    function actionIdsWithRecipients(
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount);

    function currentRecipientGroupIdsByRecipientId(
        address sourceTokenAddress,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory groupIds, uint256 totalCount);

    function currentRecipientSourceActionIdsByRecipientIdByGroupId(
        address sourceTokenAddress,
        uint256 recipientId,
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory sourceActionIds, uint256 totalCount);
}
