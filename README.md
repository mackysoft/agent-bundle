# AgentBundle

[![verify](https://github.com/mackysoft/skills-pack/actions/workflows/verify.yaml/badge.svg)](https://github.com/mackysoft/skills-pack/actions/workflows/verify.yaml) [![NuGet](https://img.shields.io/nuget/v/MackySoft.AgentBundle?label=MackySoft.AgentBundle)](https://www.nuget.org/packages/MackySoft.AgentBundle) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

AgentBundle is a .NET global tool that distributes a curated bundle of reusable skills and custom agents through [Agent Distribution](https://github.com/mackysoft/agent-distribution).

The package contains the canonical Agent Distribution bundle, including host-independent agent instructions and adapters for Codex, Claude Code, and GitHub Copilot.

## Install

```bash
dotnet tool install --global MackySoft.AgentBundle
```

This installs the `agent-bundle` CLI and its embedded canonical bundle. It does not write Skills or custom agents into a host; use the `install` commands below for that.

### Update AgentBundle

```bash
dotnet tool update --global MackySoft.AgentBundle
```

The tool update replaces the CLI and its embedded bundle. It does not change Skill or custom agent files that are already installed in a host. Update and prune those files separately for every host and scope where you installed them, using the same selectors and applicable target overrides. Reuse `--target-dir` for Skill update, prune, and doctor; `--agent-target-dir` for custom-agent update, prune, and doctor; and `--skill-target-dir` for custom-agent update and doctor. For example:

```bash
agent-bundle skills update --host codex --scope user --category basic,development
agent-bundle agents update --host codex --scope user --agent architect,implementer,operator,researcher,reviewer,verifier
```

If a release removes or renames a managed Skill or custom agent, clean up each old name explicitly after updating the tool. `update` does not prune removed entries:

```bash
agent-bundle skills prune --host codex --scope user --skill <removed-or-renamed-skill>
agent-bundle agents prune --host codex --scope user --agent <removed-or-renamed-agent>
```

### Migrate from SkillsPack

Migration from `MackySoft.SkillsPack`, the `skills-pack` CLI, and the `com.mackysoft.skills-pack` catalog is a one-time replacement. AgentBundle provides no compatibility aliases, and the new CLI does not own the old catalog or its installation state.

Before uninstalling the old global tool, use the old CLI to remove every managed Skill installation. Run the applicable user-scope commands for each old host you used:

```bash
skills-pack skills uninstall --host openai --scope user --category basic,development
skills-pack skills uninstall --host claude --scope user --category basic,development
skills-pack skills uninstall --host copilot --scope user --category basic,development
```

If an old installation used `--target-dir`, pass that exact target directory to its uninstall command. The old CLI must resolve the same managed installation that it originally created.

For project-scope installations, run the applicable old CLI command in every repository where SkillsPack was installed. Preserve both the original `--repository-root` and any original `--target-dir` override:

```bash
skills-pack skills uninstall --host openai --scope project --repository-root /path/to/repository --category basic,development
skills-pack skills uninstall --host claude --scope project --repository-root /path/to/repository --category basic,development
skills-pack skills uninstall --host copilot --scope project --repository-root /path/to/repository --category basic,development
```

The `openai`, `claude`, and `copilot` literals above belong only to these historical `skills-pack` migration commands; they are not host aliases for `agent-bundle`.

After the old CLI has removed its managed files, replace the global tool:

```bash
dotnet tool uninstall --global MackySoft.SkillsPack
dotnet tool install --global MackySoft.AgentBundle
```

Finally, create installations owned by the new `com.mackysoft.agent-bundle` catalog with `agent-bundle`. For example:

```bash
agent-bundle skills install --host codex --scope user --category basic,development
agent-bundle agents install --host codex --scope user --agent architect,implementer,operator,researcher,reviewer,verifier
```

Repeat the new installation for each required host and scope. Project-scope installations must be run for each repository with `--scope project --repository-root /path/to/repository`.

## Skills

List the bundled skills:

```bash
agent-bundle skills list
```

Install the development category into the current project for Codex:

```bash
agent-bundle skills install --host codex --scope project --repository-root . --category development
```

Select exact skills or multiple categories with comma-separated values:

```bash
agent-bundle skills install --host claude-code --scope user --skill writing
agent-bundle skills install --host github-copilot --scope project --repository-root . --category basic,development
```

Use `--dry-run --print-diff` before an installation when you need its planned file changes. `export`, `install`, `update`, `doctor`, `uninstall`, and `prune` require `--category` or `--skill`; `list` does not.

## Custom agents

List the bundled agents and their direct skill dependencies:

```bash
agent-bundle agents list
```

Install exact custom agents and their resolved skill dependencies:

```bash
agent-bundle agents install --host codex --scope project --repository-root . --agent architect
agent-bundle agents install --host claude-code --scope user --agent architect,reviewer
agent-bundle agents install --host github-copilot --scope project --repository-root . --agent reviewer --dry-run --print-diff
```

The `agents` resource group supports `list`, `export`, `install`, `update`, `doctor`, `uninstall`, and `prune`. Agent selection uses exact names through `--agent`; installation and update start from the selected Agent → Skill dependencies and resolve their transitive Skill → Skill closure. Agent definitions never depend on other agents.

## Included skills

| Skill | Category | Purpose |
| --- | --- | --- |
| `branch-create` | `development` | Create or reuse task branches while preserving detached or uncommitted work. |
| `changelog` | `development` | Write reader-facing changelogs, release notes, and pull request change summaries. |
| `change-framing` | `basic` | Reconstruct change purpose, authority, contract changes, permissions, acceptance conditions, implementation constraints, and unresolved decisions. |
| `code-authoring-rules` | `development` | Apply language-independent code design and authoring rules. |
| `commit` | `development` | Create responsibility-scoped Conventional Commit messages. |
| `csharp-authoring-rules` | `development` | Apply C#-specific implementation and review judgment rules. |
| `claim-grounding` | `basic` | Ground claims in sources, evidence composition, adoption status, scope, and relationships. |
| `issue-planner` | `development` | Split tasks and specifications into single or parent-child GitHub Issue structures. |
| `issue-writer` | `development` | Write, create, update, or review structured GitHub Issue bodies. |
| `orchestrator` | `development` | Manage one objective in the current task and bridge context and results among responsible subagents. |
| `pr-merge` | `development` | Merge pull requests through continuous integration and branch cleanup. |
| `pr-submit` | `development` | Verify, push, and create or update pull requests. |
| `push` | `development` | Commit pending work when needed and push the current branch safely. |
| `referent-modeling` | `basic` | Ground terms and abstractions in concrete referents, roles, and relationships before naming. |
| `review-triage` | `development` | Triage review comments against code, specifications, and evidence. |
| `skill-authoring` | `development` | Create, update, and review behaviorally effective agent skills. |
| `skill-usage-analysis` | `development` | Analyze agent usage and identify evidence-backed skill improvements. |
| `supervisor` | `development` | Route independent objectives to user-operable tasks that apply the orchestrator Skill. |
| `sync-latest` | `development` | Fetch remotes and safely synchronize a worktree with the right base. |
| `test-authoring` | `development` | Design, update, and consolidate minimal contract-based test suites. |
| `test-oracle-assessment` | `development` | Assess whether test judgments are contract-aligned, independently derived, and supported by detection evidence. |
| `ultra-review` | `development` | Orchestrate review planning, independent reviews, triage, responsibility-owned fixes, verification, and re-review until the work converges. |
| `unity-authoring-rules` | `development` | Apply Unity-specific implementation and review rules with the C# rules. |
| `verification-gate` | `development` | Select and run the evidence needed for acceptance. |
| `writing` | `basic` | Write, revise, review, summarize, and localize text while preserving meaning and ownership boundaries. |
| `xml-doc-writer` | `development` | Write contract-focused XML documentation comments. |

Supervisor and Orchestrator are Skills applied in tasks that the user can open and continue. Supervisor only assigns each independent objective to a new or existing task and applies `$orchestrator` in each new task. Orchestrator manages one objective inside that task and bridges the required context and results among leaf custom agents; it does not perform their specialized work. These Skills use the current task's model, reasoning level, and permissions rather than Agent host bindings.

## Included custom agents

Custom agents use one flat catalog namespace:

| Agent | Purpose | Direct skill dependencies |
| --- | --- | --- |
| `architect` | Creates implementation-ready design decisions and contracts. | `claim-grounding`, `referent-modeling` |
| `implementer` | Implements an agreed design, including natural-language artifacts, and reports implementation verification. | `code-authoring-rules`, `writing` |
| `reviewer` | Independently evaluates defects and risks in candidate work, including writing and content placement. | `review-triage`, `writing` |
| `verifier` | Determines acceptance evidence and its result. | `verification-gate` |
| `researcher` | Collects bounded read-only evidence and reports unchecked areas. | `claim-grounding` |
| `operator` | Performs a fully specified closed action, including waiting for a long-running or external execution, and reports its terminal result or configured stop state. | None |

Agent bindings materialize as host-specific files while `AGENT.md` remains host-independent. The package intentionally does not install or maintain host-shared configuration files.

When the Orchestrator Skill handles natural-language changes, it assigns the change to an implementer and requires a separate read-only reviewer to audit the latest candidate with the `writing` contract. Accepted findings return to implementation, and the revised candidate is audited again before completion.

## Supported hosts

| Host literal | Skills | Custom agents |
| --- | --- | --- |
| `codex` | Codex skill directory | `.codex/agents` |
| `claude-code` | Claude Code skill directory | `.claude/agents` |
| `github-copilot` | GitHub Copilot skill directory | `.github/agents` |

See the [Agent Distribution command reference](https://github.com/mackysoft/agent-distribution/blob/4.0.0/README.md#run-standard-commands) for selector, scope, target-directory, ownership-state, and reload details.

## Development

The source of truth is `bundle/bundle.json` and `bundle/definitions`. Schema 3 keeps categorized Skill definitions under `definitions/skills` and flat custom-agent definitions under `definitions/agents`; `bundle/generated` is the checked-in canonical output.

```bash
dotnet tool restore
dotnet restore AgentBundle.slnx
bash scripts/generate-bundle.sh
bash scripts/verify.sh
```

## Author

Hiroya Aramaki ([Makihiro](https://twitter.com/makihiro_dev))

## License

AgentBundle is under the [MIT License](LICENSE).
