// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IGroupActionEvents {}

interface IGroupAction is IGroupActionEvents {
    function JOIN_TOKEN_ADDRESS() external view returns (address);
    function ACTIVATION_STAKE_AMOUNT() external view returns (uint256);
    function MAX_JOIN_AMOUNT_RATIO() external view returns (uint256);
    function ACTIVATION_MIN_GOV_RATIO() external view returns (uint256);

    function generatedActionRewardByGroupId(
        uint256 round,
        uint256 groupId
    ) external view returns (uint256);

    function generatedActionRewardByVerifier(
        address verifier,
        uint256 round
    ) external view returns (uint256);
}
