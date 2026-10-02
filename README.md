# LOVE20BSC Action

Action 负责 `ActionTarget`、LP、GroupAction 和 GroupService 四类行动执行合约，依赖 `core`。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/extension`、`LOVE20TKM/extension-group`、`LOVE20TKM/extension-lp`（提交版本见 [repositories.md](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/repositories.md#旧代码基线)）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/core` | Core 接口声明的唯一来源与测试夹具用的 Core 实现 |
| `lib/libs` | 共享库（分页、集合原语、按轮历史） |
| `lib/openzeppelin-contracts` | 标准 ERC 与数学库 |
| `lib/forge-std` | 测试与脚本 |

Core 的接口以 `core` 代码库为准：生产代码直接从 `lib/core/src/interfaces/` 导入，标准能力（如 ERC721 的 `ownerOf`）由 core 侧接口继承提供，因此本仓不另存 Core 接口副本。`lib/core` 须与 `core` 的 `main` 同步——core 源码用相对路径引用自己的 `lib/libs`，升版本仓时必须同时让其嵌套子模块与其 `foundry.lock` 一致。

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`，不在文档中另行登记。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- 规格入口 `docs/specs/` 与 Action 自有接口（`src/interfaces/`，来自 `matt-gov` 的 `action/` 暂存目录）尚未迁入，合约尚未开始迁移。Core 的接口不走暂存副本，直接使用 `lib/core/src/interfaces/`。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge test
```
