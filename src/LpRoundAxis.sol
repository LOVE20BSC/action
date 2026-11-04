// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library LpRoundAxis {
    uint256 private constant MINT_ROUND_PHASE_OFFSET = 2;

    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= MINT_ROUND_PHASE_OFFSET ? 0 : phase - MINT_ROUND_PHASE_OFFSET;
    }
}
