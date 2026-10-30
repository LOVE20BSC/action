// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILpExecutor} from "./interfaces/ILpExecutor.sol";
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

    address public ACTION_TARGET_ADDRESS;
    bool public initialized;

    address public MEMBER_NFT_ADDRESS;
    address public PHASE_ADDRESS;
    address public STAKE_ADDRESS;
    address public PAIR_FACTORY_ADDRESS;

    /// @dev tokenAddress => actionId => join token address
    mapping(address => mapping(uint256 => address)) internal _joinTokenAddressByActionId;

    /// @dev tokenAddress => actionId => gov ratio multiplier (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _govRatioMultiplierByActionId;

    /// @dev tokenAddress => actionId => minimum gov ratio (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _minGovRatioByActionId;

    /// @dev tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRoundByActionId;

    /// @dev tokenAddress => actionId => round => memberId => accumulated deduction for time-weighted LP calculation
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _deductionByMemberId;

    /// @dev tokenAddress => actionId => round => accumulated total deduction across all members
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _deductionByRound;

    /// @dev tokenAddress => actionId => round => memberId => block numbers of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinBlocksByMemberId;

    /// @dev tokenAddress => actionId => round => memberId => amounts of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinAmountsByMemberId;

    /// @dev tokenAddress => actionId => round => memberId => gov ratio at mint time
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _mintedGovRatioByMemberId;

    /// @dev tokenAddress => actionId => memberId => joined amount history
    mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History)))
        internal _joinedAmountByMemberId;

    /// @dev tokenAddress => actionId => total joined amount history
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _joinedAmountByActionId;

    /// @dev tokenAddress => actionId => round => memberId => whether the member reward is minted
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) internal _memberMinted;

    /// @dev tokenAddress => actionId => round => memberId => minted reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _mintedRewardByMemberId;

    /// @dev tokenAddress => actionId => round => memberId => burned reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _burnedRewardByMemberId;

    modifier onlyActionTarget() {
        if (msg.sender != ACTION_TARGET_ADDRESS) {
            revert NotActionTarget(msg.sender);
        }
        _;
    }

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

    // forge-lint: disable-next-item(missing-zero-check)
    function init(address actionTargetAddress, address stakeAddress) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        address memberNFTAddress = IStake(stakeAddress).MEMBER_NFT_ADDRESS();
        address phaseAddress = IStake(stakeAddress).PHASE_ADDRESS();
        address pairFactoryAddress = IStake(stakeAddress).PAIR_FACTORY_ADDRESS();

        ACTION_TARGET_ADDRESS = actionTargetAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        STAKE_ADDRESS = stakeAddress;
        PHASE_ADDRESS = phaseAddress;
        PAIR_FACTORY_ADDRESS = pairFactoryAddress;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        address tokenAddress,
        uint256 actionId,
        bytes[] calldata targetData
    ) external onlyActionTarget {
        if (targetData.length != 4) {
            revert TargetDataLengthMismatch(4, targetData.length);
        }
        // forge-lint: disable-next-item(require-revert-in-loop)
        for (uint256 i = 0; i < 4; i++) {
            if (targetData[i].length != 32) {
                revert InvalidTargetDataShape(i, targetData[i].length);
            }
        }

        address lpTokenAddress = abi.decode(targetData[1], (address));
        uint256 govRatioMultiplierValue = abi.decode(targetData[2], (uint256));
        uint256 minGovRatioValue = abi.decode(targetData[3], (uint256));

        if (lpTokenAddress == address(0)) {
            revert ZeroJoinTokenAddress();
        }
        if (!_isRegisteredPair(lpTokenAddress, PAIR_FACTORY_ADDRESS)) {
            revert InvalidJoinTokenFactory(lpTokenAddress, PAIR_FACTORY_ADDRESS);
        }
        if (minGovRatioValue > PRECISION) {
            revert InvalidMinGovRatio(minGovRatioValue);
        }

        _joinTokenAddressByActionId[tokenAddress][actionId] = lpTokenAddress;
        _govRatioMultiplierByActionId[tokenAddress][actionId] = govRatioMultiplierValue;
        _minGovRatioByActionId[tokenAddress][actionId] = minGovRatioValue;
        _createdRoundByActionId[tokenAddress][actionId] = IPhase(PHASE_ADDRESS).currentPhase();

        emit LpActionCreated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            joinTokenAddress: lpTokenAddress,
            govRatioMultiplier: govRatioMultiplierValue,
            minGovRatio: minGovRatioValue
        });
    }

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata)
        external
        virtual
        override
        onlyActionTarget
    {}

    function onProposalVoted(address, uint256, uint256, uint256, uint256, bytes[] calldata targetData)
        external
        virtual
        override
        onlyActionTarget
    {
        if (targetData.length > 1) {
            revert TargetDataLengthMismatch(1, targetData.length);
        }
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
            _clearJoinState(tokenAddress, actionId, joinRound, memberId, memberJoinedAmount);
        } else {
            uint256 memberDeduction = _deductionByMemberId[tokenAddress][actionId][joinRound][memberId];
            uint256 deductionReduction = Math.mulDiv(memberDeduction, amount, memberJoinedAmount);

            _deductionByMemberId[tokenAddress][actionId][joinRound][memberId] = memberDeduction - deductionReduction;
            _deductionByRound[tokenAddress][actionId][joinRound] -= deductionReduction;
            _joinedAmountByMemberId[tokenAddress][actionId][memberId].record(joinRound, memberJoinedAmount - amount);
            _joinedAmountByActionId[tokenAddress][actionId].decrease(joinRound, amount);
        }

        IERC20(_joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        _emitLpWithdrawn(tokenAddress, actionId, memberId, joinRound, amount);

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

        _clearJoinState(tokenAddress, actionId, joinRound, memberId, memberJoinedAmount);

        IERC20(_joinTokenAddressByActionId[tokenAddress][actionId]).safeTransfer(msg.sender, memberJoinedAmount);

        _emitLpWithdrawn(tokenAddress, actionId, memberId, joinRound, memberJoinedAmount);

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
        uint256 actionId,
        uint256 round,
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
        uint256 actionId,
        uint256 memberId,
        uint256 round,
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
        uint256 actionId,
        uint256 round,
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
        if (IStake(STAKE_ADDRESS).totalValidGovVotes(tokenAddress, currentPhase) == 0) {
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
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 amount, uint256[] memory joinBlocks, uint256[] memory joinAmounts) {
        amount = _deductionByMemberId[tokenAddress][actionId][round][memberId];
        joinBlocks = _joinBlocksByMemberId[tokenAddress][actionId][round][memberId];
        joinAmounts = _joinAmountsByMemberId[tokenAddress][actionId][round][memberId];
    }

    function deductionByRound(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return _deductionByRound[tokenAddress][actionId][round];
    }

    /// @dev The cap is priced on the weight the member holds now, not on the weight of the round being
    ///      settled: the old protocol read the live `globalGovVotes` / `validGovVotes` too.
    function _calculateGovRatio(
        address tokenAddress,
        uint256 currentPhase,
        uint256 memberId
    ) internal view returns (uint256) {
        uint256 totalValidGovVotes = IStake(STAKE_ADDRESS).totalValidGovVotes(tokenAddress, currentPhase);
        if (totalValidGovVotes == 0) {
            return 0;
        }
        uint256 memberGovVotes = IStake(STAKE_ADDRESS).validGovVotes(tokenAddress, currentPhase, memberId);
        return Math.mulDiv(memberGovVotes, PRECISION, totalValidGovVotes);
    }

    function govRatio(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
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
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted) {
        minted = _memberMinted[tokenAddress][actionId][round][memberId];
        if (minted) {
            mintAmount = _mintedRewardByMemberId[tokenAddress][actionId][round][memberId];
            burnAmount = _burnedRewardByMemberId[tokenAddress][actionId][round][memberId];
            return (mintAmount, burnAmount, minted);
        }

        uint256 createdRound = _createdRoundByActionId[tokenAddress][actionId];
        if (createdRound != 0 && round >= createdRound && round <= _mintRound()) {
            (mintAmount, burnAmount) = _pendingMemberReward(tokenAddress, actionId, round, memberId);
        }
    }

    function joinedAmountByActionId(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256 amount) {
        if (round > _joinRound()) {
            return 0;
        }
        return _joinedAmountByActionId[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 amount) {
        if (round > _joinRound()) {
            return 0;
        }
        return _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(round);
    }

    function joinTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return _joinTokenAddressByActionId[tokenAddress][actionId];
    }

    function _totalEffectiveAmount(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (uint256) {
        return _joinedAmountByActionId[tokenAddress][actionId].value(round) - _deductionByRound[tokenAddress][actionId][round];
    }

    function _pendingMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 totalEffectiveAmount = _totalEffectiveAmount(tokenAddress, actionId, round);
        if (totalEffectiveAmount == 0) {
            return (0, 0);
        }
        (uint256 proposalReward, ) = IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
        (mintAmount, burnAmount) =
            _calculateReward(tokenAddress, actionId, round, memberId, totalEffectiveAmount, proposalReward);
    }

    function _memberNFTAddress() internal view override returns (address) {
        return MEMBER_NFT_ADDRESS;
    }

    function _phaseAddress() internal view override returns (address) {
        return PHASE_ADDRESS;
    }

    function _joinRound() internal view override returns (uint256) {
        return LpRoundAxis.joinRound(PHASE_ADDRESS);
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
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 createdRound = _createdRoundByActionId[tokenAddress][actionId];
        if (createdRound == 0) {
            revert ActionNotCreated(tokenAddress, actionId);
        }
        if (round < createdRound) {
            revert RoundBeforeActionCreated(round, createdRound);
        }
        uint256 mintRound = _mintRound();
        if (round > mintRound) {
            revert RoundAfterMintWindow(round, mintRound);
        }

        if (_memberMinted[tokenAddress][actionId][round][memberId]) {
            revert RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }

        uint256 totalEffectiveAmount = _totalEffectiveAmount(tokenAddress, actionId, round);
        if (totalEffectiveAmount != 0) {
            (uint256 proposalReward, bool actionMinted) =
                IActionTarget(ACTION_TARGET_ADDRESS).actionReward(tokenAddress, actionId, round);
            if (!actionMinted && proposalReward != 0) {
                // forge-lint: disable-next-line(reentrancy-no-eth)
                proposalReward = IActionTarget(ACTION_TARGET_ADDRESS).mintActionReward(tokenAddress, actionId, round);
            }
            (mintAmount, burnAmount) =
                _calculateReward(tokenAddress, actionId, round, memberId, totalEffectiveAmount, proposalReward);
        }

        if (mintAmount == 0 && burnAmount == 0) {
            revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
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
