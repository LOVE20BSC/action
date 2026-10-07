// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IGroupActionIndexes {
    function isGroupMember(
        uint256 groupId,
        uint256 memberId
    ) external view returns (bool);

    function gGroupIds(
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

    function gGroupIdsByMemberId(
        uint256 memberId,
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

    function gTokenAddressesByGroupIdByMemberId(
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
            uint256 total
        );

    function gMemberIds(
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

    function gMemberIdsByGroupId(
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
}
