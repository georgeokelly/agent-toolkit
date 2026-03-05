# Commands Catalog / Command 目录

## What is a Command? / 什么是 Command？

A **Command** is a Markdown file that defines a Cursor slash-command (`/command-name`). It contains a prompt template the agent executes when the command is invoked — useful for standardizing repeated workflows like code review, commit drafting, or benchmark runs.

**Command** 是定义 Cursor 斜杠命令（`/command-name`）的 Markdown 文件，包含 Agent 执行时遵循的提示模板，适合将高频工作流（如代码审查、提交草稿、benchmark 运行）标准化为一键指令。

## How to Use / 如何使用

Commands are deployed to `.cursor/commands/<name>.md` by `agent-sync`. Once deployed, invoke them directly in the Cursor chat input:

Command 由 `agent-sync` 部署至 `.cursor/commands/<name>.md`。部署完成后，在 Cursor 对话框中直接输入斜杠命令触发：

```
/pre-commit
/review
/run-bench
```

## How to Add / 如何新增

```bash
# Create commands/<command-name>.md with your prompt template
git add commands/<command-name>.md
git commit -m "Add <command-name> command"
```

See [Naming Conventions](../README.md#naming-conventions--命名约定) in the root README for naming rules.

命名规范见根目录 README 的 [Naming Conventions](../README.md#naming-conventions--命名约定) 一节。

---

## Catalog / 目录

| Name / 名称 | Description / 描述 | Source / 来源 | License |
|---|---|---|---|
| _(none yet)_ | | | |
