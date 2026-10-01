# 完整配置步骤

## 前置条件

- DSH `0.1.7-rc.1` 或兼容版本；
- Node.js `^22.19 || >=24`；
- `corepack` / `pnpm` 可用；
- 一个可用的 model provider；
- 两个独立目录：
  - 父 `DSH_HOME`；
  - worker `DSH_HOME`。

本文使用以下占位符：

```text
<DSH_ROOT>                 DSH 安装根目录
<YOUR_PROVIDER>            model provider 名称
<YOUR_MODEL>               model 名称
<YOUR_CHARACTER_PERSONA>   角色层 persona
```

## 步骤一：初始化 worker profile

`dsh-sdk` provider 不会自动创建 worker profile，必须先初始化。

运行：

```powershell
./scripts/init-worker-profile.ps1 `
  -WorkerHome "$env:DSH_ROOT/worker-home" `
  -DshSource "$env:DSH_ROOT/deepseek-harness"
```

脚本内部执行的核心命令是：

```powershell
$env:DSH_HOME = "$env:DSH_ROOT/worker-home"
corepack pnpm dsh --profile worker --from-default-profile sdk --dump-config
```

执行完成后，应存在：

```text
<DSH_ROOT>/worker-home/profiles/worker/cordis.yml
<DSH_ROOT>/worker-home/profiles/worker/cordis.patch.yml
<DSH_ROOT>/worker-home/profiles/worker/package.json
```

如果目录已存在，脚本会跳过初始化。

## 步骤二：创建 worker patch

在 `<DSH_ROOT>` 下创建三个模式模板：

```text
worker-readonly.patch.yml
worker-autonomous.patch.yml
worker-open.patch.yml
```

以及当前生效文件：

```text
worker-profile.patch.yml
```

`worker-profile.patch.yml` 由 `switch-mode.ps1` 从模板复制生成。

### readonly 模式

```yaml
- id: sandbox-policy
  config:
    mode: read-only
    workspaceRoot: !!js process.cwd()

- id: approval
  config:
    policy: ask

- id: agent-instructions
  disabled: true
```

### autonomous 模式

```yaml
- id: system-prompt
  config:
    personaPrefix: |-
      你是执行层。你的职责是准确完成父会话派发的任务。

      执行前先判断：
      - 如果任务只涉及读取、查询、分析、在工作区内创建或修改文件，直接执行。
      - 如果任务涉及以下任何一项，先不要执行，返回一份“待确认计划”，说明你打算做什么、影响范围是什么：
        - 删除文件或目录
        - 修改工作区外的文件
        - 执行可能影响系统状态的命令
        - 任何不可逆的操作

      返回“待确认计划”时，用以下格式：
      【待确认】
      计划：<具体要做什么>
      影响：<会影响哪些文件或系统状态>
      风险：<可能的不可逆后果>
    personaSuffix: 'Your working directory is {{cwd}}.'

- id: sandbox-policy
  config:
    mode: workspace-write
    workspaceRoot: !!js process.cwd()

- id: approval
  config:
    policy: ask

- id: agent-instructions
  disabled: true
```

### open 模式

```yaml
- id: sandbox-policy
  config:
    mode: danger-full-access
    workspaceRoot: !!js process.cwd()

- id: approval
  config:
    policy: never

- id: agent-instructions
  disabled: true
```

说明：

- `agent-instructions` 必须显式禁用，否则 worker 会读取父工作区的 `AGENTS.md` 等指令；
- `workspaceRoot` 使用 `process.cwd()`，worker 的工作目录由 provider 传入；
- `autonomous` 的“待确认计划”是 system prompt 约定，不是系统级审批保证。

## 步骤三：配置父 profile 的 cordis.patch.yml

父 profile 通常在：

```text
<DSH_ROOT>/dsh-home/profiles/web/cordis.patch.yml
```

加入 `session-mode`：

```yaml
- id: session-mode
  config:
    default: chat
    modes:
      chat:
        name: 对话模式
        description: 只做角色对话与确认；执行任务通过 dispatch_worker 派发到独立 worker。
        role:
          - main
        persona:
          prefix: |-
            <YOUR_CHARACTER_PERSONA>

            你是一个角色层 Agent。你负责理解用户目标、表达结果、处理用户确认。
            当 dispatch_worker 返回【待确认】格式的结果时：
            1. 把计划、影响、风险完整转告用户。
            2. 询问用户是否确认执行。
            3. 用户明确确认后，重新调用 dispatch_worker，prompt 里带上“用户已确认，执行以下计划：<原计划>”。
            4. 用户没有明确确认，不要重新派发。
          suffix: 当前工作目录是 `{{cwd}}`
        allowTools:
          - ask_user_question
          - web_search
          - web_fetch
          - dispatch_worker
        instructions: false
        runtimeContext: false
    models: {}
```

关键点：

- `instructions: false`：父会话不注入工作区指令；
- `runtimeContext: false`：父会话不注入额外 runtime context；
- `allowTools` 只保留角色层需要的工具；
- `dispatch_worker` 必须在白名单中。

## 步骤四：注册 dsh-sdk provider 和 dispatch_worker 工具

在父 profile 的 `cordis.patch.yml` 中插入：

```yaml
- insert:
    - id: subagent-dsh-sdk-worker
      name: '@deepseek-ai/dsh-subagent-dsh-sdk'
      config:
        providerName: worker
        profile: worker
        dshHome: "<DSH_ROOT>/worker-home"
        patches:
          - "<DSH_ROOT>/worker-profile.patch.yml"
        provider: <YOUR_PROVIDER>
        model: <YOUR_MODEL>
        env:
          # 可选项：只有 TLS 抓包导致证书链断裂时才需要。
          NODE_EXTRA_CA_CERTS: "<DSH_ROOT>/certs/proxy-ca.pem"

    - id: tool-dispatch-worker
      name: '@deepseek-ai/dsh-tool-subagent'
      config:
        provider: worker
        toolName: dispatch_worker
        maxDepth: provider-managed
        backgroundMode: one-shot
```

说明：

- `providerName: worker` 是父会话中使用的逻辑名；
- `profile: worker` 指向 worker profile；
- `dshHome` 必须和初始化 worker profile 的目录一致；
- `patches` 指向当前生效的 `worker-profile.patch.yml`；
- `env.NODE_EXTRA_CA_CERTS` 仅在需要自定义 CA 时配置。

## 步骤五：配置角色层 persona 和工具白名单

角色层 persona 放在 `session-mode.chat.persona.prefix`。

通用示例：

```text
<YOUR_CHARACTER_PERSONA>

你是一个角色层 Agent。你负责理解用户目标、表达结果、处理用户确认。
当 dispatch_worker 返回【待确认】格式的结果时：
1. 把计划、影响、风险完整转告用户。
2. 询问用户是否确认执行。
3. 用户明确确认后，重新调用 dispatch_worker，prompt 里带上“用户已确认，执行以下计划：<原计划>”。
4. 用户没有明确确认，不要重新派发。
```

工具白名单：

```yaml
allowTools:
  - ask_user_question
  - web_search
  - web_fetch
  - dispatch_worker
```

不要给角色层文件、Shell、编辑类工具。

## 步骤六：启动并验证

启动：

```powershell
./examples/start-web.ps1 -DshRoot "$env:DSH_ROOT"
```

验证顺序：

1. 在角色层发一条普通对话，确认人格表达正常；
2. 发一个需要执行的任务，确认返回结果没有人格污染；
3. 发“删除工作目录下所有 .md 文件”，确认 worker 先返回待确认计划；
4. 用户确认后重新派发，观察是否执行；
5. 用 `switch-mode.ps1` 切换模式并重启，观察行为差异。

详细验证方法见 [04-verification.md](04-verification.md)。

## 步骤七：切换安全模式

切换模板：

```powershell
./examples/switch-mode.ps1 -Mode readonly -DshRoot "$env:DSH_ROOT"
./examples/switch-mode.ps1 -Mode autonomous -DshRoot "$env:DSH_ROOT"
./examples/switch-mode.ps1 -Mode open -DshRoot "$env:DSH_ROOT"
```

切换后必须重启 web host，新的 `worker-profile.patch.yml` 才会生效。

## 目录结构示例

```text
<DSH_ROOT>/
├─ deepseek-harness/
├─ dsh-home/
│  └─ profiles/
│     └─ web/
│        └─ cordis.patch.yml
├─ worker-home/
│  └─ profiles/
│     └─ worker/
├─ worker-readonly.patch.yml
├─ worker-autonomous.patch.yml
├─ worker-open.patch.yml
└─ worker-profile.patch.yml
```

## 最小验证

```powershell
# 1. 初始化 worker profile
./scripts/init-worker-profile.ps1

# 2. 复制三个模式模板到 <DSH_ROOT>
# 3. 配置父 profile 的 cordis.patch.yml
# 4. 启动
./examples/start-web.ps1

# 5. 在角色层发：
#    删除工作目录下所有 .md 文件
# 6. 预期：worker 返回【待确认】计划，而不是直接删除
```
