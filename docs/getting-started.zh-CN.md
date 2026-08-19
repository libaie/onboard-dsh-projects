# 快速上手：从零搭建中控会话

本指南带一个全新用户从干净环境走到可用的 `onboard-dsh-projects` 中控会话。
假设你已会用 DeepSeek Harness（DSH）会话，但对本技能完全陌生。

> 权威契约在 `SKILL.md`。本指南只是实用路径；两者冲突时以 `SKILL.md` 为准。

## 1. 前置条件（依赖项，务必先读）

必需：

- DeepSeek Harness（DSH）——技能只在 DSH 会话内运行；
- Windows PowerShell 5.1——全部脚本的目标环境；
- DSH 会话持久化后端——入口子代理是 continuable 子会话，必须有持久化后端；
- 已注册的 LLM 模型——分层模型（出厂 `deepseek-official` 下的
  `deepseek-v4-flash` / `deepseek-v4-pro`）必须在你的部署中可解析；否则用
  `set-model-tier` 把档位设为 `null`（会话默认模型）；
- 每次任务一个 DSH 工作区（技能状态都在 `<工作区>/.agents/onboard-dsh/` 下）。

按需：

- Git——仅接入远端仓库时需要；
- OpenSSH 客户端——仅 SSH 源需要；
- Git LFS——仅完整 LFS 检出需要；
- Node 18+——中控经 `workflow` 派发及任何 Node 脚本需要。

可选：codebase-memory（`cbm_*` 图查询桥；没有它技能自动回退轻量索引）。

`scripts/preflight.ps1` 会逐项检查并安全失败。

## 2. 安装技能

克隆到你的 DSH 技能目录（通常是 `~/.dsh/skills/`）：

```powershell
git clone https://github.com/libaie/onboard-dsh-projects.git "$env:USERPROFILE\.dsh\skills\onboard-dsh-projects"
```

新开的 DSH 会话即可使用该技能（若你的 DSH 从别的目录加载技能，克隆到那里）。

## 3. 首次运行：初始化状态根

在工作区的 DSH 会话里说：

```text
使用 onboard-dsh-projects。

indexMode: full
```

技能会运行 `scripts/index-mode.ps1`（首次让你选 `fast|moderate|full`）和
`scripts/preflight.ps1`。看到 `ready` 再继续。

## 4. 接入你的仓库

给技能一份封闭的 sources 清单（本地目录或 Git URL）：

```text
sources:
- source: C:\work\service-a
- source: C:\work\web-app
- source: { source: https://github.com/org/repo.git, cloneRoot: C:\work\clones }
```

技能对每个仓库：读取其 `AGENTS.md` → 核验根/分支/HEAD/脏状态 → 写
`projects/<repoId>/binding.json` → 生成快照索引 → 创建一个常驻入口子代理
（durable id 写入绑定）。每个仓库返回一行报告（含 `state`、`reasonCode`）。

此后每个仓库都躲在它的入口代理后面——默认只读，写入只发生在授权派发内。

## 5. 初始化中控

同一轮或下一轮加上中控输入：

```text
controllerRoot: <工作区内的绝对路径>
initializeController: true
createControllerAgent: true
```

`init-controller-dsh.ps1` 生成中控根：清单（`.dsh-controller.json`）、`AGENTS.md`、
`TASKS.md`、`memory/`、`docs/`、`tools/control-state.ps1`、`tools/chain-store.ps1`、
`state/`。`createControllerAgent` 同时创建常驻中控子代理（种子为「先读 AGENTS.md」）。

## 6. 选择中控形态（二选一）

**A. 中控子代理（托管式）。** 一切走子代理：把跨项目需求 `send_message` 给它；
它读 `memory/MEMORY.md` + `state/index.json` + 清单后派发。

**B. 用户驱动的中控会话（交互式）。** 开一个工作目录受你控制的 DSH 会话
（专用空目录即可），给它一份简短的 `AGENTS.md`：

```markdown
# Controller session

You are the controller for the onboard-dsh-projects skill.
Controller root: <工作区>\.agents\onboard-dsh\controller
On startup: read the controller root AGENTS.md, run
control-state.ps1 -Action Read and chain-store.ps1 -Action Verify, then report
controller-ready. Route every request per SKILL.md "Request routing".
```

然后在该会话里登记为中控会话，让清单和 UI 都能定位它：

```text
使用 onboard-dsh-projects。
为本会话执行 set-controller-session。
```

（内部即执行 `set-controller-session` 操作，写入你的会话 id。）

## 7. 日常运转

用自然语言把目标交给中控。它按 `SKILL.md`「Request routing」分类每个请求：

- **单仓库工作** → `send_message` 到该仓库入口代理；
- **跨仓库/契约工作** → 冻结契约（`freeze-contract`）→ 入队
  （`enqueue-dispatch`，档位 `economy|balanced|frontier`）→ 启动
  （`start-next-dispatch`）→ `workflow` 逐泳道执行 → `record-dispatch-outcome`
  + CHAIN 终态；
- **外部变更**（Jenkins/Nacos/数据库/Redis/SSH）→ external-write 泳道：
  `register-capability` → 带 `accessMode=external-write` 入队 → **你**
  执行 `authorize-dispatch` → 泳道执行器运行 → CHAIN 终态。

随时用 `control-state.ps1 -Action Read` 和自动生成的 `TASKS.md`
（`scripts/rebuild-dashboard.ps1`）查看状态。

## 8. 成本纪律（读一遍，长期遵守）

1. **中控会话按批轮换**——每 24 条终态 CHAIN（或业务批次结束）交接新会话：
   `set-controller-session` 登记新会话，再在新会话下重建入口代理
   （逐仓库 `replace-project-binding`；DSH 子代理绑定其持久父会话）。旧会话归档。
2. **大批量派发错峰**——避开提供商的峰时定价窗口；紧急单条注明溢价。
3. **分层执行**——`economy`（flash）管单仓库常规，`balanced`/`frontier`（pro）
   管跨仓库工程与契约；中控自身分析可用最大推理强度。

## 9. 排障

每个公开恢复结果按序返回 `state, reasonCode, nextAction, safeToRerun`。常见码：

| 码 | 含义 | 下一步 |
| --- | --- | --- |
| `needs-entry-agent` | 某仓库入口子代理丢失 | 重建，`replace-project-binding` |
| `authorization-pending` | external-write 队头待授权 | `authorize-dispatch`（或拒绝） |
| `dependency-unsatisfied` | 队头依赖未终态或状态不允许 | 等待，或 `cancel-pending-dispatch` |
| `no-external-write-lane` | 该变更没有已注册 capability | `register-capability` 或停止 |
| `controller-filesystem-conflict` | 中控根与清单漂移 | 人工核对，绝不自动覆盖 |

随时验证部署：`powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/run-all.ps1`
