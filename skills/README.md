# Skills Catalog / Skill 目录

## What is a Skill? / 什么是 Skill？

A **Skill** is a structured prompt file (`SKILL.md`) that gives a Cursor Agent step-by-step instructions for a repeatable, domain-specific task. When the agent detects a relevant request, it reads the skill file and follows its procedure — effectively extending the agent with new capabilities without modifying core rules.

**Skill** 是一个结构化的提示文件（`SKILL.md`），为 Cursor Agent 提供可复用的、领域特定任务的分步执行指引。Agent 识别到相关请求时，会读取并遵循该文件的流程，从而在不修改核心规则的前提下扩展 Agent 能力。

## How to Use / 如何使用

Skills are deployed to `.cursor/skills/<skill-name>/` by `agent-sync`. Once deployed, reference a skill in your prompt:

Skill 由 `agent-sync` 部署至 `.cursor/skills/<skill-name>/`。部署完成后，在 Cursor 中直接描述任务即可触发对应 skill：

> "Use the `parse-ncu` skill to analyze this profile."
> "帮我用 `cluster-launch` skill 在 umbriel-b200-236 上启动任务。"

## How to Add / 如何新增

```bash
mkdir -p skills/<skill-name>
# Create skills/<skill-name>/SKILL.md following the Cursor skill format
# See https://github.com/georgeokelly/agent-rules for the skill template
git add skills/<skill-name>
git commit -m "Add <skill-name> skill"
```

See [Naming Conventions](../README.md#naming-conventions--命名约定) in the root README for naming rules.

命名规范见根目录 README 的 [Naming Conventions](../README.md#naming-conventions--命名约定) 一节。

---

## Catalog / 目录

| Name / 名称 | Description / 描述 | Source / 来源 | License |
|---|---|---|---|
| _(none yet)_ | | | |
