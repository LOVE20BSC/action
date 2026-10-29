// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {GroupActionExecutor} from "../src/GroupActionExecutor.sol";
import {GroupConfig} from "../src/interfaces/IGroupActionManager.sol";
import {MockGroupActionToken} from "./mocks/GroupActionExecutorMocks.sol";
import {MockGroupActionPhase} from "./mocks/GroupActionMocks.sol";
import {GroupActionExecutorTestBase, GroupActionExecutorVm} from "./GroupActionExecutorTestBase.sol";

contract GroupActionHandler {
    GroupActionExecutorVm internal constant vm =
        GroupActionExecutorVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ACTION_ID = 21;
    uint256 internal constant GROUP_ID = 5;
    uint256 internal constant MEMBER2_ID = 2;
    uint256 internal constant PROVIDER_ID = 4;
    uint256 internal constant PHASE_BLOCKS = 1000;
    uint256 internal constant ACTIVATION_STAKE = 100e18;

    address public executor;
    address public token;
    address public joinToken;
    address public member1;
    address public member2;
    address public provider;

    mapping(uint256 => uint256) public ownModel;
    mapping(uint256 => uint256) public providerModel;
    uint256 public quotaModel;
    uint256 public grantModel;

    constructor(
        address executor_,
        address phase_,
        address token_,
        address joinToken_,
        address groupOwner_,
        address member1_,
        address member2_,
        address provider_
    ) {
        executor = executor_;
        token = token_;
        joinToken = joinToken_;
        member1 = member1_;
        member2 = member2_;
        provider = provider_;

        MockGroupActionPhase(phase_).setCurrentPhase(3);
        vm.roll(3 * PHASE_BLOCKS);
        MockGroupActionToken(token_).mint(groupOwner_, ACTIVATION_STAKE);
        vm.prank(groupOwner_);
        MockGroupActionToken(token_).approve(executor_, type(uint256).max);
        vm.prank(groupOwner_);
        GroupActionExecutor(executor_).activateGroup(
            token_,
            ACTION_ID,
            GROUP_ID,
            GroupConfig({description: "g", maxCapacity: 0, minJoinAmount: 1e18, maxJoinAmount: 0, maxAccounts: 0})
        );

        _fund(member1_, 1e26);
        _fund(member2_, 1e26);
        _fund(provider_, 1e26);
    }

    function joinOwn(uint256 seed) external {
        uint256 memberId = seed % 2 + 1;
        uint256 amount = ((seed >> 8) % 1e22) + 1e18;
        address actor = memberId == 1 ? member1 : member2;
        vm.prank(actor);
        try
            GroupActionExecutor(executor).join(token, ACTION_ID, GROUP_ID, memberId, amount, 0, new string[](0))
        {
            ownModel[memberId] += amount;
        } catch {}
    }

    function joinWithProvider(uint256 seed) external {
        if (quotaModel == 0) return;
        uint256 amount = (seed % quotaModel) + 1;
        vm.prank(member2);
        try
            GroupActionExecutor(executor).join(
                token, ACTION_ID, GROUP_ID, MEMBER2_ID, amount, PROVIDER_ID, new string[](0)
            )
        {
            providerModel[MEMBER2_ID] += amount;
            quotaModel -= amount;
        } catch {}
    }

    function grantQuota(uint256 seed) external {
        uint256 amount = (seed % 1e22) + 1;
        uint256[] memory memberIds = new uint256[](1);
        memberIds[0] = MEMBER2_ID;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(provider);
        try
            GroupActionExecutor(executor).providerQuotaAdd(
                token, ACTION_ID, GROUP_ID, PROVIDER_ID, memberIds, amounts
            )
        {
            quotaModel += amount;
            grantModel += amount;
        } catch {}
    }

    function removeQuota() external {
        if (grantModel == 0) return;
        uint256[] memory memberIds = new uint256[](1);
        memberIds[0] = MEMBER2_ID;
        vm.prank(provider);
        GroupActionExecutor(executor).providerQuotaRemove(token, ACTION_ID, GROUP_ID, PROVIDER_ID, memberIds);
        quotaModel = 0;
        grantModel = 0;
        providerModel[MEMBER2_ID] = 0;
    }

    function withdrawOwn(uint256 seed) external {
        uint256 memberId = seed % 2 + 1;
        uint256 balance = ownModel[memberId];
        if (balance == 0) return;
        uint256 amount = (seed % balance) + 1;
        address actor = memberId == 1 ? member1 : member2;
        vm.prank(actor);
        GroupActionExecutor(executor).withdraw(token, ACTION_ID, memberId, amount);
        ownModel[memberId] -= amount;
    }

    function exitAll(uint256 seed) external {
        uint256 memberId = seed % 2 + 1;
        if (ownModel[memberId] + providerModel[memberId] == 0) return;
        address actor = memberId == 1 ? member1 : member2;
        vm.prank(actor);
        GroupActionExecutor(executor).exit(token, ACTION_ID, memberId);
        if (memberId == MEMBER2_ID) {
            quotaModel += providerModel[memberId];
            providerModel[memberId] = 0;
        }
        ownModel[memberId] = 0;
    }

    function providerQuotaWithdraw(uint256 seed) external {
        if (quotaModel == 0) return;
        uint256 amount = (seed % quotaModel) + 1;
        vm.prank(provider);
        GroupActionExecutor(executor).providerQuotaWithdraw(token, ACTION_ID, GROUP_ID, MEMBER2_ID, PROVIDER_ID, amount);
        quotaModel -= amount;
        grantModel -= amount;
    }

    function _fund(address account, uint256 amount) internal {
        MockGroupActionToken(joinToken).mint(account, amount);
        vm.prank(account);
        MockGroupActionToken(joinToken).approve(executor, type(uint256).max);
    }
}

contract GroupActionInvariantTest is GroupActionExecutorTestBase {
    GroupActionHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GroupActionHandler(
            address(executor),
            address(phase),
            address(token),
            address(joinToken),
            GROUP_OWNER,
            MEMBER1,
            MEMBER2,
            PROVIDER
        );
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_JoinLedgersMatchModel() public view {
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER1_ID) == handler.ownModel(MEMBER1_ID),
            "member 1 amount matches model"
        );
        require(
            executor.joinedAmountByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID)
                == handler.ownModel(MEMBER2_ID) + handler.providerModel(MEMBER2_ID),
            "member 2 amount matches model"
        );
        require(
            executor.totalJoinedAmountByGroupId(address(token), ACTION_ID, 2, GROUP_ID)
                == handler.ownModel(MEMBER1_ID) + handler.ownModel(MEMBER2_ID) + handler.providerModel(MEMBER2_ID),
            "group total matches model"
        );
    }

    function invariant_ExecutorBalanceConserved() public view {
        require(
            joinToken.balanceOf(address(executor))
                == handler.ownModel(MEMBER1_ID) + handler.ownModel(MEMBER2_ID) + handler.providerModel(MEMBER2_ID)
                    + handler.quotaModel(),
            "balance equals deposits minus refunds"
        );
    }

    function invariant_MembershipMirrorsModel() public view {
        for (uint256 memberId = MEMBER1_ID; memberId <= MEMBER2_ID; memberId++) {
            bool expected = handler.ownModel(memberId) + handler.providerModel(memberId) > 0;
            require(executor.isGroupMember(GROUP_ID, memberId) == expected, "membership mirrors model");
        }
    }

    function invariant_ProviderLedgerMatchesModel() public view {
        (uint256[] memory providerIds, uint256[] memory amounts, uint256 total) =
            executor.providerAmountsByMemberId(address(token), ACTION_ID, 2, MEMBER2_ID, 0, 10, false);
        uint256 invested = handler.providerModel(MEMBER2_ID);
        if (invested == 0) {
            require(total == 0, "no provider entries when uninvested");
        } else {
            require(total == 1 && providerIds[0] == PROVIDER_ID && amounts[0] == invested, "ledger matches model");
        }
    }

    function invariant_ProviderGrantMatchesModel() public view {
        (uint256[] memory memberIds, uint256[] memory quotaAmounts, uint256[] memory usedAmounts, uint256 total) =
            executor.providerQuotas(address(token), ACTION_ID, GROUP_ID, PROVIDER_ID, 0, 10, false);
        uint256 grant = handler.grantModel();
        if (grant == 0) {
            require(total == 0, "no grant entries when ungranted");
        } else {
            require(total == 1 && memberIds[0] == MEMBER2_ID, "grant listed");
            require(quotaAmounts[0] == grant, "grant matches model");
            require(usedAmounts[0] == handler.providerModel(MEMBER2_ID), "used matches model");
        }
    }
}
