// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {ILp} from "./interface/ILp.sol";
import {
    ExtensionBaseRewardTokenJoin
} from "@extension/src/ExtensionBaseRewardTokenJoin.sol";
import {RoundHistoryUint256} from "@extension/src/lib/RoundHistoryUint256.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {ILOVE20Stake} from "@core/interfaces/ILOVE20Stake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ExtensionLp is ExtensionBaseRewardTokenJoin, ILp {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    uint256 public constant DEFAULT_WAITING_BLOCKS = 1;
    uint256 internal constant PRECISION = 1e18;

    uint256 public immutable GOV_RATIO_MULTIPLIER;
    uint256 public immutable MIN_GOV_RATIO;

    ILOVE20Stake internal immutable _stake;

    /// @dev round => accumulated deduction for time-weighted LP calculation
    mapping(uint256 => mapping(address => uint256)) internal _deduction;

    /// @dev round => accumulated total deduction across all accounts
    mapping(uint256 => uint256) internal _totalDeduction;

    /// @dev round => account => block numbers of each join in this round
    mapping(uint256 => mapping(address => uint256[])) internal _joinBlocks;

    /// @dev round => account => amounts of each join in this round
    mapping(uint256 => mapping(address => uint256[])) internal _joinAmounts;

    /// @dev round => account => gov ratio at claim time
    mapping(uint256 => mapping(address => uint256)) internal _govRatio;

    constructor(
        address factory_,
        address tokenAddress_,
        address joinTokenAddress_,
        uint256 govRatioMultiplier_,
        uint256 minGovRatio_
    )
        ExtensionBaseRewardTokenJoin(
            factory_,
            tokenAddress_,
            joinTokenAddress_,
            DEFAULT_WAITING_BLOCKS
        )
    {
        GOV_RATIO_MULTIPLIER = govRatioMultiplier_;
        MIN_GOV_RATIO = minGovRatio_;
        _stake = ILOVE20Stake(_center.stakeAddress());
    }

    function join(
        uint256 amount,
        string[] memory verificationInfos
    ) public virtual override(ExtensionBaseRewardTokenJoin) {
        bool isFirstJoin = _lastJoinedBlockByAccount[msg.sender] == 0;
        if (isFirstJoin) {
            if (_calculateGovRatio(msg.sender) < MIN_GOV_RATIO) {
                revert InsufficientGovRatio();
            }
        }

        // Accumulate deduction: amount * elapsedBlocks / phaseBlocks
        uint256 currentRound = _join.currentRound();
        uint256 phaseBlocks = _join.phaseBlocks();
        uint256 roundStartBlock = _join.originBlocks() +
            currentRound *
            phaseBlocks;
        uint256 elapsedBlocks = block.number - roundStartBlock;
        uint256 d = (amount * elapsedBlocks) / phaseBlocks;
        _deduction[currentRound][msg.sender] += d;
        _totalDeduction[currentRound] += d;
        _joinBlocks[currentRound][msg.sender].push(block.number);
        _joinAmounts[currentRound][msg.sender].push(amount);

        super.join(amount, verificationInfos);
    }

    function exit() public virtual override {
        uint256 currentRound = _join.currentRound();
        uint256 accountDeduction = _deduction[currentRound][msg.sender];
        super.exit();
        _totalDeduction[currentRound] -= accountDeduction;
        delete _deduction[currentRound][msg.sender];
        delete _joinBlocks[currentRound][msg.sender];
        delete _joinAmounts[currentRound][msg.sender];
    }

    function _calculateReward(
        uint256 round,
        address account
    )
        internal
        view
        virtual
        override
        returns (uint256 mintReward, uint256 burnReward)
    {
        if (round >= _verify.currentRound()) {
            return (0, 0);
        }

        uint256 totalActionReward = reward(round);
        if (totalActionReward == 0) {
            return (0, 0);
        }

        uint256 joinedAmount = _joinedAmountByAccountHistory[account].value(
            round
        );
        uint256 totalJoined = _joinedAmountHistory.value(round);
        uint256 totalEffective = totalJoined - _totalDeduction[round];
        if (totalEffective == 0 || joinedAmount == 0) {
            return (0, 0);
        }

        // Effective LP ratio (denominator is totalEffective)
        uint256 roundDeduction = _deduction[round][account];
        uint256 effectiveAmount = joinedAmount - roundDeduction;
        uint256 effectiveLpRatio = (effectiveAmount * PRECISION) /
            totalEffective;

        // Theoretical reward based on effective ratio
        uint256 theoreticalReward = (totalActionReward * effectiveLpRatio) /
            PRECISION;

        if (GOV_RATIO_MULTIPLIER == 0) {
            return (theoreticalReward, 0);
        }

        uint256 totalGovVotes = _stake.govVotesNum(TOKEN_ADDRESS);
        if (totalGovVotes == 0) {
            return (0, theoreticalReward);
        }
        uint256 govVotes = _stake.validGovVotes(TOKEN_ADDRESS, account);
        uint256 govVotesRatio = (govVotes * PRECISION * GOV_RATIO_MULTIPLIER) /
            totalGovVotes;

        uint256 cappedRatio = effectiveLpRatio < govVotesRatio
            ? effectiveLpRatio
            : govVotesRatio;

        mintReward = (totalActionReward * cappedRatio) / PRECISION;
        burnReward = theoreticalReward - mintReward;

        return (mintReward, burnReward);
    }

    function _calculateBurnAmount(
        uint256 round,
        uint256 totalReward
    ) internal view virtual override returns (uint256) {
        if (totalReward == 0) return 0;

        uint256 totalJoined = _joinedAmountHistory.value(round);

        // If no one participated, burn all reward
        if (totalJoined == 0) {
            return totalReward;
        }

        // If someone participated, burning is handled by each participant during claim
        return 0;
    }

    function deduction(
        uint256 round,
        address account
    )
        external
        view
        returns (
            uint256 deduction_,
            uint256[] memory joinBlocks_,
            uint256[] memory joinAmounts_
        )
    {
        deduction_ = _deduction[round][account];
        joinBlocks_ = _joinBlocks[round][account];
        joinAmounts_ = _joinAmounts[round][account];
        return (deduction_, joinBlocks_, joinAmounts_);
    }

    function totalDeduction(uint256 round) external view returns (uint256) {
        return _totalDeduction[round];
    }

    /// @return Account's gov ratio (1e18): govValid / govTotal; 0 if govTotal==0
    function _calculateGovRatio(
        address account
    ) internal view returns (uint256) {
        uint256 govTotal = _stake.govVotesNum(TOKEN_ADDRESS);
        if (govTotal == 0) return 0;
        uint256 govValid = _stake.validGovVotes(TOKEN_ADDRESS, account);
        return (govValid * PRECISION) / govTotal;
    }

    function govRatio(
        uint256 round,
        address account
    ) external view returns (uint256 ratio, bool claimed) {
        claimed = _claimedByAccount[round][account];
        if (claimed) {
            ratio = _govRatio[round][account];
        } else {
            ratio = _calculateGovRatio(account);
        }
    }

    function _claimReward(
        uint256 round
    ) internal override returns (uint256 mintReward, uint256 burnReward) {
        uint256 ratioAtClaim = _calculateGovRatio(msg.sender);
        (mintReward, burnReward) = super._claimReward(round);
        _govRatio[round][msg.sender] = ratioAtClaim;
        return (mintReward, burnReward);
    }
}
