# SkillsPack - Agent Skills CLI

[![verify](https://github.com/mackysoft/skills-pack/actions/workflows/verify.yaml/badge.svg)](https://github.com/mackysoft/skills-pack/actions/workflows/verify.yaml) [![NuGet](https://img.shields.io/nuget/v/MackySoft.SkillsPack?label=MackySoft.SkillsPack)](https://www.nuget.org/packages/MackySoft.SkillsPack) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Created by Hiroya Aramaki ([Makihiro](https://twitter.com/makihiro_dev))**

SkillsPack is a .NET global tool for distributing reusable Agent Skills to supported agent hosts.

Use it when the same curated skill set should be shared across repositories or user environments without copying `SKILL.md` files by hand.
The package includes canonical skill definitions, generated host-specific skill files, and commands for listing, exporting, installing, updating, diagnosing, and uninstalling skills.

## Install

```bash
dotnet tool install --global MackySoft.SkillsPack
```

Update the tool to receive the latest bundled skills:

```bash
dotnet tool update --global MackySoft.SkillsPack
```

## Quick Start

List available skills and supported hosts:

```bash
skills-pack skills list
```

Install the development skill category into the current repository:

```bash
skills-pack skills install --host openai --scope project --repo-root . --category development
```

Install the writing skill for the current user:

```bash
skills-pack skills install --host openai --scope user --skill writing
```

Preview changes before writing files:

```bash
skills-pack skills install --host openai --scope project --repo-root . --category development --dry-run --print-diff
```

Check installed project skills:

```bash
skills-pack skills doctor --host openai --scope project --repo-root . --category development
```

## Included Skills

SkillsPack includes these reusable skills:

| Skill | Category | Purpose |
| --- | --- | --- |
| `branch-create` | `development` | Create or reuse task branches while preserving detached or uncommitted work. |
| `changelog` | `development` | Write reader-facing changelogs, release notes, and PR change summaries. |
| `code-authoring-rules` | `development` | Apply language-independent code design and authoring rules. |
| `commit` | `development` | Create responsibility-scoped Conventional Commit messages. |
| `csharp-authoring-rules` | `development` | Apply C#-specific implementation and review judgment rules. |
| `claim-grounding` | `basic` | Ground claims in their sources, adoption status, information validity, scope, and relationships. |
| `issue-planner` | `development` | Split tasks and specifications into single or parent-child GitHub Issue structures. |
| `issue-writer` | `development` | Write, create, update, or review structured GitHub Issue bodies. |
| `pr-submit` | `development` | Verify, push, and create or update pull requests. |
| `pr-merge` | `development` | Merge pull requests through CI and branch cleanup. |
| `push` | `development` | Commit pending work when needed and push the current branch safely. |
| `referent-modeling` | `basic` | Ground new terms and abstractions in concrete referents, roles, and relationships before naming. |
| `review-triage` | `development` | Triage review comments against code, specifications, and evidence. |
| `skill-authoring` | `development` | Create, update, and review behaviorally effective agent skills. |
| `skill-usage-analysis` | `development` | Analyze real agent usage and identify evidence-backed skill improvements. |
| `sync-latest` | `development` | Fetch remotes and safely synchronize the target worktree with the right base. |
| `test-authoring` | `development` | Design, update, and consolidate minimal contract-based test suites. |
| `ultra-review` | `development` | Run deeper multi-pass review and apply safe fixes. |
| `unity-authoring-rules` | `development` | Apply Unity-specific implementation and review judgment rules with C# rules. |
| `verification-gate` | `development` | Run the verification needed before PRs or final checks. |
| `writing` | `basic` | Write, revise, review, summarize, and localize text while preserving meaning and assigning content to the document or section that owns it. |
| `xml-doc-writer` | `development` | Write contract-focused XML documentation comments. |

## Categories

SkillsPack includes these categories:

| Category | Purpose |
| --- | --- |
| `basic` | Foundational reusable skills. |
| `development` | Code, review, test, Git, and pull request workflow skills. |

## Skill Selection

`--category` selects one or more bundled skill categories.
`--skill` selects exact `skillName` values.
Selectors accept comma-separated values:

```bash
skills-pack skills install --host openai --scope project --repo-root . --category basic,development
skills-pack skills install --host openai --scope project --repo-root . --skill changelog,commit
```

`skills list` can run without selectors.
For `export`, `install`, `update`, `doctor`, and `uninstall`, at least one package selector is required: `--category` or `--skill`.

When both `--category` and `--skill` are specified, selected skills must match the selected categories.
Exact skill selections also include transitive dependencies declared by the selected skills.
For example, selecting `pr-merge` also exports or installs the Git and PR workflow skills it invokes.

## Command Reference

List bundled skills, supported hosts, categories, and package counts:

```bash
skills-pack skills list
skills-pack skills list --category development
skills-pack skills list --category basic,development
skills-pack skills list --skill changelog
skills-pack skills list --category development --skill changelog
```

Export host-specific skill files:

```bash
skills-pack skills export --host openai --category development --output ./exported-skills
skills-pack skills export --host openai --skill changelog --output ./exported-skills
```

Install skills into a repository:

```bash
skills-pack skills install --host openai --scope project --repo-root . --category development
skills-pack skills install --host openai --scope project --repo-root . --skill changelog
```

Update installed skills:

```bash
skills-pack skills update --host openai --scope project --repo-root . --category development
```

Diagnose installed skills:

```bash
skills-pack skills doctor --host openai --scope project --repo-root . --category development
```

Uninstall managed skills:

```bash
skills-pack skills uninstall --host openai --scope project --repo-root . --category development
```

Install skills into the current user's host skill directory:

```bash
skills-pack skills install --host openai --scope user --category development
skills-pack skills install --host openai --scope user --skill writing
```

Use `--dry-run` before changing installed files:

```bash
skills-pack skills install --host openai --scope project --repo-root . --category development --dry-run --print-diff
skills-pack skills doctor --host openai --scope project --repo-root . --category development
```

Supported hosts are reported by `skills-pack skills list`.

## Author

Hiroya Aramaki is an indie game developer in Japan.

- Website: <https://mackysoft.net/>
- GitHub: <https://github.com/mackysoft>

## License

SkillsPack is under the [MIT License](LICENSE).
