# LOVE20BSC Action

Action 负责 `ActionTarget`、LP、GroupAction 和 GroupService 四类行动执行合约，依赖 `core`。

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
- ActionTarget 与 LP 迁移完成：旧代码基线、改名、BSC 实现与测试均已提交（第 2-4 步）；LP 含真实 core 栈集成测试，`src/LpExecutor.sol` 达 100% 行与分支覆盖。
- acceptance.md 的 LP 全周期集成场景（`love20-anvil/scenarios/lp-action-full-cycle.yml`）依赖 BSC 版 `love20-anvil` 仓库，该仓库尚在规划中未创建，属仓库级阻塞项，不影响 LP 四步迁移收口；仓库创建后补跑该场景。
- GroupAction 已完成旧代码基线、改名、BSC 实现与单元测试（第 1-4 步），测试含事件、边界、fuzz 与 invariant 覆盖；GroupService 已完成旧代码基线、改名与 BSC 实现（第 1-3 步），单元测试未开始。
- 自有接口以 `matt-gov` 的 `interfaces/action/` 为唯一来源，`src/interfaces/` 与本轮迁移范围内的接口逐字节同步（`IGroupServiceExecutor.sol`、`IGroupRecipients.sol` 已随 GroupService 迁移启动纳入）；Core 的接口不走暂存副本，直接使用 `lib/core/src/interfaces/`。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge test
```
