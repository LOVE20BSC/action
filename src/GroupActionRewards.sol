// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionStorage} from "./GroupActionStorage.sol";
import {Pagination} from "@libs/Pagination.sol";

library GroupActionRewards {
    using GroupActionStorage for GroupActionStorage.Layout;

    function totalGeneratedActionRewardByProviderId(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 providerId
    ) external view returns (uint256 attributedRewardAmount) {
        uint256[] storage ownGroupActionIds = self.verifiedActionIdsByGroupId[tokenAddress][round][providerId];
        attributedRewardAmount = self.totalGeneratedActionRewardByGroupIdByProviderId(
            tokenAddress, round, providerId, providerId, ownGroupActionIds
        );

        uint256[] storage externalGroupIds = self.providerGroupIdsByProviderId[tokenAddress][round][providerId];
        for (uint256 i = 0; i < externalGroupIds.length; ++i) {
            uint256 groupId = externalGroupIds[i];
            uint256[] storage actionIds =
                self.providerActionIdsByGroupIdByProviderId[tokenAddress][round][providerId][groupId];
            attributedRewardAmount += self.totalGeneratedActionRewardByGroupIdByProviderId(
                tokenAddress, round, groupId, providerId, actionIds
            );
        }
    }

    function actionIdsWithGeneratedActionReward(
        GroupActionStorage.Layout storage self,
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory actionIds, uint256 totalCount) {
        return Pagination.paginate(self.actionIdsWithGeneratedActionReward[tokenAddress][round], offset, limit, reverse);
    }
}
