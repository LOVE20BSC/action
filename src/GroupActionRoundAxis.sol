// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library GroupActionRoundAxis {
    uint256 private constant OFFSET_VERIFY_ROUND = 2;
    uint256 private constant OFFSET_MINT_ROUND = 3;

    function verifyRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_VERIFY_ROUND ? 0 : phase - OFFSET_VERIFY_ROUND;
    }

    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_MINT_ROUND ? 0 : phase - OFFSET_MINT_ROUND;
    }
}
