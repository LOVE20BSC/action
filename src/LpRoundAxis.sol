// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

library LpRoundAxis {
    /// @dev 返回 0 表示「阶段未开始」；调用方必须显式判 0 后才能当作轮次使用——哨兵不体现在类型里。
    function mintRound(address phaseAddress) internal view returns (uint256) {
        uint256 phase = IPhase(phaseAddress).currentPhase();
        return phase < 3 ? 0 : phase - 2;
    }
}
