# opencode-configs

Portable configuration for an [opencode](https://opencode.ai) development environment on Windows, plus the scripts that deploy it to a fresh machine and sync changes back.

Everything in this repository is **secret-free by design**. Real API keys and tokens live in a local, git-ignored `secrets.env`; the tracked files only ever contain `{{PLACEHOLDER}}` tokens. The repository can be kept public without leaking credentials.

This document covers:

- [New-PC bootstrap](#new-pc-bootstrap)
- [Repository layout](#repository-layout)
- [Backing up from a live machine (`backup.ps1`)](#backing-up-from-a-live-machine)
- [Troubleshooting](#troubleshooting)

## New-PC bootstrap

The steps below take a fresh Windows machine to a fully configured opencode setup. **👤 = manual action required from you; ⚙️ = done automatically (by script or by opencode itself).**

### Action plan (summary)

| # | Step | Who | What happens |
| --- | --- | --- | --- |
| 1 | Install git + Node.js | 👤 | run 2 winget commands, restart terminal |
| 2 | Install opencode (GUI or CLI) | 👤 | download/install the app — **not** in this repo |
| 3 | Clone this repo | 👤 | one git command |
| 4 | Create + fill `secrets.env` | 👤 | **your keys/tokens — the only real manual config step** |
| 5 | Run `install.ps1` | ⚙️ | renders and deploys all 14 config targets (backs up existing) |
| 6 | Provider login | 👤 | `opencode auth login` or GUI account panel (or run `write-auth.ps1`) |
| 7 | First opencode run | ⚙️ | auto-installs the oh-my-openagent plugin (needs network) |
| 8 | Install rtk | 👤 | optional — only if you use the antigravity rules |

### 1. Prerequisites: git and Node.js (via winget) — 👤

Install git and Node.js with the Windows Package Manager:

```powershell
winget install --id Git.Git -e
winget install --id OpenJS.NodeJS.LTS -e
```

Restart the terminal so `git` and `node` are on `PATH`. Verify with `git --version` and `node --version`.

### 2. Install opencode (CLI or desktop GUI) — 👤

opencode is available both as a terminal CLI and as a desktop GUI app — **they share the exact same config files**, so this repo works identically for either. The app itself is **not** in this repo; you install it once:

```powershell
# Option A — desktop GUI app (recommended for GUI users)
#   download the desktop installer from https://opencode.ai and install it,
#   or copy your existing portable install (OpenCode.exe + opencode-cli.exe).

# Option B — terminal CLI
npm i -g opencode-ai
```

Verify the install with `opencode --version` (or open the app — the GUI reads the same `%USERPROFILE%\.config\opencode`).

### 3. Clone the repository — 👤

```powershell
git clone https://github.com/rostikowb/opencode-configs %USERPROFILE%\opencode-configs
cd %USERPROFILE%\opencode-configs
```

### 4. Create and fill `secrets.env` — 👤 (the only manual config step)

```powershell
Copy-Item secrets.env.example secrets.env
```

Open `secrets.env` and fill in the values. All keys are listed with empty values in the example; the ones marked REQUIRED below must be non-empty for the installer to run:

| Variable | Required | Purpose |
| --- | --- | --- |
| `CONTEXT7_API_KEY` | required | context7 MCP server key (injected into `opencode.json`) |
| `NPM_TOKEN` | required | npm registry auth token (injected into `.npmrc`) |
| `OC_USAGE_DIR` | optional | absolute path to the oc-usage tool directory (injected into `command/oc-usage.md`); if empty, the `/oc-usage` plugin is not used (see below) |
| `GIT_NAME` | required | `user.name` for the rendered `.gitconfig` |
| `GIT_EMAIL` | required | `user.email` for the rendered `.gitconfig` |
| `GIT_EDITOR` | required | editor command for the rendered `.gitconfig` |
| `OPENROUTER_API_KEY` | optional | uses `scripts/write-auth.ps1` (openrouter provider) |
| `NVIDIA_API_KEY` | optional | used only by `scripts/write-auth.ps1` (nvidia provider) |
| `OPENCODE_API_KEY` | optional | used only by `scripts/write-auth.ps1` (opencode provider) |
| `OPENCODE_GO_KEY` | optional | used only by `scripts/write-auth.ps1` (opencode-go provider) |

`secrets.env` is git-ignored and never leaves the machine. **Tip:** you can copy the whole file from your existing machine (`%USERPROFILE%\opencode-configs\secrets.env`) — nothing to re-type.

### 5. Run the installer — ⚙️

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

What it does (no human input needed):

- loads `secrets.env` and fails fast with a clear, named error if a REQUIRED variable is missing, empty, or multiline (then you fix that one line and re-run);
- renders every `template`-kind file (`{{VAR}}` -> value; `{{USERPROFILE}}` -> the deployment root, never a hardcoded path) and validates JSON targets with `ConvertFrom-Json` before writing;
- copies `verbatim`-kind files as-is;
- backs up any existing live target to `*.bak-<timestamp>` before overwriting — never deletes, never overwrites without a backup;
- skips files whose content is identical (idempotent — safe to re-run);
- `-DryRun` prints every action without writing anything (use it to preview first).

### 6. Authenticate per provider — 👤

Log in to each provider you use so `auth.json` lives under `%USERPROFILE%\.local\share\opencode`:

```powershell
opencode auth login
```

`opencode auth login` walks you through provider-by-provider authentication (including OAuth where supported). In the **desktop GUI** the same login is done through the app's settings/account panel — it writes the same `auth.json`. As an alternative, `scripts\write-auth.ps1` seeds `auth.json` from the optional API keys in `secrets.env` and merges with any existing entries.

### 7. First run: plugin auto-install — ⚙️

The first `opencode` run after install automatically installs the `oh-my-openagent` plugin (declared in `config/opencode/opencode.json.template`). This step downloads from the npm registry, so it **requires network access** — no human action, but it needs to be online.

### 8. rtk (antigravity rules prerequisite) — 👤 (optional)

`agents/rules/antigravity-rtk-rules.md` assumes the `rtk` (Rust Token Killer) CLI is installed and used as a shell-command prefix. The rule is **inactive until rtk is installed** — if `rtk` is not on `PATH`, commands prefixed with it simply fail, so install it before relying on the rule:

- Install the rtk CLI from its project's releases (see the rule file for details).
- Verify with `rtk --version` or `rtk gain`.
- Until installed, treat the rule as inactive: the rest of the setup is unaffected.

**After step 7 you're done** — opencode (GUI or CLI) is fully configured. The only steps that ever need you again: rotating keys in `secrets.env`, or running `backup.ps1` after changing live config.

## oc-usage plugin (usage statistics)

`OC_USAGE_DIR` is **optional**. It points at the `oc-usage` tool — a small Node CLI (`src\index.js`) that reads OpenCode Go usage statistics (tokens and cost per model) from the opencode.ai dashboard. When the variable is set in `secrets.env`, the `/oc-usage` opencode command is deployed and functional.

When it is **not** set, the `/oc-usage` command is left unconfigured. In that case the agent **must ask the user** whether they want the usage plugin installed, rather than silently assuming:

- Explain **what it is**: a CLI that reports token usage and cost per model for OpenCode (via the opencode.ai dashboard), rendered as a table in chat.
- Explain **where to find it** / how to install it: set `OC_USAGE_DIR` in `%USERPROFILE%\opencode-configs\secrets.env` to the absolute path of the cloned `oc-usage` tool (the directory containing `src/index.js`), then re-run `scripts\install.ps1`.
- Let the user decide. If they decline, skip it and continue — the rest of the setup is unaffected.

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

### Environment variables deployed

Beyond files, `install.ps1` also deploys the non-secret OS environment variables declared in `scripts/manifest.ps1` (`ENV_MANIFEST`). They are idempotent (skipped when already correct) and `-DryRun`-safe:

| Variable | Value | Scope | Purpose |
| --- | --- | --- | --- |
| `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` | `384000` | User | Removes opencode's hard 32_000 cap on per-request output tokens. Read from the process environment **at startup only** — it cannot live in `opencode.json` or a `.env` file. Positive integer; invalid/empty falls back to 32000. User scope survives app reinstalls (lives in the Windows registry, new processes inherit it). After a change, fully restart opencode. |

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
Required secret variable(s) missing or invalid (empty or multiline): CONTEXT7_API_KEY.
Provide them in C:\Users\<you>\opencode-configs\secrets.env or as environment variables.
```

Fix the named variable in `secrets.env` and re-run; the installer is idempotent and skips already-correct targets.

### First-run plugin install fails

The `oh-my-openagent` plugin is fetched from the npm registry on the first opencode run. Offline machines, proxies, or registry outages fail this step. Fix the network/registry issue and re-run opencode — the plugin install is retried automatically.

### Config appears in the "wrong" place

This project targets the **default Windows locations** only: `%USERPROFILE%\.config\opencode`, `%USERPROFILE%\.agents`, `%USERPROFILE%\.gemini`, `%USERPROFILE%\.omo`, `%USERPROFILE%\.gitconfig`, `%USERPROFILE%\.npmrc`. `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `%ProgramData%`-managed configuration are **out of scope** — if you redirect opencode or git through those, adjust the live paths yourself and re-run backup.

### opencode output is truncated at 32K tokens

opencode's core caps per-request output at 32_000 tokens by default, even when the model declares a higher limit (e.g. 384000). The cap is read from the process environment at startup via `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` — there is **no config-file or `.env` mechanism** for it. `install.ps1` deploys this variable automatically (see "Environment variables deployed"), but if truncation persists:

- Verify the variable exists for your user: `[Environment]::GetEnvironmentVariable('OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX','User')` → must be `384000` (a positive integer; anything invalid silently falls back to 32000).
- **Fully restart opencode** (desktop app: quit and relaunch, not just a new tab) — the value is read once at startup.
- The variable is inherited from the launching process; if opencode was started from an already-open terminal, start a new terminal/session after setting it.

### rtk-prefixed commands fail

The antigravity rtk rule is inactive until the `rtk` CLI is installed (see step 8 of the bootstrap). Verify `rtk` is on `PATH` before relying on the rule.

## Security notes

- No secret ever enters the repository: install renders from `secrets.env`, backup redacts back to placeholders, and both directions are covered by scans.
- Rotate any key that has ever been pasted into a chat or artifact (npm token, context7 key) as hygiene before publishing the repository publicly.
