// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface ILpErrors {
    error InsufficientGovRatio();
}

interface ILp is ILpErrors {
    function GOV_RATIO_MULTIPLIER() external view returns (uint256);

    function MIN_GOV_RATIO() external view returns (uint256);

    function deduction(
        uint256 round,
        address account
    )
        external
        view
        returns (
            uint256 deduction,
            uint256[] memory joinBlocks,
            uint256[] memory joinAmounts
        );

    function totalDeduction(uint256 round) external view returns (uint256);

    function govRatio(
        uint256 round,
        address account
    ) external view returns (uint256 ratio, bool claimed);
}
