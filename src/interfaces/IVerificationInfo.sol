// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IVerificationInfo {
    function verificationSchema(
        address tokenAddress,
        uint256 actionId
    )
        external
        view
        returns (string[] memory keys, string[] memory descriptions);

    function verificationValue(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        string calldata key
    ) external view returns (string memory value);

    function verificationInfos(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external view returns (string[] memory keys, string[] memory values);

    function verificationInfosByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (string[] memory keys, string[] memory values);
}
