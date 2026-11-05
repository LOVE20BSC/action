// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library ActionRoundAxis {
    uint256 private constant OFFSET_JOIN_ROUND = 1;

    function joinRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_JOIN_ROUND ? 0 : phase - OFFSET_JOIN_ROUND;
    }
}
