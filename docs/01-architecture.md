# 架构说明：角色层与执行层的跨进程隔离

## 1. 问题定义

在 DSH 上做角色 Agent，通常会出现两类职责混用：

- 角色层职责：理解用户、保持人格、组织表达、处理用户确认；
- 执行层职责：读写文件、运行 Shell、检索、调用工具、操作工作区。

如果两类职责在同一个会话里执行，会出现：

1. 角色层 persona 被 worker 继承，执行逻辑带上人格和语气；
2. 父会话的工作区指令、工具说明、历史上下文进入执行链；
3. 危险操作的审批只发生在执行 runtime 内，用户看不到、也无法真正确认；
4. 执行环境和角色设定的生命周期绑死，无法独立替换。

本方案的目标是：

```text
角色层只负责对话和确认；
执行层只负责执行；
两者通过 dsh-sdk provider 跨进程通信。
```

## 2. 为什么不直接用 session-mode 双模切换

`session-mode` 插件可以在一个 session 里定义多个模式，例如：

- `coding` 模式：完整工具链；
- `chat` 模式：只保留对话和确认工具。

它适合“同一个会话内不同任务配置”的场景，但不适合角色/执行隔离：

### 2.1 同一会话不能切换模式

`session-mode` 的设计是会话级模式。一个 session 一旦跑过 turn，再用另一个 mode 重新加载，容易出现：

```text
当前会话已经有 turn 记录，不能在同一会话内切换 mode
```

实际效果是：只能新开 session，不能把已有对话无缝切到另一种模式。

### 2.2 本质上仍是一个 runtime

`session-mode` 改变的是同一个 runtime 中的 persona、工具白名单和指令加载方式。  
它并没有创建独立进程，也没有独立 `DSH_HOME`，因此不能做到“执行层不继承父会话上下文”。

### 2.3 结论

- 适合：同一个 Agent 在不同标签页之间切换工具配置；
- 不适合：角色层和执行层的强隔离；
- 本仓库采用：`dsh-sdk` provider + 独立 worker runtime。

## 3. 为什么用 dsh-sdk provider，而不是 in-process subagent

DSH 内置的 in-process subagent 运行在同一个 host 进程内，和父会话共享 runtime 级别的配置与资源。它不适合本方案的核心原因有：

- persona：子 agent 容易继承父会话的 persona 或 system prompt；
- 审批：in-process subagent 的审批策略往往被父会话或全局策略钉死，无法按角色层的确认流程细粒度控制；
- 资源隔离：共享进程、共享 `DSH_HOME`，执行层没有独立的环境边界；
- 工具继承：父会话的工具说明、工作区指令、技能目录容易进入执行链。

`dsh-sdk` provider 的做法是：

- 启动独立 DSH runtime；
- 使用独立的 `DSH_HOME`；
- 使用独立 profile；
- 使用独立 patch 文件配置 persona、沙箱和审批；
- 通过父会话的工具 `dispatch_worker` 传递任务，结果以工具返回值回到角色层。

## 4. 架构图详解

```text
用户
  │
  ▼
┌──────────────────────┐
│ 角色层（chat）        │
│ - persona             │
│ - ask_user_question   │
│ - web_search          │
│ - web_fetch           │
│ - dispatch_worker     │
└──────────┬───────────┘
           │ dispatch_worker(prompt)
           ▼
┌──────────────────────┐
│ dsh-sdk provider      │
│ 启动独立 runtime      │
│ 使用 worker profile   │
│ 使用 worker DSH_HOME  │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 执行层（worker）      │
│ - 不继承角色人格          │
│ - 完整工具            │
│ - 沙箱 + 审批策略     │
└──────────────────────┘
```

### 4.1 父会话

父会话就是角色层，它拥有：

- 角色层 persona；
- 面向用户的工具；
- `dispatch_worker`；
- 用户确认流程。

父会话不直接执行文件或 Shell 操作。

### 4.2 dsh-sdk provider

父 profile 通过 `@deepseek-ai/dsh-subagent-dsh-sdk` 注册一个 provider：

```yaml
- id: subagent-dsh-sdk-worker
  name: '@deepseek-ai/dsh-subagent-dsh-sdk'
  config:
    providerName: worker
    profile: worker
    dshHome: "<DSH_ROOT>/worker-home"
    patches:
      - "<DSH_ROOT>/worker-profile.patch.yml"
```

职责：

- 接收父会话的派发请求；
- 启动独立 worker runtime；
- 加载 worker profile 和 worker patch；
- 返回执行结果。

### 4.3 worker runtime

worker runtime 是独立 DSH runtime：

- 独立进程；
- 独立 `DSH_HOME`；
- 独立 profile；
- 不继承父会话 persona；
- 不继承父对话历史。

### 4.4 dispatch_worker

父 profile 通过 `@deepseek-ai/dsh-tool-subagent` 把 provider 暴露为工具：

```yaml
- id: tool-dispatch-worker
  name: '@deepseek-ai/dsh-tool-subagent'
  config:
    provider: worker
    toolName: dispatch_worker
    maxDepth: provider-managed
    backgroundMode: one-shot
```

角色层只负责调用这个工具，不关心 worker 内部如何执行。

## 5. 数据流

```text
1. 认证
   DSH host 完成本地认证和会话建立。

2. 创建会话
   父会话以 chat 模式启动，加载角色层 persona 和工具白名单。

3. 派发
   用户提出任务。
   角色层判断是否需要执行。
   需要执行时，调用 dispatch_worker。

4. worker 执行
   dsh-sdk provider 启动独立 worker runtime。
   worker 加载自己的 patch，进入对应安全模式。
   worker 执行任务，或在危险操作前返回“待确认计划”。

5. 结果返回
   执行结果作为 dispatch_worker 的工具结果返回父会话。

6. 角色层包装
   角色层把结果转述给用户。
   如果结果是“待确认计划”，角色层完整转告，并等待用户确认。
   用户明确确认后，角色层重新调用 dispatch_worker。
```

## 6. 角色层的 persona 不绑定具体设定

本仓库说的“角色层”是一个架构位置：

- 它可以挂载任意 persona；
- 它可以使用任意语气和表达方式；
- 本文档不绑定任何具体角色设定；
- 示例配置中的 persona 使用 `<YOUR_CHARACTER_PERSONA>` 占位符。

执行层只关心任务本身，不关心角色层是什么人格。

## 7. 安全边界

三个安全模式对应不同的沙箱和审批策略：

| 模式 | 沙箱 | 审批 | 额外约束 |
|---|---|---|---|
| readonly | read-only | ask | 无 |
| autonomous | workspace-write | ask | worker system prompt 要求危险操作先返回待确认计划 |
| open | danger-full-access | never | 无 |

需要注意：

- 审批发生在 worker runtime 内，不能自动上报父会话；
- `autonomous` 的“危险操作先确认”主要依赖 worker system prompt；
- 存在通过 shell-launcher 委托外部进程绕过沙箱的路径；
- 因此本方案的安全是概率性的，不是强沙箱。

## 8. 适用场景

适合：

- 需要一个稳定角色层、背后接执行能力的 Agent；
- 需要把执行环境独立部署、独立清理；
- 需要给执行层单独配置沙箱和审批；
- 需要在角色层做用户确认流程。

不适合：

- 需要强沙箱保证绝对不可绕过的场景；
- 需要审批实时透传到父会话 UI 的场景；
- 需要 in-process 低延迟、共享内存的场景。
