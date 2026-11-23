// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceStorage} from "./GroupServiceStorage.sol";
import {GroupRecipients} from "./GroupRecipients.sol";
import {GroupServiceRoundAxis} from "./GroupServiceRoundAxis.sol";
import {GroupActionVerify} from "./GroupActionVerify.sol";
import {ExecutorBase} from "./ExecutorBase.sol";
import {MemberOwner} from "./MemberOwner.sol";
import {
    IGroupServiceExecutor, GroupServiceCreationParams, MemberRewardSummary, ServiceRewardDetails
} from "./interfaces/IGroupServiceExecutor.sol";
import {MemberRewardStatus} from "./interfaces/IMemberRewardExecutor.sol";
import {IActionTarget} from "./interfaces/IActionTarget.sol";
import {IGroupActionExecutor} from "./interfaces/IGroupActionExecutor.sol";
import {GroupRewardKey} from "./interfaces/IGroupActionVerify.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IPhase} from "@core/interfaces/IPhase.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract GroupServiceExecutor is IGroupServiceExecutor, ExecutorBase {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = GroupServiceStorage.PRECISION;
    uint256 public constant MAX_RECIPIENTS_PER_ACTION = GroupServiceStorage.MAX_RECIPIENTS_PER_ACTION;
    uint256 public constant MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP = GroupServiceStorage.MAX_RECIPIENT_ACTIONS_PER_TOKEN_GROUP;

    uint256 private constant CREATION_DATA_BYTES = 128;

    struct MemberShareMintResult {
        uint256 mintAmount;
        uint256 burnAmount;
        bool previouslySettled;
        GroupServiceStorage.PrimaryAmounts primaryPaid;
        GroupServiceStorage.Settlement settlement;
    }

    GroupServiceStorage.Layout internal _layout;

    address public immutable GROUP_ACTION_EXECUTOR_ADDRESS;
    address public immutable override LAUNCH_ADDRESS;
    address public immutable override MINT_ADDRESS;

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
        protocol.actionTargetAddress = ACTION_TARGET_ADDRESS;
        protocol.stakeAddress = STAKE_ADDRESS;
    }

    // Load-bearing: the service rounds are the served GroupAction rounds shifted by the same phase
    // base (vote = phase, join = phase - 1, verify = phase - 2, mint = phase - 3). The service runs
    // no verification of its own: it settles the finished GroupAction totals and group slices
    // at phase - 3, after the source verification window has closed.
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

    function providerIncentiveRatio(
        address serviceTokenAddress,
        uint256 serviceActionId
    ) external view returns (uint256) {
        return _layout.providerIncentiveRatioByActionId[serviceTokenAddress][serviceActionId];
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function join(
        address serviceTokenAddress,
        uint256 serviceActionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = currentJoinRound();

        if (_layout.createdRoundByActionId[serviceTokenAddress][serviceActionId] == 0) {
            revert ActionNotCreated(serviceTokenAddress, serviceActionId);
        }
        if (IActionTarget(ACTION_TARGET_ADDRESS).isJoined(serviceTokenAddress, serviceActionId, memberId)) {
            revert AlreadyJoined(serviceTokenAddress, serviceActionId, memberId);
        }

        IActionTarget(ACTION_TARGET_ADDRESS).registerJoinState(serviceTokenAddress, serviceActionId, memberId);

        emit ServiceJoined({
            serviceTokenAddress: serviceTokenAddress,
            serviceActionId: serviceActionId,
            memberId: memberId,
            round: round
        });
    }

    function recipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external view returns (uint256 amount, bool isMinted) {
        return GroupRecipients.shareReward(
            _layout,
            _protocol(),
            GroupServiceStorage.Share(serviceTokenAddress, round, serviceActionId, sourceActionId, groupId, recipientId),
            false,
            _mintRound()
        );
    }

    function providerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external view returns (uint256 amount, bool isMinted) {
        return GroupRecipients.shareReward(
            _layout,
            _protocol(),
            GroupServiceStorage.Share(serviceTokenAddress, round, serviceActionId, sourceActionId, groupId, providerId),
            true,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintRecipientReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 recipientId
    ) external nonReentrant onlyMemberOwner(recipientId) returns (uint256 amount) {
        (amount,) = GroupRecipients.mintShare(
            _layout,
            _protocol(),
            GroupServiceStorage.Share(serviceTokenAddress, round, serviceActionId, sourceActionId, groupId, recipientId),
            false,
            true,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintProviderReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 sourceActionId,
        uint256 groupId,
        uint256 providerId
    ) external nonReentrant onlyMemberOwner(providerId) returns (uint256 amount) {
        (amount,) = GroupRecipients.mintShare(
            _layout,
            _protocol(),
            GroupServiceStorage.Share(serviceTokenAddress, round, serviceActionId, sourceActionId, groupId, providerId),
            true,
            true,
            _mintRound()
        );
    }

    function providerRewardKeys(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        return GroupRecipients.rewardKeys(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            true,
            offset,
            limit,
            reverse
        );
    }

    function recipientRewardKeys(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (GroupRewardKey[] memory keys, uint256 totalCount) {
        return GroupRecipients.rewardKeys(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            false,
            offset,
            limit,
            reverse
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintProviderRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 providerId,
        GroupRewardKey[] calldata keys
    ) external nonReentrant onlyMemberOwner(providerId) returns (uint256[] memory amounts) {
        _checkRewardKeyBatchSize(keys.length);
        return GroupRecipients.mintShares(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, providerId),
            keys,
            true,
            _mintRound()
        );
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintRecipientRewards(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 recipientId,
        GroupRewardKey[] calldata keys
    ) external nonReentrant onlyMemberOwner(recipientId) returns (uint256[] memory amounts) {
        _checkRewardKeyBatchSize(keys.length);
        return GroupRecipients.mintShares(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, recipientId),
            keys,
            false,
            _mintRound()
        );
    }

    function _checkRewardKeyBatchSize(uint256 actual) private pure {
        uint256 limit = GroupServiceStorage.MAX_REWARD_KEYS_PER_BATCH;
        if (actual > limit) revert TooManyRewardKeys(actual, limit);
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
            uint256 totalRecipientAmount,
            uint256 ownerAmount,
            uint256 providerReserve
        )
    {
        GroupServiceStorage.MemberRewardKey memory key =
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId);
        GroupRecipients.Distribution memory distributionInfo = GroupRecipients.distributionForAction(
            _layout, _protocol(), key, sourceActionId
        );
        return (
            distributionInfo.recipientIds,
            distributionInfo.ratios,
            distributionInfo.amounts,
            distributionInfo.totalRecipientAmount,
            distributionInfo.ownerAmount,
            distributionInfo.providerReserve
        );
    }

    function joinedAmountByActionId(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).totalActivationStakeByRound(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId], round
        );
    }

    function joinedAmountByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 amount) {
        _checkJoinRound(round);
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).activationStakeByGroupIdByRound(
            _layout.actionTokenAddressByActionId[tokenAddress][actionId], round, memberId
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
        return IGroupActionExecutor(GROUP_ACTION_EXECUTOR_ADDRESS).totalGeneratedActionReward(sourceTokenAddress, round);
    }

    function groupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 amount, bool isMinted) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) return (amount, isMinted);
        GroupServiceStorage.MemberRewardKey memory key = GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId);
        amount = _ownerPaid(key);
        // forge-lint: disable-next-line(boolean-cst)
        if (amount != 0) return (amount, true);
        GroupServiceStorage.Settlement memory settlement = _settlement(serviceTokenAddress, round, serviceActionId, groupId, GroupServiceStorage.PrimaryRole.Owner);
        amount = _ownerRewardAfterDistribution(key, settlement);
        isMinted = _ownerBurnCompletesRole(key, settlement, amount);
    }

    function verifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external view returns (uint256 amount, bool isMinted) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) return (amount, isMinted);
        amount = _layout.verifierRewardByMemberId[serviceTokenAddress][serviceActionId][round][verifierId];
        // forge-lint: disable-next-line(boolean-cst)
        if (amount != 0) return (amount, true);
        amount = _settlement(serviceTokenAddress, round, serviceActionId, verifierId, GroupServiceStorage.PrimaryRole.Verifier).verifierReward;
    }

    function groupOwnerBurn(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (uint256 pendingAmount, uint256 burnedAmount) {
        if (!_isSettleableRound(serviceTokenAddress, round, serviceActionId)) return (0, 0);
        burnedAmount = _layout.ownerBurnByGroupId[serviceTokenAddress][serviceActionId][round][groupId];
        if (burnedAmount == 0) {
            pendingAmount = _settlement(serviceTokenAddress, round, serviceActionId, groupId, GroupServiceStorage.PrimaryRole.Owner).ownerBurned;
        }
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintGroupOwnerReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external nonReentrant onlyMemberOwner(groupId) returns (uint256 amount) {
        GroupServiceStorage.MemberRewardKey memory key = GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, groupId);
        (GroupServiceStorage.Settlement memory settlement, GroupServiceStorage.PrimaryAmounts memory amounts) = _mintPrimary(key, GroupServiceStorage.PrimaryRole.Owner);
        _emitPrimary(key, settlement, amounts);
        return amounts.owner;
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function mintVerifierReward(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 verifierId
    ) external nonReentrant onlyMemberOwner(verifierId) returns (uint256 amount) {
        GroupServiceStorage.MemberRewardKey memory key = GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, verifierId);
        (GroupServiceStorage.Settlement memory settlement, GroupServiceStorage.PrimaryAmounts memory amounts) = _mintPrimary(key, GroupServiceStorage.PrimaryRole.Verifier);
        _emitPrimary(key, settlement, amounts);
        return amounts.verifier;
    }

    function serviceRewardDetail(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 memberId
    ) external view returns (ServiceRewardDetails memory details) {
        return _memberDetails(GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, memberId));
    }

    function memberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) external view returns (uint256 pendingAmount, uint256 mintedAmount, MemberRewardStatus status) {
        ServiceRewardDetails memory details = _memberDetails(GroupServiceStorage.MemberRewardKey(tokenAddress, round, actionId, memberId));
        pendingAmount = details.owner.pendingAmount + details.verifier.pendingAmount
            + details.recipient.pendingAmount + details.provider.pendingAmount;
        mintedAmount = details.owner.mintedAmount + details.verifier.mintedAmount
            + details.recipient.mintedAmount + details.provider.mintedAmount;
        bool hasPending = pendingAmount != 0 || details.owner.status == MemberRewardStatus.Pending;
        bool hasSettled = mintedAmount != 0 || details.owner.status == MemberRewardStatus.Settled;
        status = _status(hasPending, hasSettled);
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
            sourceTokenAddress,
            currentVerifyRound(),
            sourceActionId,
            groupId,
            recipientIds,
            ratios,
            remarks
        );
    }

    function recipients(
        address sourceTokenAddress,
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId
    )
        external
        view
        returns (
            uint256[] memory recipientIds,
            uint256[] memory ratios,
            string[] memory remarks
        )
    {
        return GroupRecipients.recipients(_layout, sourceTokenAddress, round, sourceActionId, groupId);
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
        uint256 round,
        uint256 sourceActionId,
        uint256 groupId,
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
            GroupRecipients.distribution(_layout, sourceTokenAddress, round, sourceActionId, groupId, groupReward);
        return (distributionInfo.recipientIds, distributionInfo.ratios, distributionInfo.amounts, distributionInfo.ownerAmount);
    }

    // forge-lint: disable-next-item(missing-events-access-control)
    function exit(
        address tokenAddress,
        uint256 actionId,
        uint256 memberId
    ) external nonReentrant onlyMemberOwner(memberId) {
        uint256 round = currentJoinRound();
        if (!IActionTarget(ACTION_TARGET_ADDRESS).isJoined(tokenAddress, actionId, memberId)) {
            revert NotJoined(tokenAddress, actionId, memberId);
        }

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
        uint256 proposalId,
        bytes calldata creationData
    ) external override onlyActionTarget {
        if (creationData.length != CREATION_DATA_BYTES) {
            revert InvalidCreationDataLength(creationData.length, CREATION_DATA_BYTES);
        }
        if (abi.decode(creationData, (uint256)) > type(uint160).max) {
            revert InvalidCreationDataEncoding();
        }
        GroupServiceCreationParams memory params = abi.decode(creationData, (GroupServiceCreationParams));

        if (params.actionTokenAddress == address(0)) {
            revert ZeroActionTokenAddress();
        }
        if (params.publicVerifierRatio == 0 || params.publicVerifierRatio >= PRECISION) {
            revert InvalidRatioForPublicVerifier(params.publicVerifierRatio);
        }
        if (params.providerIncentiveRatio > PRECISION) {
            revert InvalidProviderIncentiveRatio(params.providerIncentiveRatio);
        }
        if (params.actionTokenAddress != tokenAddress) {
            address parentTokenAddress = ILaunch(LAUNCH_ADDRESS).parentToken(params.actionTokenAddress);
            if (parentTokenAddress != tokenAddress) {
                revert ActionTokenParentMismatch(params.actionTokenAddress, tokenAddress, parentTokenAddress);
            }
        }

        uint256 serviceActionId = proposalId;
        _layout.actionTokenAddressByActionId[tokenAddress][serviceActionId] = params.actionTokenAddress;
        _layout.govRatioMultiplierByActionId[tokenAddress][serviceActionId] = params.govRatioMultiplier;
        _layout.publicVerifierRatioByActionId[tokenAddress][serviceActionId] = params.publicVerifierRatio;
        _layout.providerIncentiveRatioByActionId[tokenAddress][serviceActionId] = params.providerIncentiveRatio;
        _layout.createdRoundByActionId[tokenAddress][serviceActionId] = IPhase(PHASE_ADDRESS).currentPhase();

        emit ServiceActionCreated({
            tokenAddress: tokenAddress,
            actionId: serviceActionId,
            actionTokenAddress: params.actionTokenAddress,
            govRatioMultiplier: params.govRatioMultiplier,
            publicVerifierRatio: params.publicVerifierRatio,
            providerIncentiveRatio: params.providerIncentiveRatio
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

    function _memberDetails(GroupServiceStorage.MemberRewardKey memory key) private view returns (ServiceRewardDetails memory details) {
        if (!_isSettleableRound(key.tokenAddress, key.round, key.actionId)) return details;
        GroupServiceStorage.Settlement memory settlement = _settlement(key.tokenAddress, key.round, key.actionId, key.memberId, GroupServiceStorage.PrimaryRole.Both);
        GroupServiceStorage.PrimaryAmounts memory pending = _pendingPrimary(key, settlement, GroupServiceStorage.PrimaryRole.Both);
        details.ownerBudget = settlement.ownerReward;
        details.ownerBudgetBeforeCap = settlement.ownerReward + settlement.ownerBurned;
        uint256 ownerPaid = _ownerPaid(key);
        details.owner = MemberRewardSummary(pending.owner, ownerPaid,
            _status(pending.owner != 0 || pending.burn != 0, ownerPaid != 0 || settlement.ownerBurned != 0));
        uint256 verifierPaid = _verifierPaid(key);
        details.verifier = MemberRewardSummary(pending.verifier, verifierPaid, _status(pending.verifier != 0, verifierPaid != 0));
        (details.recipient, details.provider) = GroupRecipients.shareSummaries(
            _layout, _protocol(), key, _mintRound()
        );
    }

    function _status(
        bool hasPending,
        bool hasSettled
    ) private pure returns (MemberRewardStatus) {
        if (hasPending) return MemberRewardStatus.Pending;
        return hasSettled ? MemberRewardStatus.Settled : MemberRewardStatus.Unavailable;
    }

    function _ownerRewardAfterDistribution(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement
    ) private view returns (uint256) {
        if (settlement.ownerReward == 0) {
            return 0;
        }
        return GroupRecipients.ownerRewardAfterDistribution(
            _layout,
            _protocol(),
            key,
            settlement
        );
    }

    function _settlement(
        address serviceTokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 memberId,
        GroupServiceStorage.PrimaryRole role
    ) internal view returns (GroupServiceStorage.Settlement memory settlement) {
        settlement = GroupRecipients.settlement(
            _layout,
            _protocol(),
            GroupServiceStorage.MemberRewardKey(serviceTokenAddress, round, serviceActionId, memberId),
            role
        );
    }

    function _ownerRewardAndWeight(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId
    ) internal view returns (address sourceTokenAddress, uint256 ownerReward, uint256 ownerWeight) {
        GroupServiceStorage.Settlement memory settlement = _settlement(tokenAddress, round, actionId, groupId, GroupServiceStorage.PrimaryRole.Owner);
        return (settlement.actionTokenAddress, settlement.ownerReward, settlement.ownerWeight);
    }

    function _isSettleableRound(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) internal view returns (bool) {
        uint256 createdRound = _layout.createdRoundByActionId[tokenAddress][actionId];
        return createdRound != 0 && round >= createdRound && round <= _mintRound();
    }

    function _mintRound() internal view override returns (uint256) {
        return GroupServiceRoundAxis.mintRound(PHASE_ADDRESS);
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkSettlementPool(
        GroupServiceStorage.Settlement memory settlement,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal pure {
        if (settlement.cause == GroupServiceStorage.SettlementCause.NoEligibleWeight) {
            revert ZeroRewardWeight(tokenAddress, actionId, memberId);
        }
        if (settlement.cause == GroupServiceStorage.SettlementCause.PoolEmpty) {
            revert MemberRewardPoolEmpty(tokenAddress, round);
        }
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    function _mintServiceRewardIfNeeded(
        GroupServiceStorage.Settlement memory settlement,
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal returns (bool rewardChanged) {
        if (settlement.actionMinted) {
            return false;
        }

        // The member and recipient claim entry points both hold the reentrancy guard.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 reward = IActionTarget(ACTION_TARGET_ADDRESS).mintActionReward(tokenAddress, round, actionId);
        settlement.actionMinted = true;
        if (reward == settlement.serviceReward) {
            return false;
        }
        if (reward == 0) {
            revert MemberRewardPoolEmpty(tokenAddress, round);
        }
        settlement.serviceReward = reward;
        GroupServiceStorage.Settlement memory actualSettlement =
            GroupRecipients.applyFormulas(settlement, STAKE_ADDRESS, round, memberId);
        settlement.verifierReward = actualSettlement.verifierReward;
        settlement.ownerReward = actualSettlement.ownerReward;
        settlement.ownerBurned = actualSettlement.ownerBurned;
        return true;
    }

    function _pendingOwnerBurn(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 ownerOverflow
    ) internal view returns (uint256) {
        if (ownerOverflow == 0) {
            return 0;
        }
        return _layout.ownerBurnByGroupId[tokenAddress][actionId][round][groupId] == 0 ? ownerOverflow : 0;
    }

    function _burnOwnerReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 groupId,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        _layout.ownerBurnByGroupId[tokenAddress][actionId][round][groupId] = amount;
        ILOVE20Token(tokenAddress).burn(amount);
        emit ServiceOwnerRewardBurned({
            serviceTokenAddress: tokenAddress,
            serviceActionId: actionId,
            round: round,
            groupId: groupId,
            amount: amount
        });
    }

    function _ownerPaid(GroupServiceStorage.MemberRewardKey memory key) private view returns (uint256) {
        return _layout.ownerRemainingByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId];
    }

    function _verifierPaid(GroupServiceStorage.MemberRewardKey memory key) private view returns (uint256) {
        return _layout.verifierRewardByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId];
    }

    function _ownerBurnCompletesRole(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement,
        uint256 pendingOwner
    ) private view returns (bool) {
        return pendingOwner == 0 && settlement.ownerBurned != 0
            && _pendingOwnerBurn(key.tokenAddress, key.round, key.actionId, key.memberId, settlement.ownerBurned) == 0;
    }

    function _anyPrimaryPaid(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement,
        GroupServiceStorage.PrimaryRole role,
        uint256 pendingOwner
    ) private view returns (bool) {
        if (role != GroupServiceStorage.PrimaryRole.Owner && _verifierPaid(key) != 0) return true;
        return role != GroupServiceStorage.PrimaryRole.Verifier && (_ownerPaid(key) != 0
            || _ownerBurnCompletesRole(key, settlement, pendingOwner));
    }

    function _pendingPrimary(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement,
        GroupServiceStorage.PrimaryRole role
    ) private view returns (GroupServiceStorage.PrimaryAmounts memory pending) {
        if (role != GroupServiceStorage.PrimaryRole.Owner && _verifierPaid(key) == 0) pending.verifier = settlement.verifierReward;
        if (role != GroupServiceStorage.PrimaryRole.Verifier && _ownerPaid(key) == 0) {
            pending.owner = _ownerRewardAfterDistribution(key, settlement);
            pending.burn = _pendingOwnerBurn(key.tokenAddress, key.round, key.actionId, key.memberId, settlement.ownerBurned);
        }
    }

    function _checkPrimaryAmounts(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement,
        GroupServiceStorage.PrimaryRole role,
        GroupServiceStorage.PrimaryAmounts memory pending
    ) private view {
        if (pending.owner + pending.verifier + pending.burn != 0) return;
        if (_anyPrimaryPaid(key, settlement, role, pending.owner)) {
            revert RewardAlreadyMinted(key.tokenAddress, key.actionId, key.memberId, key.round);
        }
        if (role != GroupServiceStorage.PrimaryRole.Verifier && settlement.ownerReward != 0) revert ZeroOwnerRewardRemaining(key.memberId);
        revert MemberRewardRoundedToZero(key.tokenAddress, key.round, key.memberId);
    }

    function _mintPrimary(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryRole role
    ) private returns (GroupServiceStorage.Settlement memory settlement, GroupServiceStorage.PrimaryAmounts memory pending) {
        _checkMintWindow(
            key.tokenAddress,
            key.round,
            key.actionId,
            key.memberId,
            _layout.createdRoundByActionId[key.tokenAddress][key.actionId],
            false
        );
        settlement = _settlement(key.tokenAddress, key.round, key.actionId, key.memberId, role);
        _checkSettlementPool(settlement, key.tokenAddress, key.round, key.actionId, key.memberId);
        pending = _pendingPrimary(key, settlement, role);
        if (
            pending.owner + pending.verifier + pending.burn == 0 && !settlement.actionMinted
                && (settlement.ownerWeight != 0 || settlement.verifierWeight != 0)
        ) {
            _mintServiceRewardIfNeeded(settlement, key.tokenAddress, key.round, key.actionId, key.memberId);
            pending = _pendingPrimary(key, settlement, role);
        }
        _checkPrimaryAmounts(key, settlement, role, pending);
        if (_mintServiceRewardIfNeeded(settlement, key.tokenAddress, key.round, key.actionId, key.memberId)) {
            pending = _pendingPrimary(key, settlement, role);
            _checkPrimaryAmounts(key, settlement, role, pending);
        }
        _payPrimary(key, pending);
    }

    function _payPrimary(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.PrimaryAmounts memory pending
    ) private {
        if (pending.verifier != 0) {
            _layout.verifierRewardByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId] = pending.verifier;
        }
        if (pending.owner != 0 || pending.burn != 0) {
            _layout.ownerRemainingByMemberId[key.tokenAddress][key.actionId][key.round][key.memberId] = pending.owner;
            _burnOwnerReward(key.tokenAddress, key.round, key.actionId, key.memberId, pending.burn);
        }
        uint256 amount = pending.owner + pending.verifier;
        if (amount != 0) IERC20(key.tokenAddress).safeTransfer(msg.sender, amount);
    }

    function _emitPrimary(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement,
        GroupServiceStorage.PrimaryAmounts memory amounts
    ) private {
        emit ServiceRewardsDistributed({
            serviceTokenAddress: key.tokenAddress,
            serviceActionId: key.actionId,
            round: key.round,
            actionTokenAddress: settlement.actionTokenAddress,
            memberId: key.memberId,
            verifierReward: amounts.verifier,
            ownerReward: amounts.owner != 0 || amounts.burn != 0 ? settlement.ownerReward : 0,
            ownerRemaining: amounts.owner
        });
    }

    function _mintMemberShares(
        GroupServiceStorage.MemberRewardKey memory key,
        GroupServiceStorage.Settlement memory settlement
    ) private returns (MemberShareMintResult memory result) {
        result.settlement = settlement;
        bool sharesPreviouslySettled;
        (result.mintAmount, result.burnAmount, sharesPreviouslySettled) =
            GroupRecipients.mintMemberShares(_layout, _protocol(), key, _mintRound());
        result.previouslySettled = sharesPreviouslySettled;

        (uint256 actualReward, ) =
            IActionTarget(ACTION_TARGET_ADDRESS).actionReward(key.tokenAddress, key.round, key.actionId);
        if (actualReward == settlement.serviceReward) return result;

        result.settlement =
            _settlement(key.tokenAddress, key.round, key.actionId, key.memberId, GroupServiceStorage.PrimaryRole.Both);
        GroupServiceStorage.PrimaryAmounts memory pending =
            _pendingPrimary(key, result.settlement, GroupServiceStorage.PrimaryRole.Both);
        if (pending.owner + pending.verifier + pending.burn != 0) {
            _payPrimary(key, pending);
            result.primaryPaid = pending;
            result.mintAmount += pending.owner + pending.verifier;
            result.burnAmount += pending.burn;
        }

        uint256 shareAmount;
        uint256 shareBurn;
        (shareAmount, shareBurn, sharesPreviouslySettled) =
            GroupRecipients.mintMemberShares(_layout, _protocol(), key, _mintRound());
        result.mintAmount += shareAmount;
        result.burnAmount += shareBurn;
        result.previouslySettled = result.previouslySettled || sharesPreviouslySettled;
    }

    // forge-lint: disable-next-item(missing-events-access-control, require-revert-in-loop)
    function _mintMemberReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 memberId
    ) internal override returns (uint256 mintAmount, uint256 burnAmount) {
        _checkMintWindow(
            tokenAddress, round, actionId, memberId, _layout.createdRoundByActionId[tokenAddress][actionId], false
        );
        GroupServiceStorage.MemberRewardKey memory key = GroupServiceStorage.MemberRewardKey(tokenAddress, round, actionId, memberId);
        GroupServiceStorage.Settlement memory settlement = _settlement(tokenAddress, round, actionId, memberId, GroupServiceStorage.PrimaryRole.Both);
        GroupServiceStorage.PrimaryAmounts memory pending = _pendingPrimary(key, settlement, GroupServiceStorage.PrimaryRole.Both);
        if (
            pending.owner + pending.verifier + pending.burn == 0 && !settlement.actionMinted
                && (settlement.ownerWeight != 0 || settlement.verifierWeight != 0)
        ) {
            _mintServiceRewardIfNeeded(settlement, tokenAddress, round, actionId, memberId);
            pending = _pendingPrimary(key, settlement, GroupServiceStorage.PrimaryRole.Both);
        }
        GroupServiceStorage.PrimaryAmounts memory primaryPaid;
        if (pending.owner + pending.verifier + pending.burn != 0) {
            if (_mintServiceRewardIfNeeded(settlement, tokenAddress, round, actionId, memberId)) {
                pending = _pendingPrimary(key, settlement, GroupServiceStorage.PrimaryRole.Both);
            }
            _payPrimary(key, pending);
            primaryPaid = pending;
        }
        mintAmount = pending.owner + pending.verifier;
        burnAmount = pending.burn;
        MemberShareMintResult memory shareResult = _mintMemberShares(key, settlement);
        mintAmount += shareResult.mintAmount;
        burnAmount += shareResult.burnAmount;
        if (
            shareResult.primaryPaid.owner + shareResult.primaryPaid.verifier + shareResult.primaryPaid.burn != 0
        ) {
            primaryPaid = shareResult.primaryPaid;
            settlement = shareResult.settlement;
        }
        if (mintAmount + burnAmount == 0) {
            if (shareResult.previouslySettled) revert RewardAlreadyMinted(tokenAddress, actionId, memberId, round);
            _checkSettlementPool(settlement, tokenAddress, round, actionId, memberId);
            _checkPrimaryAmounts(key, settlement, GroupServiceStorage.PrimaryRole.Both, pending);
        }
        emit MemberRewardMinted({
            tokenAddress: tokenAddress,
            actionId: actionId,
            memberId: memberId,
            round: round,
            mintAmount: mintAmount,
            burnAmount: burnAmount
        });
        if (primaryPaid.owner + primaryPaid.verifier + primaryPaid.burn != 0) {
            _emitPrimary(key, settlement, primaryPaid);
        }
    }
}
