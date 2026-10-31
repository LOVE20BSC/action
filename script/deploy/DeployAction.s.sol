// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {ActionTarget} from "../../src/ActionTarget.sol";
import {LpExecutor} from "../../src/LpExecutor.sol";
import {GroupActionExecutor} from "../../src/GroupActionExecutor.sol";
import {GroupServiceExecutor} from "../../src/GroupServiceExecutor.sol";
import {GroupActionStorage} from "../../src/GroupActionStorage.sol";
import {IActionTarget} from "../../src/interfaces/IActionTarget.sol";
import {ILaunch} from "@core/interfaces/ILaunch.sol";
import {IMint} from "@core/interfaces/IMint.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {ISubmit} from "@core/interfaces/ISubmit.sol";
import {IVote} from "@core/interfaces/IVote.sol";

contract DeployAction is Script {
    struct DeploymentAddresses {
        address actionTarget;
        address lpExecutor;
        address groupActionExecutor;
        address groupServiceExecutor;
    }

    struct ActionConfig {
        uint256 chainId;
        address mint;
        address stake;
        uint256[] splits;
    }

    function run(uint256[] memory groupActionSplits) external returns (DeploymentAddresses memory addrs) {
        ActionConfig memory config = _loadConfig(groupActionSplits);
        _validateConfig(config);

        vm.startBroadcast();
        addrs = _deployContracts(config.mint, config.splits);
        vm.stopBroadcast();

        _validateDeployment(config.mint, config.stake, config.splits, addrs);
        _logDeploymentSummary(addrs);
    }

    function _loadConfig(uint256[] memory groupActionSplits) internal view returns (ActionConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.mint = vm.envAddress("MINT_ADDRESS");
        config.stake = vm.envAddress("STAKE_ADDRESS");
        config.splits = groupActionSplits;
    }

    function _validateConfig(ActionConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");

        // Core 依赖必须是已部署合约：ActionTarget 从 Mint 派生 vote/submit/memberNFT/phase，
        // 三个 Executor 只收 ActionTarget，Stake 经 ActionTarget.VOTE_ADDRESS() 反查后派生其余地址；
        // 地址配错时模拟阶段不会回滚，会白广播 4 个合约（要到 21_check.sh 才拦下）。
        require(config.mint.code.length != 0, "Mint must be a deployed contract");
        require(config.stake.code.length != 0, "Stake must be a deployed contract");

        IMint mint = IMint(config.mint);
        IStake stake = IStake(config.stake);
        address memberNFT = mint.MEMBER_NFT_ADDRESS();
        address phase = mint.PHASE_ADDRESS();
        address vote = mint.VOTE_ADDRESS();
        address submit = mint.SUBMIT_ADDRESS();
        require(memberNFT.code.length != 0, "Mint memberNFTAddress must be a deployed contract");
        require(phase.code.length != 0, "Mint phaseAddress must be a deployed contract");
        require(vote.code.length != 0, "Mint voteAddress must be a deployed contract");
        require(submit.code.length != 0, "Mint submitAddress must be a deployed contract");

        // Executor 的派生值不可回读，部署前用 Stake 的 getter 与 Mint 的派生图逐项对齐。
        require(stake.MEMBER_NFT_ADDRESS() == memberNFT, "Stake memberNFTAddress mismatch");
        require(stake.PHASE_ADDRESS() == phase, "Stake phaseAddress mismatch");
        require(stake.VOTE_ADDRESS() == vote, "Stake voteAddress mismatch");
        address launch = stake.LAUNCH_ADDRESS();
        require(launch.code.length != 0, "Stake launchAddress must be a deployed contract");
        require(launch == mint.LAUNCH_ADDRESS(), "Stake launchAddress mismatch");
        require(
            stake.PAIR_FACTORY_ADDRESS().code.length != 0, "Stake pairFactoryAddress must be a deployed contract"
        );
        require(
            ILaunch(launch).PAIR_FACTORY_ADDRESS() == stake.PAIR_FACTORY_ADDRESS(),
            "Stake pairFactoryAddress mismatch"
        );
        require(stake.ROUTER_ADDRESS().code.length != 0, "Stake routerAddress must be a deployed contract");

        require(IVote(vote).STAKE_ADDRESS() == config.stake, "Vote stakeAddress mismatch");
        require(IVote(vote).SUBMIT_ADDRESS() == submit, "Vote submitAddress mismatch");
        require(IVote(vote).MEMBER_NFT_ADDRESS() == memberNFT, "Vote memberNFTAddress mismatch");
        require(IVote(vote).PHASE_ADDRESS() == phase, "Vote phaseAddress mismatch");
        require(ISubmit(submit).STAKE_ADDRESS() == config.stake, "Submit stakeAddress mismatch");
        require(ISubmit(submit).MEMBER_NFT_ADDRESS() == memberNFT, "Submit memberNFTAddress mismatch");
        require(ISubmit(submit).PHASE_ADDRESS() == phase, "Submit phaseAddress mismatch");

        uint256 previous = 0;
        for (uint256 i = 0; i < config.splits.length; i++) {
            // forge-lint: disable-next-item(require-revert-in-loop)
            require(
                config.splits[i] != 0 && config.splits[i] < GroupActionStorage.PRECISION
                    && config.splits[i] > previous,
                "Invalid GroupAction splits"
            );
            previous = config.splits[i];
        }
    }

    function _deployContracts(address mint, uint256[] memory groupActionSplits)
        internal
        returns (DeploymentAddresses memory addrs)
    {
        addrs.actionTarget = address(new ActionTarget());
        console2.log("ActionTarget deployed at:", addrs.actionTarget);
        ActionTarget(addrs.actionTarget).init(mint);
        console2.log("ActionTarget initialized");

        addrs.lpExecutor = address(new LpExecutor(addrs.actionTarget));
        console2.log("LpExecutor deployed at:", addrs.lpExecutor);

        addrs.groupActionExecutor = address(new GroupActionExecutor(addrs.actionTarget, groupActionSplits));
        console2.log("GroupActionExecutor deployed at:", addrs.groupActionExecutor);

        addrs.groupServiceExecutor = address(new GroupServiceExecutor(addrs.groupActionExecutor));
        console2.log("GroupServiceExecutor deployed at:", addrs.groupServiceExecutor);
    }

    function _validateDeployment(
        address mintAddress,
        address stakeAddress,
        uint256[] memory expectedSplits,
        DeploymentAddresses memory addrs
    ) internal view {
        IMint mint = IMint(mintAddress);
        IActionTarget actionTarget = IActionTarget(addrs.actionTarget);
        require(actionTarget.initialized(), "ActionTarget not initialized");
        require(actionTarget.MINT_ADDRESS() == mintAddress, "ActionTarget mint mismatch");
        require(actionTarget.VOTE_ADDRESS() == mint.VOTE_ADDRESS(), "ActionTarget vote mismatch");
        require(actionTarget.SUBMIT_ADDRESS() == mint.SUBMIT_ADDRESS(), "ActionTarget submit mismatch");
        require(actionTarget.MEMBER_NFT_ADDRESS() == mint.MEMBER_NFT_ADDRESS(), "ActionTarget member NFT mismatch");
        require(actionTarget.PHASE_ADDRESS() == mint.PHASE_ADDRESS(), "ActionTarget phase mismatch");

        LpExecutor lpExecutor = LpExecutor(addrs.lpExecutor);
        require(lpExecutor.ACTION_TARGET_ADDRESS() == addrs.actionTarget, "LpExecutor action target mismatch");
        require(lpExecutor.STAKE_ADDRESS() == stakeAddress, "LpExecutor stake mismatch");
        require(lpExecutor.MEMBER_NFT_ADDRESS() == mint.MEMBER_NFT_ADDRESS(), "LpExecutor member NFT mismatch");
        require(lpExecutor.PHASE_ADDRESS() == mint.PHASE_ADDRESS(), "LpExecutor phase mismatch");

        GroupActionExecutor groupActionExecutor = GroupActionExecutor(addrs.groupActionExecutor);
        require(
            groupActionExecutor.ACTION_TARGET_ADDRESS() == addrs.actionTarget,
            "GroupActionExecutor action target mismatch"
        );
        require(groupActionExecutor.STAKE_ADDRESS() == stakeAddress, "GroupActionExecutor stake mismatch");
        require(
            groupActionExecutor.MEMBER_NFT_ADDRESS() == mint.MEMBER_NFT_ADDRESS(),
            "GroupActionExecutor member NFT mismatch"
        );
        require(groupActionExecutor.PHASE_ADDRESS() == mint.PHASE_ADDRESS(), "GroupActionExecutor phase mismatch");
        uint256[] memory splits = groupActionExecutor.SPLITS();
        require(splits.length == expectedSplits.length, "GroupActionExecutor splits length mismatch");
        for (uint256 i = 0; i < splits.length; i++) {
            // forge-lint: disable-next-item(require-revert-in-loop)
            require(splits[i] == expectedSplits[i], "GroupActionExecutor split mismatch");
        }

        GroupServiceExecutor groupServiceExecutor = GroupServiceExecutor(addrs.groupServiceExecutor);
        require(
            groupServiceExecutor.ACTION_TARGET_ADDRESS() == addrs.actionTarget,
            "GroupServiceExecutor action target mismatch"
        );
        require(groupServiceExecutor.STAKE_ADDRESS() == stakeAddress, "GroupServiceExecutor stake mismatch");
        require(
            groupServiceExecutor.MEMBER_NFT_ADDRESS() == mint.MEMBER_NFT_ADDRESS(),
            "GroupServiceExecutor member NFT mismatch"
        );
        require(
            groupServiceExecutor.GROUP_ACTION_EXECUTOR_ADDRESS() == addrs.groupActionExecutor,
            "GroupServiceExecutor binding mismatch"
        );
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("ACTION_TARGET_ADDRESS=", addrs.actionTarget);
        console2.log("LP_EXECUTOR_ADDRESS=", addrs.lpExecutor);
        console2.log("GROUP_ACTION_EXECUTOR_ADDRESS=", addrs.groupActionExecutor);
        console2.log("GROUP_SERVICE_EXECUTOR_ADDRESS=", addrs.groupServiceExecutor);
    }
}
