# AgentBundle

[![verify](https://github.com/mackysoft/agent-bundle/actions/workflows/verify.yaml/badge.svg)](https://github.com/mackysoft/agent-bundle/actions/workflows/verify.yaml) [![NuGet](https://img.shields.io/nuget/v/MackySoft.AgentBundle?label=MackySoft.AgentBundle)](https://www.nuget.org/packages/MackySoft.AgentBundle) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

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
agent-bundle skills update --host codex --scope user --category development,git
agent-bundle skills doctor --host codex --scope user --category development,git
agent-bundle agents update --host codex --scope user --agent architect,reviewer
agent-bundle agents doctor --host codex --scope user --agent architect,reviewer
```

If a release removes or renames a managed Skill or custom agent, clean up each old name explicitly after updating the tool. `update` does not prune removed entries:

```bash
agent-bundle skills prune --host codex --scope user --skill <removed-or-renamed-skill>
agent-bundle agents prune --host codex --scope user --agent <removed-or-renamed-agent>
```

### Migrate from SkillsPack

Migration from `MackySoft.SkillsPack`, the `skills-pack` CLI, and the `com.mackysoft.skills-pack` catalog is a one-time replacement. AgentBundle provides no compatibility aliases, and the new CLI does not own the old catalog or its installation state.

Before uninstalling the old global tool, use the old CLI to remove every managed Skill installation. Run the applicable command for each old host you used:

```bash
skills-pack skills uninstall --host openai --scope user --category basic,development
```

If an old installation used `--target-dir`, pass that exact target directory to its uninstall command. The old CLI must resolve the same managed installation that it originally created.

For project-scope installations, run the applicable old CLI command in every repository where SkillsPack was installed. Preserve both the original `--repository-root` and any original `--target-dir` override:

```bash
skills-pack skills uninstall --host openai --scope project --repository-root /path/to/repository --category basic,development
```

The historical `openai`, `claude`, and `copilot` host literals belong only to `skills-pack` migration commands; they are not host aliases for `agent-bundle`.

After the old CLI has removed its managed files, replace the global tool:

```bash
dotnet tool uninstall --global MackySoft.SkillsPack
dotnet tool install --global MackySoft.AgentBundle
```

Finally, create installations owned by the new `com.mackysoft.agent-bundle` catalog with `agent-bundle`. For example:

```bash
agent-bundle skills install --host codex --scope user --category development,git
agent-bundle agents install --host codex --scope user --agent architect,reviewer
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

The following categories are public selectors for distinct work surfaces.

### basic

Cross-domain grounding, change framing, terminology, and writing.

| Skill | Purpose |
| --- | --- |
| `challenge` | Critically question concrete choices in plans and artifacts when evidence shows a weak rationale, mismatch, unnecessary indirection, duplication, or brittleness; return all independent, meaningful questions. |
| `change-framing` | Reconstruct change purpose, authority, contract changes, permissions, acceptance conditions, implementation constraints, and unresolved decisions. |
| `claim-grounding` | Ground claims in sources, evidence composition, adoption status, scope, and relationships. |
| `referent-modeling` | Ground terms and abstractions in concrete referents, roles, and relationships before naming. |
| `writing` | Write, revise, review, summarize, and localize text while preserving meaning and ownership boundaries. |

### development

Software implementation, testing, review, documentation, issue planning, and interactive application testing.

| Skill | Purpose |
| --- | --- |
| `changelog` | Write reader-facing changelogs, release notes, and pull request change summaries. |
| `code-authoring-rules` | Apply language-independent code design and authoring rules. |
| `csharp-authoring-rules` | Apply C#-specific implementation and review judgment rules. |
| `interactive-app-testing` | Design a frozen interactive execution-and-evidence envelope from user paths and interpret generic evidence packages into scoped comparison results and candidate findings. |
| `interactive-session-execution` | Execute the execution portion of one frozen interactive execution-and-evidence envelope and return its raw action, wait, observation, media, and cleanup record. |
| `issue-planner` | Split tasks and specifications into single or parent-child GitHub Issue structures. |
| `issue-writer` | Write, create, update, or review structured GitHub Issue bodies. |
| `review-triage` | Triage review comments against code, specifications, and evidence. |
| `test-authoring` | Design, update, and consolidate minimal contract-based test suites. |
| `test-oracle-assessment` | Assess whether test judgments are contract-aligned, independently derived, and supported by detection evidence. |
| `ultra-review` | Orchestrate review planning, independent reviews, triage, responsibility-owned fixes, verification, and re-review until the work converges. |
| `unity-authoring-rules` | Apply Unity-specific implementation and review rules with the C# rules. |
| `verification-gate` | Select and run the evidence needed for acceptance. |
| `xml-doc-writer` | Write contract-focused XML documentation comments. |

### git

Git history, branches, remotes, and delivery through pull requests.

| Skill | Purpose |
| --- | --- |
| `branch-create` | Create or reuse task branches while preserving detached or uncommitted work. |
| `commit` | Create responsibility-scoped Conventional Commit messages. |
| `pr-merge` | Merge pull requests through continuous integration and branch cleanup. |
| `pr-submit` | Verify, push, and create or update pull requests. |
| `push` | Commit pending work when needed and push the current branch safely. |
| `sync-latest` | Fetch remotes and safely synchronize a worktree with the right base. |

### agent-harness

Authoring, isolated behavior validation, execution reconstruction, and deviation analysis for Skills and custom agents.

| Skill | Purpose |
| --- | --- |
| `behavior-deviation-analysis` | Attribute behavior deviations to evidence-backed causes, repair owners, and revalidation scope. |
| `custom-agent-authoring` | Create, update, and validate host-independent custom agent definitions and host bindings. |
| `custom-agent-behavior-validation` | Exercise custom agents in isolated subagent runs and assess dispatch, runtime binding, behavior, handoff, termination, and resource efficiency. |
| `skill-authoring` | Create, update, and review behaviorally effective agent skills. |
| `skill-behavior-validation` | Exercise agent Skills in isolated scenarios and report contract conformance, gaps, and rerun scope. |
| `subagent-execution-analysis` | Reconstruct subagent executions, lifecycle, configuration, actions, and resource usage from runtime evidence. |

### orchestration

Root-task supervision and orchestration for user-operated tasks.

| Skill | Purpose |
| --- | --- |
| `artifact-handoff` | Hand off temporary work artifacts by reference. |
| `orchestrator` | Allocate one objective's outcome responsibilities to capable subagents and manage their handoffs, dependencies, and execution states. |
| `supervisor` | Classify received work into independent objectives and create, update, or split user-operable tasks that apply the orchestrator Skill. |

AgentBundle distributes Supervisor and Orchestrator as Skills for host runtimes where the user-operated root task cannot be supplied as a custom agent. Supervisor performs task-level orchestration: it separates received work by objective and completion boundary, decides whether to create, update, or split tasks, and applies `$orchestrator` in each new task. Orchestrator performs within-task orchestration: it decomposes one objective into outcome responsibilities, selects capable subagents, and manages their handoffs, dependencies, and execution states. Both roots remain on the coordination plane and assign domain research, artifact changes, target monitoring, review, and verification to responsible subagents. After an allocation cycle completes, they wait for new input instead of monitoring assigned work.

Supervisor and Orchestrator use the current task's model, reasoning level, and permissions as their coordination capacity. Leaf custom agents use the settings defined by their host bindings and defer unspecified settings to the host runtime unless the user explicitly requests an override.

### game-planning

Game design, balance analysis, interface design, and gameplay observation.

| Skill | Purpose |
| --- | --- |
| `game-balance-analysis` | Quantitatively model game rules to find viable ranges, dominant choices, failure conditions, and recovery paths. |
| `game-design` | Connect intended player experiences to player activity, game rules, feedback, and progression, and evaluate design hypotheses from gameplay observation records. |
| `game-interface-design` | Map gameplay information, actions, and outcomes to player-facing displays, controls, and interface states. |
| `game-planning` | Define the shared contract and semantic dependencies for mixed game-planning outcomes, then integrate specialist results. |
| `gameplay-observation` | Turn neutral observation requests and generic evidence packages into report-ready gameplay observation records without interpreting them. |

### slack

Context acquisition, request completion, and authorized external effects.

| Skill | Purpose |
| --- | --- |
| `slack-action-executor` | Establish one fully specified effect, safely recover from confirmed non-application, and classify its observed result. |
| `slack-context-reader` | Read a bounded conversation or discovery scope with traceable coverage, omissions, and access state. |
| `slack-interaction` | Read references first, then resolve whether the request ends in context, intent confirmation, a draft, or one authorized effect. |

## Custom agents

List the bundled agents and their direct skill dependencies:

```bash
agent-bundle agents list
```

Install exact custom agents and their resolved skill dependencies:

```bash
agent-bundle agents install --host codex --scope project --repository-root . --agent architect
agent-bundle agents install --host claude-code --scope user --agent architect,reviewer
agent-bundle agents install --host github-copilot --scope project --repository-root . --agent challenger --dry-run --print-diff
```

The `agents` resource group supports `list`, `export`, `install`, `update`, `doctor`, `uninstall`, and `prune`. Agent selection uses exact names through `--agent`; installation and update start from the selected Agent → Skill dependencies and resolve their transitive Skill → Skill closure. Agent definitions never depend on other agents.

### Included custom agents

Custom agents use one flat catalog namespace:

| Agent | Purpose | Direct skill dependencies |
| --- | --- | --- |
| `architect` | Creates implementation-ready design decisions and contracts. | `claim-grounding`, `referent-modeling` |
| `challenger` | Returns non-blocking, evidence-backed challenges to questionable concrete choices in plans and artifacts. | `challenge` |
| `evidence-organizer` | Organizes frozen evidence into a generic, traceable evidence package without interpretation. | `claim-grounding` |
| `implementer` | Implements an agreed design, including natural-language artifacts, and reports implementation verification. | `code-authoring-rules`, `writing` |
| `interactive-tester` | Executes the execution portion of one frozen interactive execution-and-evidence envelope and returns its raw session result unchanged. | `interactive-session-execution` |
| `reviewer` | Independently evaluates defects and risks in candidate work, including writing and content placement. | `review-triage`, `writing` |
| `verifier` | Determines acceptance evidence and its result. | `verification-gate` |
| `researcher` | Finds and grounds the facts needed for a downstream decision, reports checked scope, and keeps missing evidence unconfirmed. | `claim-grounding` |
| `operator` | Performs a fully specified closed action, including waiting for a long-running or external execution, and reports its terminal result or configured stop state. | None |

Agent bindings materialize as host-specific files while `AGENT.md` remains host-independent. The package intentionally does not install or maintain host-shared configuration files.

## Supported hosts

| Host literal | Skills | Custom agents |
| --- | --- | --- |
| `codex` | Codex skill directory | `.codex/agents` |
| `claude-code` | Claude Code skill directory | `.claude/agents` |
| `github-copilot` | GitHub Copilot skill directory | `.github/agents` |

See the [Agent Distribution command reference](https://github.com/mackysoft/agent-distribution/blob/6.1.0/README.md#run-standard-commands) for selector, scope, target-directory, ownership-state, and reload details.

## Development

The source of truth is the schema 4 source under `bundle`: categorized Skill definitions live in `bundle/skills`, and custom-agent definitions live in `bundle/agents`. `bash scripts/generate-bundle.sh` builds the canonical runtime bundle at the ignored `artifacts/agent-distribution` path. Generated manifests, digests, and host artifacts are build outputs and are not committed.

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
