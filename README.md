# dotfiles

Portable configuration for an [opencode](https://opencode.ai) development environment on Windows, plus the scripts that deploy it to a fresh machine and sync changes back.

Everything in this repository is **secret-free by design**. Real API keys and tokens live in a local, git-ignored `secrets.env`; the tracked files only ever contain `{{PLACEHOLDER}}` tokens. The repository can be kept public without leaking credentials.

This document covers:

- [New-PC bootstrap](#new-pc-bootstrap)
- [Repository layout](#repository-layout)
- [Backing up from a live machine (`backup.ps1`)](#backing-up-from-a-live-machine)
- [Troubleshooting](#troubleshooting)

## New-PC bootstrap

The steps below take a fresh Windows machine to a fully configured opencode setup in a few commands. Everything is driven from a plain PowerShell prompt.

### 1. Prerequisites: git and Node.js (via winget)

Install git and Node.js with the Windows Package Manager:

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
```

Restart the terminal so `git` and `node` are on `PATH`. Verify with `git --version` and `node --version`.

### 2. Install the opencode CLI

```powershell
npm i -g opencode-ai
```

Verify the install with `opencode --version`.

### 3. Clone the repository

```powershell
git clone <repo-url> %USERPROFILE%\dotfiles
cd %USERPROFILE%\dotfiles
```

(Use the actual repository URL in place of `<repo-url>`.)

### 4. Create and fill `secrets.env`

```powershell
Copy-Item secrets.env.example secrets.env
```

Open `secrets.env` and fill in the values. All keys are listed with empty values in the example; the ones marked REQUIRED below must be non-empty for the installer to run:

| Variable | Required | Purpose |
| --- | --- | --- |
| `CONTEXT7_API_KEY` | required | context7 MCP server key (injected into `opencode.json`) |
| `NPM_TOKEN` | required | npm registry auth token (injected into `.npmrc`) |
| `OC_USAGE_DIR` | required | absolute path to the oc-usage tool directory (injected into `command/oc-usage.md`) |
| `GIT_NAME` | required | `user.name` for the rendered `.gitconfig` |
| `GIT_EMAIL` | required | `user.email` for the rendered `.gitconfig` |
| `GIT_EDITOR` | required | editor command for the rendered `.gitconfig` |
| `OPENROUTER_API_KEY` | optional | used only by `scripts/write-auth.ps1` (openrouter provider) |
| `NVIDIA_API_KEY` | optional | used only by `scripts/write-auth.ps1` (nvidia provider) |
| `OPENCODE_API_KEY` | optional | used only by `scripts/write-auth.ps1` (opencode provider) |
| `OPENCODE_GO_KEY` | optional | used only by `scripts/write-auth.ps1` (opencode-go provider) |

`secrets.env` is git-ignored and never leaves the machine.

### 5. Run the installer

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

What it does:

- loads `secrets.env` and fails fast with a clear, named error if a REQUIRED variable is missing, empty, or multiline;
- renders every `template`-kind file (`{{VAR}}` -> value; `{{USERPROFILE}}` -> the deployment root, never a hardcoded path) and validates JSON targets with `ConvertFrom-Json` before writing;
- copies `verbatim`-kind files as-is;
- backs up any existing live target to `*.bak-<timestamp>` before overwriting — never deletes, never overwrites without a backup;
- skips files whose content is identical (idempotent — safe to re-run);
- `-DryRun` prints every action without writing anything.

### 6. Authenticate per provider

Log in to each provider you use so `auth.json` lives under `%USERPROFILE%\.local\share\opencode`:

```powershell
opencode auth login
```

`opencode auth login` walks you through provider-by-provider authentication (including OAuth where supported). As an alternative, `scripts\write-auth.ps1` seeds `auth.json` from the optional API keys in `secrets.env` and merges with any existing entries.

### 7. First run: plugin auto-install

The first `opencode` run after install automatically installs the `oh-my-openagent` plugin (declared in `config/opencode/opencode.json.template`). This step downloads from the npm registry, so it **requires network access**.

### 8. rtk (antigravity rules prerequisite)

`agents/rules/antigravity-rtk-rules.md` assumes the `rtk` (Rust Token Killer) CLI is installed and used as a shell-command prefix. The rule is **inactive until rtk is installed** — if `rtk` is not on `PATH`, commands prefixed with it simply fail, so install it before relying on the rule:

- Install the rtk CLI from its project's releases (see the rule file for details).
- Verify with `rtk --version` or `rtk gain`.
- Until installed, treat the rule as inactive: the rest of the setup is unaffected.

## Repository layout

The layout below mirrors `scripts/manifest.ps1` (`FILE_MANIFEST`) — the single source of truth for what gets deployed. Live targets are relative to the deployment root (`%USERPROFILE%` by default; the scripts accept `-HomeRoot` for staging).

| Repo path | Live target (relative to `%USERPROFILE%`) | Kind |
| --- | --- | --- |
| `config/opencode/opencode.json.template` | `.config/opencode/opencode.json` | template |
| `config/opencode/tui.json` | `.config/opencode/tui.json` | verbatim |
| `config/opencode/AGENTS.md` | `.config/opencode/AGENTS.md` | verbatim |
| `config/opencode/lsp-install-decisions.json` | `.config/opencode/lsp-install-decisions.json` | verbatim |
| `config/opencode/command/oc-usage.md.template` | `.config/opencode/command/oc-usage.md` | template |
| `config/omo/omo.jsonc` | `.omo/omo.jsonc` | verbatim |
| `agents/rules/antigravity-rtk-rules.md` | `.agents/rules/antigravity-rtk-rules.md` | verbatim |
| `agents/skills/find-skills/**` | `.agents/skills/find-skills/**` | verbatim-dir |
| `agents/skills/skill-creator/**` | `.agents/skills/skill-creator/**` | verbatim-dir |
| `agents/skills/typescript-advanced-types/**` | `.agents/skills/typescript-advanced-types/**` | verbatim-dir |
| `agents/.skill-lock.json` | `.agents/.skill-lock.json` | verbatim |
| `gemini/GEMINI.md` | `.gemini/GEMINI.md` | verbatim |
| `git/.gitconfig.template` | `.gitconfig` | template |
| `npm/.npmrc.template` | `.npmrc` | template |

- `template` — rendered at install time with values from `secrets.env`.
- `verbatim` — copied byte-for-byte.
- `verbatim-dir` — the whole directory tree is copied recursively.

Repo-only files that are **never deployed**: `README.md`, `.gitignore`, `secrets.env.example`, and everything under `scripts/` (including `manifest.ps1` itself).

## Backing up from a live machine

`scripts/backup.ps1` syncs the *other* direction: live files -> repository, redacting secrets on the way out.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\backup.ps1
```

Behavior:

- **Redaction is mandatory.** Every value from `secrets.env` that appears in a live template file is replaced back with its `{{VAR}}` placeholder; machine-specific paths are normalized (`%USERPROFILE%` -> `{{USERPROFILE}}`, the configured `OC_USAGE_DIR` -> `{{OC_USAGE_DIR}}`).
- **Fail-closed.** If `secrets.env` is missing or empty, backup aborts with a "create secrets.env first" error — redaction would be impossible without it.
- `-SkipSecrets` — do **not** redact, therefore **abort whenever any secret value is detected**. It never proceeds unprotected; it is the opposite of a bypass.
- `-WhatIf` — explicit no-write branch: prints exactly one action per manifest row (14 rows) and changes nothing, in the repo or on disk.
- `-Commit` — after a successful sync, runs `git add -A` and creates a conventional commit.
- Only files in `FILE_MANIFEST` are touched; nothing else in the repo or on the live machine is modified.

## Troubleshooting

### Installer aborts with a missing-variable error

If a REQUIRED variable is missing, empty, or contains newlines, the installer stops with an error naming the variable, e.g.:

```
CONTEXT7_API_KEY is required (missing or empty). Add it to secrets.env and re-run.
```

Fix the named variable in `secrets.env` and re-run; the installer is idempotent and skips already-correct targets.

### First-run plugin install fails

The `oh-my-openagent` plugin is fetched from the npm registry on the first opencode run. Offline machines, proxies, or registry outages fail this step. Fix the network/registry issue and re-run opencode — the plugin install is retried automatically.

### Config appears in the "wrong" place

This project targets the **default Windows locations** only: `%USERPROFILE%\.config\opencode`, `%USERPROFILE%\.agents`, `%USERPROFILE%\.gemini`, `%USERPROFILE%\.omo`, `%USERPROFILE%\.gitconfig`, `%USERPROFILE%\.npmrc`. `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `%ProgramData%`-managed configuration are **out of scope** — if you redirect opencode or git through those, adjust the live paths yourself and re-run backup.

### rtk-prefixed commands fail

The antigravity rtk rule is inactive until the `rtk` CLI is installed (see step 8 of the bootstrap). Verify `rtk` is on `PATH` before relying on the rule.

## Security notes

- No secret ever enters the repository: install renders from `secrets.env`, backup redacts back to placeholders, and both directions are covered by scans.
- Rotate any key that has ever been pasted into a chat or artifact (npm token, context7 key) as hygiene before publishing the repository publicly.
