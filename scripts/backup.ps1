#Requires -Version 5.1
<#
.SYNOPSIS
    Sync live dotfiles -> repository, redacting every secret back to its {{PLACEHOLDER}}.

.DESCRIPTION
    Manifest-driven live->repo sync. The single source of truth (FILE_MANIFEST and
    SECRET_KEYS) is dot-sourced from scripts/manifest.ps1 next to this script.

    - template files: live text is read, every non-empty SECRET_KEYS value from
      secrets.env is replaced back to {{KEY}}, machine literals are path-normalized
      (deployment root -> {{USERPROFILE}}, configured OC_USAGE_DIR -> {{OC_USAGE_DIR}}),
      and the result is written only when it differs from the repo file.
    - verbatim / verbatim-dir files: copied byte-for-byte (tree-compared for dirs).
    - FAIL-CLOSED: a missing/empty secrets.env aborts ("create secrets.env first"),
      and any secret value left in rendered output aborts the run.
    - -SkipSecrets: redaction is NOT performed, therefore the run ABORTS whenever any
      secret value is detected in a live template. It never proceeds unprotected.
    - -WhatIf: explicit no-write branch - prints exactly one action per manifest row
      (14 rows) and touches nothing (no files, no git).
    - -Commit: after a successful sync, runs `git add -A` plus a conventional commit.
      Git is never invoked without -Commit.

    Only files listed in FILE_MANIFEST are touched. Secret values are never printed.

.PARAMETER RepoRoot
    Repository root. Defaults to the directory containing this script's parent.

.PARAMETER HomeRoot
    Deployment root where live files live. Defaults to $env:USERPROFILE; override for
    staging QA. NEVER hardcoded - {{USERPROFILE}} normalization is derived from it.

.PARAMETER SecretsFile
    Path to secrets.env (KEY=VALUE lines, '#' comments). Defaults to $RepoRoot\secrets.env.

.PARAMETER WhatIf
    Explicit no-write branch: print one action per manifest row and exit. No file or
    git operations are performed.

.PARAMETER Commit
    After a successful sync, stage everything (`git add -A`) and commit with the
    conventional subject "chore(dotfiles): sync from live machine".

.PARAMETER SkipSecrets
    Do not redact. Consequently abort with exit code 1 whenever any secret value is
    detected in a live template file (never syncs secrets unprotected).

.EXAMPLE
    pwsh -File scripts\backup.ps1 -WhatIf
    pwsh -File scripts\backup.ps1 -Commit
#>
param(
    [string]$RepoRoot     = (Split-Path -Parent $PSScriptRoot),
    [string]$HomeRoot     = $env:USERPROFILE,
    [string]$SecretsFile  = (Join-Path (Split-Path -Parent $PSScriptRoot) 'secrets.env'),
    [switch]$WhatIf,
    [switch]$Commit,
    [switch]$SkipSecrets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Single source of truth: FILE_MANIFEST (rows: RepoRel, LiveRel, Kind) + SECRET_KEYS.
. (Join-Path $PSScriptRoot 'manifest.ps1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Deterministic per-file fingerprint list of a tree (relative path | SHA256 | size).
# Both the root and each item are canonicalized via [IO.Path]::GetFullPath first so
# 8.3 short-name roots (e.g. C:\Users\ROSTIK~1\...) align with the long-form FullName
# Get-ChildItem returns (Resolve-Path preserves the short form; GetFullPath expands it).
function Get-TreeFingerprint {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $canonRoot = [System.IO.Path]::GetFullPath($Root)
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        $canon = [System.IO.Path]::GetFullPath($_.FullName)
        '{0}|{1}|{2}' -f $canon.Substring($canonRoot.Length + 1),
                           (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash,
                           $_.Length
    } | Sort-Object)
}

function Copy-TreeInto {
    param([string]$Source, [string]$Dest)
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force
    }
}

function Ensure-ParentDir {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
        throw 'HomeRoot is empty - set -HomeRoot explicitly.'
    }
    if (-not (Test-Path -LiteralPath $HomeRoot)) {
        throw "HomeRoot does not exist: $HomeRoot"
    }

    $manifest = $script:FILE_MANIFEST
    if (-not $manifest -or @($manifest).Count -eq 0) {
        throw 'FILE_MANIFEST is empty - manifest.ps1 did not load.'
    }

    # --- -WhatIf: explicit no-write branch (one action line per manifest row). ---
    if ($WhatIf) {
        foreach ($row in $manifest) {
            Write-Output ('[DRYRUN] would sync {0} ({1})' -f $row.RepoRel, $row.Kind)
        }
        exit 0
    }

    # --- Load secrets (fail-closed: redaction is impossible without them). ---
    if (-not (Test-Path -LiteralPath $SecretsFile)) {
        throw "create secrets.env first (missing: $SecretsFile) - redaction is impossible without it."
    }
    $envMap = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($SecretsFile)) {
        $l = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($l) -or $l.StartsWith('#')) { continue }
        $idx = $l.IndexOf('=')
        if ($idx -le 0) { continue }
        $envMap[$l.Substring(0, $idx).Trim()] = $l.Substring($idx + 1).Trim()
    }
    if ($envMap.Count -eq 0) {
        throw 'create secrets.env first (file exists but has no KEY=VALUE entries) - redaction is impossible without it.'
    }

    # Redaction set: non-empty values of the secret keys only.
    $values = @{}
    foreach ($k in $script:SECRET_KEYS) {
        $v = $envMap[$k]
        if ($v -and $v.Trim().Length -gt 0) { $values[$k] = $v.Trim() }
    }
    if ($values.Count -eq 0) {
        throw 'create secrets.env first (no non-empty secret values found) - redaction is impossible without it.'
    }
    # Longest values first so a short value can never clobber a longer one
    # (e.g. a one-letter GIT_NAME must not match inside a longer API key value).
    $orderedKeys = @($values.Keys | Sort-Object { $values[$_].Length } -Descending)

    # Machine literals for path normalization, derived from -HomeRoot (staging-safe).
    $resolvedHome = (Resolve-Path -LiteralPath $HomeRoot).Path
    $profileBk    = $resolvedHome                       # C:\Users\name
    $profileFwd   = $resolvedHome.Replace('\', '/')     # C:/Users/name
    $profileJson  = $resolvedHome.Replace('\', '\\')    # C:\\Users\\name (JSON-escaped)
    $ocUsageDir   = $values['OC_USAGE_DIR']

    # --- -SkipSecrets pre-pass: abort on ANY secret value BEFORE touching anything. ---
    if ($SkipSecrets) {
        foreach ($row in $manifest) {
            if ($row.Kind -ne 'template') { continue }
            $livePath = Join-Path $HomeRoot ($row.LiveRel -replace '/\*\*$', '')
            if (-not (Test-Path -LiteralPath $livePath)) { continue }
            $text = [System.IO.File]::ReadAllText($livePath)
            foreach ($k in $orderedKeys) {
                if ($text.Contains($values[$k])) {
                    throw ('secret found - aborting: value of {0} detected in live template {1}. -SkipSecrets never syncs secrets unprotected; re-run without -SkipSecrets to redact.' -f $k, $row.LiveRel)
                }
            }
        }
    }

    $changed = 0
    $unchanged = 0
    $hadError = $false

    foreach ($row in $manifest) {
        $repoPath = Join-Path $RepoRoot ($row.RepoRel -replace '/\*\*$', '')
        $livePath = Join-Path $HomeRoot ($row.LiveRel -replace '/\*\*$', '')

        if (-not (Test-Path -LiteralPath $livePath)) {
            Write-Output ('[ERROR] {0}: live source not found: {1}' -f $row.RepoRel, $row.LiveRel)
            $hadError = $true
            continue
        }

        switch ($row.Kind) {
            'verbatim' {
                $srcHash = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
                $dstHash = if (Test-Path -LiteralPath $repoPath) { (Get-FileHash -LiteralPath $repoPath -Algorithm SHA256).Hash } else { $null }
                if ($srcHash -eq $dstHash) {
                    $unchanged++
                    Write-Output ('[OK] {0}: unchanged' -f $row.RepoRel)
                } else {
                    Ensure-ParentDir $repoPath
                    Copy-Item -LiteralPath $livePath -Destination $repoPath -Force
                    $changed++
                    Write-Output ('[SYNCED] {0}: copied' -f $row.RepoRel)
                }
            }
            'verbatim-dir' {
                $srcFp = Get-TreeFingerprint $livePath
                $dstFp = Get-TreeFingerprint $repoPath
                if (@(Compare-Object $srcFp $dstFp).Count -eq 0) {
                    $unchanged++
                    Write-Output ('[OK] {0}: unchanged' -f $row.RepoRel)
                } else {
                    Copy-TreeInto -Source $livePath -Dest $repoPath
                    $changed++
                    Write-Output ('[SYNCED] {0}: tree copied' -f $row.RepoRel)
                }
            }
            'template' {
                $content = [System.IO.File]::ReadAllText($livePath)

                if (-not $SkipSecrets) {
                    foreach ($k in $orderedKeys) {
                        $content = $content.Replace($values[$k], ('{{' + $k + '}}'))
                    }
                }

                # Path normalization (portability) - applies in both modes.
                $content = $content.Replace($profileFwd, '{{USERPROFILE}}')
                $content = $content.Replace($profileBk, '{{USERPROFILE}}')
                $content = $content.Replace($profileJson, '{{USERPROFILE}}')
                if ($ocUsageDir) { $content = $content.Replace($ocUsageDir, '{{OC_USAGE_DIR}}') }

                if (-not $SkipSecrets) {
                    foreach ($k in $orderedKeys) {
                        if ($content.Contains($values[$k])) {
                            throw ('FAIL-CLOSED: value of {0} still present in rendered output for {1} - aborting, nothing written.' -f $k, $row.RepoRel)
                        }
                    }
                }

                $existing = if (Test-Path -LiteralPath $repoPath) { [System.IO.File]::ReadAllText($repoPath) } else { $null }
                if ($existing -eq $content) {
                    $unchanged++
                    Write-Output ('[OK] {0}: unchanged' -f $row.RepoRel)
                } else {
                    Ensure-ParentDir $repoPath
                    [System.IO.File]::WriteAllText($repoPath, $content, (New-Object System.Text.UTF8Encoding($false)))
                    $changed++
                    Write-Output ('[SYNCED] {0}: redacted and written' -f $row.RepoRel)
                }
            }
            default {
                Write-Output ('[ERROR] {0}: unknown kind ''{1}''' -f $row.RepoRel, $row.Kind)
                $hadError = $true
            }
        }
    }

    Write-Output ('Backup complete: {0} changed, {1} unchanged.' -f $changed, $unchanged)
    if ($hadError) { throw 'One or more manifest rows failed - see errors above.' }

    # --- -Commit: only after a fully successful sync, and never without -Commit. ---
    if ($Commit) {
        $status = & git -C $RepoRoot status --porcelain
        if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
        if ([string]::IsNullOrWhiteSpace($status)) {
            Write-Output 'Nothing to commit - working tree clean.'
        } else {
            & git -C $RepoRoot add -A
            if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
            & git -C $RepoRoot commit -m 'chore(dotfiles): sync from live machine'
            if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
            Write-Output 'Committed backup sync.'
        }
    }

    exit 0
}
catch {
    [Console]::Error.WriteLine('backup.ps1: ' + $_.Exception.Message)
    exit 1
}
