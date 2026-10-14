// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ActionTarget} from "../../src/ActionTarget.sol";
import {LpExecutor} from "../../src/LpExecutor.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";

contract DeployAction is Script {
    struct DeploymentAddresses {
        address actionTarget;
        address lpExecutor;
        address groupActionExecutor;
        address groupServiceExecutor;
    }

    function run(uint256[] memory groupActionSplits) external returns (DeploymentAddresses memory addrs) {
        require(block.chainid == vm.envUint("CHAIN_ID"), "Chain ID mismatch");

        // Core 依赖必须是已部署合约：ActionTarget 从 Mint 派生 vote/submit/memberNFT/phase，
        // 三个 Executor 从 Stake 派生 memberNFT/phase/vote/launch/pairFactory，
        // 地址配错时模拟阶段不会回滚，会白广播 4 个合约（要到 99_check.sh 才拦下）。
        address mint = vm.envAddress("MINT_ADDRESS");
        address stake = vm.envAddress("STAKE_ADDRESS");
        require(mint.code.length != 0, "Mint must be a deployed contract");
        require(stake.code.length != 0, "Stake must be a deployed contract");

        vm.startBroadcast();

        addrs = _deployContracts(groupActionSplits);

        vm.stopBroadcast();

        _logDeploymentSummary(addrs);
    }

    function _deployContracts(uint256[] memory groupActionSplits)
        private
        returns (DeploymentAddresses memory addrs)
    {
        addrs.actionTarget = address(new ActionTarget());
        console2.log("ActionTarget deployed at:", addrs.actionTarget);
        ActionTarget(addrs.actionTarget).init(vm.envAddress("MINT_ADDRESS"));
        console2.log("ActionTarget initialized");

        addrs.lpExecutor = address(new LpExecutor());
        console2.log("LpExecutor deployed at:", addrs.lpExecutor);
        LpExecutor(addrs.lpExecutor).init(addrs.actionTarget, vm.envAddress("STAKE_ADDRESS"));
        console2.log("LpExecutor initialized");

        addrs.groupActionExecutor = address(new GroupActionExecutor());
        console2.log("GroupActionExecutor deployed at:", addrs.groupActionExecutor);
        GroupActionExecutor(addrs.groupActionExecutor).init(
            addrs.actionTarget,
            vm.envAddress("STAKE_ADDRESS"),
            groupActionSplits
        );
        console2.log("GroupActionExecutor initialized");

        addrs.groupServiceExecutor = address(new GroupServiceExecutor());
        console2.log("GroupServiceExecutor deployed at:", addrs.groupServiceExecutor);
        GroupServiceExecutor(addrs.groupServiceExecutor).init(
            addrs.actionTarget,
            vm.envAddress("STAKE_ADDRESS"),
            addrs.groupActionExecutor
        );
        console2.log("GroupServiceExecutor initialized");
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("ACTIONTARGET_ADDRESS=", addrs.actionTarget);
        console2.log("LPEXECUTOR_ADDRESS=", addrs.lpExecutor);
        console2.log("GROUPACTIONEXECUTOR_ADDRESS=", addrs.groupActionExecutor);
        console2.log("GROUPSERVICEEXECUTOR_ADDRESS=", addrs.groupServiceExecutor);
    }
}
