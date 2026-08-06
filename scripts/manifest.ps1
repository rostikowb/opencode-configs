# Single source of truth for the dotfiles repo.
# Dot-sourced by install.ps1 / backup.ps1 / write-auth.ps1.
# README.md layout table mirrors this file. Do not duplicate these lists elsewhere.

$script:FILE_MANIFEST = @(
  @{ RepoRel = 'config/opencode/opencode.json.template';      LiveRel = '.config/opencode/opencode.json';           Kind = 'template' },
  @{ RepoRel = 'config/opencode/tui.json';                     LiveRel = '.config/opencode/tui.json';                Kind = 'verbatim' },
  @{ RepoRel = 'config/opencode/AGENTS.md';                    LiveRel = '.config/opencode/AGENTS.md';               Kind = 'verbatim' },
  @{ RepoRel = 'config/opencode/lsp-install-decisions.json';   LiveRel = '.config/opencode/lsp-install-decisions.json'; Kind = 'verbatim' },
  @{ RepoRel = 'config/opencode/command/oc-usage.md.template'; LiveRel = '.config/opencode/command/oc-usage.md';      Kind = 'template' },
  @{ RepoRel = 'config/omo/omo.jsonc';                         LiveRel = '.omo/omo.jsonc';                            Kind = 'verbatim' },
  @{ RepoRel = 'agents/rules/antigravity-rtk-rules.md';        LiveRel = '.agents/rules/antigravity-rtk-rules.md';    Kind = 'verbatim' },
  @{ RepoRel = 'agents/skills/find-skills/**';                 LiveRel = '.agents/skills/find-skills/**';             Kind = 'verbatim-dir' },
  @{ RepoRel = 'agents/skills/skill-creator/**';               LiveRel = '.agents/skills/skill-creator/**';           Kind = 'verbatim-dir' },
  @{ RepoRel = 'agents/skills/typescript-advanced-types/**';   LiveRel = '.agents/skills/typescript-advanced-types/**'; Kind = 'verbatim-dir' },
  @{ RepoRel = 'agents/.skill-lock.json';                      LiveRel = '.agents/.skill-lock.json';                  Kind = 'verbatim' },
  @{ RepoRel = 'gemini/GEMINI.md';                             LiveRel = '.gemini/GEMINI.md';                         Kind = 'verbatim' },
  @{ RepoRel = 'git/.gitconfig.template';                      LiveRel = '.gitconfig';                                Kind = 'template' },
  @{ RepoRel = 'npm/.npmrc.template';                          LiveRel = '.npmrc';                                    Kind = 'template' }
)

$script:ENV_MANIFEST = @(
  @{
    # Raises opencode's hard default cap on per-request output tokens from
    # 32_000 (OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX, read at startup from the
    # process environment only - it CANNOT live in opencode.json/.env). Without
    # it, models declaring a higher output limit (e.g. 384000) are silently
    # truncated to 32000. Value is non-secret and fixed; it must be a positive
    # integer (invalid/empty falls back to 32000). User scope survives app
    # reinstalls (lives in the registry, opened processes inherit it).
    Name  = 'OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX'
    Value = '384000'
    Scope = 'User'
  }
)

$script:SECRET_KEYS = @('CONTEXT7_API_KEY','NPM_TOKEN','OPENROUTER_API_KEY','NVIDIA_API_KEY','OPENCODE_API_KEY','OPENCODE_GO_KEY','OC_USAGE_DIR','GIT_NAME','GIT_EMAIL','GIT_EDITOR')
$script:REQUIRED_VARS  = @('CONTEXT7_API_KEY','NPM_TOKEN','GIT_NAME','GIT_EMAIL','GIT_EDITOR')
$script:OPTIONAL_VARS  = @('OC_USAGE_DIR','OPENROUTER_API_KEY','NVIDIA_API_KEY','OPENCODE_API_KEY','OPENCODE_GO_KEY')
$script:PROVIDER_MAP   = @{ OPENCODE_API_KEY='opencode'; OPENROUTER_API_KEY='openrouter'; NVIDIA_API_KEY='nvidia'; OPENCODE_GO_KEY='opencode-go' }
