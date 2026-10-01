# 踩坑记录

以下问题来自实际搭建“角色层 + 执行层”隔离时的记录。每条包含现象、原因和处理方式。

## 1. TLS 证书链断裂

### 现象

Node 端 `fetch` 报证书链错误，例如：

```text
unable to verify the first certificate
UNABLE_TO_VERIFY_LEAF_SIGNATURE
```

### 原因

杀毒软件或企业代理进行 HTTPS 扫描时，会在链路中插入自己的根证书。Node 默认信任系统根证书，但有时无法拿到完整的中间证书链。

### 处理

为 Node 进程提供额外的 CA 文件：

```powershell
$env:NODE_EXTRA_CA_CERTS = "<DSH_ROOT>/certs/proxy-ca.pem"
```

在 worker provider 配置中也可以单独指定：

```yaml
env:
  NODE_EXTRA_CA_CERTS: "<DSH_ROOT>/certs/proxy-ca.pem"
```

注意：

- 只把可信 CA 文件放进去；
- 不要把代理凭据、API Key 写进仓库；
- 如果不需要自定义 CA，可以删除这个 `env` 段。

## 2. Windows ACL：workspace-write 需要 WRITE_OWNER

### 现象

`workspace-write` 沙箱启动失败，或执行文件写入时报权限错误。

### 原因

Windows 上的 workspace-write 沙箱需要工作目录具备 `WRITE_OWNER` 权限。普通用户目录默认可能不包含这个 ACL。

### 处理

对工作目录授予当前用户 `WRITE_OWNER`：

```powershell
icacls "<WORKSPACE_DIR>" /grant "$env:USERNAME:(OI)(CI)WO"
```

如果使用独立账户运行 worker，把 `$env:USERNAME` 换成该账户。

验证：

```powershell
icacls "<WORKSPACE_DIR>"
```

输出中应包含类似：

```text
<USER>:(OI)(CI)(WO)
```

## 3. source-kind 兼容：plugin 需要带名称

### 现象

第三方 DSH 插件在 `0.1.7-rc.1` 下加载失败，提示 `source.kind: 'plugin'` 不被接受。

### 原因

rc.1 对 source kind 的校验更严格，要求 `plugin` 这类 kind 带名称。

### 处理

把：

```yaml
kind: plugin
```

改成：

```yaml
kind: plugin:<name>
```

具体名称按插件文档或插件包名填写。

## 4. rc.2 构建残留导致降级失败

### 现象

从 rc.2 降级回 rc.1 后，旧构建产物导致模块解析失败或启动异常。

### 原因

`lib/`、`dist/` 等构建目录中残留了 rc.2 产物。

### 处理

在 DSH 源码目录执行：

```powershell
pnpm run clean
```

然后重新安装依赖并构建。

## 5. worker profile 不存在

### 现象

父会话调用 `dispatch_worker` 时失败，提示找不到 worker profile。

### 原因

`dsh-sdk` provider 不会自动创建 profile。只配置了 `profile: worker`，但没有初始化对应目录。

### 处理

先运行初始化脚本：

```powershell
./scripts/init-worker-profile.ps1 `
  -WorkerHome "$env:DSH_ROOT/worker-home" `
  -DshSource "$env:DSH_ROOT/deepseek-harness"
```

确认以下文件存在：

```text
<DSH_ROOT>/worker-home/profiles/worker/cordis.yml
<DSH_ROOT>/worker-home/profiles/worker/cordis.patch.yml
<DSH_ROOT>/worker-home/profiles/worker/package.json
```

## 6. session-mode 不能在同一会话内切换

### 现象

尝试在已经跑过 turn 的会话里切换 `session-mode`，报错或行为异常。

### 原因

`session-mode` 是会话级配置。一个 session 一旦执行过 turn，不能直接切到另一个 mode。

### 处理

- 切换 mode 后新开会话；
- 或者在会话开始前就确定模式；
- 不要把“运行中切换模式”作为角色/执行隔离的方案。

## 7. 审批无法跨进程上报

### 现象

worker 内部触发审批，但父会话 UI 看不到；用户无法在角色层确认。

### 原因

`dsh-sdk` child runtime 的审批执行在 worker 进程内，不能直接回传父会话。

### 处理

- 不要在架构上依赖“父会话审批桥”；
- 用 worker system prompt 约定“危险操作先返回待确认计划”；
- 角色层收到待确认计划后，转告用户并等待确认；
- 用户确认后，角色层重新派发。

注意：这只是流程约定，不是系统级审批。

## 8. shell-launcher 绕过沙箱

### 现象

worker 被要求执行受限操作时，可能通过 `explorer`、`start`、`powershell` 等命令委托外部进程，绕过当前沙箱。

### 原因

沙箱约束的是 worker 自身执行的进程，无法完全控制所有子进程委托路径。

### 处理

- 在 worker system prompt 中明确禁止通过 shell-launcher 委托外部进程；
- 只使用 `readonly` 或 `autonomous` 这类有限模式；
- 不要在 worker 可访问的路径中放置高权限凭据；
- 接受“安全是概率性的”这一限制。

## 9. 某些 persona 覆盖插件与 rc.1 不兼容

### 现象

安装 persona 覆盖类插件后，`session-mode` 无法正常工作，或者 persona 被插件覆盖。

### 原因

`session-mode` 在 rc.1 中已经原生覆盖了 persona 能力；再叠加同类插件会产生冲突。

### 处理

- 二选一：使用 `session-mode` 的 persona，或使用 persona 插件；
- 不要同时开启两者；
- 如果必须使用插件，先确认它和当前 DSH 版本的兼容性。

## 10. worker 默认读取父工作区的 AGENTS.md

### 现象

worker 返回内容里引用了父工作区的开发约定、仓库说明或技能目录。

### 原因

worker 的工作目录和父会话相同，`agent-instructions` 默认会读取工作区中的 `AGENTS.md` 等文件。

### 处理

在三个 worker patch 中都显式禁用：

```yaml
- id: agent-instructions
  disabled: true
```

如果某次任务确实需要遵循仓库规范，由角色层在派发时显式传递，而不是让 worker 自动继承。
