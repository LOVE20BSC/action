// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILpExecutor} from "./interfaces/ILpExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {RoundHistoryUint256} from "libs/RoundHistoryUint256.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IStake} from "core/src/interfaces/IStake.sol";
import {ILOVE20Token} from "core/src/interfaces/ILOVE20Token.sol";
import {IUniswapV2Factory} from "core/src/interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "core/src/interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LpExecutor is ILpExecutor, ReentrancyGuard {
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

    function init(address actionTargetAddress, address stakeAddress) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        if (actionTargetAddress == address(0) || stakeAddress == address(0)) {
            revert InvalidAddress();
        }

        address memberNFTAddress = IStake(stakeAddress).memberNFTAddress();
        address phaseAddress = IStake(stakeAddress).phaseAddress();
        address pairFactoryAddress = IStake(stakeAddress).pairFactoryAddress();
        if (memberNFTAddress == address(0) || phaseAddress == address(0) || pairFactoryAddress == address(0)) {
            revert InvalidAddress();
        }

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
    ) external {
        if (msg.sender != actionTarget) {
            revert UnauthorizedCallback();
        }
        if (
            targetData.length != 4 || targetData[0].length != 32 || targetData[1].length != 32
                || targetData[2].length != 32 || targetData[3].length != 32
        ) {
            revert InvalidTargetDataLength();
        }

        address joinTokenAddress = abi.decode(targetData[1], (address));
        uint256 govRatioMultiplier = abi.decode(targetData[2], (uint256));
        uint256 minGovRatio = abi.decode(targetData[3], (uint256));

        if (joinTokenAddress == address(0)) {
            revert InvalidJoinTokenAddress();
        }
        if (!_isRegisteredPair(joinTokenAddress, _pairFactory)) {
            revert InvalidJoinTokenFactory();
        }
        if (minGovRatio > PRECISION) {
            revert InvalidMinGovRatio();
        }

        _joinTokenAddress[tokenAddress][actionId] = joinTokenAddress;
        _govRatioMultiplier[tokenAddress][actionId] = govRatioMultiplier;
        _minGovRatio[tokenAddress][actionId] = minGovRatio;
        _createdRound[tokenAddress][actionId] = IPhase(_phase).currentPhase();
    }

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata)
        external
        virtual
        override
    {
        if (msg.sender != actionTarget) {
            revert UnauthorizedCallback();
        }
    }

    function onProposalVoted(address, uint256, uint256, uint256, uint256, bytes[] calldata targetData)
        external
        virtual
        override
    {
        if (msg.sender != actionTarget) {
            revert UnauthorizedCallback();
        }
        if (targetData.length > 1) {
            revert InvalidTargetDataLength();
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert InvalidParticipationAmount();
        }
        _requireMemberOwner(memberId);

        uint256 joinRound = currentJoinRound();

        bool isFirstJoin = !IActionTarget(actionTarget).isJoined(tokenAddress, actionId, memberId);
        if (isFirstJoin && _calculateGovRatio(tokenAddress, memberId) < _minGovRatio[tokenAddress][actionId]) {
            revert InsufficientGovRatio();
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

        emit Joined({
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
    ) external nonReentrant {
        if (amount == 0) {
            revert InvalidParticipationAmount();
        }
        _requireMemberOwner(memberId);

        uint256 joinRound = currentJoinRound();
        uint256 memberJoinedAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(joinRound);
        if (amount > memberJoinedAmount) {
            revert InvalidParticipationAmount();
        }

        if (amount == memberJoinedAmount) {
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

        emit Withdrawn({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: joinRound,
            amount: amount
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(address tokenAddress, uint256 actionId, uint256 memberId) external nonReentrant {
        _requireMemberOwner(memberId);

        uint256 joinRound = currentJoinRound();
        uint256 memberJoinedAmount = _joinedAmountByMemberId[tokenAddress][actionId][memberId].value(joinRound);
        if (memberJoinedAmount == 0) {
            revert NotJoined();
        }

        _clearJoinState(tokenAddress, actionId, joinRound, memberId, memberJoinedAmount);

        IERC20(_joinTokenAddress[tokenAddress][actionId]).safeTransfer(msg.sender, memberJoinedAmount);

        emit Exited({tokenAddress: tokenAddress, actionId: actionId, memberId: memberId, round: joinRound});
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _requireMemberOwner(uint256 memberId) internal view {
        if (IMemberNFT(_memberNFT).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
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
        IActionTarget(actionTarget).clearJoinState(tokenAddress, actionId, memberId);
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
        uint256 theoreticalReward = Math.mulDiv(proposalReward, effectiveLpRatio, PRECISION);

        uint256 govRatioMultiplier = _govRatioMultiplier[tokenAddress][actionId];
        if (govRatioMultiplier == 0) {
            return (theoreticalReward, 0);
        }

        if (IStake(_stake).globalGovVotes(tokenAddress) == 0) {
            return (0, theoreticalReward);
        }

        uint256 govRatioCap = Math.mulDiv(_calculateGovRatio(tokenAddress, memberId), govRatioMultiplier, PRECISION);
        uint256 cappedRatio = effectiveLpRatio < govRatioCap ? effectiveLpRatio : govRatioCap;

        mintAmount = Math.mulDiv(proposalReward, cappedRatio, PRECISION);
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

    function _calculateGovRatio(
        address tokenAddress,
        uint256 memberId
    ) internal view returns (uint256) {
        uint256 totalGovVotes = IStake(_stake).globalGovVotes(tokenAddress);
        if (totalGovVotes == 0) {
            return 0;
        }
        return Math.mulDiv(IStake(_stake).validGovVotes(tokenAddress, memberId), PRECISION, totalGovVotes);
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
            ratio = _calculateGovRatio(tokenAddress, memberId);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop, missing-events-access-control)
    function mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) public nonReentrant returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 createdRound = _createdRound[tokenAddress][actionId];
        if (createdRound == 0 || round < createdRound) {
            revert RoundNotStarted();
        }
        if (round > _mintRound()) {
            revert InvalidRound(round);
        }
        _requireMemberOwner(memberId);

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
            revert NoRewardAvailable();
        }

        _memberMinted[tokenAddress][actionId][round][memberId] = true;
        _mintedReward[tokenAddress][actionId][round][memberId] = mintAmount;
        _burnedReward[tokenAddress][actionId][round][memberId] = burnAmount;
        _govRatioAtMint[tokenAddress][actionId][round][memberId] = _calculateGovRatio(tokenAddress, memberId);

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

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256 memberId,
        uint256[] calldata rounds
    ) external returns (uint256[] memory mintAmounts, uint256[] memory burnAmounts) {
        uint256 length = actionIds.length;
        if (length != rounds.length) {
            revert BatchLengthMismatch(length, rounds.length);
        }

        mintAmounts = new uint256[](length);
        burnAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            (mintAmounts[i], burnAmounts[i]) = mintMemberReward(tokenAddress, actionIds[i], memberId, rounds[i]);
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

    function currentVoteRound() external view returns (uint256) {
        uint256 phase = IPhase(_phase).currentPhase();
        if (phase < 1) {
            revert RoundNotStarted();
        }
        return phase;
    }

    function currentJoinRound() public view returns (uint256) {
        uint256 round = _joinRound();
        if (round == 0) {
            revert RoundNotStarted();
        }
        return round;
    }

    function currentMintRound() external view returns (uint256) {
        uint256 round = _mintRound();
        if (round == 0) {
            revert RoundNotStarted();
        }
        return round;
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

    function _joinRound() internal view returns (uint256) {
        uint256 phase = IPhase(_phase).currentPhase();
        return phase < 2 ? 0 : phase - 1;
    }

    function _mintRound() internal view returns (uint256) {
        uint256 phase = IPhase(_phase).currentPhase();
        return phase < 3 ? 0 : phase - 2;
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
}
