// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {GroupRecipients} from "./GroupRecipients.sol";
import {GroupActionRoundAxis} from "./GroupActionRoundAxis.sol";
import {GroupActionVerify} from "./GroupActionVerify.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {MemberOwner} from "./MemberOwner.sol";
import {IGroupServiceExecutor} from "./interfaces/IGroupServiceExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IMint} from "@core/interfaces/IMint.sol";
import {VerifierApplication} from "./interfaces/IGroupActionVerify.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract GroupServiceExecutor is IGroupServiceExecutor, ExecutorBase {
    using GroupServiceStorage for GroupServiceStorage.Layout;
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = GroupServiceStorage.PRECISION;
    uint256 public constant DEFAULT_MAX_RECIPIENTS = GroupServiceStorage.DEFAULT_MAX_RECIPIENTS;

    GroupServiceStorage.Layout internal _layout;

    address public immutable GROUP_ACTION_EXECUTOR_ADDRESS;
    address public immutable override LAUNCH_ADDRESS;
    address public immutable override MINT_ADDRESS;

    struct Settlement {
        address actionTokenAddress;
        uint256 publicVerifierRatio;
        uint256 govRatioMultiplier;
        uint256 verifierWeight;
        uint256 ownerWeight;
        uint256 denominator;
        uint256 serviceReward;
        bool actionMinted;
        uint256 verifierReward;
        uint256 ownerReward;
        uint256 ownerBurned;
    }

    struct RoundActions {
        address actionTokenAddress;
        uint256 round;
        uint256[] actionIds;
    }

    modifier onlyGroupOwner(uint256 groupId) {
        address owner = MemberOwner.ownerOrZero(MEMBER_NFT_ADDRESS, groupId);
        if (owner == address(0)) {
            revert GroupNotExist(groupId);
        }
        if (owner != msg.sender) {
            revert NotGroupOwner(groupId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address groupActionExecutorAddress)
        ExecutorBase(IGroupActionExecutor(groupActionExecutorAddress).ACTION_TARGET_ADDRESS())
    {
        GROUP_ACTION_EXECUTOR_ADDRESS = groupActionExecutorAddress;
        LAUNCH_ADDRESS = IStake(STAKE_ADDRESS).LAUNCH_ADDRESS();
        MINT_ADDRESS = IActionTarget(ACTION_TARGET_ADDRESS).MINT_ADDRESS();
    }

    function _protocol() internal view returns (GroupServiceStorage.Protocol memory protocol) {
        protocol.memberNFTAddress = MEMBER_NFT_ADDRESS;
        protocol.groupActionExecutorAddress = GROUP_ACTION_EXECUTOR_ADDRESS;
    }

    // Load-bearing: the service rounds are the served GroupAction rounds shifted by the same phase
    // base (vote = phase, join = phase - 1, verify = phase - 2, mint = phase - 3). The service runs
    // no verification of its own: it reads `generatedActionReward` /
    // `generatedActionRewardByGroupId` for the round the GroupAction verified at phase - 2 and
    // settles it at phase - 3. If either side shifts, the service reads a round the GroupAction has
    // not verified yet and the divisor silently reads 0.
    function currentVerifyRound() public view returns (uint256) {
        return GroupActionVerify.currentVerifyRound(PHASE_ADDRESS);
    }

    function govRatioMultiplier(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.govRatioMultiplierByActionId[serviceTokenAddress][serviceActionId];
    }

    function actionTokenAddress(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (address) {
        return _layout.actionTokenAddressByActionId[serviceTokenAddress][serviceActionId];
    }

    function publicVerifierRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.publicVerifierRatioByActionId[serviceTokenAddress][serviceActionId];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = currentJoinRound();

        if (IActionTarget(ACTION_TARGET_ADDRESS).isJoined(serviceTokenAddress, serviceActionId, memberId)) {
            revert AlreadyJoined(serviceTokenAddress, serviceActionId, memberId);
        }

        address sourceTokenAddress = _layout.actionTokenAddressByActionId[serviceTokenAddress][serviceActionId];
        if (!_isQualified(sourceTokenAddress, round, memberId)) {
            revert NotQualified(sourceTokenAddress, round, memberId);
        }

        IActionTarget(ACTION_TARGET_ADDRESS).registerJoinState(serviceTokenAddress, serviceActionId, memberId);

        emit ServiceJoined({
            serviceTokenAddress: serviceTokenAddress,
            serviceActionId: serviceActionId,
            memberId: memberId,
            round: round
        });
    }

    function rewardByRecipientId(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256) {
        GroupRecipients.Distribution memory distributionInfo =
            _distribution(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);

        if (recipientId == groupId) {
            return distributionInfo.ownerAmount;
        }
        for (uint256 i = 0; i < distributionInfo.recipientIds.length; i++) {
            if (distributionInfo.recipientIds[i] == recipientId) {
                return distributionInfo.amounts[i];
            }
        }
        return 0;
    }

    function rewardDistribution(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            uint256[] memory amounts,
            uint256 ownerAmount
        )
    {
        GroupRecipients.Distribution memory distributionInfo =
            _distribution(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);
        return (distributionInfo.recipientIds, distributionInfo.ratios, distributionInfo.amounts, distributionInfo.ownerAmount);
    }

    function joinedAmountByActionId(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount) {
        if (round > _joinRound()) {
            return 0;
        }
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).totalStaked(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId]
        );
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
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).stakedByMemberId(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId], memberId
        );
    }

    function joinTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return _layout.actionTokenAddressByActionId[tokenAddress][actionId];
    }

    function totalGroupActionReward(
        address sourceTokenAddress,
        uint256 round
    ) public view returns (uint256) {
        uint256 cached = _layout.cachedDenominator(sourceTokenAddress, round);
        if (cached != 0) {
            return cached;
        }
        return _totalGroupActionReward(_roundActions(sourceTokenAddress, round));
    }

    function serviceRewardByMemberId(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    )
        external
        view
        returns (
            uint256 verifierReward,
            uint256 ownerReward,
            uint256 ownerBurned,
            uint256 ownerDistributed,
            uint256 ownerRemaining,
            bool claimed
        )
    {
        if (_layout.memberMinted[serviceTokenAddress][serviceActionId][round][memberId]) {
            verifierReward = _layout.verifierRewardByMemberId[serviceTokenAddress][serviceActionId][round][memberId];
            ownerDistributed = _layout.ownerDistributedByMemberId[serviceTokenAddress][serviceActionId][round][memberId];
            ownerRemaining = _layout.ownerRemainingByMemberId[serviceTokenAddress][serviceActionId][round][memberId];
            ownerReward = ownerDistributed + ownerRemaining;
            ownerBurned = _layout.ownerBurnedByMemberId[serviceTokenAddress][serviceActionId][round][memberId];
            // forge-lint: disable-next-line(boolean-cst)
            return (verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining, true);
        }

        if (!_isSettleableRound(serviceTokenAddress, serviceActionId, round)) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, 0, 0, 0, false);
        }

        Settlement memory settlement = _settlement(serviceTokenAddress, serviceActionId, round, memberId);
        verifierReward = settlement.verifierReward;
        ownerReward = settlement.ownerReward;
        ownerBurned = settlement.ownerBurned;
        if (ownerReward != 0) {
            ownerDistributed = GroupRecipients.projectedDistribution(
                _layout, _protocol(), settlement.actionTokenAddress, round, memberId, ownerReward, settlement.ownerWeight
            );
            ownerRemaining = ownerReward - ownerDistributed;
        }
        // forge-lint: disable-next-line(boolean-cst)
        return (verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining, false);
    }

    function memberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted) {
        if (_layout.memberMinted[tokenAddress][actionId][round][memberId]) {
            return (
                _layout.verifierRewardByMemberId[tokenAddress][actionId][round][memberId]
                    + _layout.ownerDistributedByMemberId[tokenAddress][actionId][round][memberId]
                    + _layout.ownerRemainingByMemberId[tokenAddress][actionId][round][memberId],
                _layout.ownerBurnedByMemberId[tokenAddress][actionId][round][memberId],
                // forge-lint: disable-next-line(boolean-cst)
                true
            );
        }

        if (!_isSettleableRound(tokenAddress, actionId, round)) {
            // forge-lint: disable-next-line(boolean-cst)
            return (0, 0, false);
        }

        Settlement memory settlement = _settlement(tokenAddress, actionId, round, memberId);
        // forge-lint: disable-next-line(boolean-cst)
        return (settlement.verifierReward + settlement.ownerReward, settlement.ownerBurned, false);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function setRecipients(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256[] calldata recipientIds,
        uint256[] calldata ratios,
        string[] calldata remarks
    ) external onlyGroupOwner(groupId) {
        GroupRecipients.setRecipients(
            _layout,
            _protocol(),
            currentVerifyRound(),
            sourceTokenAddress,
            sourceActionId,
            groupId,
            recipientIds,
            ratios,
            remarks
        );
    }

    function recipients(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 round
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            string[] memory remarks
        )
    {
        return GroupRecipients.recipients(_layout, sourceTokenAddress, sourceActionId, groupId, round);
    }

    function actionIdsWithRecipients(
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return GroupRecipients.actionIdsWithRecipients(_layout, sourceTokenAddress, groupId, round, offset, limit, reverse);
    }

    function distribution(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 round,
        uint256 groupReward
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            uint256[] memory amounts,
            uint256 ownerAmount
        )
    {
        GroupRecipients.Distribution memory distributionInfo =
            GroupRecipients.distribution(_layout, sourceTokenAddress, sourceActionId, groupId, round, groupReward);
        return (distributionInfo.recipientIds, distributionInfo.ratios, distributionInfo.amounts, distributionInfo.ownerAmount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        if (!IActionTarget(ACTION_TARGET_ADDRESS).isJoined(tokenAddress, actionId, memberId)) {
            revert NotJoined(tokenAddress, actionId, memberId);
        }

        uint256 round = currentJoinRound();
        IActionTarget(ACTION_TARGET_ADDRESS).clearJoinState(tokenAddress, actionId, memberId);

        emit ServiceExited({
            serviceTokenAddress: tokenAddress,
            serviceActionId: actionId,
            memberId: memberId,
            round: round
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        address tokenAddress,
        uint256 serviceActionId,
        bytes[] calldata targetData
    ) external override onlyActionTarget {
        if (targetData.length != 4) {
            revert TargetDataLengthMismatch(4, targetData.length);
        }
        // forge-lint: disable-next-item(require-revert-in-loop)
        for (uint256 i = 0; i < 4; i++) {
            if (targetData[i].length != 32) {
                revert InvalidTargetDataShape(i, targetData[i].length);
            }
        }

        address sourceTokenAddress = abi.decode(targetData[1], (address));
        uint256 govRatioMultiplierValue = abi.decode(targetData[2], (uint256));
        uint256 publicVerifierRatioValue = abi.decode(targetData[3], (uint256));

        if (sourceTokenAddress == address(0)) {
            revert ZeroActionTokenAddress();
        }
        if (publicVerifierRatioValue > PRECISION) {
            revert InvalidRatioForPublicVerifier(publicVerifierRatioValue);
        }
        if (sourceTokenAddress != tokenAddress) {
            address parentTokenAddress = ILaunch(LAUNCH_ADDRESS).parentToken(sourceTokenAddress);
            if (parentTokenAddress != tokenAddress) {
                revert ActionTokenParentMismatch(sourceTokenAddress, tokenAddress, parentTokenAddress);
            }
        }

        _layout.actionTokenAddressByActionId[tokenAddress][serviceActionId] = sourceTokenAddress;
        _layout.govRatioMultiplierByActionId[tokenAddress][serviceActionId] = govRatioMultiplierValue;
        _layout.publicVerifierRatioByActionId[tokenAddress][serviceActionId] = publicVerifierRatioValue;
        _layout.createdRoundByActionId[tokenAddress][serviceActionId] = IPhase(PHASE_ADDRESS).currentPhase();

        emit ServiceActionCreated({
            tokenAddress: tokenAddress,
            actionId: serviceActionId,
            actionTokenAddress: sourceTokenAddress,
            govRatioMultiplier: govRatioMultiplierValue,
            publicVerifierRatio: publicVerifierRatioValue
        });
    }

    function onProposalVoted(
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes[] calldata targetData
    ) external virtual override onlyActionTarget {
        if (targetData.length > 1) {
            revert TargetDataLengthMismatch(1, targetData.length);
        }
    }

    function _distribution(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) internal view returns (GroupRecipients.Distribution memory) {
        (address sourceTokenAddress, uint256 slice) =
            _ownerSlice(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);
        return GroupRecipients.distribution(_layout, sourceTokenAddress, sourceActionId, groupId, round, slice);
    }

    function _ownerSlice(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) internal view returns (address sourceTokenAddress, uint256 slice) {
        uint256 ownerReward;
        uint256 ownerWeight;
        (sourceTokenAddress, ownerReward, ownerWeight) =
            _ownerRewardAndWeight(serviceTokenAddress, serviceActionId, round, groupId);
        if (ownerReward != 0 && ownerWeight != 0) {
            slice = GroupRecipients.ownerSlice(
                _protocol(), sourceTokenAddress, sourceActionId, round, groupId, ownerReward, ownerWeight
            );
        }
    }

    function _settlement(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (Settlement memory settlement) {
        settlement.actionTokenAddress = _layout.actionTokenAddressByActionId[serviceTokenAddress][serviceActionId];
        if (!IActionTarget(ACTION_TARGET_ADDRESS).isJoinedByRound(serviceTokenAddress, serviceActionId, round, memberId)) {
            return settlement;
        }

        RoundActions memory scope = _roundActions(settlement.actionTokenAddress, round);
        (settlement.verifierWeight, settlement.ownerWeight) = _memberWeights(scope, memberId);
        if (settlement.verifierWeight == 0 && settlement.ownerWeight == 0) {
            return settlement;
        }

        settlement.publicVerifierRatio = _layout.publicVerifierRatioByActionId[serviceTokenAddress][serviceActionId];
        settlement.govRatioMultiplier = _layout.govRatioMultiplierByActionId[serviceTokenAddress][serviceActionId];
        settlement.denominator = _denominator(scope);
        if (settlement.denominator == 0) {
            return settlement;
        }

        (settlement.serviceReward, settlement.actionMinted) =
            IActionTarget(ACTION_TARGET_ADDRESS).actionReward(serviceTokenAddress, serviceActionId, round);
        if (settlement.serviceReward == 0) {
            return settlement;
        }

        _applyFormulas(settlement, memberId);
    }

    function _applyFormulas(
        Settlement memory settlement,
        uint256 memberId
    ) internal view {
        settlement.ownerBurned = 0;
        settlement.verifierReward = Math.mulDiv(
            settlement.serviceReward,
            settlement.publicVerifierRatio * settlement.verifierWeight,
            settlement.denominator * PRECISION
        );

        uint256 ownerRatioWeight = (PRECISION - settlement.publicVerifierRatio) * settlement.ownerWeight;
        uint256 theoreticalOwnerReward =
            Math.mulDiv(settlement.serviceReward, ownerRatioWeight, settlement.denominator * PRECISION);

        if (settlement.govRatioMultiplier == 0) {
            settlement.ownerReward = theoreticalOwnerReward;
            return;
        }

        uint256 cap = 0;
        uint256 currentPhase = IPhase(PHASE_ADDRESS).currentPhase();
        uint256 totalValidGovVotes = IStake(STAKE_ADDRESS).totalValidGovVotes(settlement.actionTokenAddress, currentPhase);
        if (totalValidGovVotes != 0) {
            uint256 govRatio = Math.mulDiv(
                IStake(STAKE_ADDRESS).validGovVotes(settlement.actionTokenAddress, currentPhase, memberId),
                PRECISION,
                totalValidGovVotes
            );
            cap = Math.mulDiv(govRatio, settlement.govRatioMultiplier, PRECISION);
        }

        // Load-bearing: ceil, not floor. The threshold must be the smallest cap that reaches the
        // theoretical reward, so the two branches stay continuous at the boundary; a cap one below
        // also passes under floor and the fractional burn silently disappears.
        uint256 capForTheoreticalOwnerReward =
            Math.mulDiv(ownerRatioWeight, 1, settlement.denominator, Math.Rounding.Ceil);
        if (cap >= capForTheoreticalOwnerReward) {
            settlement.ownerReward = theoreticalOwnerReward;
        } else {
            settlement.ownerReward = Math.mulDiv(settlement.serviceReward, cap, PRECISION);
            settlement.ownerBurned = theoreticalOwnerReward - settlement.ownerReward;
        }
    }

    function _ownerRewardAndWeight(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    )
        internal
        view
        returns (
            address sourceTokenAddress,
            uint256 ownerReward,
            uint256 ownerWeight
        )
    {
        sourceTokenAddress = _layout.actionTokenAddressByActionId[serviceTokenAddress][serviceActionId];
        if (_layout.memberMinted[serviceTokenAddress][serviceActionId][round][memberId]) {
            ownerReward = _layout.ownerDistributedByMemberId[serviceTokenAddress][serviceActionId][round][memberId]
                + _layout.ownerRemainingByMemberId[serviceTokenAddress][serviceActionId][round][memberId];
            if (ownerReward != 0) {
                (, ownerWeight) = _memberWeights(_roundActions(sourceTokenAddress, round), memberId);
            }
            return (sourceTokenAddress, ownerReward, ownerWeight);
        }

        Settlement memory settlement = _settlement(serviceTokenAddress, serviceActionId, round, memberId);
        return (sourceTokenAddress, settlement.ownerReward, settlement.ownerWeight);
    }

    function _isQualified(
        address sourceTokenAddress,
        uint256 round,
        uint256 memberId
    ) internal view returns (bool) {
        IGroupActionExecutor groupActionExecutor = IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS);
        if (groupActionExecutor.hasActiveGroups(sourceTokenAddress, memberId)) {
            return true;
        }

        uint256[] memory actionIds = _votedGroupActions(sourceTokenAddress, round);
        for (uint256 i = 0; i < actionIds.length; i++) {
            VerifierApplication memory application =
                groupActionExecutor.verifierApplication(sourceTokenAddress, actionIds[i], round, memberId);
            if (application.applicationId != 0) {
                return true;
            }
        }
        return false;
    }

    function _memberWeights(
        RoundActions memory scope,
        uint256 memberId
    ) internal view returns (uint256 verifierWeight, uint256 ownerWeight) {
        for (uint256 i = 0; i < scope.actionIds.length; i++) {
            uint256 actionId = scope.actionIds[i];
            ownerWeight += GroupServiceStorage.groupReward(
                GROUP_ACTION_EXECUTOR_ADDRESS, scope.actionTokenAddress, actionId, scope.round, memberId
            );
            if (_lockedVerifierId(scope.actionTokenAddress, actionId, scope.round) == memberId) {
                verifierWeight += IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).generatedActionReward(
                    scope.actionTokenAddress, actionId, scope.round
                );
            }
        }
    }

    function _denominator(RoundActions memory scope) internal view returns (uint256) {
        uint256 cached = _layout.cachedDenominator(scope.actionTokenAddress, scope.round);
        return cached != 0 ? cached : _totalGroupActionReward(scope);
    }

    function _totalGroupActionReward(RoundActions memory scope) internal view returns (uint256 total) {
        for (uint256 i = 0; i < scope.actionIds.length; i++) {
            total += IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).generatedActionReward(
                scope.actionTokenAddress, scope.actionIds[i], scope.round
            );
        }
    }

    function _roundActions(
        address sourceTokenAddress,
        uint256 round
    ) internal view returns (RoundActions memory scope) {
        scope.actionTokenAddress = sourceTokenAddress;
        scope.round = round;
        scope.actionIds = _votedGroupActions(sourceTokenAddress, round);
    }

    function _votedGroupActions(
        address sourceTokenAddress,
        uint256 round
    ) internal view returns (uint256[] memory) {
        (uint256[] memory actionIds, address[] memory executors, ) =
            IActionTarget(ACTION_TARGET_ADDRESS).votedActions(sourceTokenAddress, round, 0, type(uint256).max, false);

        uint256 count = 0;
        for (uint256 i = 0; i < actionIds.length; i++) {
            if (executors[i] == GROUP_ACTION_EXECUTOR_ADDRESS) {
                count++;
            }
        }

        uint256[] memory groupActionIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < actionIds.length; i++) {
            if (executors[i] == GROUP_ACTION_EXECUTOR_ADDRESS) {
                groupActionIds[index] = actionIds[i];
                index++;
            }
        }
        return groupActionIds;
    }

    function _lockedVerifierId(
        address sourceTokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (uint256) {
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).lockedVerifierId(sourceTokenAddress, actionId, round);
    }

    function _isSettleableRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (bool) {
        uint256 createdRound = _layout.createdRoundByActionId[tokenAddress][actionId];
        return createdRound != 0 && round >= createdRound && round <= _mintRound();
    }

    // Load-bearing: this must stay equal to ActionTarget's own join round (phase - 1). ActionTarget
    // keys the join snapshot it writes by that round, and every `isJoinedByRound` / `joinedAmount`
    // argument here is read in the same round space; if the two drift, the reported round and the
    // recorded snapshot disagree without any revert.
    function _joinRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.joinRound(PHASE_ADDRESS);
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupActionRoundAxis.mintRound(PHASE_ADDRESS);
    }
    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(
            tokenAddress,
            actionId,
            round,
            memberId,
            _layout.createdRoundByActionId[tokenAddress][actionId],
            _layout.memberMinted[tokenAddress][actionId][round][memberId]
        );

        Settlement memory settlement = _settlement(tokenAddress, actionId, round, memberId);
        mintAmount = settlement.verifierReward + settlement.ownerReward;
        burnAmount = settlement.ownerBurned;
        if (mintAmount == 0 && burnAmount == 0) {
            revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
        }

        if (!settlement.actionMinted) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            settlement.serviceReward = IActionTarget(ACTION_TARGET_ADDRESS).mintActionReward(tokenAddress, actionId, round);
            _applyFormulas(settlement, memberId);
            mintAmount = settlement.verifierReward + settlement.ownerReward;
            burnAmount = settlement.ownerBurned;
            if (mintAmount == 0 && burnAmount == 0) {
                revert MemberActionRewardUnavailable(tokenAddress, actionId, memberId, round);
            }
        }

        // Load-bearing: the cache key is the action token's round, not the service token's; a parent
        // service leaves the child's round open, and caching there pairs a frozen divisor with live weights.
        if (
            _layout.cachedDenominator(settlement.actionTokenAddress, round) == 0
                && IMint(MINT_ADDRESS).isRewardPrepared(settlement.actionTokenAddress, round)
        ) {
            _layout.cacheDenominator(settlement.actionTokenAddress, round, settlement.denominator);
        }

        _layout.memberMinted[tokenAddress][actionId][round][memberId] = true;
        _layout.verifierRewardByMemberId[tokenAddress][actionId][round][memberId] = settlement.verifierReward;
        _layout.ownerBurnedByMemberId[tokenAddress][actionId][round][memberId] = burnAmount;

        if (burnAmount != 0) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            ILOVE20Token(tokenAddress).burn(burnAmount);
        }

        uint256 distributed = 0;
        if (settlement.ownerReward != 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth)
            distributed = GroupRecipients.distribute(
                _layout,
                _protocol(),
                settlement.actionTokenAddress,
                tokenAddress,
                actionId,
                round,
                memberId,
                settlement.ownerReward,
                settlement.ownerWeight
            );
        }
        uint256 remaining = settlement.ownerReward - distributed;
        _layout.ownerDistributedByMemberId[tokenAddress][actionId][round][memberId] = distributed;
        _layout.ownerRemainingByMemberId[tokenAddress][actionId][round][memberId] = remaining;

        if (remaining != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, remaining);
        }
        if (settlement.verifierReward != 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, settlement.verifierReward);
        }

        emit MemberRewardMinted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            mintAmount: mintAmount,
            burnAmount: burnAmount
        });
        emit ServiceRewardsDistributed({
            serviceTokenAddress: tokenAddress,
            serviceActionId: actionId,
            round: round,
            actionTokenAddress: settlement.actionTokenAddress,
            memberId: memberId,
            verifierReward: settlement.verifierReward,
            ownerReward: settlement.ownerReward,
            ownerBurned: burnAmount,
            ownerDistributed: distributed,
            ownerRemaining: remaining
        });
    }
}
