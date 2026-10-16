// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LpExecutor} from "../src/LpExecutor.sol";
import {MockERC20, MockLpActionTarget, MockLpPhase} from "./mocks/LpExecutorMocks.sol";
import {LpExecutorTestBase, LpExecutorVm} from "./LpExecutorTestBase.sol";

contract LpExecutorHandler {
    LpExecutorVm internal constant vm = LpExecutorVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ACTION_ID = 11;
    uint256 internal constant JOIN_PHASE = 3;
    uint256 internal constant PHASE_BLOCKS = 1000;
    uint256 internal constant PROPOSAL_REWARD = 1000e18;

    address public lpExecutor;
    address public phaseContract;
    address public actionTarget;
    address public token;
    address public joinToken;
    address public member1;
    address public member2;

    mapping(uint256 => uint256) public balanceModel;
    mapping(uint256 => uint256) public deductionModel;
    mapping(uint256 => bool) public mintedModel;
    mapping(uint256 => uint256) public mintedAmountModel;
    mapping(uint256 => uint256) public burnedAmountModel;

    uint256 public totalJoinedModel;
    uint256 public totalDeductionModel;
    uint256 public mintedSumModel;
    uint256 public burnedSumModel;
    bool public mintPhase;

    constructor(
        address lpExecutor_,
        address phase_,
        address actionTarget_,
        address token_,
        address joinToken_,
        address member1_,
        address member2_
    ) {
        lpExecutor = lpExecutor_;
        phaseContract = phase_;
        actionTarget = actionTarget_;
        token = token_;
        joinToken = joinToken_;
        member1 = member1_;
        member2 = member2_;
    }

    function join(uint256 seed) external {
        if (mintPhase) return;
        uint256 memberId = seed % 2 + 1;
        uint256 amount = (seed >> 8) % 1e24 + 1;
        _rollToJoinPhase(seed >> 16);

        vm.prank(_memberAddress(memberId));
        LpExecutor(lpExecutor).join(token, ACTION_ID, memberId, amount);

        uint256 elapsed = block.number - JOIN_PHASE * PHASE_BLOCKS;
        uint256 added = amount * elapsed / PHASE_BLOCKS;
        if (added > amount) added = amount;
        balanceModel[memberId] += amount;
        deductionModel[memberId] += added;
        totalJoinedModel += amount;
        totalDeductionModel += added;
    }

    function withdraw(uint256 seed) external {
        if (mintPhase) return;
        uint256 memberId = seed % 2 + 1;
        uint256 balance = balanceModel[memberId];
        if (balance == 0) return;
        uint256 amount = (seed >> 8) % balance + 1;
        _rollToJoinPhase(seed >> 16);

        vm.prank(_memberAddress(memberId));
        LpExecutor(lpExecutor).withdraw(token, ACTION_ID, memberId, amount);

        if (amount == balance) {
            totalDeductionModel -= deductionModel[memberId];
            deductionModel[memberId] = 0;
            totalJoinedModel -= balance;
            balanceModel[memberId] = 0;
        } else {
            uint256 reduction = deductionModel[memberId] * amount / balance;
            deductionModel[memberId] -= reduction;
            totalDeductionModel -= reduction;
            totalJoinedModel -= amount;
            balanceModel[memberId] -= amount;
        }
    }

    function exit(uint256 seed) external {
        if (mintPhase) return;
        uint256 memberId = seed % 2 + 1;
        uint256 balance = balanceModel[memberId];
        if (balance == 0) return;
        _rollToJoinPhase(seed >> 16);

        vm.prank(_memberAddress(memberId));
        LpExecutor(lpExecutor).exit(token, ACTION_ID, memberId);

        totalDeductionModel -= deductionModel[memberId];
        deductionModel[memberId] = 0;
        totalJoinedModel -= balance;
        balanceModel[memberId] = 0;
    }

    function advanceToMintPhase() external {
        if (mintPhase) return;
        mintPhase = true;
        MockLpPhase(phaseContract).setCurrentPhase(JOIN_PHASE + 1);
        vm.roll((JOIN_PHASE + 1) * PHASE_BLOCKS);
        MockLpActionTarget(actionTarget).setActionReward(token, ACTION_ID, 2, PROPOSAL_REWARD, true);
        MockERC20(token).mint(lpExecutor, PROPOSAL_REWARD);
    }

    function mint(uint256 seed) external {
        if (!mintPhase) return;
        uint256 memberId = seed % 2 + 1;
        if (mintedModel[memberId]) return;

        // Zero settlement reverts NoRewardAvailable; skip members with nothing to settle.
        uint256 memberEffective = balanceModel[memberId] - deductionModel[memberId];
        uint256 totalEffective = totalJoinedModel - totalDeductionModel;
        if (memberEffective == 0 || totalEffective == 0) return;
        uint256 effectiveLpRatio = memberEffective * 1e18 / totalEffective;
        if (PROPOSAL_REWARD * effectiveLpRatio / 1e18 == 0) return;

        vm.prank(_memberAddress(memberId));
        (uint256 mintAmount, uint256 burnAmount) =
            LpExecutor(lpExecutor).mintMemberReward(token, ACTION_ID, memberId, 2);
        mintedModel[memberId] = true;
        mintedAmountModel[memberId] = mintAmount;
        burnedAmountModel[memberId] = burnAmount;
        mintedSumModel += mintAmount;
        burnedSumModel += burnAmount;
    }

    function _memberAddress(uint256 memberId) internal view returns (address) {
        return memberId == 1 ? member1 : member2;
    }

    function _rollToJoinPhase(uint256 seed) internal {
        MockLpPhase(phaseContract).setCurrentPhase(JOIN_PHASE);
        vm.roll(JOIN_PHASE * PHASE_BLOCKS + (seed % PHASE_BLOCKS));
    }
}

contract LpExecutorInvariantTest is LpExecutorTestBase {
    LpExecutorHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LpExecutorHandler(
            address(lpExecutor),
            address(phase),
            address(actionTarget),
            address(token),
            address(joinToken),
            MEMBER1,
            MEMBER2
        );
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_LedgersMatchModel() public view {
        require(
            lpExecutor.joinedAmount(address(token), ACTION_ID, 2) == handler.totalJoinedModel(),
            "total joined matches model"
        );
        require(
            lpExecutor.totalDeduction(address(token), ACTION_ID, 2) == handler.totalDeductionModel(),
            "total deduction matches model"
        );
        for (uint256 memberId = 1; memberId <= 2; memberId++) {
            require(
                lpExecutor.joinedAmountByMemberId(address(token), ACTION_ID, 2, memberId)
                    == handler.balanceModel(memberId),
                "member balance matches model"
            );
            (uint256 deduction,,) = lpExecutor.deduction(address(token), ACTION_ID, 2, memberId);
            require(deduction == handler.deductionModel(memberId), "member deduction matches model");
        }
    }

    function invariant_DeductionNeverExceedsBalance() public view {
        require(
            lpExecutor.totalDeduction(address(token), ACTION_ID, 2)
                <= lpExecutor.joinedAmount(address(token), ACTION_ID, 2),
            "contract deduction bound"
        );
        for (uint256 memberId = 1; memberId <= 2; memberId++) {
            require(handler.deductionModel(memberId) <= handler.balanceModel(memberId), "model deduction bound");
        }
    }

    function invariant_MintRecordsMatchModel() public view {
        for (uint256 memberId = 1; memberId <= 2; memberId++) {
            (uint256 mintAmount, uint256 burnAmount, bool minted) =
                lpExecutor.memberReward(address(token), ACTION_ID, memberId, 2);
            if (handler.mintedModel(memberId)) {
                require(minted, "minted flag matches model");
                require(
                    mintAmount == handler.mintedAmountModel(memberId)
                        && burnAmount == handler.burnedAmountModel(memberId),
                    "recorded amounts match model"
                );
            } else if (!handler.mintPhase()) {
                require(minted == false, "not minted before the mint phase");
            }
        }
    }

    function invariant_MintWithinBudget() public view {
        require(handler.mintedSumModel() + handler.burnedSumModel() <= 1000e18, "mint and burn within budget");
    }
}
