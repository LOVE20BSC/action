// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {GroupRecipients} from "./GroupRecipients.sol";
import {IGroupServiceExecutor} from "./interfaces/IGroupServiceExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {IMint} from "core/src/interfaces/IMint.sol";
import {VerifierApplication} from "./interfaces/IGroupActionVerify.sol";
import {ILaunch} from "core/src/interfaces/ILaunch.sol";
import {ILOVE20Token} from "core/src/interfaces/ILOVE20Token.sol";
import {IPhase} from "core/src/interfaces/IPhase.sol";
import {IStake} from "core/src/interfaces/IStake.sol";
import {IMemberNFT} from "core/src/interfaces/IMemberNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GroupServiceExecutor is IGroupServiceExecutor, ReentrancyGuard {
    using GroupServiceStorage for GroupServiceStorage.Layout;
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = GroupServiceStorage.PRECISION;
    uint256 public constant DEFAULT_MAX_RECIPIENTS = GroupServiceStorage.DEFAULT_MAX_RECIPIENTS;

    GroupServiceStorage.Layout internal s;

    struct Settlement {
        address actionTokenAddress;
        uint256 ratioForPublicVerifier;
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

    modifier onlyActionTarget() {
        if (msg.sender != s.actionTarget) {
            revert UnauthorizedCallback();
        }
        _;
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(s.memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        _;
    }

    modifier onlyGroupOwner(uint256 groupId) {
        try IMemberNFT(s.memberNFTAddress).ownerOf(groupId) returns (address owner) {
            if (owner != msg.sender) {
                revert NotGroupOwner(groupId);
            }
        } catch {
            revert GroupNotExist(groupId);
        }
        _;
    }

    function init(
        address actionTargetAddress,
        address stakeAddress,
        address groupActionExecutorAddress
    ) external {
        if (s.initialized) {
            revert AlreadyInitialized();
        }
        s.initialized = true;

        if (
            actionTargetAddress == address(0) || stakeAddress == address(0)
                || groupActionExecutorAddress == address(0)
        ) {
            revert InvalidAddress();
        }

        IStake stake = IStake(stakeAddress);
        address memberNFTAddress = stake.memberNFTAddress();
        address phaseAddress = stake.phaseAddress();
        address launchAddress = stake.launchAddress();
        address mintAddress = IActionTarget(actionTargetAddress).mintAddress();
        if (
            memberNFTAddress == address(0) || phaseAddress == address(0) || launchAddress == address(0)
                || mintAddress == address(0)
        ) {
            revert InvalidAddress();
        }

        s.actionTarget = actionTargetAddress;
        s.mintAddress = mintAddress;
        s.stakeAddress = stakeAddress;
        s.groupActionExecutorAddress = groupActionExecutorAddress;
        s.memberNFTAddress = memberNFTAddress;
        s.phaseAddress = phaseAddress;
        s.launchAddress = launchAddress;
    }

    // Load-bearing: the service rounds are the served GroupAction rounds shifted by the same phase
    // base (vote = phase, join = phase - 1, verify = phase - 2, mint = phase - 3). The service runs
    // no verification of its own: it reads `generatedActionReward` /
    // `generatedActionRewardByGroupId` for the round the GroupAction verified at phase - 2 and
    // settles it at phase - 3. If either side shifts, the service reads a round the GroupAction has
    // not verified yet and the divisor silently reads 0.
    function currentVerifyRound() public view returns (uint256) {
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        if (phase < 3) {
            revert RoundNotStarted();
        }
        return phase - 2;
    }

    function currentVoteRound() external view returns (uint256) {
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        if (phase < 1) {
            revert RoundNotStarted();
        }
        return phase;
    }

    function currentJoinRound() public view returns (uint256) {
        uint256 round = s.joinRound();
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

    function GOV_RATIO_MULTIPLIER(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return s.govRatioMultiplier[serviceTokenAddress][serviceActionId];
    }

    function ACTION_TOKEN_ADDRESS(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (address) {
        return s.actionTokenAddress[serviceTokenAddress][serviceActionId];
    }

    function RATIO_FOR_PUBLIC_VERIFIER(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return s.ratioForPublicVerifier[serviceTokenAddress][serviceActionId];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = s.currentJoinRound();

        if (IActionTarget(s.actionTarget).isJoined(serviceTokenAddress, serviceActionId, memberId)) {
            revert AlreadyJoined(serviceTokenAddress, serviceActionId, memberId);
        }

        address actionTokenAddress = s.actionTokenAddress[serviceTokenAddress][serviceActionId];
        if (!_isQualified(actionTokenAddress, round, memberId)) {
            revert NotQualified(actionTokenAddress, round, memberId);
        }

        IActionTarget(s.actionTarget).registerJoinState(serviceTokenAddress, serviceActionId, memberId);

        emit Joined({
            serviceTokenAddress: serviceTokenAddress,
            serviceActionId: serviceActionId,
            memberId: memberId,
            round: round
        });
    }

    function joinInfo(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    ) external view returns (bool joined) {
        return IActionTarget(s.actionTarget).isJoinedByRound(serviceTokenAddress, serviceActionId, memberId, round);
    }

    function rewardByRecipient(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256) {
        GroupRecipients.Distribution memory distribution =
            _distribution(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);

        if (recipientId == groupId) {
            return distribution.ownerAmount;
        }
        for (uint256 i = 0; i < distribution.recipientIds.length; i++) {
            if (distribution.recipientIds[i] == recipientId) {
                return distribution.amounts[i];
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
        GroupRecipients.Distribution memory distribution =
            _distribution(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);
        return (distribution.recipientIds, distribution.ratios, distribution.amounts, distribution.ownerAmount);
    }

    function joinedAmountTokenAddress(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address joinedTokenAddress) {
        return s.actionTokenAddress[tokenAddress][actionId];
    }

    function joinedAmount(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount) {
        if (round > s.joinRound()) {
            return 0;
        }
        return IGroupActionExecutor(s.groupActionExecutorAddress).totalStaked(
            s.actionTokenAddress[tokenAddress][actionId]
        );
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256 amount) {
        if (round > s.joinRound()) {
            return 0;
        }
        return IGroupActionExecutor(s.groupActionExecutorAddress).totalStakedByMemberId(
            s.actionTokenAddress[tokenAddress][actionId], memberId
        );
    }

    function totalGroupActionReward(
        address actionTokenAddress,
        uint256 round
    ) public view returns (uint256) {
        uint256 cached = s.cachedDenominator(actionTokenAddress, round);
        if (cached != 0) {
            return cached;
        }
        return _totalGroupActionReward(_roundActions(actionTokenAddress, round));
    }

    function serviceRewardByMember(
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
        if (s.memberMinted[serviceTokenAddress][serviceActionId][round][memberId]) {
            verifierReward = s.verifierRewardByMember[serviceTokenAddress][serviceActionId][round][memberId];
            ownerDistributed = s.ownerDistributedByMember[serviceTokenAddress][serviceActionId][round][memberId];
            ownerRemaining = s.ownerRemainingByMember[serviceTokenAddress][serviceActionId][round][memberId];
            ownerReward = ownerDistributed + ownerRemaining;
            ownerBurned = s.ownerBurnedByMember[serviceTokenAddress][serviceActionId][round][memberId];
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
                s, settlement.actionTokenAddress, round, memberId, ownerReward, settlement.ownerWeight
            );
            ownerRemaining = ownerReward - ownerDistributed;
        }
        // forge-lint: disable-next-line(boolean-cst)
        return (verifierReward, ownerReward, ownerBurned, ownerDistributed, ownerRemaining, false);
    }

    function memberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) external view returns (uint256 mintAmount, uint256 burnAmount, bool minted) {
        if (s.memberMinted[tokenAddress][actionId][round][memberId]) {
            return (
                s.verifierRewardByMember[tokenAddress][actionId][round][memberId]
                    + s.ownerDistributedByMember[tokenAddress][actionId][round][memberId]
                    + s.ownerRemainingByMember[tokenAddress][actionId][round][memberId],
                s.ownerBurnedByMember[tokenAddress][actionId][round][memberId],
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
    function mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) public nonReentrant onlyMemberOwner(memberId) returns (uint256 mintAmount, uint256 burnAmount) {
        return _mintMemberReward(tokenAddress, actionId, memberId, round);
    }

    function mintMemberRewards(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256 memberId,
        uint256[] calldata rounds
    ) external nonReentrant onlyMemberOwner(memberId) returns (uint256[] memory mintAmounts, uint256[] memory burnAmounts) {
        uint256 length = actionIds.length;
        if (length != rounds.length) {
            revert BatchLengthMismatch(length, rounds.length);
        }

        mintAmounts = new uint256[](length);
        burnAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            (mintAmounts[i], burnAmounts[i]) = _mintMemberReward(tokenAddress, actionIds[i], memberId, rounds[i]);
        }
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
            s, currentVerifyRound(), sourceTokenAddress, sourceActionId, groupId, recipientIds, ratios, remarks
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
        return GroupRecipients.recipients(s, sourceTokenAddress, sourceActionId, groupId, round);
    }

    function actionIdsWithRecipients(
        address sourceTokenAddress,
        uint256 groupId,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 total) {
        return GroupRecipients.actionIdsWithRecipients(s, sourceTokenAddress, groupId, round, offset, limit, reverse);
    }

    function getDistribution(
        address sourceTokenAddress,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 groupReward,
        uint256 round
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
        GroupRecipients.Distribution memory distribution =
            GroupRecipients.getDistribution(s, sourceTokenAddress, sourceActionId, groupId, groupReward, round);
        return (distribution.recipientIds, distribution.ratios, distribution.amounts, distribution.ownerAmount);
    }

    function actionTarget() external view returns (address) {
        return s.actionTarget;
    }

    function initialized() external view returns (bool) {
        return s.initialized;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        if (!IActionTarget(s.actionTarget).isJoined(tokenAddress, actionId, memberId)) {
            revert NotJoined(tokenAddress, actionId, memberId);
        }

        uint256 round = s.currentJoinRound();
        IActionTarget(s.actionTarget).clearJoinState(tokenAddress, actionId, memberId);

        emit Exited({
            serviceTokenAddress: tokenAddress,
            serviceActionId: actionId,
            memberId: memberId,
            round: round
        });
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes[] calldata targetData
    ) external override onlyActionTarget {
        if (
            targetData.length != 4 || targetData[0].length != 32 || targetData[1].length != 32
                || targetData[2].length != 32 || targetData[3].length != 32
        ) {
            revert InvalidTargetDataLength();
        }

        address actionTokenAddress = abi.decode(targetData[1], (address));
        uint256 govRatioMultiplier = abi.decode(targetData[2], (uint256));
        uint256 ratioForPublicVerifier = abi.decode(targetData[3], (uint256));

        if (actionTokenAddress == address(0)) {
            revert InvalidAddress();
        }
        if (ratioForPublicVerifier > PRECISION) {
            revert InvalidRatio();
        }
        if (
            actionTokenAddress != tokenAddress
                && ILaunch(s.launchAddress).parentTokenOf(actionTokenAddress) != tokenAddress
        ) {
            revert InvalidParentToken();
        }

        s.actionTokenAddress[tokenAddress][proposalId] = actionTokenAddress;
        s.govRatioMultiplier[tokenAddress][proposalId] = govRatioMultiplier;
        s.ratioForPublicVerifier[tokenAddress][proposalId] = ratioForPublicVerifier;
        s.createdRound[tokenAddress][proposalId] = IPhase(s.phaseAddress).currentPhase();
    }

    function onProposalSubmitted(
        address,
        uint256,
        uint256,
        bytes[] calldata
    ) external
        virtual
        override
        onlyActionTarget
    {}

    function onProposalVoted(
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes[] calldata targetData
    ) external virtual override onlyActionTarget {
        if (targetData.length > 1) {
            revert InvalidTargetDataLength();
        }
    }

    function _distribution(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) internal view returns (GroupRecipients.Distribution memory) {
        (address actionTokenAddress, uint256 slice) =
            _ownerSlice(serviceTokenAddress, serviceActionId, round, sourceActionId, groupId);
        return GroupRecipients.getDistribution(s, actionTokenAddress, sourceActionId, groupId, slice, round);
    }

    function _ownerSlice(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    ) internal view returns (address actionTokenAddress, uint256 slice) {
        uint256 ownerReward;
        uint256 ownerWeight;
        (actionTokenAddress, ownerReward, ownerWeight) =
            _ownerRewardAndWeight(serviceTokenAddress, serviceActionId, round, groupId);
        if (ownerReward != 0 && ownerWeight != 0) {
            slice = GroupRecipients.ownerSlice(
                s, actionTokenAddress, sourceActionId, round, groupId, ownerReward, ownerWeight
            );
        }
    }

    function _settlement(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 round,
        uint256 memberId
    ) internal view returns (Settlement memory settlement) {
        settlement.actionTokenAddress = s.actionTokenAddress[serviceTokenAddress][serviceActionId];
        if (!IActionTarget(s.actionTarget).isJoinedByRound(serviceTokenAddress, serviceActionId, memberId, round)) {
            return settlement;
        }

        RoundActions memory scope = _roundActions(settlement.actionTokenAddress, round);
        (settlement.verifierWeight, settlement.ownerWeight) = _memberWeights(scope, memberId);
        if (settlement.verifierWeight == 0 && settlement.ownerWeight == 0) {
            return settlement;
        }

        settlement.ratioForPublicVerifier = s.ratioForPublicVerifier[serviceTokenAddress][serviceActionId];
        settlement.govRatioMultiplier = s.govRatioMultiplier[serviceTokenAddress][serviceActionId];
        settlement.denominator = _denominator(scope);
        if (settlement.denominator == 0) {
            return settlement;
        }

        (settlement.serviceReward, settlement.actionMinted) =
            IActionTarget(s.actionTarget).actionReward(serviceTokenAddress, serviceActionId, round);
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
            settlement.ratioForPublicVerifier * settlement.verifierWeight,
            settlement.denominator * PRECISION
        );

        uint256 ownerRatioWeight = (PRECISION - settlement.ratioForPublicVerifier) * settlement.ownerWeight;
        uint256 theoreticalOwnerReward =
            Math.mulDiv(settlement.serviceReward, ownerRatioWeight, settlement.denominator * PRECISION);

        if (settlement.govRatioMultiplier == 0) {
            settlement.ownerReward = theoreticalOwnerReward;
            return;
        }

        uint256 cap = 0;
        uint256 globalGovVotes = IStake(s.stakeAddress).globalGovVotes(settlement.actionTokenAddress);
        if (globalGovVotes != 0) {
            uint256 govRatio = Math.mulDiv(
                IStake(s.stakeAddress).validGovVotes(settlement.actionTokenAddress, memberId),
                PRECISION,
                globalGovVotes
            );
            cap = Math.mulDiv(govRatio, settlement.govRatioMultiplier, PRECISION);
        }

        // Load-bearing: compare against the smallest cap that reaches the theoretical reward instead
        // of cross-multiplying. `cap * denominator >= ownerRatioWeight` is exactly
        // `cap >= ceil(ownerRatioWeight / denominator)`, and the division form cannot overflow. The
        // multiplication overflows for an extreme `govRatioMultiplier`, which would revert every
        // settlement of the action and strand its reward forever.
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
            address actionTokenAddress,
            uint256 ownerReward,
            uint256 ownerWeight
        )
    {
        actionTokenAddress = s.actionTokenAddress[serviceTokenAddress][serviceActionId];
        if (s.memberMinted[serviceTokenAddress][serviceActionId][round][memberId]) {
            ownerReward = s.ownerDistributedByMember[serviceTokenAddress][serviceActionId][round][memberId]
                + s.ownerRemainingByMember[serviceTokenAddress][serviceActionId][round][memberId];
            if (ownerReward != 0) {
                (, ownerWeight) = _memberWeights(_roundActions(actionTokenAddress, round), memberId);
            }
            return (actionTokenAddress, ownerReward, ownerWeight);
        }

        Settlement memory settlement = _settlement(serviceTokenAddress, serviceActionId, round, memberId);
        return (actionTokenAddress, settlement.ownerReward, settlement.ownerWeight);
    }

    function _isQualified(
        address actionTokenAddress,
        uint256 round,
        uint256 memberId
    ) internal view returns (bool) {
        IGroupActionExecutor groupActionExecutor = IGroupActionExecutor(s.groupActionExecutorAddress);
        if (groupActionExecutor.hasActiveGroups(actionTokenAddress, memberId)) {
            return true;
        }

        uint256[] memory actionIds = _votedGroupActions(actionTokenAddress, round);
        for (uint256 i = 0; i < actionIds.length; i++) {
            VerifierApplication memory application =
                groupActionExecutor.verifierApplication(actionTokenAddress, actionIds[i], round, memberId);
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
            ownerWeight += s.groupReward(scope.actionTokenAddress, actionId, scope.round, memberId);
            if (_lockedVerifierId(scope.actionTokenAddress, actionId, scope.round) == memberId) {
                verifierWeight += IGroupActionExecutor(s.groupActionExecutorAddress).generatedActionReward(
                    scope.actionTokenAddress, actionId, scope.round
                );
            }
        }
    }

    function _denominator(RoundActions memory scope) internal view returns (uint256) {
        uint256 cached = s.cachedDenominator(scope.actionTokenAddress, scope.round);
        return cached != 0 ? cached : _totalGroupActionReward(scope);
    }

    function _totalGroupActionReward(RoundActions memory scope) internal view returns (uint256 total) {
        for (uint256 i = 0; i < scope.actionIds.length; i++) {
            total += IGroupActionExecutor(s.groupActionExecutorAddress).generatedActionReward(
                scope.actionTokenAddress, scope.actionIds[i], scope.round
            );
        }
    }

    function _roundActions(
        address actionTokenAddress,
        uint256 round
    ) internal view returns (RoundActions memory scope) {
        scope.actionTokenAddress = actionTokenAddress;
        scope.round = round;
        scope.actionIds = _votedGroupActions(actionTokenAddress, round);
    }

    function _votedGroupActions(
        address actionTokenAddress,
        uint256 round
    ) internal view returns (uint256[] memory) {
        (uint256[] memory actionIds, address[] memory executors, ) =
            IActionTarget(s.actionTarget).votedActions(actionTokenAddress, round, 0, type(uint256).max, false);

        uint256 count = 0;
        for (uint256 i = 0; i < actionIds.length; i++) {
            if (executors[i] == s.groupActionExecutorAddress) {
                count++;
            }
        }

        uint256[] memory groupActionIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < actionIds.length; i++) {
            if (executors[i] == s.groupActionExecutorAddress) {
                groupActionIds[index] = actionIds[i];
                index++;
            }
        }
        return groupActionIds;
    }

    function _lockedVerifierId(
        address actionTokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (uint256) {
        return IGroupActionExecutor(s.groupActionExecutorAddress).lockedVerifierId(actionTokenAddress, actionId, round);
    }

    function _isSettleableRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) internal view returns (bool) {
        uint256 createdRound = s.createdRound[tokenAddress][actionId];
        return createdRound != 0 && round >= createdRound && round <= _mintRound();
    }

    function _mintRound() internal view returns (uint256) {
        uint256 phase = IPhase(s.phaseAddress).currentPhase();
        return phase < 4 ? 0 : phase - 3;
    }
    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function _mintMemberReward(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId,
        uint256 round
    ) private returns (uint256 mintAmount, uint256 burnAmount) {
        uint256 createdRound = s.createdRound[tokenAddress][actionId];
        if (createdRound == 0) {
            revert ActionNotCreated(tokenAddress, actionId);
        }
        if (round < createdRound) {
            revert RoundNotStarted();
        }
        if (round > _mintRound()) {
            revert InvalidRound(round);
        }

        if (s.memberMinted[tokenAddress][actionId][round][memberId]) {
            revert RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
        }

        Settlement memory settlement = _settlement(tokenAddress, actionId, round, memberId);
        mintAmount = settlement.verifierReward + settlement.ownerReward;
        burnAmount = settlement.ownerBurned;
        if (mintAmount == 0 && burnAmount == 0) {
            revert NoRewardAvailable();
        }

        if (!settlement.actionMinted) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            settlement.serviceReward = IActionTarget(s.actionTarget).mintActionReward(tokenAddress, actionId, round);
            _applyFormulas(settlement, memberId);
            mintAmount = settlement.verifierReward + settlement.ownerReward;
            burnAmount = settlement.ownerBurned;
            if (mintAmount == 0 && burnAmount == 0) {
                revert NoRewardAvailable();
            }
        }

        // Load-bearing: the cache key is the action token's round, not the service token's; a parent
        // service leaves the child's round open, and caching there pairs a frozen divisor with live weights.
        if (
            s.cachedDenominator(settlement.actionTokenAddress, round) == 0
                && IMint(s.mintAddress).isRewardPrepared(settlement.actionTokenAddress, round)
        ) {
            s.cacheDenominator(settlement.actionTokenAddress, round, settlement.denominator);
        }

        s.memberMinted[tokenAddress][actionId][round][memberId] = true;
        s.verifierRewardByMember[tokenAddress][actionId][round][memberId] = settlement.verifierReward;
        s.ownerBurnedByMember[tokenAddress][actionId][round][memberId] = burnAmount;

        if (burnAmount != 0) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            ILOVE20Token(tokenAddress).burn(burnAmount);
        }

        uint256 distributed = 0;
        if (settlement.ownerReward != 0) {
            // forge-lint: disable-next-item(reentrancy-no-eth)
            distributed = GroupRecipients.distribute(
                s,
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
        s.ownerDistributedByMember[tokenAddress][actionId][round][memberId] = distributed;
        s.ownerRemainingByMember[tokenAddress][actionId][round][memberId] = remaining;

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
        emit ServiceRewardDistributed({
            serviceTokenAddress: tokenAddress,
            round: round,
            serviceActionId: actionId,
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
