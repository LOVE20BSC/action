// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";

/// @dev Formula and conservation properties: every settlement is checked against
///      an independent reference implementation of the spec formulas, and the
///      sum of all transfers plus burns never exceeds the service reward.
///
///      Inputs are bounded by construction, never by reverting: the parameters
///      pick weights and ratios that keep every settled member above the payout
///      floor, so a revert on any fuzz input is itself a failure.
contract GroupServiceFuzzTest is GroupServiceTestBase {
    /// @dev Two actions, four joined members: the group owner earns in both
    ///      actions, owner B in the first only, and each action locks a
    ///      different verifier. Settles all four and checks every payout
    ///      against the reference formulas, then the conservation invariants.
    function testFuzzSettlementMatchesReferenceFormulas(
        uint96 rewardSeedA,
        uint96 rewardSeedB,
        uint64 ratioSeed,
        uint64 govSeed,
        uint72 validVotesSeed,
        uint72 globalVotesSeed,
        uint96 recipientSeed,
        uint96 serviceSeed
    ) external {
        uint256 rewardA = 1 + uint256(rewardSeedA) % 1e9;
        uint256 rewardB = 1 + uint256(rewardSeedB) % 1e9;
        // r = 0 would leave the pure verifiers with nothing to mint and nothing
        // to burn, and r = PRECISION would do the same to the pure owners; both
        // revert with NoRewardAvailable instead of settling, so those saturated
        // cases are unit-tested instead.
        uint256 ratio = 1 + uint256(ratioSeed) % (PRECISION - 1);
        uint256 govMultiplier = uint256(govSeed) % (2 * PRECISION + 1);
        uint256 validVotes = uint256(validVotesSeed);
        uint256 globalVotes = 1 + uint256(globalVotesSeed) % 1e21;
        uint256 recipientRatio = 1 + uint256(recipientSeed) % PRECISION;

        // The divisor is the sum of every action's total (action A pays
        // rewardA + rewardB across its two groups, action B pays rewardA), while
        // each member's weight is only that member's own share of it.
        uint256 denominator = 2 * rewardA + rewardB;
        uint256 ownerWeight = 2 * rewardA;
        uint256 serviceReward = denominator * (PRECISION + uint256(serviceSeed) % (1e21 - PRECISION));

        _settleFuzzScenario(
            rewardA, rewardB, ratio, govMultiplier, validVotes, globalVotes, recipientRatio, serviceReward
        );

        _assertOwnerSettlement(
            GROUP_ID, serviceReward, denominator, ownerWeight, ratio, govMultiplier, validVotes, globalVotes
        );
        _assertOwnerSettlement(
            GROUP_OWNER_B_ID, serviceReward, denominator, rewardB, ratio, govMultiplier, validVotes, globalVotes
        );
        _assertVerifierSettlement(VERIFIER_ID, rewardA + rewardB, serviceReward, denominator, ratio);
        _assertVerifierSettlement(MEMBER1_ID, rewardA, serviceReward, denominator, ratio);

        // Conservation: everything paid out plus everything burned never
        // exceeds the service reward, and the executor is drained exactly.
        require(
            token.balanceOf(address(executor)) + token.balanceOf(GROUP_OWNER) + token.balanceOf(GROUP_OWNER_B)
                    + token.balanceOf(VERIFIER) + token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2)
                    + token.burnedTotal() == serviceReward,
            "every wei of the reward is accounted for"
        );

        // The recorded owner split always keeps the owner budget intact: the
        // distributed and remaining halves sum back to the reference reward.
        (,, uint256 ownerBurned, uint256 ownerDistributed, uint256 ownerRemaining,) =
            executor.serviceRewardByMember(address(token), SERVICE_ACTION_ID, SERVICE_ROUND, GROUP_ID);
        (uint256 expectedOwner,) =
            _expectedOwner(serviceReward, denominator, ownerWeight, ratio, govMultiplier, validVotes, globalVotes);
        require(
            ownerBurned
                == _expectedBurn(
                    serviceReward, denominator, ownerWeight, ratio, govMultiplier, validVotes, globalVotes
                ),
            "recorded burn matches"
        );
        require(ownerDistributed + ownerRemaining == expectedOwner, "owner budget intact after redistribution");
        require(ownerDistributed <= expectedOwner, "distribution never exceeds the budget");
    }

    /// @dev Redistribution property: whatever the ratios, the recipients get
    ///      exactly their projected share and the owner the remainder, with the
    ///      budget and the executor balance conserved to the wei.
    function testFuzzOwnerRedistributionKeepsTheBudget(
        uint96 serviceRewardSeed,
        uint96 groupRewardSeed,
        uint256 ratioSeedA,
        uint256 ratioSeedB,
        uint256 ratioSeedC
    ) external {
        uint256 serviceReward = 1 + uint256(serviceRewardSeed);
        uint256 groupReward = 1 + uint256(groupRewardSeed);
        // Each ratio must be at least one wei (ZeroRatio) and the three must not
        // sum past PRECISION (DistributionOverflow); the bounds nest so both
        // hold for every input.
        uint256 ratioA = 1 + ratioSeedA % (PRECISION - 2);
        uint256 ratioB = 1 + ratioSeedB % (PRECISION - ratioA - 1);
        uint256 ratioC = 1 + ratioSeedC % (PRECISION - ratioA - ratioB);

        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, 0);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID));
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(groupReward), VERIFIER_ID);
        _armServiceReward(serviceReward);
        _atPhase(VERIFY_PHASE);
        _setRecipients(
            GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID, MEMBER2_ID, GROUP_OWNER_B_ID), _ratios(ratioA, ratioB, ratioC)
        );
        _atPhase(MINT_PHASE);

        (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
        // ratio 0 sends the whole reward to the owner side, and the owner weight
        // equals the divisor, so the theoretical reward is the entire service
        // reward with nothing burned.
        require(mintAmount == serviceReward && burnAmount == 0, "owner receives the theoretical reward");

        uint256 distributed = token.balanceOf(MEMBER1) + token.balanceOf(MEMBER2) + token.balanceOf(GROUP_OWNER_B);
        uint256 remaining = token.balanceOf(GROUP_OWNER);
        require(distributed + remaining == serviceReward, "distributed plus remaining equals the owner reward");
        require(
            token.balanceOf(address(executor)) + distributed + remaining == serviceReward,
            "the executor is drained exactly"
        );

        // The projection agrees with the executed split.
        (uint256[] memory recipientIds,, uint256[] memory amounts, uint256 ownerAmount) =
            executor.rewardDistribution(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID);
        uint256 projected;
        for (uint256 i = 0; i < amounts.length; i++) {
            projected += amounts[i];
        }
        require(projected == distributed, "projection matches the executed distribution");
        require(recipientIds.length == 3, "three recipients");
        require(ownerAmount == remaining, "projected remainder matches");
    }

    function _settleFuzzScenario(
        uint256 rewardA,
        uint256 rewardB,
        uint256 ratio,
        uint256 govMultiplier,
        uint256 validVotes,
        uint256 globalVotes,
        uint256 recipientRatio,
        uint256 serviceReward
    ) internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, govMultiplier, ratio);
        _atPhase(JOIN_PHASE);
        _setVotedGroupActions(_ids(GROUP_ACTION_ID, GROUP_ACTION_ID_B));
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _qualifyCandidate(VERIFIER_ID);
        _qualifyCandidate(MEMBER1_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        _joinService(VERIFIER_ID);
        _joinService(MEMBER1_ID);
        // Owner B holds a group in action A, the plain owner in action B.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(rewardA, rewardB), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(rewardA), MEMBER1_ID);
        stake.setGlobalGovVotes(address(token), globalVotes);
        stake.setValidGovVotes(address(token), GROUP_ID, validVotes);
        stake.setValidGovVotes(address(token), GROUP_OWNER_B_ID, validVotes);
        _armServiceReward(serviceReward);
        _atPhase(VERIFY_PHASE);
        _setRecipients(GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER2_ID), _ratios(recipientRatio));
        _atPhase(MINT_PHASE);
    }

    function _assertOwnerSettlement(
        uint256 memberId,
        uint256 serviceReward,
        uint256 denominator,
        uint256 ownerWeight,
        uint256 ratio,
        uint256 govMultiplier,
        uint256 validVotes,
        uint256 globalVotes
    ) internal {
        (uint256 expectedMint, uint256 expectedBurned) = _expectedOwner(
            serviceReward, denominator, ownerWeight, ratio, govMultiplier, validVotes, globalVotes
        );
        (uint256 mintAmount, uint256 burnAmount) = _settleService(memberId);
        require(mintAmount == expectedMint && burnAmount == expectedBurned, "owner settlement matches the reference");
    }

    function _assertVerifierSettlement(
        uint256 memberId,
        uint256 verifierWeight,
        uint256 serviceReward,
        uint256 denominator,
        uint256 ratio
    ) internal {
        (uint256 mintAmount, uint256 burnAmount) = _settleService(memberId);
        require(
            mintAmount == Math.mulDiv(serviceReward, ratio * verifierWeight, denominator * PRECISION),
            "verifier settlement matches the reference"
        );
        require(burnAmount == 0, "verifiers never burn");
    }

    function _expectedBurn(
        uint256 serviceReward,
        uint256 denominator,
        uint256 ownerWeight,
        uint256 ratioForPublicVerifier,
        uint256 govRatioMultiplier,
        uint256 validGovVotes,
        uint256 globalGovVotes
    ) internal pure returns (uint256) {
        (, uint256 burned) = _expectedOwner(
            serviceReward,
            denominator,
            ownerWeight,
            ratioForPublicVerifier,
            govRatioMultiplier,
            validGovVotes,
            globalGovVotes
        );
        return burned;
    }

    /// @dev A pure restatement of the settlement spec. Kept independent from the
    ///      executor on purpose: any drift between the two is a bug.
    function _expectedOwner(
        uint256 serviceReward,
        uint256 denominator,
        uint256 ownerWeight,
        uint256 ratioForPublicVerifier,
        uint256 govRatioMultiplier,
        uint256 validGovVotes,
        uint256 globalGovVotes
    ) internal pure returns (uint256 ownerReward, uint256 ownerBurned) {
        uint256 ownerRatioWeight = (PRECISION - ratioForPublicVerifier) * ownerWeight;
        uint256 theoretical = Math.mulDiv(serviceReward, ownerRatioWeight, denominator * PRECISION);
        if (govRatioMultiplier == 0) {
            return (theoretical, 0);
        }
        uint256 cap;
        if (globalGovVotes != 0) {
            uint256 govRatio = Math.mulDiv(validGovVotes, PRECISION, globalGovVotes);
            cap = Math.mulDiv(govRatio, govRatioMultiplier, PRECISION);
        }
        if (cap * denominator >= ownerRatioWeight) {
            return (theoretical, 0);
        }
        ownerReward = Math.mulDiv(serviceReward, cap, PRECISION);
        ownerBurned = theoretical - ownerReward;
    }
}
