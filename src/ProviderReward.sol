// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library ProviderReward {
    uint256 private constant PRECISION = 1e18;

    function weight(uint256 groupWeight, uint256 providerScore, uint256 groupScore) internal pure returns (uint256) {
        if (providerScore == 0) return 0;
        return Math.mulDiv(groupWeight * PRECISION, providerScore, groupScore);
    }

    function amount(uint256 marketBudget, uint256 providerWeight, uint256 ownerWeight) internal pure returns (uint256) {
        return Math.mulDiv(marketBudget, providerWeight, ownerWeight * PRECISION);
    }
}
