// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library ActionRoundAxis {
    function joinRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase < 2 ? 0 : phase - 1;
    }
}
