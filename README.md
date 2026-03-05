# Agent Toolkit / Agent 工具箱

Domain-specific skills and commands for AI coding agents (Cursor, OpenAI Codex, Claude Code).

面向特定领域的 AI 编程代理扩展工具，适用于 Cursor、OpenAI Codex 和 Claude Code。

---

## 1. Overview / 概述

This repo is the **domain-specific extension layer** of the
[agent-rules](https://github.com/georgeokelly/agent-rules) system.

本仓库是 [agent-rules](https://github.com/georgeokelly/agent-rules) 系统的**领域扩展层**。

| Type / 类型 | Location / 路径 | Deployed to / 部署目标 |
|---|---|---|
| **Skills** (skills/) | `skills/<name>/SKILL.md` | `.cursor/skills/<name>/` |
| **Commands** (commands/) | `commands/<name>.md` | `.cursor/commands/<name>.md` |

**Why a separate repo? / 为什么单独一个仓库？**

- Domain-specific tools evolve independently from core rules / 领域工具与核心规则节奏不同，独立迭代
- Optional — not every project needs every skill / 按需挂载，不是每个项目都需要全部工具
- Mounted as a git submodule in `agent-rules` for versioned, controlled updates / 以 git submodule 形式挂入，版本可控

---

## 2. Directory Structure / 目录结构

```
agent-toolkit/                   ← This repo / 本仓库
├── skills/                      ← Cursor Agent Skills / Cursor Agent 技能
│   └── <skill-name>/
│       └── SKILL.md             # Skill entry point / 技能入口
│
└── commands/                    ← Cursor slash-commands / Cursor 斜杠命令
    └── <command-name>.md
```

---

## 3. Setup / 安装

This repo is consumed via `agent-sync` in `agent-rules`. See that repo for full setup instructions.

本仓库通过 `agent-rules` 中的 `agent-sync` 自动部署，完整安装说明见主仓库。

```bash
# In ~/.config/agent-rules — add this repo as a submodule
# 在 ~/.config/agent-rules 中添加为 submodule
git submodule add https://github.com/<you>/agent-toolkit extras/agent-toolkit
git commit -m "Add agent-toolkit as submodule"
```

---

## 4. Adding a New Skill / 新增 Skill

```bash
mkdir -p skills/<skill-name>
# Create skills/<skill-name>/SKILL.md — follow Cursor skill format
git add skills/<skill-name>
git commit -m "Add <skill-name> skill"
```

`agent-sync` deploys it to `.cursor/skills/<skill-name>/` on next run.

---

## 5. Adding a New Command / 新增 Command

```bash
# Create commands/<command-name>.md
git add commands/<command-name>.md
git commit -m "Add <command-name> command"
```

`agent-sync` deploys it to `.cursor/commands/<command-name>.md` on next run.
