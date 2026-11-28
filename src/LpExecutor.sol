// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILpExecutor, LpCreationParams} from "./interfaces/ILpExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {LpRoundAxis} from "./LpRoundAxis.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IUniswapV2Factory} from "@core/interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@core/interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LpExecutor is ILpExecutor, ExecutorBase {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e18;

    uint256 private constant CREATION_DATA_BYTES = 96;

    address public immutable PAIR_FACTORY_ADDRESS;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address actionTargetAddress) ExecutorBase(actionTargetAddress) {
        PAIR_FACTORY_ADDRESS = IStake(STAKE_ADDRESS).PAIR_FACTORY_ADDRESS();
    }

    // tokenAddress => actionId => join token address
    mapping(address => mapping(uint256 => address)) internal _joinTokenAddressByActionId;

    // tokenAddress => actionId => gov ratio multiplier (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _govRatioMultiplierByActionId;

    // tokenAddress => actionId => minimum gov ratio (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _minGovRatioByActionId;

    // tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRoundByActionId;

    // tokenAddress => actionId => round => memberId => accumulated deduction for time-weighted LP calculation
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _deductionByMemberId;

    // tokenAddress => actionId => round => accumulated total deduction across all members
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _deductionByRound;

    // tokenAddress => actionId => round => memberId => block numbers of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinBlocksByMemberId;

    // tokenAddress => actionId => round => memberId => amounts of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinAmountsByMemberId;

    // tokenAddress => actionId => round => memberId => gov ratio at mint time
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _mintedGovRatioByMemberId;

    // tokenAddress => actionId => memberId => joined amount history
    mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History)))
        internal _joinedAmountByMemberId;

    // tokenAddress => actionId => total joined amount history
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _joinedAmountByActionId;

    // tokenAddress => actionId => round => memberId => whether the member reward is minted
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) internal _memberMinted;

    // tokenAddress => actionId => round => memberId => minted reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _mintedRewardByMemberId;

    // tokenAddress => actionId => round => memberId => burned reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _burnedRewardByMemberId;

    function govRatioMultiplier(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _govRatioMultiplierByActionId[tokenAddress][actionId];
    }

    function minGovRatio(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _minGovRatioByActionId[tokenAddress][actionId];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes calldata creationData
    ) external override onlyActionTarget {
        if (creationData.length != CREATION_DATA_BYTES) {
            revert InvalidCreationDataLength(creationData.length, CREATION_DATA_BYTES);
        }
        if (abi.decode(creationData, (uint256)) > type(uint160).max) {
            revert InvalidCreationDataEncoding();
        }
        LpCreationParams memory params = abi.decode(creationData, (LpCreationParams));

        if (params.joinTokenAddress == address(0)) {
            revert ZeroJoinTokenAddress();
        }
        if (!_isRegisteredPair(params.joinTokenAddress, PAIR_FACTORY_ADDRESS)) {
            revert InvalidJoinTokenFactory(params.joinTokenAddress, PAIR_FACTORY_ADDRESS);
        }
        if (params.minGovRatio > PRECISION) {
            revert InvalidMinGovRatio(params.minGovRatio);
        }

        uint256 actionId = proposalId;
        _joinTokenAddressByActionId[tokenAddress][actionId] = params.joinTokenAddress;
        _govRatioMultiplierByActionId[tokenAddress][actionId] = params.govRatioMultiplier;
        _minGovRatioByActionId[tokenAddress][actionId] = params.minGovRatio;
        _createdRoundByActionId[tokenAddress][actionId] = IPhase(PHASE_ADDRESS).currentPhase();

        emit LpActionCreated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            joinTokenAddress: params.joinTokenAddress,
            govRatioMultiplier: params.govRatioMultiplier,
            minGovRatio: params.minGovRatio
        });
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external virtual override onlyActionTarget {
        (tokenAddress, round, proposalId, voterId, voteAmount);
        if (voteData.length != 0) revert UnexpectedVoteData();
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external nonReentrant onlyMemberOwner(memberId) {
        if (amount == 0) {
            revert ZeroParticipationAmount();
        }
        if (_createdRoundByActionId[tokenAddress][actionId] == 0) {
            revert ActionNotCreated(tokenAddress, actionId);
        }

        uint256 joinRound = currentJoinRound();

        bool isFirstJoin = !IActionTarget(ACTION_TARGET_ADDRESS).isJoined(tokenAddress, actionId, memberId);
        if (isFirstJoin) {
            uint256 minGovRatioValue = _minGovRatioByActionId[tokenAddress][actionId];
            uint256 memberGovRatio = _calculateGovRatio(tokenAddress, IPhase(PHASE_ADDRESS).currentPhase(), memberId);
            if (memberGovRatio < minGovRatioValue) {
                revert InsufficientGovRatio(minGovRatioValue, memberGovRatio);
            }
        }

        (uint256 phaseStartBlock, uint256 phaseBlocks) = IPhase(PHASE_ADDRESS).phaseInfo(joinRound + 1);
        uint256 deductionAdded = Math.mulDiv(amount, block.number - phaseStartBlock, phaseBlocks);
        if (deductionAdded > amount) {
            deductionAdded = amount;
        }
        _deductionByMemberId[tokenAddress][actionId][joinRound][memberId] += deductionAdded;
        _deductionByRound[tokenAddress][actionId][joinRound] += deductionAdded;
        _joinBlocksByMemberId[tokenAddress][actionId][joinRound][memberId].push(block.number);
        _joinAmountsByMemberId[tokenAddress][actionId][joinRound][memberId].push(amount);
        _joinedAmountByMemberId[tokenAddress][actionId][memberId].increase(joinRound, amount);
        _joinedAmountByActionId[tokenAddress][actionId].increase(joinRound, amount);

        if (isFirstJoin) {
            IActionTarget(ACTION_TARGET_ADDRESS).registerJoinState(tokenAddress, actionId, memberId);
        }

        IERC20(_joinTokenAddressByActionId[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), amount);

        emit LpJoined({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound,
            amount: amount
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function withdraw(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external nonReentrant onlyMemberOwner(memberId) {
        if (amount == 0) {
            revert ZeroParticipationAmount();
        }

        uint256 joinRound = currentJoinRound();
        uint256 memberJoinedAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(joinRound);
        if (amount > memberJoinedAmount) {
            revert WithdrawAmountExceeded(amount, memberJoinedAmount);
        }

        bool isFullExit = amount == memberJoinedAmount;
        if (isFullExit) {
            _clearJoinState(tokenAddress, joinRound, actionId, memberId, memberJoinedAmount);
        } else {
            uint256 memberDeduction = _deductionByMemberId[tokenAddress][actionId][joinRound][memberId];
            uint256 deductionReduction = Math.mulDiv(memberDeduction, amount, memberJoinedAmount);

            _deductionByMemberId[tokenAddress][actionId][joinRound][memberId] = memberDeduction - deductionReduction;
            _deductionByRound[tokenAddress][actionId][joinRound] -= deductionReduction;
            _joinedAmountByMemberId[tokenAddress][actionId][memberId].record(joinRound, memberJoinedAmount - amount);
            _joinedAmountByActionId[tokenAddress][actionId].decrease(joinRound, amount);
        }

        IERC20(_joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        _emitLpWithdrawn(tokenAddress, joinRound, actionId, memberId, amount);

        if (isFullExit) {
            IActionTarget(ACTION_TARGET_ADDRESS).clearJoinState(tokenAddress, actionId, memberId);
            emit LpExited({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: joinRound
            });
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(address tokenAddress, uint256 actionId, uint256 memberId)
        external
        nonReentrant
        onlyMemberOwner(memberId)
    {
        uint256 joinRound = currentJoinRound();
        uint256 memberJoinedAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(joinRound);
        if (memberJoinedAmount == 0) {
            revert NotJoined(tokenAddress, actionId, memberId);
        }

        _clearJoinState(tokenAddress, joinRound, actionId, memberId, memberJoinedAmount);

        IERC20(_joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, memberJoinedAmount);

        _emitLpWithdrawn(tokenAddress, joinRound, actionId, memberId, memberJoinedAmount);

        IActionTarget(ACTION_TARGET_ADDRESS).clearJoinState(tokenAddress, actionId, memberId);

        emit LpExited({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function _clearJoinState(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 memberJoinedAmount
    ) internal {
        _deductionByRound[tokenAddress][actionId][round] -= _deductionByMemberId[tokenAddress][actionId][round][memberId];
        delete _deductionByMemberId[tokenAddress][actionId][round][memberId];
        delete _joinBlocksByMemberId[tokenAddress][actionId][round][memberId];
        delete _joinAmountsByMemberId[tokenAddress][actionId][round][memberId];
        _joinedAmountByMemberId[tokenAddress][actionId][memberId].record(round, 0);
        _joinedAmountByActionId[tokenAddress][actionId].decrease(round, memberJoinedAmount);
    }

    function _emitLpWithdrawn(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) private {
        emit LpWithdrawn({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            amount: amount
        });
    }

    function _calculateReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId,
        uint256 totalEffectiveAmount,
        uint256 proposalReward
    ) internal view returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 effectiveAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(round)
            - _deductionByMemberId[tokenAddress][actionId][round][memberId];
        uint256 effectiveLpRatio = Math.mulDiv(effectiveAmount, PRECISION, totalEffectiveAmount);
        uint256 theoreticalReward = Math.mulDiv(proposalReward, effectiveAmount, totalEffectiveAmount);

        uint256 govRatioMultiplierValue = _govRatioMultiplierByActionId[tokenAddress][actionId];
        if (govRatioMultiplierValue == 0) {
            return (theoreticalReward, 0);
        }

        uint256 currentPhase = IPhase(PHASE_ADDRESS).currentPhase();
        if (IStake(STAKE_ADDRESS).totalGovPower(tokenAddress, currentPhase) == 0) {
            return (0, theoreticalReward);
        }

        uint256 govRatioCap =
            Math.mulDiv(_calculateGovRatio(tokenAddress, currentPhase, memberId), govRatioMultiplierValue, PRECISION);
        uint256 cappedRatio = effectiveLpRatio < govRatioCap ? effectiveLpRatio : govRatioCap;

        // Load-bearing: when the cap does not bind, mint the exact theoretical amount. Re-deriving it
        // from the truncated ratio can fall short by one unit and turn a no-burn settlement into a
        // one-unit burn.
        mintAmount =
            cappedRatio == effectiveLpRatio ? theoreticalReward : Math.mulDiv(proposalReward, cappedRatio, PRECISION);
        burnAmount = theoreticalReward - mintAmount;
    }

    function deduction(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 amount, uint256[] memory joinBlocks, uint256[] memory joinAmounts) {
        amount = _deductionByMemberId[tokenAddress][actionId][round][memberId];
        joinBlocks = _joinBlocksByMemberId[tokenAddress][actionId][round][memberId];
        joinAmounts = _joinAmountsByMemberId[tokenAddress][actionId][round][memberId];
    }

    function deductionByRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256) {
        return _deductionByRound[tokenAddress][actionId][round];
    }

    function _calculateGovRatio(
        address tokenAddress,
        uint256 currentPhase,
        uint256 memberId
    ) internal view returns (uint256) {
        uint256 totalGovPower = IStake(STAKE_ADDRESS).totalGovPower(tokenAddress, currentPhase);
        if (totalGovPower == 0) {
            return 0;
        }
        uint256 memberGovPower = IStake(STAKE_ADDRESS).govPower(tokenAddress, currentPhase, memberId);
        return Math.mulDiv(memberGovPower, PRECISION, totalGovPower);
    }

    function govRatio(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 ratio, bool minted) {
        minted = _memberMinted[tokenAddress][actionId][round][memberId];
        if (minted) {
            ratio = _mintedGovRatioByMemberId[tokenAddress][actionId][round][memberId];
        } else {
            ratio = _calculateGovRatio(tokenAddress, IPhase(PHASE_ADDRESS).currentPhase(), memberId);
        }
    }

    function memberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        uint256 amount;
        (amount,, status) = rewardDetail(tokenAddress, round, actionId, memberId);
        if (status == MemberRewardStatus.Settled) {
            mintedAmount = amount;
        } else {
            pendingAmount = amount;
        }
    }

    function rewardDetail(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) public view returns (uint256 mintAmount, uint256 burnAmount, MemberRewardStatus status) {
        if (_memberMinted[tokenAddress][actionId][round][memberId]) {
            return (
                _mintedRewardByMemberId[tokenAddress][actionId][round][memberId],
                _burnedRewardByMemberId[tokenAddress][actionId][round][memberId],
                MemberRewardStatus.Settled
            );
        }

        if (_isSettleableRound(tokenAddress, round, actionId)) {
            (mintAmount, burnAmount) = _pendingMemberReward(tokenAddress, round, actionId, memberId);
            if (mintAmount != 0 || burnAmount != 0) {
                status = MemberRewardStatus.Pending;
            }
        }
    }

    function joinedAmountByActionId(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return _joinedAmountByActionId[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(round);
    }

    function joinTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return _joinTokenAddressByActionId[tokenAddress][actionId];
    }

    function _isSettleableRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) private view returns (bool) {
        uint256 createdRound = _createdRoundByActionId[tokenAddress][actionId];
        return createdRound != 0 && round >= createdRound && round <= _mintRound();
    }

    function _totalEffectiveAmount(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) internal view returns (uint256) {
        return _joinedAmountByActionId[tokenAddress][actionId].value(round) - _deductionByRound[tokenAddress][actionId][round];
    }

    function _pendingMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal view returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 totalEffectiveAmount = _totalEffectiveAmount(tokenAddress, round, actionId);
        if (totalEffectiveAmount == 0) {
            return (0, 0);
        }
        (uint256 proposalReward, ) = IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, round, actionId);
        (mintAmount, burnAmount) =
            _calculateReward(tokenAddress, round, actionId, memberId, totalEffectiveAmount, proposalReward);
    }

    function _mintRound() internal view override returns (uint256) {
        return LpRoundAxis.mintRound(PHASE_ADDRESS);
    }

    function _isRegisteredPair(address lpTokenAddress, address factory) internal view returns (bool) {
        if (lpTokenAddress.code.length == 0 || factory.code.length == 0) {
            return false;
        }

        address token0 = address(0);
        try IUniswapV2Pair(lpTokenAddress).token0() returns (address result) {
            token0 = result;
        } catch {
            return false;
        }

        address token1 = address(0);
        try IUniswapV2Pair(lpTokenAddress).token1() returns (address result) {
            token1 = result;
        } catch {
            return false;
        }

        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            return false;
        }

        try IUniswapV2Factory(factory).getPair(token0, token1) returns (address pair) {
            return pair == lpTokenAddress;
        } catch {
            return false;
        }
    }
    // forge-lint: disable-next-item(require-revert-in-loop, missing-events-access-control)
    function _mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(
            tokenAddress,
            round,
            actionId,
            memberId,
            _createdRoundByActionId[tokenAddress][actionId],
            _memberMinted[tokenAddress][actionId][round][memberId]
        );

        uint256 totalEffectiveAmount = _totalEffectiveAmount(tokenAddress, round, actionId);
        if (totalEffectiveAmount == 0) {
            revert MemberRewardPoolEmpty(tokenAddress, round);
        }

        (uint256 proposalReward, bool actionMinted) =
            IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, round, actionId);
        if (!actionMinted && proposalReward != 0) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            proposalReward = IActionTarget(ACTION_TARGET_ADDRESS).mintActionReward(tokenAddress, round, actionId);
        }
        if (proposalReward == 0) {
            revert MemberRewardPoolEmpty(tokenAddress, round);
        }

        (mintAmount, burnAmount) =
            _calculateReward(tokenAddress, round, actionId, memberId, totalEffectiveAmount, proposalReward);

        if (mintAmount == 0 && burnAmount == 0) {
            uint256 effectiveAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(round)
                - _deductionByMemberId[tokenAddress][actionId][round][memberId];
            if (effectiveAmount == 0) {
                revert ZeroEffectiveJoinAmount(tokenAddress, actionId, memberId);
            }
            revert MemberRewardRoundedToZero(tokenAddress, round, memberId);
        }

        _memberMinted[tokenAddress][actionId][round][memberId] = true;
        _mintedRewardByMemberId[tokenAddress][actionId][round][memberId] = mintAmount;
        _burnedRewardByMemberId[tokenAddress][actionId][round][memberId] = burnAmount;
        _mintedGovRatioByMemberId[tokenAddress][actionId][round][memberId] =
            _calculateGovRatio(tokenAddress, IPhase(PHASE_ADDRESS).currentPhase(), memberId);

        if (burnAmount != 0) {
            ILOVE20Token(tokenAddress).burn(burnAmount);
        }
        if (mintAmount != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, mintAmount);
        }

        emit MemberRewardMinted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            mintAmount: mintAmount,
            burnAmount: burnAmount
        });
    }
}
