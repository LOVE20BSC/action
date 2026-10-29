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

    address public actionTarget;
    bool public initialized;

    address internal _memberNFT;
    address internal _phase;
    address internal _stake;
    address internal _pairFactory;

    /// @dev tokenAddress => actionId => join token address
    mapping(address => mapping(uint256 => address)) internal _joinTokenAddress;

    /// @dev tokenAddress => actionId => gov ratio multiplier (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _govRatioMultiplier;

    /// @dev tokenAddress => actionId => minimum gov ratio (1e18 precision)
    mapping(address => mapping(uint256 => uint256)) internal _minGovRatio;

    /// @dev tokenAddress => actionId => creation vote round
    mapping(address => mapping(uint256 => uint256)) internal _createdRound;

    /// @dev tokenAddress => actionId => round => memberId => accumulated deduction for time-weighted LP calculation
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _deduction;

    /// @dev tokenAddress => actionId => round => accumulated total deduction across all members
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _totalDeduction;

    /// @dev tokenAddress => actionId => round => memberId => block numbers of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinBlocks;

    /// @dev tokenAddress => actionId => round => memberId => amounts of each join in this round
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256[])))) internal _joinAmounts;

    /// @dev tokenAddress => actionId => round => memberId => gov ratio at mint time
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _govRatioAtMint;

    /// @dev tokenAddress => actionId => memberId => joined amount history
    mapping(address => mapping(uint256 => mapping(uint256 => RoundHistoryUint256.History)))
        internal _joinedAmountByMemberId;

    /// @dev tokenAddress => actionId => total joined amount history
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _joinedAmount;

    /// @dev tokenAddress => actionId => round => memberId => whether the member reward is minted
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => bool)))) internal _memberMinted;

    /// @dev tokenAddress => actionId => round => memberId => minted reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _mintedReward;

    /// @dev tokenAddress => actionId => round => memberId => burned reward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal _burnedReward;

    modifier onlyActionTarget() {
        if (msg.sender != actionTarget) {
            revert NotActionTarget(msg.sender);
        }
        _;
    }

    function GOV_RATIO_MULTIPLIER(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _govRatioMultiplier[tokenAddress][actionId];
    }

    function MIN_GOV_RATIO(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256) {
        return _minGovRatio[tokenAddress][actionId];
    }

    // forge-lint: disable-next-item(missing-zero-check)
    function init(address actionTargetAddress, address stakeAddress) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        address memberNFTAddress = IStake(stakeAddress).memberNFTAddress();
        address phaseAddress = IStake(stakeAddress).phaseAddress();
        address pairFactoryAddress = IStake(stakeAddress).pairFactoryAddress();

        actionTarget = actionTargetAddress;
        _memberNFT = memberNFTAddress;
        _stake = stakeAddress;
        _phase = phaseAddress;
        _pairFactory = pairFactoryAddress;
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

        address joinTokenAddress = abi.decode(targetData[1], (address));
        uint256 govRatioMultiplier = abi.decode(targetData[2], (uint256));
        uint256 minGovRatio = abi.decode(targetData[3], (uint256));

        if (joinTokenAddress == address(0)) {
            revert ZeroJoinTokenAddress();
        }
        if (!_isRegisteredPair(joinTokenAddress, _pairFactory)) {
            revert InvalidJoinTokenFactory(joinTokenAddress, _pairFactory);
        }
        if (minGovRatio > PRECISION) {
            revert InvalidMinGovRatio(minGovRatio);
        }

        _joinTokenAddress[tokenAddress][actionId] = joinTokenAddress;
        _govRatioMultiplier[tokenAddress][actionId] = govRatioMultiplier;
        _minGovRatio[tokenAddress][actionId] = minGovRatio;
        _createdRound[tokenAddress][actionId] = IPhase(_phase).currentPhase();

        emit LpActionCreated({
            tokenAddress: tokenAddress,
            actionId: actionId,
            joinTokenAddress: joinTokenAddress,
            govRatioMultiplier: govRatioMultiplier,
            minGovRatio: minGovRatio
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

        bool isFirstJoin = !IActionTarget(actionTarget).isJoined(tokenAddress, actionId, memberId);
        if (isFirstJoin) {
            uint256 minGovRatio = _minGovRatio[tokenAddress][actionId];
            uint256 memberGovRatio = _calculateGovRatio(tokenAddress, IPhase(_phase).currentPhase(), memberId);
            if (memberGovRatio < minGovRatio) {
                revert InsufficientGovRatio(minGovRatio, memberGovRatio);
            }
        }

        (uint256 phaseStartBlock, uint256 phaseBlocks) = IPhase(_phase).phaseInfo(joinRound + 1);
        uint256 deductionAdded = Math.mulDiv(amount, block.number - phaseStartBlock, phaseBlocks);
        if (deductionAdded > amount) {
            deductionAdded = amount;
        }
        _deduction[tokenAddress][actionId][joinRound][memberId] += deductionAdded;
        _totalDeduction[tokenAddress][actionId][joinRound] += deductionAdded;
        _joinBlocks[tokenAddress][actionId][joinRound][memberId].push(block.number);
        _joinAmounts[tokenAddress][actionId][joinRound][memberId].push(amount);
        _joinedAmountByMemberId[tokenAddress][actionId][memberId].increase(joinRound, amount);
        _joinedAmount[tokenAddress][actionId].increase(joinRound, amount);

        if (isFirstJoin) {
            IActionTarget(actionTarget).registerJoinState(tokenAddress, actionId, memberId);
        }

        IERC20(_joinTokenAddress[tokenAddress][actionId]).safeTransferFrom(msg.sender, address(this), amount);

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
            uint256 memberDeduction = _deduction[tokenAddress][actionId][joinRound][memberId];
            uint256 deductionReduction = Math.mulDiv(memberDeduction, amount, memberJoinedAmount);

            _deduction[tokenAddress][actionId][joinRound][memberId] = memberDeduction - deductionReduction;
            _totalDeduction[tokenAddress][actionId][joinRound] -= deductionReduction;
            _joinedAmountByMemberId[tokenAddress][actionId][memberId].record(joinRound, memberJoinedAmount - amount);
            _joinedAmount[tokenAddress][actionId].decrease(joinRound, amount);
        }

        IERC20(_joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, amount);

        _emitLpWithdrawn(tokenAddress, actionId, memberId, joinRound, amount);

        if (isFullExit) {
            IActionTarget(actionTarget).clearJoinState(tokenAddress, actionId, memberId);
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

        IERC20(_joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, memberJoinedAmount);

        _emitLpWithdrawn(tokenAddress, actionId, memberId, joinRound, memberJoinedAmount);

        IActionTarget(actionTarget).clearJoinState(tokenAddress, actionId, memberId);

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
        _totalDeduction[tokenAddress][actionId][round] -= _deduction[tokenAddress][actionId][round][memberId];
        delete _deduction[tokenAddress][actionId][round][memberId];
        delete _joinBlocks[tokenAddress][actionId][round][memberId];
        delete _joinAmounts[tokenAddress][actionId][round][memberId];
        _joinedAmountByMemberId[tokenAddress][actionId][memberId].record(round, 0);
        _joinedAmount[tokenAddress][actionId].decrease(round, memberJoinedAmount);
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
            - _deduction[tokenAddress][actionId][round][memberId];
        uint256 effectiveLpRatio = Math.mulDiv(effectiveAmount, PRECISION, totalEffectiveAmount);
        uint256 theoreticalReward = Math.mulDiv(proposalReward, effectiveAmount, totalEffectiveAmount);

        uint256 govRatioMultiplier = _govRatioMultiplier[tokenAddress][actionId];
        if (govRatioMultiplier == 0) {
            return (theoreticalReward, 0);
        }

        uint256 currentPhase = IPhase(_phase).currentPhase();
        if (IStake(_stake).totalValidGovVotes(tokenAddress, currentPhase) == 0) {
            return (0, theoreticalReward);
        }

        uint256 govRatioCap =
            Math.mulDiv(_calculateGovRatio(tokenAddress, currentPhase, memberId), govRatioMultiplier, PRECISION);
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
        amount = _deduction[tokenAddress][actionId][round][memberId];
        joinBlocks = _joinBlocks[tokenAddress][actionId][round][memberId];
        joinAmounts = _joinAmounts[tokenAddress][actionId][round][memberId];
    }

    function totalDeduction(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        return _totalDeduction[tokenAddress][actionId][round];
    }

    /// @dev The cap is priced on the weight the member holds now, not on the weight of the round being
    ///      settled: the old protocol read the live `globalGovVotes` / `validGovVotes` too.
    function _calculateGovRatio(
        address tokenAddress,
        uint256 currentPhase,
        uint256 memberId
    ) internal view returns (uint256) {
        uint256 totalValidGovVotes = IStake(_stake).totalValidGovVotes(tokenAddress, currentPhase);
        if (totalValidGovVotes == 0) {
            return 0;
        }
        uint256 memberGovVotes = IStake(_stake).validGovVotes(tokenAddress, currentPhase, memberId);
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
            ratio = _govRatioAtMint[tokenAddress][actionId][round][memberId];
        } else {
            ratio = _calculateGovRatio(tokenAddress, IPhase(_phase).currentPhase(), memberId);
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
            mintAmount = _mintedReward[tokenAddress][actionId][round][memberId];
            burnAmount = _burnedReward[tokenAddress][actionId][round][memberId];
            return (mintAmount, burnAmount, minted);
        }

        uint256 createdRound = _createdRound[tokenAddress][actionId];
        if (createdRound != 0 && round >= createdRound && round <= _mintRound()) {
            (mintAmount, burnAmount) = _pendingMemberReward(tokenAddress, actionId, round, memberId);
        }
    }

    function joinedAmount(address tokenAddress, uint256 actionId, uint256 round) external view returns (uint256) {
        if (round > _joinRound()) {
            return 0;
        }
        return _joinedAmount[tokenAddress][actionId].value(round);
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256) {
        if (round > _joinRound()) {
            return 0;
        }
        return _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(round);
    }

    function joinedAmountTokenAddress(address tokenAddress, uint256 actionId) external view returns (address) {
        return _joinTokenAddress[tokenAddress][actionId];
    }

    function _totalEffectiveAmount(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (uint256) {
        return _joinedAmount[tokenAddress][actionId].value(round) - _totalDeduction[tokenAddress][actionId][round];
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
        (uint256 proposalReward, ) = IActionTarget(actionTarget).actionReward(tokenAddress, actionId, round);
        (mintAmount, burnAmount) =
            _calculateReward(tokenAddress, actionId, round, memberId, totalEffectiveAmount, proposalReward);
    }

    function _memberNFTAddress() internal view override returns (address) {
        return _memberNFT;
    }

    function _phaseAddress() internal view override returns (address) {
        return _phase;
    }

    function _joinRound() internal view override returns (uint256) {
        return LpRoundAxis.joinRound(_phase);
    }

    function _mintRound() internal view override returns (uint256) {
        return LpRoundAxis.mintRound(_phase);
    }

    function _isRegisteredPair(address lpToken, address factory) internal view returns (bool) {
        if (lpToken.code.length == 0 || factory.code.length == 0) {
            return false;
        }

        address token0 = address(0);
        try IUniswapV2Pair(lpToken).token0() returns (address result) {
            token0 = result;
        } catch {
            return false;
        }

        address token1 = address(0);
        try IUniswapV2Pair(lpToken).token1() returns (address result) {
            token1 = result;
        } catch {
            return false;
        }

        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            return false;
        }

        try IUniswapV2Factory(factory).getPair(token0, token1) returns (address pair) {
            return pair == lpToken;
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
        uint256 createdRound = _createdRound[tokenAddress][actionId];
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
                IActionTarget(actionTarget).actionReward(tokenAddress, actionId, round);
            if (!actionMinted && proposalReward != 0) {
                // forge-lint: disable-next-line(reentrancy-no-eth)
                proposalReward = IActionTarget(actionTarget).mintActionReward(tokenAddress, actionId, round);
            }
            (mintAmount, burnAmount) =
                _calculateReward(tokenAddress, actionId, round, memberId, totalEffectiveAmount, proposalReward);
        }

        if (mintAmount == 0 && burnAmount == 0) {
            revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
        }

        _memberMinted[tokenAddress][actionId][round][memberId] = true;
        _mintedReward[tokenAddress][actionId][round][memberId] = mintAmount;
        _burnedReward[tokenAddress][actionId][round][memberId] = burnAmount;
        _govRatioAtMint[tokenAddress][actionId][round][memberId] =
            _calculateGovRatio(tokenAddress, IPhase(_phase).currentPhase(), memberId);

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
