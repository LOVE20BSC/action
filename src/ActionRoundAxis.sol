// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library ActionRoundAxis {
    uint256 private constant JOIN_ROUND_PHASE_OFFSET = 1;

    function joinRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= JOIN_ROUND_PHASE_OFFSET ? 0 : phase - JOIN_ROUND_PHASE_OFFSET;
    }
}
