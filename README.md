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

三个内置 Executor 都实现 [`IMemberRewardExecutor`](src/interfaces/IMemberRewardExecutor.sol)。`memberReward` 按代币、轮次、行动和 `memberId` 返回待铸造到账金额、已铸造到账金额及状态。仍有金额待铸造或待销毁时为 `Pending`，结算完成为 `Settled`，其余为 `Unavailable`。待铸造和已铸造的到账金额都大于零时，前端可显示「已领取一部分」。`mintMemberReward` 返回本次实际到账。`mintMemberRewards` 每笔最多结算 4 项，返回各项实际到账。

按 `memberId` 查奖励时，链群行动用 `memberReward` 就能查到完整的个人奖励。需要额外信息时才加明细入口，单类用 `rewardDetail`，多类用 `xxxRewardDetail`。LP 的 `rewardDetail` 返回铸造量、销毁量和状态，待结算时返回预估量，结算后返回实际量。

[`IGroupActionExecutor`](src/interfaces/IGroupActionExecutor.sol) 的 `providerAttribution` 按链群和行动者返回首次归属身份和区块高度。`providerScore` 返回指定 Provider 的分数和全群总分，群主归属的分数也可查询。`generatedActionRewardAttributionByProviderId` 返回某个来源行动和链群归属该 Provider 的激励。`totalGeneratedActionRewardAttributionByProviderId` 汇总该身份当轮在其他链群的归属激励，`totalGeneratedActionRewardAttributionByGroupOwnerId` 汇总其在自有链群的归属激励。`providerIdsWithPositiveScoreByActionIdByGroupId` 分页返回正分 Provider，单笔激励可能向下取整为零。

`memberRewardDetail` 按 `memberId` 返回群主、验证者、合伙人和 Provider 四组激励，以及治理上限前后的群主预算。`groupOwnerRewardBudget` 也可单独查询这两种预算，差额是应销毁的超额。群主只需销毁时，`groupOwnerReward` 的两个金额均为零，状态从 `Pending` 变为 `Settled`。 [IGroupServiceExecutor](src/interfaces/IGroupServiceExecutor.sol)

群主直接查询或领取分账后的奖励。权重按该链群当轮已验证的行动计算。合约先按整轮预算切出 Provider 激励，再按验证成果计算外部 Provider 份额和归属 owner 的部分。Provider 的取整尾差留在合约。

| 角色 | 按身份汇总查询与领取 | 细分查询与领取 | 查找细分来源 |
| --- | --- | --- | --- |
| 公共验证者 | `verifierReward`、`mintVerifierReward` | 按服务行动整轮结算 | 按服务行动整轮结算 |
| 链群 owner | `groupOwnerReward`、`mintGroupOwnerReward` | 按服务行动整轮结算 | 按服务行动整轮结算 |
| 合伙人 | `recipientReward`、`mintRecipientReward` | `recipientRewardBySourceActionIdByGroupId`、`mintRecipientRewardBySourceActionIdByGroupId` | `groupIdsWithRecipientRewardByRecipientId` → `actionIdsWithRecipientRewardByGroupIdByRecipientId`；`mintRecipientRewards` 可批量领取 |
| Provider | `providerReward`、`mintProviderReward` | `providerRewardBySourceActionIdByGroupId`、`mintProviderRewardBySourceActionIdByGroupId` | `groupIdsWithProviderRewardByProviderId` → `actionIdsWithProviderRewardByGroupIdByProviderId`；`mintProviderRewards` 可批量领取 |

四类角色的整轮查询均直接返回待铸造量、已铸造量和状态，与 `memberReward` 一致。按角色领取会跳过已领的份额。查历史来源时，先分页查询链群，再按链群分页查询来源行动。单笔查询返回金额和 `isMinted`。选定多笔后可用两组并行的来源行动 ID 和链群 ID 批量领取，每笔最多 32 项。

当前合作关系可单独查询。Provider 用 `groupIdsWithQuotaByProviderId` 和 `actionIdsWithQuotaByProviderIdByGroupId` 查询仍有额度的链群和行动，已投入行动的额度也计入。Recipient 用 `currentRecipientGroupIdsByRecipientId` 和 `currentRecipientSourceActionIdsByRecipientIdByGroupId` 查询当前配置，用 `recipientRatio` 查看指定轮次的比例。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge build --sizes
forge test
```
