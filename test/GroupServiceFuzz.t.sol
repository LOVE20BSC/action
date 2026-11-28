// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MemberRewardStatus} from "../src/interfaces/IMemberRewardExecutor.sol";
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
        uint72 totalGovPowerSeed,
        uint96 recipientSeed,
        uint96 serviceSeed
    ) external {
        uint256 rewardA = 1 + uint256(rewardSeedA) % 1e9;
        uint256 rewardB = 1 + uint256(rewardSeedB) % 1e9;
        // The public verifier ratio must be strictly inside (0, 1e18); both bounds
        // are rejected at creation (InvalidRatioForPublicVerifier) and covered by
        // the constructor unit tests.
        uint256 ratio = 1 + uint256(ratioSeed) % (PRECISION - 1);
        uint256 govMultiplier = uint256(govSeed) % (2 * PRECISION + 1);
        uint256 memberGovPower = uint256(validVotesSeed);
        uint256 totalGovPower = 1 + uint256(totalGovPowerSeed) % 1e21;
        uint256 recipientRatio = 1 + uint256(recipientSeed) % PRECISION;

        // The divisor is the sum of every action's total (action A pays
        // rewardA + rewardB across its two groups, action B pays rewardA), while
        // each member's weight is only that member's own share of it.
        uint256 denominator = 2 * rewardA + rewardB;
        uint256 ownerWeight = 2 * rewardA;
        uint256 serviceReward = denominator * (PRECISION + uint256(serviceSeed) % (1e21 - PRECISION));

        _settleFuzzScenario(
            rewardA, rewardB, ratio, govMultiplier, memberGovPower, totalGovPower, recipientRatio, serviceReward
        );

        _assertOwnerSettlement(
            GROUP_ID, serviceReward, denominator, ownerWeight, ratio, govMultiplier, memberGovPower, totalGovPower,
            recipientRatio
        );
        _assertOwnerSettlement(
            GROUP_OWNER_B_ID, serviceReward, denominator, rewardB, ratio, govMultiplier, memberGovPower, totalGovPower, 0
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
            _primaryAccounting(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        (uint256 expectedOwner,) =
            _expectedOwner(serviceReward, denominator, ownerWeight, ratio, govMultiplier, memberGovPower, totalGovPower);
        require(
            ownerBurned
                == _expectedBurn(
                    serviceReward, denominator, ownerWeight, ratio, govMultiplier, memberGovPower, totalGovPower
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
        uint256 serviceReward = 2 + uint256(serviceRewardSeed);
        uint256 groupReward = 1 + uint256(groupRewardSeed);
        // Each ratio must be at least one wei (ZeroRatio) and the three must not
        // sum past PRECISION (DistributionOverflow); the bounds nest so both
        // hold for every input.
        uint256 ratioA = 1 + ratioSeedA % (PRECISION - 2);
        uint256 ratioB = 1 + ratioSeedB % (PRECISION - ratioA - 1);
        uint256 ratioC = 1 + ratioSeedC % (PRECISION - ratioA - ratioB);

        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, 0, PRECISION / 2);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _joinService(GROUP_ID);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(groupReward), VERIFIER_ID);
        _armServiceReward(serviceReward);
        _atPhase(VERIFY_PHASE);
        _setRecipients(
            GROUP_ID, GROUP_ACTION_ID, _ids(MEMBER1_ID, MEMBER2_ID, GROUP_OWNER_B_ID), _ratios(ratioA, ratioB, ratioC)
        );
        _atPhase(MINT_PHASE);

        uint256 ownerBudget = serviceReward / 2;
        uint256 distributed = _assertRecipientClaim(MEMBER1_ID, ownerBudget * ratioA / PRECISION)
            + _assertRecipientClaim(MEMBER2_ID, ownerBudget * ratioB / PRECISION)
            + _assertRecipientClaim(GROUP_OWNER_B_ID, ownerBudget * ratioC / PRECISION);
        uint256 remaining = ownerBudget - distributed;

        if (remaining != 0) {
            (uint256 mintAmount, uint256 burnAmount) = _settleService(GROUP_ID);
            require(mintAmount == remaining && burnAmount == 0, "owner receives the remainder");
        }
        require(token.balanceOf(GROUP_OWNER) == remaining, "owner balance reflects its own share");
        require(
            token.balanceOf(address(executor)) + distributed + remaining == serviceReward,
            "the executor is drained exactly"
        );

        (uint256 pending, uint256 minted, MemberRewardStatus status) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        MemberRewardStatus expectedStatus = remaining == 0 ? MemberRewardStatus.Unavailable : MemberRewardStatus.Settled;
        require(pending == 0 && minted == remaining && status == expectedStatus, "owner quote agrees with the payout");
    }

    function _settleFuzzScenario(
        uint256 rewardA,
        uint256 rewardB,
        uint256 ratio,
        uint256 govMultiplier,
        uint256 memberGovPower,
        uint256 totalGovPower,
        uint256 recipientRatio,
        uint256 serviceReward
    ) internal {
        _atPhase(CREATION_PHASE);
        _createServiceAction(SERVICE_ACTION_ID, govMultiplier, ratio);
        _atPhase(JOIN_PHASE);
        _qualifyGroupOwner(GROUP_ID);
        _qualifyGroupOwner(GROUP_OWNER_B_ID);
        _qualifyVerifier(VERIFIER_ID);
        _qualifyVerifier(MEMBER1_ID);
        _joinService(GROUP_ID);
        _joinService(GROUP_OWNER_B_ID);
        _joinService(VERIFIER_ID);
        _joinService(MEMBER1_ID);
        // Owner B holds a group in action A, the plain owner in action B.
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID, GROUP_OWNER_B_ID), _amounts(rewardA, rewardB), VERIFIER_ID);
        _setGroupLedger(GROUP_ACTION_ID_B, _ids(GROUP_ID), _amounts(rewardA), MEMBER1_ID);
        stake.setTotalGovPower(address(token), SERVICE_ROUND, totalGovPower);
        stake.setGovPower(address(token), SERVICE_ROUND, GROUP_ID, memberGovPower);
        stake.setGovPower(address(token), SERVICE_ROUND, GROUP_OWNER_B_ID, memberGovPower);
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
        uint256 memberGovPower,
        uint256 totalGovPower,
        uint256 recipientRatio
    ) internal {
        (uint256 ownerBudget, uint256 expectedBurned) = _expectedOwner(
            serviceReward, denominator, ownerWeight, ratio, govMultiplier, memberGovPower, totalGovPower
        );
        // For the owner with a recipient, the configured source action contributes half the owner's weight.
        uint256 recipientAmount;
        if (recipientRatio != 0) {
            recipientAmount = _assertRecipientClaim(MEMBER2_ID, (ownerBudget / 2) * recipientRatio / PRECISION);
        }
        (uint256 mintAmount, uint256 burnAmount) = _settleService(memberId);
        require(mintAmount == ownerBudget - recipientAmount && burnAmount == expectedBurned, "owner settlement matches the reference");
    }

    function _assertRecipientClaim(uint256 recipientId, uint256 expectedAmount) internal returns (uint256) {
        (uint256 quoted, bool isMinted) = executor.recipientRewardBySourceActionIdByGroupId(
            address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ACTION_ID, GROUP_ID, recipientId
        );
        require(quoted == expectedAmount && !isMinted, "recipient quote follows the formula");
        if (expectedAmount == 0) {
            return 0;
        }
        address holder = _memberAddress(recipientId);
        uint256 balance = token.balanceOf(holder);
        uint256 amount = _claimRecipient(GROUP_ACTION_ID, recipientId);
        require(amount == expectedAmount && token.balanceOf(holder) == balance + amount, "recipient share paid as projected");
        return amount;
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
        uint256 publicVerifierRatio,
        uint256 govRatioMultiplier,
        uint256 govPower,
        uint256 totalGovPower
    ) internal pure returns (uint256) {
        (, uint256 burned) = _expectedOwner(
            serviceReward,
            denominator,
            ownerWeight,
            publicVerifierRatio,
            govRatioMultiplier,
            govPower,
            totalGovPower
        );
        return burned;
    }

    /// @dev A pure restatement of the settlement spec. Kept independent from the
    ///      executor on purpose: any drift between the two is a bug.
    function _expectedOwner(
        uint256 serviceReward,
        uint256 denominator,
        uint256 ownerWeight,
        uint256 publicVerifierRatio,
        uint256 govRatioMultiplier,
        uint256 govPower,
        uint256 totalGovPower
    ) internal pure returns (uint256 ownerReward, uint256 ownerBurned) {
        uint256 ownerRatioWeight = (PRECISION - publicVerifierRatio) * ownerWeight;
        uint256 theoretical = Math.mulDiv(serviceReward, ownerRatioWeight, denominator * PRECISION);
        if (govRatioMultiplier == 0) {
            return (theoretical, 0);
        }
        uint256 cap;
        if (totalGovPower != 0) {
            uint256 govRatio = Math.mulDiv(govPower, PRECISION, totalGovPower);
            cap = Math.mulDiv(govRatio, govRatioMultiplier, PRECISION);
        }
        if (cap * denominator >= ownerRatioWeight) {
            return (theoretical, 0);
        }
        ownerReward = Math.mulDiv(serviceReward, cap, PRECISION);
        ownerBurned = theoretical - ownerReward;
    }
}
