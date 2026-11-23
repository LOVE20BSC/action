// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupServiceTestBase} from "./GroupServiceTestBase.sol";
import {
    IGroupServiceExecutor,
    IGroupServiceExecutorErrors,
    IGroupServiceExecutorEvents
} from "../src/interfaces/IGroupServiceExecutor.sol";

interface IGroupServiceProviderReservePreparation {
    function prepareProviderReserve(
        address tokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId,
        uint256 limit
    ) external returns (uint256 processedActionCount, uint256 totalActionCount, uint256 providerReserve);

    function providerReservePreparation(
        address tokenAddress,
        uint256 round,
        uint256 serviceActionId,
        uint256 groupId
    ) external view returns (
        uint256 ownerWeight,
        uint256 processedActionCount,
        uint256 totalActionCount,
        uint256 providerReserve
    );
}

contract GroupServiceOwnerReservePreparationTest is GroupServiceTestBase, IGroupServiceExecutorEvents {
    event log_named_uint(
        string key,
        uint256 value
    );

    function testOwnerMintWaitsForAllProviderReservePages() external {
        _prepareProviderWeightedActions(65);

        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ProviderReservePreparationRequired.selector,
                address(token),
                SERVICE_ACTION_ID,
                SERVICE_ROUND,
                GROUP_ID,
                0,
                65
            )
        );
        vm.prank(GROUP_OWNER);
        executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(actionTarget.mintRewardCalls() == 0, "gated mint did not mint the service budget");

        _expectReserveProgress(64, 65, 192);
        (uint256 processed, uint256 total, uint256 reserve) = _prepareProviderReserve(64);
        require(processed == 64 && total == 65 && reserve == 192, "first provider reserve page");
        _assertPreparation(6500, 64, 65, 192);
        require(actionTarget.mintRewardCalls() == 1, "first page mints the actual service budget");
        vm.expectRevert(
            abi.encodeWithSelector(
                IGroupServiceExecutorErrors.ProviderReservePreparationRequired.selector,
                address(token),
                SERVICE_ACTION_ID,
                SERVICE_ROUND,
                GROUP_ID,
                64,
                65
            )
        );
        vm.prank(GROUP_OWNER);
        executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(actionTarget.mintRewardCalls() == 1, "partial preparation keeps the budget minted once");

        _expectReserveProgress(65, 65, 195);
        (processed, total, reserve) = _prepareProviderReserve(1);
        require(processed == 65 && total == 65 && reserve == 195, "final provider reserve page");
        _assertPreparation(6500, 65, 65, 195);

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 305,
            "owner receives the prepared remainder"
        );
        (uint256 ownerAmount, bool isMinted) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(ownerAmount == 305 && isMinted, "prepared owner quote matches payment");
        require(actionTarget.mintRewardCalls() == 1, "service budget minted once");
    }

    function testSmallProviderActionSetNeedsNoPreparation() external {
        _prepareProviderWeightedActions(2);

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 250,
            "small owner reward remains directly mintable"
        );
    }

    function testNoProviderActionsAreACompleteZeroReservePreparation() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18);
        _setGroupLedger(GROUP_ACTION_ID, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
        _armServiceReward(1000);
        _atPhase(MINT_PHASE);

        (uint256 processed, uint256 total, uint256 reserve) = _prepareProviderReserve(1);
        require(processed == 0 && total == 0 && reserve == 0, "empty reserve page is complete");
        _assertPreparation(100, 0, 0, 0);

        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 500,
            "owner receives full owner share without providers"
        );
    }

    function testZeroProviderRatioSkipsLargeReservePreparation() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0);
        _armServiceReward(1000);
        for (uint256 i; i < 65; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50
            );
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 6500);
        _atPhase(MINT_PHASE);

        (uint256 processed, uint256 total, uint256 reserve) = _prepareProviderReserve(64);
        require(processed == 0 && total == 0 && reserve == 0, "zero ratio has no preparation work");
        require(actionTarget.mintRewardCalls() == 0, "zero ratio preparation does not mint budget");
        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 500,
            "owner can settle without Provider preparation"
        );
        require(actionTarget.mintRewardCalls() == 1, "owner settlement mints the service budget once");
    }

    function testProviderReservePreparationUsesTheActualServiceBudget() external {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(2000);
        actionTarget.setActionReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, 1000, false);
        for (uint256 i; i < 65; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50
            );
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 6500);
        _atPhase(MINT_PHASE);

        vm.expectEmit(true, true, true, true, address(executor));
        emit ProviderReservePreparationAdvanced({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            ownerReward: 1000,
            processedActionCount: 64,
            totalActionCount: 65,
            providerReserve: 192
        });
        (uint256 processed, uint256 total, uint256 reserve) = _prepareProviderReserve(64);
        require(processed == 64 && total == 65 && reserve == 192, "first page uses actual owner budget");
        require(actionTarget.mintRewardCalls() == 1, "preparation minted actual service budget once");

        vm.expectEmit(true, true, true, true, address(executor));
        emit ProviderReservePreparationAdvanced({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            ownerReward: 1000,
            processedActionCount: 65,
            totalActionCount: 65,
            providerReserve: 195
        });
        (processed, total, reserve) = _prepareProviderReserve(1);
        require(processed == 65 && total == 65 && reserve == 195, "all reserve pages use the same budget");
        _assertPreparation(6500, 65, 65, 195);

        (uint256 ownerAmount, bool isMinted) =
            executor.groupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        require(ownerAmount == 805 && !isMinted, "owner quote uses the actual budget and reserve");
        vm.prank(GROUP_OWNER);
        require(
            executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID) == 805,
            "owner payment matches the actual budget"
        );
        require(actionTarget.mintRewardCalls() == 1, "settlement does not mint a second budget");
    }

    function testProviderReservePreparationIsScopedToEachServiceAction() external {
        uint256 secondServiceActionId = SERVICE_ACTION_ID + 1;
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _createServiceAction(secondServiceActionId, 0, 0.5e18, 0.2e18);
        _armServiceRewardOn(SERVICE_ACTION_ID, 2000);
        _armServiceRewardOn(secondServiceActionId, 2000);
        for (uint256 i; i < 65; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50
            );
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 6500);
        _atPhase(MINT_PHASE);
        require(
            executor.providerIncentiveRatio(address(token), SERVICE_ACTION_ID) == 0.5e18
                && executor.providerIncentiveRatio(address(token), secondServiceActionId) == 0.2e18,
            "service proposals keep their configured ratios"
        );

        (uint256 processed, uint256 total, uint256 reserve) =
            _prepareProviderReserveFor(SERVICE_ACTION_ID, 64);
        require(processed == 64 && total == 65 && reserve == 192, "first proposal reserve starts from zero");
        (processed, total, reserve) = _prepareProviderReserveFor(SERVICE_ACTION_ID, 1);
        require(processed == 65 && total == 65 && reserve == 195, "first proposal reserve uses its ratio");

        (processed, total, reserve) = _prepareProviderReserveFor(secondServiceActionId, 64);
        require(processed == 64 && total == 65 && reserve == 64, "second proposal gets a separate cache");
        (processed, total, reserve) = _prepareProviderReserveFor(secondServiceActionId, 1);
        require(processed == 65 && total == 65 && reserve == 65, "second proposal reserve uses its own ratio");
        require(actionTarget.mintRewardCalls() == 2, "each service proposal mints its budget once");

        _assertPreparationFor(SERVICE_ACTION_ID, 6500, 65, 65, 195);
        _assertPreparationFor(secondServiceActionId, 6500, 65, 65, 65);
    }

    function testThousandProviderActionsUseBoundedPreparationAndOwnerMintGas() external {
        vm.pauseGasMetering();
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(1000e18);
        for (uint256 i; i < 1000; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 50, MEMBER1_ID, 50
            );
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 100_000);
        _atPhase(MINT_PHASE);
        vm.resumeGasMetering();

        uint256 processed;
        uint256 total;
        uint256 reserve;
        uint256 largestPageGas;
        while (processed < 1000) {
            uint256 beforeGas = gasleft();
            (processed, total, reserve) = executor.prepareProviderReserve(
                address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID, 64
            );
            uint256 pageGas = beforeGas - gasleft();
            if (pageGas > largestPageGas) largestPageGas = pageGas;
            require(pageGas < 10_000_000, "reserve page exceeds the BSC transaction budget");
        }
        require(total == 1000 && reserve == 125e18, "all per-action provider reserves are counted");

        vm.prank(GROUP_OWNER);
        uint256 ownerMintGasStart = gasleft();
        uint256 paid = executor.mintGroupOwnerReward(address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID);
        uint256 ownerMintGas = ownerMintGasStart - gasleft();
        emit log_named_uint("largest Provider reserve preparation page gas", largestPageGas);
        emit log_named_uint("prepared GroupService owner mint gas", ownerMintGas);
        require(ownerMintGas < 10_000_000, "prepared owner mint exceeds the local gas budget");
        require(paid == 375e18, "owner receives budget less provider reserve");
        require(actionTarget.mintRewardCalls() == 1, "service budget is minted once during preparation");
        require(largestPageGas < 10_000_000, "every preparation page stays within budget");
    }

    function _prepareProviderWeightedActions(uint256 actionCount) private {
        _createServiceAction(SERVICE_ACTION_ID, 0, 0.5e18, 0.5e18);
        _armServiceReward(1000);
        for (uint256 i; i < actionCount; ++i) {
            uint256 sourceActionId = GROUP_ACTION_ID + i;
            _setGroupLedger(sourceActionId, _ids(GROUP_ID), _amounts(100), VERIFIER_ID);
            groupAction.setMarketScores(
                address(token), SERVICE_ROUND, sourceActionId, GROUP_ID, 100, MEMBER1_ID, 100
            );
        }
        groupAction.setPreparedGroupReward(address(token), SERVICE_ROUND, GROUP_ID, 100 * actionCount);
        _atPhase(MINT_PHASE);
    }

    function _expectReserveProgress(uint256 processed, uint256 total, uint256 reserve) private {
        vm.expectEmit(true, true, true, true, address(executor));
        emit ProviderReservePreparationAdvanced({
            serviceTokenAddress: address(token),
            serviceActionId: SERVICE_ACTION_ID,
            round: SERVICE_ROUND,
            groupId: GROUP_ID,
            ownerReward: 500,
            processedActionCount: processed,
            totalActionCount: total,
            providerReserve: reserve
        });
    }

    function _prepareProviderReserve(uint256 limit)
        private
        returns (uint256 processed, uint256 total, uint256 reserve)
    {
        return _prepareProviderReserveFor(SERVICE_ACTION_ID, limit);
    }

    function _prepareProviderReserveFor(uint256 serviceActionId, uint256 limit)
        private
        returns (uint256 processed, uint256 total, uint256 reserve)
    {
        (bool success, bytes memory result) = address(executor).call(
            abi.encodeCall(
                IGroupServiceProviderReservePreparation.prepareProviderReserve,
                (address(token), SERVICE_ROUND, serviceActionId, GROUP_ID, limit)
            )
        );
        require(success, "provider reserve preparation call succeeded");
        return abi.decode(result, (uint256, uint256, uint256));
    }

    function _assertPreparation(
        uint256 expectedOwnerWeight,
        uint256 expectedProcessed,
        uint256 expectedTotal,
        uint256 expectedReserve
    ) private view {
        (bool success, bytes memory result) = address(executor).staticcall(
            abi.encodeCall(
                IGroupServiceProviderReservePreparation.providerReservePreparation,
                (address(token), SERVICE_ROUND, SERVICE_ACTION_ID, GROUP_ID)
            )
        );
        require(success, "provider reserve preparation query succeeded");
        (uint256 ownerWeight, uint256 processed, uint256 total, uint256 reserve) =
            abi.decode(result, (uint256, uint256, uint256, uint256));
        require(
            ownerWeight == expectedOwnerWeight && processed == expectedProcessed && total == expectedTotal
                && reserve == expectedReserve,
            "provider reserve preparation progress"
        );
    }

    function _assertPreparationFor(
        uint256 serviceActionId,
        uint256 expectedOwnerWeight,
        uint256 expectedProcessed,
        uint256 expectedTotal,
        uint256 expectedReserve
    ) private view {
        (bool success, bytes memory result) = address(executor).staticcall(
            abi.encodeCall(
                IGroupServiceProviderReservePreparation.providerReservePreparation,
                (address(token), SERVICE_ROUND, serviceActionId, GROUP_ID)
            )
        );
        require(success, "provider reserve preparation query succeeded");
        (uint256 ownerWeight, uint256 processed, uint256 total, uint256 reserve) =
            abi.decode(result, (uint256, uint256, uint256, uint256));
        require(
            ownerWeight == expectedOwnerWeight && processed == expectedProcessed && total == expectedTotal
                && reserve == expectedReserve,
            "service proposal keeps its own preparation state"
        );
    }
}
