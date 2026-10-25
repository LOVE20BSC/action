# Action 合约部署指南

Action 负责 `ActionTarget`、`LpExecutor`、`GroupActionExecutor`、`GroupServiceExecutor` 四类行动执行合约，依赖 `core`。部署前须先在目标网络按 `dex → core` 顺序完成被依赖方的部署与验收。

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy.sh        # 一键部署入口（纯编排，不载入任何环境文件）
│   ├── 11_deploy.sh               # 合约部署与初始化（自载入部署输入）
│   ├── 21_check.sh                # 部署与初始化正确性校验（自载入校验文件）
│   ├── 31_verify.sh               # 合约开源验证（自载入网络与地址文件）
│   ├── DeployAction.s.sol         # Foundry 部署脚本
│   └── README.md
└── network/
    └── anvil31337_dev/            # 本地 anvil · dev
        ├── .account               # 账户信息（敏感，已 gitignore）
        ├── network.params         # 网络参数
        ├── action.params          # 合约部署参数
        ├── addresses.core.params  # core 已部署地址（跨库依赖，从 core 复制）
        └── addresses.action.params # 本协议已部署地址（含 4 个链接库），部署成功后自动写入
```

## 部署前准备

### 1. 按依赖顺序部署被依赖方

Action 的 `init` 从 core 的 `Mint`（ActionTarget）与 `Stake`（三个 Executor）派生全部依赖：

```bash
# 1) dex（core 的依赖）：WETH / Factory / Router
cd dex && ./script/deploy/one_click_deploy.sh anvil31337_dev

# 2) core：8 个核心合约（写入 core/script/network/<net>/addresses.core.params）
cd core && ./script/deploy/one_click_deploy.sh anvil31337_dev
```

### 2. 复制 core 地址

把 `core/script/network/anvil31337_dev/addresses.core.params` 复制到 `action/script/network/anvil31337_dev/addresses.core.params`（当前文件已内含来源注释）。core 重新部署后只需重新复制该文件，不得在 action 配置里手工转抄单个地址。

### 3. 配置账户信息

创建 `script/network/<network>/.account`（此文件已被 .gitignore，且为必需文件）：

```bash
KEYSTORE_ACCOUNT=anvil_account
ACCOUNT_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
KEYSTORE_PASSWORD=anvil
```

本地链与公共网络统一走 keystore 签名，不提供 `--unlocked` 回退。`KEYSTORE_PASSWORD` 非空时部署全程无交互；留空或未配时由 macOS `osascript` 弹窗读取。`one_click_deploy.sh` 入口把密码**只解析一次**（先重置、再读 `.account`、最后才交互）并导出给全部部署步骤，多模块仓库不会重复弹窗；单独运行某个部署步骤时，该步骤按 环境变量 → `.account` → 交互 自行解析。**入口不接受通过环境变量传密码**：`KEYSTORE_PASSWORD=xxx ./script/deploy/one_click_deploy.sh <net>` 里的值会被入口重置掉（有意为之，避免上次运行的残留密码被静默复用），非交互场景请把密码写进 `.account` 的 `KEYSTORE_PASSWORD`。非 macOS 环境没有 `osascript`，必须填写该项，脚本会在缺失时明确报错。

密码不会出现在进程参数里：`11_deploy.sh` 把 `KEYSTORE_PASSWORD` 写入权限 600 的临时文件，用 `--password-file` 交给 forge，并在广播结束（或脚本退出）时删除。进程参数对本机所有用户可读，环境变量只对同一用户可读；而 `.account` 本身就是明文密码，同一用户已能直接读取，所以密码作为环境变量传递不增加泄露面。

### 4. 配置合约参数

编辑 `script/network/<network>/action.params`：

```bash
# GroupActionExecutor 初始化参数
# 奖励分层阈值（splits）：可为空数组（不分层）；非空时严格递增、每项大于 0 且小于 1e18。
GROUP_ACTION_SPLITS=1e17,4e17,7e17      # 10% / 40% / 70%
```

参数文件里的长整数可写成 `<尾数>e<指数>`（`1e17` 即 10%）或带下划线的分组写法（`1_000_000`），由 `script/deploy/params.sh` 在载入时展开为十进制再导出；展开是纯词法的、没有键表，写错的写法会留给 `vm.envUint` 在广播前报错。

`splits` 经 `11_deploy.sh` 以 `--sig "run(uint256[])"` 传入 `DeployAction.s.sol`；`DeployAction` 在广播前校验：空数组合法（不分层，仅投票第一名作为当轮唯一公共验证者），非空时每项 `0 < split < 1e18` 且严格递增；21_check 复核。splits 是部署期静态配置，由部署脚本校验、21_check 复核，合约不重复校验；`ActionTarget` 允许提案绑定任意 Executor，非本脚本部署的 Executor 由其提案方自担 splits 配置风险。其余合约无构造/init 数值参数：`ActionTarget.init` 只收 `Mint` 地址，三个 Executor 的 `memberNFT/phase/vote/launch/pairFactory` 均由 `Stake` 派生。

## 设计约定：自包含步骤

每个步骤脚本统一 `<step>.sh <network>` 一种调用形态，**自行加载自己需要的文件**，没有任何文件互相 source：

| 步骤 | 自行载入的输入 |
| --- | --- |
| `11_deploy.sh` | `network.params`、`addresses.core.params`、`action.params`、`.account`；读取本次广播生成的 `broadcast/DeployAction.s.sol/<chain-id>/run-latest.json`；写入 `addresses.action.params` |
| `21_check.sh` | `network.params`、`addresses.core.params`、`action.params`、`addresses.action.params`；通过 `forge inspect` 读取本地构建产物做逐字节比对 |
| `31_verify.sh` | `network.params`、`addresses.action.params` |

入口 `one_click_deploy.sh` 只做编排：备份地址 → 依次跑三步 → 校验失败回滚。新增合约/模块时新建 `one_click_deploy_<x>.sh` 与自己的步骤脚本、参数文件，对现有文件零改动——各模块的部署输入互不要求存在，不会因别的模块参数变动而失败。

`DeployAction.s.sol` 在广播前校验 `MINT_ADDRESS` 与 `STAKE_ADDRESS` 有代码，并交叉核对 Mint 派生的 `memberNFT/phase/vote/submit/launch`、Stake 派生的 `memberNFT/phase/vote/launch/pairFactory/router`、`Stake.launch == Mint.launch`、`Launch.pairFactory == Stake.pairFactory` 以及 Vote/Submit 的绑定；缺失、地址无代码或 splits 非法在广播前即失败，不会白广播行动合约。`11_deploy.sh` 只做文件、链、账户与密码编排，不重复这些校验。部署后 `_validateDeployment` 再核对四个合约的初始化与固定关系；`21_check.sh` 独立复核，并直接读取 Stake 的派生 getter。

## 部署流程

### 一键部署

```bash
cd action
./script/deploy/one_click_deploy.sh anvil31337_dev
```

该脚本依次调用下列单步骤脚本（各步骤只做自己那一步、互不调用、自行载入输入；单独执行见「分步部署」）：

1. `11_deploy.sh` —— 自载入部署输入并调用 forge 部署初始化 4 个合约，原子写入地址；Foundry 自动以 CREATE2 部署的 4 个链接库地址从本次 broadcast 产物提取、核对后一并写入
2. `21_check.sh` —— 自载入校验文件，校验部署与初始化结果
3. `31_verify.sh` —— 自载入地址文件，对 4 个合约与 4 个链接库做合约开源验证；链支持时执行（需 `ETHERSCAN_API_KEY`），链不支持时跳过

链 ID、core 依赖地址、初始化绑定任一不一致，部署入口返回失败，并回滚到上一次已保存的地址（校验失败不覆盖旧地址）。网络名必填，缺参直接报错。广播前校验全部在 `DeployAction.s.sol` 内完成。

### 分步部署

各步骤的输入文件各自明确（见「设计约定：自包含步骤」表），任一一步都可脱离入口单独执行：

```bash
# 部署与初始化
./script/deploy/11_deploy.sh anvil31337_dev

# 校验部署与初始化结果（自载入，可重复运行）
./script/deploy/21_check.sh anvil31337_dev

# 合约开源验证
./script/deploy/31_verify.sh anvil31337_dev
```

`21_check.sh` 缺失 `addresses.action.params` 时提示先跑一键部署，不会静默通过。

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
export ETHERSCAN_API_KEY=your-api-key
./script/deploy/31_verify.sh anvil31337_dev
```

四个合约均无构造函数参数（依赖经 `init` 绑定），四个链接库同样没有构造参数，全部直接提交验证。`GroupActionExecutor` 与 `GroupServiceExecutor` 的运行时字节码内嵌链接库地址，验证时按 `addresses.action.params` 里的库地址传 `--libraries`；不传会让 standard-json 的 `settings.libraries` 为空，链上字节码无法匹配。链接库本身也逐一提交验证。使用 Etherscan V2 API Key；缺少 Key 或任何一份合约/库验证失败均返回非零；链不支持开源验证时跳过并返回 0。API Key 只通过环境变量传入，不要写进 `network.params`。

## 部署输出

部署成功后，合约地址自动写入 `script/network/<network>/addresses.action.params`：

```bash
ACTION_TARGET_ADDRESS=0x...
LP_EXECUTOR_ADDRESS=0x...
GROUP_ACTION_EXECUTOR_ADDRESS=0x...
GROUP_SERVICE_EXECUTOR_ADDRESS=0x...
GROUP_ACTION_JOIN_LIBRARY_ADDRESS=0x...
GROUP_ACTION_MANAGER_LIBRARY_ADDRESS=0x...
GROUP_ACTION_VERIFY_LIBRARY_ADDRESS=0x...
GROUP_RECIPIENTS_LIBRARY_ADDRESS=0x...
```

后 4 项是 `GroupActionExecutor` / `GroupServiceExecutor` 通过 `delegatecall` 调用的外部库，由 Foundry 在广播阶段自动以 CREATE2 部署。它们不在部署日志中，`11_deploy.sh` 从本次运行写出的 `broadcast/DeployAction.s.sol/<chain-id>/run-latest.json` 的 `libraries` 字段提取；产物须由本次运行生成，且回填的 Executor 地址须与部署日志一致，缺项、过期或不一致时不写地址文件。这些校验都在广播之后：此时合约已经上链，脚本会保留部署日志并打印日志与 broadcast 产物路径，便于人工恢复地址记录。

`DeployAction.s.sol` 的部署与初始化顺序：`ActionTarget`（从 Mint 派生）→ `LpExecutor` / `GroupActionExecutor`（从 Stake 派生）→ `GroupServiceExecutor`（依赖前两者地址）。

## 校验内容（21_check.sh）

只读链上状态（`forge inspect` 会在本地编译并刷新 `out`/`cache`，不写地址文件），可重复运行：

- 4 个合约均已部署（`cast code` 非空）、运行时代码与构建产物逐字节一致，且 `initialized() == true`
- `ActionTarget` 的 `mintAddress / voteAddress / submitAddress / memberNFTAddress / phaseAddress` 与 core 地址一致
- 三个 Executor 的 `actionTarget()` 指向本次部署的 `ActionTarget`；`GroupServiceExecutor.groupActionExecutorAddress()` 指向本次部署的 `GroupActionExecutor`
- `GroupActionExecutor.SPLITS()` 与 `action.params` 配置一致，并复核每项 `0 < split < 1e18` 且严格递增（cast 对大整数的 `[1e17]` 科学计数法标注已归一化）
- 4 个链接库地址均已入账、链上有代码，且运行时字节码与构建产物一致（库的 runtime 内嵌自身地址，比对时按入账地址替换该处）；两个 Executor 的比对按入账地址传 `--libraries`（地址文件键集合必须恰好是 4 个合约 + 4 个库）

部署后若修改过源码，`forge inspect` 会用当前产物比对，校验会失败——这是预期结果（链上代码与工作区源码不符），不是部署缺陷。

Executor 对 `Stake` 的派生依赖没有独立 getter；部署前由 `DeployAction` 用 `Stake` 的 getter 与 Mint 的派生图交叉核对，部署后由 21_check 直接读取 `Stake` 的 `memberNFT/phase/vote/launch/pairFactory/router` 并与 core 地址文件比对。`GroupServiceExecutor -> GroupActionExecutor` 的绑定通过 getter 由 21_check 复核。core 侧重建后重新部署 action 即可刷新绑定。

## 安全注意事项

1. **敏感文件**: `.account` 已被 `.gitignore`，内含 Keystore 名称、账户地址与可选密码，绝不提交到仓库
2. **凭据传递**: 密码经权限 600 的临时文件传给 forge（`--password-file`），不进进程参数——进程参数对本机所有用户可读；作为环境变量传递只对同一用户可见，与 `.account` 明文同级
3. **私钥管理**: 生产环境建议使用硬件钱包或 Keystore
4. **参数检查**: 部署前仔细检查 `action.params`，特别是 `GROUP_ACTION_SPLITS`
5. **测试先行**: 生产部署前先在测试网完整测试流程

## 本地回归

```bash
git submodule update --init --recursive
forge build
forge test
./script/deploy/one_click_deploy.sh anvil31337_dev
```

按依赖顺序先跑 `dex`、`core` 的一键部署，再跑本仓入口脚本，确认校验步骤全部通过、工作区无残留改动。
