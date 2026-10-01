# dsh-character-execution-isolation

用 DSH 的 SDK provider 把「角色层」和「执行层」拆成两个独立 runtime：角色层只负责对话、人格表达和用户确认，执行层使用无人格、独立进程、独立 DSH home 的 worker 完成任务。

> 这个仓库不是插件，也不是客户端项目。它是文档、脱敏示例配置和可复现验证方法的集合。

## 背景

角色 Agent 通常会把两类职责混在同一个会话里：

- 对用户可见的人格、语气、确认流程；
- 文件读写、Shell、检索、工作区操作等执行逻辑。

混在一个会话里会带来几个问题：

1. `persona` 会进入执行链，影响 worker 的判断和输出；
2. 执行层的工具说明、工作区约定、历史上下文会污染角色层；
3. 危险操作的审批发生在执行层，但用户只和角色层交互，审批流程容易被绕开；
4. 想复用同一个执行环境时，角色人格无法干净剥离。

本仓库给出一种已验证可行的拆法：角色层通过 `dsh-sdk` provider 派发到独立 worker runtime，worker 不继承父会话 persona，也不继承父对话历史。

## 架构图

```text
用户
  │
  ▼
┌──────────────────┐
│  角色层（chat）    │  ← 唯一对用户可见
│  persona + 工具    │
└────────┬─────────┘
         │ dispatch_worker
         ▼
┌──────────────────┐
│  执行层（worker）  │  ← 独立进程，无人格
│  沙箱 + 完整工具   │
└──────────────────┘
```

角色层只挂三类工具：

- `ask_user_question`
- `web_search`
- `web_fetch`
- `dispatch_worker`

执行层不直接和用户说话。需要用户确认的操作，由执行层返回一份「待确认计划」，角色层完整转告用户，用户确认后再重新派发。

## 核心特性

- **跨进程隔离**：worker 是独立 DSH runtime，使用独立 `DSH_HOME`，不继承父会话 persona。
- **三个安全模式**：
  - `readonly`：read-only 沙箱，审批 `ask`；
  - `autonomous`：workspace-write 沙箱，审批 `ask`，并在 worker system prompt 中要求危险操作先返回待确认计划；
  - `open`：danger-full-access 沙箱，审批 `never`。
- **用户确认流程**：worker 返回待确认计划，角色层转告用户，用户明确确认后重新派发。
- **禁止继承工作区指令**：三个 worker 模式都显式禁用 `agent-instructions`。
- **配置即代码**：worker 的 persona、沙箱模式、审批策略都由 patch 文件控制。

## 已知限制

- DSH 的跨进程审批无法从 worker 回传到父会话；worker 只能在自己的 runtime 内 allow/deny。
- `workspace-write` 下的“工作区内危险操作”主要靠 worker 的 system prompt 自觉遵守，安全是概率性的。
- 存在通过 `shell-launcher` 委托外部进程（如 `explorer`、`start`、`powershell`）绕过沙箱的路径。
- `session-mode` 不支持同一会话内切换模式；已经跑过 turn 的会话只能新开会话。
- `dsh-sdk` provider 不会自动创建 worker profile，需要手动初始化。
- 第三方插件如果需要 `source.kind: 'plugin'`，在 `0.1.7-rc.1` 下需要写成 `plugin:<name>`。

## 快速开始

1. 初始化 worker profile：

```powershell
./scripts/init-worker-profile.ps1 -WorkerHome "$env:DSH_ROOT/worker-home" -DshSource "$env:DSH_ROOT/deepseek-harness"
```

2. 把 `examples/` 下的 patch 文件复制到 DSH 根目录，并按注释修改占位符。

3. 配置父 profile 的 `cordis.patch.yml`，加入 `session-mode`、`subagent-dsh-sdk-worker` 和 `dispatch_worker`。

4. 启动并验证：

```powershell
./examples/start-web.ps1 -DshRoot "$env:DSH_ROOT"
```

完整步骤见 [docs/02-setup-guide.md](docs/02-setup-guide.md)。

## 文档

- [架构说明](docs/01-architecture.md)
- [完整配置步骤](docs/02-setup-guide.md)
- [踩坑记录](docs/03-pitfalls.md)
- [验证方法](docs/04-verification.md)

## 许可证

MIT。详见 [LICENSE](LICENSE)。

## 致谢

本仓库的配置模式来自 DSH 的 `dsh-sdk` provider、`session-mode` 插件和 `dsh-tool-subagent` 工具的组合使用。文中示例为去标识化配置，不包含任何具体角色设定。
