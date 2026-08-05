#Requires -Version 7.0
<#
install.ps1 — deploy dotfiles from the repo to a target home directory.

* Dot-sources scripts/manifest.ps1 (single source of truth: FILE_MANIFEST).
* Loads secrets from -SecretsFile (KEY=value lines) or, when the file is
  absent, from process environment variables. Missing/empty/multiline values
  for REQUIRED_VARS abort with an error naming the variable (unless -Prompt);
  missing OPTIONAL_VARS only warn, they never abort.
* Renders templates: {{KEY}} <- secret value, {{USERPROFILE}} <- $HomeRoot
  (never a hardcoded $env:USERPROFILE — staging isolation). JSON-kind targets
  (Kind=template with RepoRel *.json.template) get JSON-escaped values
  (backslash + quote) and the rendered document MUST parse via ConvertFrom-Json
  before it is written live (abort on parse failure). Non-JSON targets use
  plain substitution.
* For every manifest entry the live target is either left untouched (content
  identical -> skip, idempotent), backed up to <file>.bak-<ts-ms> (uniqueness
  loop, never overwrites) and rewritten (content differs), or created (missing).
* -DryRun is an explicit no-write branch: prints every action, writes nothing.
* Never deletes live files, never overwrites without a backup, never prints
  secret values, collects per-file results and exits 1 on any error.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Alias('HomeOverride')]
    [string]$HomeRoot = $env:USERPROFILE,
    [string]$SecretsFile = (Join-Path $RepoRoot 'secrets.env'),
    [switch]$DryRun,
    [switch]$Prompt
)

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------- manifest --
$manifestPath = Join-Path $RepoRoot 'scripts\manifest.ps1'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Error "Manifest not found: $manifestPath (run install.ps1 from the dotfiles repo)."
    exit 1
}
. $manifestPath

if ($null -eq $script:FILE_MANIFEST -or @($script:FILE_MANIFEST).Count -lt 1) {
    Write-Error 'FILE_MANIFEST is empty — manifest.ps1 did not load correctly.'
    exit 1
}

# ----------------------------------------------------------------- secrets --
$secrets = @{}
if (Test-Path -LiteralPath $SecretsFile) {
    # File present -> file is authoritative (no env fallback: a missing var
    # here must surface as an error, never be silently filled from the env).
    $lines = [System.IO.File]::ReadAllLines($SecretsFile)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) {
            Write-Warning "Ignoring malformed line $($i + 1) in $SecretsFile (no '=')."
            continue
        }
        $key = $line.Substring(0, $eq).Trim()
        if ($key -eq '') {
            Write-Warning "Ignoring malformed line $($i + 1) in $SecretsFile (empty key)."
            continue
        }
        $secrets[$key] = $line.Substring($eq + 1).Trim()
    }
}
else {
    foreach ($key in $script:SECRET_KEYS) {
        $val = [Environment]::GetEnvironmentVariable($key)
        if ($null -ne $val) { $secrets[$key] = $val }
    }
}

function Test-MultilineValue {
    param([string]$Value)
    return ($Value -match "[\r\n]")
}

# Required vars: missing / empty / multiline -> clear error naming the var
# (unless -Prompt, which fills them interactively).
$badRequired = @()
foreach ($key in $script:REQUIRED_VARS) {
    if (-not $secrets.ContainsKey($key)) { $badRequired += $key; continue }
    if ($secrets[$key] -eq '' -or (Test-MultilineValue $secrets[$key])) { $badRequired += $key }
}
if ($badRequired.Count -gt 0 -and $Prompt) {
    foreach ($key in @($badRequired)) {
        for ($i = 0; $i -lt 3 -and $secrets[$key] -in @($null, ''); $i++) {
            $answer = Read-Host "Required variable '$key' is missing or invalid. Enter a value"
            if ($null -ne $answer -and $answer.Trim() -ne '') { $secrets[$key] = $answer.Trim() }
        }
    }
    $badRequired = @($script:REQUIRED_VARS | Where-Object {
        -not $secrets.ContainsKey($_) -or $secrets[$_] -eq '' -or (Test-MultilineValue $secrets[$_])
    })
}
if ($badRequired.Count -gt 0) {
    Write-Error ("Required secret variable(s) missing or invalid (empty or multiline): " +
        ($badRequired -join ', ') +
        ". Provide them in $SecretsFile or as environment variables.")
    exit 1
}

# Optional vars: missing -> warn only; provided-but-empty/multiline -> reject.
foreach ($key in $script:OPTIONAL_VARS) {
    if (-not $secrets.ContainsKey($key)) {
        Write-Warning "Optional secret variable '$key' is not set; continuing without it."
        continue
    }
    if ($secrets[$key] -eq '' -or (Test-MultilineValue $secrets[$key])) {
        Write-Error "Secret variable '$key' has an empty or multiline value — refusing to proceed."
        exit 1
    }
}

# ---------------------------------------------------------------- helpers --
function ConvertTo-JsonEscapedValue {
    param([string]$Value)
    $esc = $Value.Replace('\', '\\').Replace('"', '\"')
    $esc = [regex]::Replace($esc, '[\x00-\x1F]', { param($m) ('\u{0:x4}' -f [int][char]$m.Value[0]) })
    return $esc
}

function Get-RenderedContent {
    param([string]$RawContent, [bool]$IsJson, [string]$RepoLabel)
    $content = $RawContent
    foreach ($key in $script:SECRET_KEYS) {
        if ($secrets.ContainsKey($key)) {
            $value = if ($IsJson) { ConvertTo-JsonEscapedValue $secrets[$key] } else { $secrets[$key] }
            $content = $content.Replace("{{$key}}", $value)
        }
    }
    $userProfile = if ($IsJson) { ConvertTo-JsonEscapedValue $HomeRoot } else { $HomeRoot }
    $content = $content.Replace('{{USERPROFILE}}', $userProfile)
    if ($content -match '\{\{[A-Z0-9_]+\}\}') {
        Write-Warning "$RepoLabel still contains {{...}} placeholders after rendering."
    }
    return $content
}

function Get-BackupPath {
    param([string]$LivePath)
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $candidate = "$LivePath.bak-$ts"
    $n = 0
    while (Test-Path -LiteralPath $candidate) {
        $n++
        $candidate = "$LivePath.bak-$ts-$n"
    }
    return $candidate
}

function Invoke-WriteOneFile {
    param([string]$LivePath, [string]$Content, [string]$RepoLabel, [bool]$IsJson)
    try {
        if ($IsJson) {
            try { $null = $Content | ConvertFrom-Json }
            catch {
                return @{ Status = 'error'; Live = $LivePath; Message = "rendered JSON for $RepoLabel failed to parse: $($_.Exception.Message)" }
            }
        }
        $exists = Test-Path -LiteralPath $LivePath
        if ($exists -and ([System.IO.File]::ReadAllText($LivePath) -eq $Content)) {
            Write-Host "identical: $LivePath"
            return @{ Status = 'identical'; Live = $LivePath; Message = $null }
        }
        if ($DryRun) {
            if ($exists) { Write-Host "DRY-RUN: would back up and rewrite $LivePath" }
            else { Write-Host "DRY-RUN: would create $LivePath" }
            return @{ Status = 'would-change'; Live = $LivePath; Message = $null }
        }
        $parent = Split-Path -Parent $LivePath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        if ($exists) {
            $backup = Get-BackupPath $LivePath
            [System.IO.File]::Copy($LivePath, $backup, $false)
            Write-Host "backed up: $LivePath -> $backup"
        }
        [System.IO.File]::WriteAllText($LivePath, $Content, $script:Utf8NoBom)
        Write-Host "wrote: $LivePath"
        return @{ Status = 'changed'; Live = $LivePath; Message = $null }
    }
    catch {
        return @{ Status = 'error'; Live = $LivePath; Message = $_.Exception.Message }
    }
}

# ------------------------------------------------------------------- deploy --
$results = @()
foreach ($entry in $script:FILE_MANIFEST) {
    $repoRel = $entry.RepoRel
    $liveRel = $entry.LiveRel
    $kind = $entry.Kind
    $isJsonTarget = ($kind -eq 'template' -and $repoRel -like '*.json.template')

    if ($kind -eq 'verbatim-dir') {
        $repoBase = $repoRel -replace '/\*\*$', ''
        $liveBase = $liveRel -replace '/\*\*$', ''
        $srcDir = Join-Path $RepoRoot $repoBase
        if (-not (Test-Path -LiteralPath $srcDir)) {
            $results += @{ Status = 'error'; Live = $liveRel; Message = "source directory missing: $srcDir" }
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force | Sort-Object FullName)
        foreach ($file in $files) {
            $rel = $file.FullName.Substring($srcDir.Length).TrimStart('\', '/')
            $livePath = Join-Path $HomeRoot (Join-Path $liveBase $rel)
            $content = [System.IO.File]::ReadAllText($file.FullName)
            $results += Invoke-WriteOneFile -LivePath $livePath -Content $content -RepoLabel $repoRel -IsJson $false
        }
        continue
    }

    $srcPath = Join-Path $RepoRoot $repoRel
    if (-not (Test-Path -LiteralPath $srcPath)) {
        $results += @{ Status = 'error'; Live = $liveRel; Message = "source file missing: $srcPath" }
        continue
    }
    $raw = [System.IO.File]::ReadAllText($srcPath)
    $content = if ($kind -eq 'template') { Get-RenderedContent -RawContent $raw -IsJson $isJsonTarget -RepoLabel $repoRel } else { $raw }
    $livePath = Join-Path $HomeRoot $liveRel
    $results += Invoke-WriteOneFile -LivePath $livePath -Content $content -RepoLabel $repoRel -IsJson $isJsonTarget
}

# ----------------------------------------------------------------- summary --
$changed = @($results | Where-Object { $_.Status -eq 'changed' })
$identical = @($results | Where-Object { $_.Status -eq 'identical' })
$wouldChange = @($results | Where-Object { $_.Status -eq 'would-change' })
$errors = @($results | Where-Object { $_.Status -eq 'error' })
foreach ($e in $errors) {
    Write-Error "install error for $($e.Live): $($e.Message)"
}
Write-Host "Summary: $($changed.Count) changed, $($identical.Count) identical, $($wouldChange.Count) would-change, $($errors.Count) errors"
if ($errors.Count -gt 0) { exit 1 }
exit 0
