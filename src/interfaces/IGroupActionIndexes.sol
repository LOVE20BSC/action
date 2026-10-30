// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupActionIndexes {
    function isGroupMember(
        uint256 groupId,
        uint256 memberId
    ) external view returns (bool);

    function joinedGroupIds(
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

    function joinedGroupIdsByMemberId(
        uint256 memberId,
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

    function joinedTokenAddressesByGroupIdByMemberId(
        uint256 groupId,
        uint256 memberId,
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

    function joinedMemberIds(
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256 totalCount
        );

    function joinedMemberIdsByGroupId(
        uint256 groupId,
        uint256 offset,
        uint256 limit,
        bool reverse
    )
        external
        view
        returns (
            uint256[] memory memberIds,
            uint256 totalCount
        );
}
