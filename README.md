# LOVE20BSC Action

Action 负责 `ActionTarget`、LP、GroupAction 和 GroupService 四类行动执行合约，依赖 `core`。

面向普通读者的说明见 [Action 白皮书](docs/DESIGN_WHITEPAPER.md)，涵盖行动运作、链群行动、链群服务和 LP 行动。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/extension`、`LOVE20TKM/extension-group`、`LOVE20TKM/extension-lp`（提交版本见 [repositories.md](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/repositories.md#旧代码基线)）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/core` | Core 接口声明的唯一来源与测试夹具用的 Core 实现；本仓的 `libs` 与 OpenZeppelin 从该子模块的嵌套依赖解析 |
| `lib/forge-std` | 测试与脚本 |

Core 的接口以 `core` 代码库为准：生产代码通过 `@core/` 别名（指向 `lib/core/src/`）导入，例如 `@core/interfaces/...`；标准能力（如 ERC721 的 `ownerOf`）由 core 侧接口继承提供，因此本仓不另存 Core 接口副本。`lib/core` 须与 `core` 的 `main` 同步；本仓不直接声明 `libs` 与 OpenZeppelin，二者经 `lib/core` 的嵌套依赖解析，路径见 `remappings.txt`；升级 `lib/core` 时必须同步其嵌套子模块与 `core` 的 `foundry.lock`，并重跑本仓完整构建与测试。

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`（仅直接子模块；`libs`/OpenZeppelin 由 `lib/core` 的 commit 固定），跨仓解析路径固定在 `remappings.txt`；规则见 [合约开发规范](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md) §3.2。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- ActionTarget 与 LP 迁移完成：旧代码基线、改名、BSC 实现与测试均已提交（第 2-4 步）；LP 含真实 core 栈集成测试（`test/integration/LpExecutorRealIntegration.t.sol`）。覆盖率不在 CI 门禁内，需要时用 `forge coverage --ir-minimum` 本地复核（`--ir-minimum` 用于规避默认设置下的 stack too deep）。
- acceptance.md 的 LP 全周期集成场景（`love20-anvil/scenarios/lp-action-full-cycle.yml`）依赖 BSC 版 `love20-anvil` 仓库，该仓库尚在规划中未创建，属仓库级阻塞项，不影响 LP 四步迁移收口；仓库创建后补跑该场景。
- GroupAction 已完成旧代码基线、改名、BSC 实现与单元测试（第 1-4 步），测试含事件、边界、fuzz 与 invariant 覆盖；GroupService 已完成旧代码基线、改名、BSC 实现与单元测试，`test/GroupService*.t.sol` 覆盖构造、加入、结算、二次分配、事件与边界。
- 自有接口以本仓 `src/interfaces/` 为唯一来源：`matt-gov` 的 `interfaces/` 自迁移后只保留说明（`interfaces/action/` 已迁出），不再存副本；Core 的接口不走暂存副本，直接使用 `lib/core/src/interfaces/`。

## 成员激励接口

三个内置 Executor 都实现 [`IMemberRewardExecutor`](src/interfaces/IMemberRewardExecutor.sol)。`memberReward` 按代币、轮次、行动和身份返回待铸造到账金额、已铸造到账金额及状态。状态为 `Unavailable`、`Pending`、`Partial` 或 `Settled`，由是否还有待结算份额及是否已完成结算决定。`mintMemberReward` 返回本次实际到账。`mintMemberRewards` 每笔最多结算 4 项，返回各项实际到账。LP 的 `lpRewardBurn` 查询该身份的待销毁和已销毁金额。

[`IGroupActionExecutor`](src/interfaces/IGroupActionExecutor.sol) 的 `providerAttribution` 按链群和行动者返回首次归属身份和区块高度。`providerWeights` 给出全群、外部 Provider 合计及单个 Provider 的验证权重，供链群服务按服务提案创建时固定的 Provider 比例分账。

[`IGroupServiceExecutor`](src/interfaces/IGroupServiceExecutor.sol) 的 `serviceRewardByMemberId` 按身份查看四类激励及通过治理上限后的群主预算。`rewardDistribution` 按来源行动和链群给出合伙人编号、比例和金额，以及合伙人合计、群主自留和 Provider 预留。`groupOwnerBurn` 按链群预算查询待销毁和已销毁金额。

当一轮有超过 64 项带 Provider 权重的来源行动时，先完成 GroupAction 群主权重准备，再调用 `prepareProviderReserve`，每页最多准备 64 项市场预留。准备首个有效页面会触发一次实际服务预算铸造。准备完成前，群主相关查询与群主或合并铸造会回滚 `ProviderReservePreparationRequired`，返回当前游标。Provider 和合伙人的单笔铸造仍直接按对应份额计算。

| 角色 | 查金额与铸造状态 | 单项铸造 | 按身份分页与分批 |
| --- | --- | --- | --- |
| 公共验证者 | `verifierReward` | `mintVerifierReward` | 按服务行动整轮结算 |
| 链群 owner | `groupOwnerReward` | `mintGroupOwnerReward` | 按服务行动整轮结算 |
| 合伙人 | `recipientReward` | `mintRecipientReward` | `recipientRewardKeys`、`mintRecipientRewards` |
| Provider | `providerReward` | `mintProviderReward` | `providerRewardKeys`、`mintProviderRewards` |

份额键包含来源行动和链群。用单项查询核对候选份额的金额和状态后，可以选定待铸造的份额一起提交。按链群对账时，`joinedActionIdsByGroupId` 给出目标轮的来源行动，验证记录和首次归属可还原有外部权重的 Provider。验证者在某群某项来源行动的分摊额，按这项链群权重占本人所有已验证来源行动权重的比例，从本人整轮验证激励中折算。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge build --sizes
forge test
```
