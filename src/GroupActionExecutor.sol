// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IGroupAction} from "./interface/IGroupAction.sol";
import {IGroupActionFactory} from "./interface/IGroupActionFactory.sol";
import {IGroupJoin} from "./interface/IGroupJoin.sol";
import {IGroupVerify} from "./interface/IGroupVerify.sol";
import {IGroupManager} from "./interface/IGroupManager.sol";
import {ExtensionBaseReward} from "@extension/src/ExtensionBaseReward.sol";
import {ExtensionBase} from "@extension/src/ExtensionBase.sol";

contract ExtensionGroupAction is ExtensionBaseReward, IGroupAction {
    IGroupJoin internal immutable _groupJoin;
    IGroupVerify internal immutable _groupVerify;
    IGroupManager internal immutable _groupManager;

    address public immutable JOIN_TOKEN_ADDRESS;
    uint256 public immutable ACTIVATION_STAKE_AMOUNT;
    uint256 public immutable MAX_JOIN_AMOUNT_RATIO;
    uint256 public immutable ACTIVATION_MIN_GOV_RATIO;

    constructor(
        address factory_,
        address tokenAddress_,
        uint256 activationMinGovRatio_,
        uint256 activationStakeAmount_,
        address joinTokenAddress_,
        uint256 maxJoinAmountRatio_
    ) ExtensionBaseReward(factory_, tokenAddress_) {
        IGroupActionFactory factory = IGroupActionFactory(factory_);
        address groupJoinAddress = factory.GROUP_JOIN_ADDRESS();
        _groupJoin = IGroupJoin(groupJoinAddress);
        _groupVerify = IGroupVerify(factory.GROUP_VERIFY_ADDRESS());
        _groupManager = IGroupManager(factory.GROUP_MANAGER_ADDRESS());
        _center.setExtensionDelegate(groupJoinAddress);

        JOIN_TOKEN_ADDRESS = joinTokenAddress_;
        ACTIVATION_STAKE_AMOUNT = activationStakeAmount_;
        MAX_JOIN_AMOUNT_RATIO = maxJoinAmountRatio_;
        ACTIVATION_MIN_GOV_RATIO = activationMinGovRatio_;
    }

    function _calculateBurnAmount(
        uint256 round,
        uint256 totalReward
    ) internal view override returns (uint256) {
        uint256[] memory groupIds_ = _groupVerify.groupIds(
            address(this),
            round
        );
        if (groupIds_.length > 0) {
            return 0;
        }
        return totalReward;
    }

    function generatedActionRewardByGroupId(
        uint256 round,
        uint256 groupId
    ) external view returns (uint256) {
        return _calculateRewardByGroupId(round, groupId);
    }

    function generatedActionRewardByVerifier(
        address verifier,
        uint256 round
    ) external view returns (uint256 amount) {
        uint256[] memory groupIds = _groupVerify.groupIdsByVerifier(
            address(this),
            round,
            verifier
        );
        for (uint256 i = 0; i < groupIds.length; i++) {
            amount += _calculateRewardByGroupId(round, groupIds[i]);
        }
        return amount;
    }

    function joinedAmount()
        external
        view
        override(ExtensionBase)
        returns (uint256)
    {
        return _groupJoin.joinedAmount(address(this), _join.currentRound());
    }

    function joinedAmountByAccount(
        address account
    ) external view override(ExtensionBase) returns (uint256) {
        (, uint256 amount, , ) = _groupJoin.joinInfo(
            address(this),
            _join.currentRound(),
            account
        );
        return amount;
    }

    function joinedAmountTokenAddress()
        external
        view
        override(ExtensionBase)
        returns (address)
    {
        return JOIN_TOKEN_ADDRESS;
    }

    function _calculateReward(
        uint256 round,
        address account
    ) internal view override returns (uint256 mintReward, uint256 burnReward) {
        uint256 groupId = _groupJoin.groupIdByAccount(
            address(this),
            round,
            account
        );
        if (groupId == 0) return (0, 0);

        uint256 accountScore = _groupVerify.accountScore(
            address(this),
            round,
            account
        );
        if (accountScore == 0) return (0, 0);

        uint256 groupTotalScore = _groupVerify.totalAccountScore(
            address(this),
            round,
            groupId
        );
        if (groupTotalScore == 0) return (0, 0);

        uint256 groupReward = _calculateRewardByGroupId(round, groupId);
        if (groupReward == 0) return (0, 0);

        mintReward = (groupReward * accountScore) / groupTotalScore;
        return (mintReward, 0); // No burn for group action
    }

    function _calculateRewardByGroupId(
        uint256 round,
        uint256 groupId
    ) internal view returns (uint256) {
        uint256 totalReward = reward(round);
        if (totalReward == 0) return 0;

        uint256 totalScore = _groupVerify.totalGroupScore(address(this), round);
        if (totalScore == 0) return 0;

        uint256 groupScore = _groupVerify.groupScore(
            address(this),
            round,
            groupId
        );
        return (totalReward * groupScore) / totalScore;
    }
}
