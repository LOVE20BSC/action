// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library GroupServiceRoundAxis {
    uint256 private constant SERVICE_MINT_ROUND_PHASE_OFFSET = 3;

    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= SERVICE_MINT_ROUND_PHASE_OFFSET ? 0 : phase - SERVICE_MINT_ROUND_PHASE_OFFSET;
    }
}
