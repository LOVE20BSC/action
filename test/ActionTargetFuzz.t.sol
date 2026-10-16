// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IActionTargetErrors} from "../src/interfaces/IActionTarget.sol";
import {IMintErrors} from "core/src/interfaces/IMint.sol";
import {MockExecutor} from "./mocks/ActionTargetMocks.sol";
import {ActionTargetTestBase} from "./ActionTargetTestBase.sol";

contract ActionTargetFuzzTest is ActionTargetTestBase {
    mapping(uint256 => mapping(uint256 => bool)) internal _joined;

    function testFuzzActionIdsByMemberIdWindows(uint256 offset, uint256 limit, bool reverse) external {
        uint256[] memory model = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            model[i] = 11 + i;
            _createAction(model[i]);
        }
        phase.setPhase(2);
        for (uint256 i = 0; i < 5; i++) {
            _join(model[i], 1);
        }

        (uint256[] memory page, uint256 total) =
            actionTarget.actionIdsByMemberId(address(token), 1, offset, limit, reverse);
        (uint256[] memory expected, uint256 expectedTotal) = _expectedPage(model, offset, limit, reverse);
        require(total == expectedTotal, "total");
        _requireSamePage(page, expected);
    }

    function testFuzzMemberIdsByActionIdWindows(uint256 offset, uint256 limit, bool reverse) external {
        _createAction(11);
        phase.setPhase(2);
        uint256[] memory model = new uint256[](3);
        model[0] = 1;
        model[1] = 2;
        model[2] = 3;
        for (uint256 i = 0; i < 3; i++) {
            _join(11, model[i]);
        }

        (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(token), 11, 1, offset, limit, reverse);
        (uint256[] memory expected, uint256 expectedTotal) = _expectedPage(model, offset, limit, reverse);
        require(total == expectedTotal, "total");
        _requireSamePage(page, expected);
    }

    function testFuzzJoinClearSequence(uint256 seed) external {
        uint256[4] memory actionIds;
        for (uint256 i = 0; i < 4; i++) {
            actionIds[i] = 11 + i;
            _createAction(actionIds[i]);
        }
        phase.setPhase(2);

        for (uint256 i = 0; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 memberId = (seed % 3) + 1;
            uint256 actionId = actionIds[seed >> 8 & 3];
            if (_joined[memberId][actionId]) {
                _clear(actionId, memberId);
            } else {
                _join(actionId, memberId);
            }
            _joined[memberId][actionId] = !_joined[memberId][actionId];
        }

        for (uint256 memberId = 1; memberId <= 3; memberId++) {
            (uint256[] memory page, uint256 total) =
                actionTarget.actionIdsByMemberId(address(token), memberId, 0, 10, false);
            uint256 expectedTotal;
            for (uint256 i = 0; i < 4; i++) {
                if (_joined[memberId][actionIds[i]]) expectedTotal++;
            }
            require(total == expectedTotal, "member total");
            require(page.length == total, "page length");
            for (uint256 i = 0; i < page.length; i++) {
                require(_joined[memberId][page[i]], "page member of model");
            }
            for (uint256 i = 0; i < 4; i++) {
                require(
                    actionTarget.isJoined(address(token), actionIds[i], memberId) == _joined[memberId][actionIds[i]],
                    "isJoined matches model"
                );
            }
        }
        for (uint256 i = 0; i < 4; i++) {
            (uint256[] memory page, uint256 total) = actionTarget.memberIdsByActionId(address(token), actionIds[i], 1, 0, 10, false);
            uint256 expectedTotal;
            for (uint256 memberId = 1; memberId <= 3; memberId++) {
                if (_joined[memberId][actionIds[i]]) expectedTotal++;
            }
            require(total == expectedTotal, "action total");
            for (uint256 j = 0; j < page.length; j++) {
                require(_joined[page[j]][actionIds[i]], "page member of action model");
            }
        }
    }

    function testFuzzJoinRoundBoundary(uint256 createdSeed, uint256 phaseSeed) external {
        uint256 created = createdSeed % 21;
        uint256 atPhase = phaseSeed % 26;
        phase.setPhase(created);
        _createAction(11);
        phase.setPhase(atPhase);

        if (atPhase <= created) {
            vm.prank(address(executor));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IActionTargetErrors.JoinNotOpen.selector, address(token), 11, atPhase, created
                )
            );
            actionTarget.registerJoinState(address(token), 11, 1);
        } else {
            _join(11, 1);
            uint256 joinRound = atPhase - 1;
            require(actionTarget.isJoinedByRound(address(token), 11, 1, joinRound), "snapshot at join round");
            if (joinRound > 0) {
                require(
                    actionTarget.isJoinedByRound(address(token), 11, 1, joinRound - 1) == false,
                    "no snapshot before join round"
                );
            }
        }
    }

    function testFuzzCreateForwardsBusinessItems(uint8 itemCount, bytes32 payload) external {
        uint256 count = uint256(itemCount) % 4;
        bytes[] memory targetData = new bytes[](count + 1);
        targetData[0] = abi.encode(address(executor));
        for (uint256 i = 0; i < count; i++) {
            targetData[i + 1] = abi.encode(payload, i);
        }
        vm.prank(submitAddress);
        actionTarget.onProposalCreated(address(token), 11, targetData);
        require(executor.lastCreatedTargetDataHash() == keccak256(abi.encode(targetData)), "forwarded verbatim");
    }

    function testFuzzMintRoundIndependence(uint256 roundA, uint256 roundB) external {
        vm.assume(roundA != roundB);
        _createAction(11);
        vote.setProposalVoted(address(token), roundA, 11, true);
        vote.setProposalVoted(address(token), roundB, 11, true);

        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, roundA);
        vm.prank(address(executor));
        actionTarget.mintActionReward(address(token), 11, roundB);

        (uint256 amountA, bool mintedA) = actionTarget.actionReward(address(token), 11, roundA);
        (uint256 amountB, bool mintedB) = actionTarget.actionReward(address(token), 11, roundB);
        require(amountA == MINT_AMOUNT && mintedA, "round A minted");
        require(amountB == MINT_AMOUNT && mintedB, "round B minted");

        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        actionTarget.mintActionReward(address(token), 11, roundA);
    }

    function testFuzzVotedActionsFiltering(uint256 idA, uint256 idB, uint256 idC) external {
        MockExecutor second = new MockExecutor(address(actionTarget));
        _createAction(1, second);
        _createAction(2);
        _createAction(3);

        uint256[] memory votedIds = new uint256[](3);
        votedIds[0] = idA % 5;
        votedIds[1] = idB % 5;
        votedIds[2] = idC % 5;
        vm.assume(votedIds[0] != votedIds[1] && votedIds[0] != votedIds[2] && votedIds[1] != votedIds[2]);
        vote.setVotedProposalIds(address(token), 3, votedIds);

        (uint256[] memory page,, uint256 total) = actionTarget.votedActions(address(token), 3, 0, 10, false);
        uint256 expectedTotal;
        for (uint256 i = 0; i < votedIds.length; i++) {
            if (votedIds[i] >= 1 && votedIds[i] <= 3) expectedTotal++;
        }
        require(total == expectedTotal && page.length == expectedTotal, "filtered total");
        uint256 expectedIndex;
        for (uint256 i = 0; i < votedIds.length; i++) {
            if (votedIds[i] >= 1 && votedIds[i] <= 3) {
                require(page[expectedIndex] == votedIds[i], "order preserved");
                expectedIndex++;
            }
        }
    }

    function _expectedPage(uint256[] memory items, uint256 offset, uint256 limit, bool reverse)
        internal
        pure
        returns (uint256[] memory page, uint256 total)
    {
        total = items.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;
        page = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = reverse ? items[total - 1 - offset - i] : items[offset + i];
        }
    }

    function _requireSamePage(uint256[] memory page, uint256[] memory expected) internal pure {
        require(page.length == expected.length, "page length");
        for (uint256 i = 0; i < page.length; i++) {
            require(page[i] == expected[i], "page item");
        }
    }
}
