# Action 合约部署指南

Action 负责 `ActionTarget`、`LpExecutor`、`GroupActionExecutor`、`GroupServiceExecutor` 四类行动执行合约，依赖 `core`。部署前须先在目标网络按 `dex → core` 顺序完成被依赖方的部署与验收。

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy.sh        # 一键部署入口（编排下列步骤）
│   ├── 00_init.sh                 # 部署环境初始化（只载入部署所需文件）
│   ├── 01_deploy.sh               # 合约部署与初始化
│   ├── 99_check.sh                # 部署与初始化正确性校验（自载入校验文件）
│   ├── verify.sh                  # 合约开源验证
│   ├── DeployAction.s.sol         # Foundry 部署脚本
│   └── README.md
└── network/
    └── anvil31337_dev/            # 本地 anvil · dev
        ├── .account               # 账户信息（敏感，已 gitignore）
        ├── network.params         # 网络参数
        ├── action.params          # 合约部署参数
        ├── addresses.core.params  # core 已部署地址（跨库依赖，从 core 复制）
        └── addresses.action.params # 本协议已部署地址，部署成功后自动写入
```

## 部署前准备

### 1. 按依赖顺序部署被依赖方

Action 的 `init` 从 core 的 `Mint`（ActionTarget）与 `Stake`（三个 Executor）派生全部依赖：

```bash
# 1) dex（core 的依赖）：WBNB / Factory / Router
cd dex && ./script/deploy/one_click_deploy.sh anvil31337_dev

# 2) core：8 个核心合约（写入 core/script/network/<net>/addresses.core.params）
cd core && ./script/deploy/one_click_deploy.sh anvil31337_dev
```

### 2. 复制 core 地址

把 `core/script/network/anvil31337_dev/addresses.core.params` 复制到 `action/script/network/anvil31337_dev/addresses.core.params`（当前文件已内含来源注释）。core 重新部署后只需重新复制该文件，不得在 action 配置里手工转抄单个地址。

`00_init.sh` 会校验 `MINT_ADDRESS` 与 `STAKE_ADDRESS` 为已部署合约；缺失或地址无代码在广播前即失败，不会白广播行动合约。

### 3. 配置账户信息

创建 `script/network/<network>/.account`（此文件已被 .gitignore）：

```bash
KEYSTORE_ACCOUNT=anvil_account
ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
KEYSTORE_PASSWORD=anvil
```

公共网络通过 Keystore 签名；仅 `CHAIN_ID=31337` 的本地网络可省略 `KEYSTORE_ACCOUNT`、仅用 `ACCOUNT_ADDRESS` 配合节点解锁账户。`KEYSTORE_PASSWORD` 非空时部署全程无交互；留空则由 forge 在终端询问密码。

### 4. 配置合约参数

编辑 `script/network/<network>/action.params`：

```bash
# GroupActionExecutor 初始化参数
# 奖励分层阈值（splits）：严格递增、每项小于 1e18；留空表示不配置分层。
GROUP_ACTION_SPLITS=100000000000000000,400000000000000000,700000000000000000
```

`splits` 经 `01_deploy.sh` 以 `--sig "run(uint256[])"` 传入 `DeployAction.s.sol`；`GroupActionExecutor.init` 内部校验递增性与上界，不合规在模拟阶段即回滚。其余合约无构造/init 数值参数：`ActionTarget.init` 只收 `Mint` 地址，三个 Executor 的 `memberNFT/phase/vote/launch/pairFactory` 均由 `Stake` 派生。

## 部署流程

### 一键部署

```bash
cd action
./script/deploy/one_click_deploy.sh anvil31337_dev
```

该脚本依次调用下列单步骤脚本（各步骤只做自己那一步、互不调用；单独执行见「分步部署」）：

1. `00_init.sh` —— 加载并校验环境配置（链 ID、core 依赖地址已部署）
2. `01_deploy.sh` —— 部署并初始化 4 个合约，写入合约地址
3. `99_check.sh <network>` —— 自载入校验文件，校验部署与初始化结果
4. `verify.sh` —— 合约开源验证；链支持时执行（需 `ETHERSCAN_API_KEY`），链不支持时跳过

链 ID、core 依赖地址、初始化绑定任一不一致，部署入口返回失败，并回滚到上一次已保存的地址（校验失败不覆盖旧地址）。网络名必填，缺参直接报错。

### 分步部署

各步骤的输入文件各自明确：`00_init.sh` 只载入部署所需文件（`network.params`、`addresses.core.params`、`action.params`、`.account`）；`01_deploy.sh` / `verify.sh` 由调用方先载入环境后以子进程运行；`99_check.sh` 自行独立载入校验所需文件（含上次部署的 `addresses.action.params`），不依赖预载环境，可直接单独执行。

```bash
# 部署与初始化
bash -c 'source script/deploy/00_init.sh anvil31337_dev && bash script/deploy/01_deploy.sh'

# 校验部署与初始化结果（只读，自载入，可重复运行）
./script/deploy/99_check.sh anvil31337_dev

# 合约开源验证
bash -c 'source script/deploy/00_init.sh anvil31337_dev && bash script/deploy/verify.sh'
```

`99_check.sh` 缺失 `addresses.action.params` 时提示先跑一键部署，不会静默通过。

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
export ETHERSCAN_API_KEY=your-api-key
bash -c 'source script/deploy/00_init.sh bsc97_dev && bash script/deploy/verify.sh'
```

四个合约均无构造函数参数（依赖经 `init` 绑定），直接提交验证。使用 Etherscan V2 API Key；缺少 Key 或任何一份合约验证失败均返回非零；链不支持开源验证时跳过并返回 0。API Key 只通过环境变量传入，不要写进 `network.params`。

## 部署输出

部署成功后，合约地址自动写入 `script/network/<network>/addresses.action.params`：

```bash
ACTIONTARGET_ADDRESS=0x...
LPEXECUTOR_ADDRESS=0x...
GROUPACTIONEXECUTOR_ADDRESS=0x...
GROUPSERVICEEXECUTOR_ADDRESS=0x...
```

`DeployAction.s.sol` 的部署与初始化顺序：`ActionTarget`（从 Mint 派生）→ `LpExecutor` / `GroupActionExecutor`（从 Stake 派生）→ `GroupServiceExecutor`（依赖前两者地址）。

## 校验内容（99_check.sh）

只读链上状态，可重复运行：

- 4 个合约均已部署（`cast code` 非空）且 `initialized() == true`
- `ActionTarget` 的 `mintAddress / voteAddress / submitAddress / memberNFTAddress / phaseAddress` 与 core 地址一致
- 三个 Executor 的 `actionTarget()` 指向本次部署的 `ActionTarget`
- `GroupActionExecutor.SPLITS()` 与 `action.params` 配置一致（cast 对大整数的 `[1e17]` 科学计数法标注已归一化）

Executor 对 `Stake` 等派生依赖的绑定无独立 getter，由 `init` 的参数校验与 `initialized` 状态保证；core 侧重建后重新部署 action 即可刷新绑定。

## 安全注意事项

1. **敏感文件**: `.account` 已被 `.gitignore`，仅配置 Keystore 名称及账户地址，绝不提交到仓库
2. **私钥管理**: 生产环境建议使用硬件钱包或 Keystore
3. **参数检查**: 部署前仔细检查 `action.params`，特别是 `GROUP_ACTION_SPLITS`
4. **测试先行**: 生产部署前先在测试网完整测试流程

## 本地回归

```bash
git submodule update --init --recursive
forge build
forge test
./script/deploy/one_click_deploy.sh anvil31337_dev
```

按依赖顺序先跑 `dex`、`core` 的一键部署，再跑本仓入口脚本，确认校验步骤全部通过、工作区无残留改动。
