// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";
import {IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

library GroupActionRoundAxis {
    uint256 private constant OFFSET_VERIFY_ROUND = 2;
    uint256 private constant OFFSET_MINT_ROUND = 3;

    function verifyRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_VERIFY_ROUND ? 0 : phase - OFFSET_VERIFY_ROUND;
    }

    function currentVerifyRound(address phaseAddress) internal view returns (uint256 round) {
        round = verifyRound(phaseAddress);
        if (round == 0) revert IActionExecutorErrors.RoundNotStarted(1, 0);
    }

    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase <= OFFSET_MINT_ROUND ? 0 : phase - OFFSET_MINT_ROUND;
    }
}
