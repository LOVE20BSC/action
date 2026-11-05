// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library GroupServiceRoundAxis {
    uint256 private constant OFFSET_SERVICE_MINT = 3;

    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_SERVICE_MINT ? 0 : phase - OFFSET_SERVICE_MINT;
    }
}
