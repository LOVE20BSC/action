# LOVE20BSC Action

Action 负责 `ActionTarget`、LP、GroupAction 和 GroupService 四类行动执行合约，依赖 `core`。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/extension`、`LOVE20TKM/extension-group`、`LOVE20TKM/extension-lp`（提交版本见 [repositories.md](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/repositories.md#旧代码基线)）。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/core` | Core 合约与本层依赖的接口、常量 |
| `lib/libs` | 共享库（分页、历史索引） |
| `lib/openzeppelin-contracts` | 标准 ERC 与数学库 |
| `lib/forge-std` | 测试与脚本 |

依赖版本固定在同一提交的 `.gitmodules` + `foundry.lock`，不在文档中另行登记。

## 当前状态

- 仓库骨架与工具链已建立，编译基线为 Solidity `0.8.37`、Foundry `1.8.1`、`evm_version = "osaka"`，不使用 `via_ir`。
- 规格入口 `docs/specs/` 与接口来源 `src/interfaces/` 尚未从 `matt-gov` 迁入，合约尚未开始迁移。

## 构建与测试

```sh
git submodule update --init --recursive
forge build --force --deny warnings
forge test
```
