// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IActionExecutor, IActionExecutorErrors} from "./interfaces/IActionExecutor.sol";

abstract contract ExecutorBase is IActionExecutor, ReentrancyGuard {
    // forge-lint: disable-next-item(require-revert-in-loop)
    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(_memberNFTAddress()).ownerOf(memberId) != msg.sender) {
            revert IActionExecutorErrors.NotMemberOwner(memberId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) public override nonReentrant onlyMemberOwner(memberId) returns (uint256 mintAmount, uint256 burnAmount) {
        return _mintMemberReward(tokenAddress, actionId, memberId, round);
    }

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata actionIds_,
        uint256 memberId,
        uint256[] calldata rounds
    )
        external
        override
        nonReentrant
        onlyMemberOwner(memberId)
        returns (uint256[] memory mintAmounts, uint256[] memory burnAmounts)
    {
        uint256 length = actionIds_.length;
        if (length != rounds.length) {
            revert IActionExecutorErrors.BatchLengthMismatch(length, rounds.length);
        }

        mintAmounts = new uint256[](length);
        burnAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            (mintAmounts[i], burnAmounts[i]) = _mintMemberReward(tokenAddress, actionIds_[i], memberId, rounds[i]);
        }
    }

    function currentVoteRound() external view override returns (uint256) {
        uint256 phase = IPhase(_phaseAddress()).currentPhase();
        if (phase < 1) {
            revert IActionExecutorErrors.RoundNotStarted(1, phase);
        }
        return phase;
    }

    function currentJoinRound() public view override returns (uint256) {
        uint256 round = _joinRound();
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    function currentMintRound() external view override returns (uint256) {
        uint256 round = _mintRound();
        if (round == 0) {
            revert IActionExecutorErrors.RoundNotStarted(1, 0);
        }
        return round;
    }

    function _memberNFTAddress() internal view virtual returns (address);

    function _phaseAddress() internal view virtual returns (address);

    function _joinRound() internal view virtual returns (uint256);

    function _mintRound() internal view virtual returns (uint256);

    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) internal virtual returns (uint256 mintAmount, uint256 burnAmount);
}
