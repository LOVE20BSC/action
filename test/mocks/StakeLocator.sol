// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

/// @dev Stands in for the Vote contract when the only thing an Executor reads is its Stake address.
contract MockStakeLocator {
    address public STAKE_ADDRESS;

    constructor(address stakeAddress) {
        STAKE_ADDRESS = stakeAddress;
    }
}
