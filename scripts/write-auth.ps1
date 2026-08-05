# write-auth.ps1
# Seed opencode auth.json with api-type provider keys from secrets.env,
# preserving ALL existing entries (including oauth), then ACL-restrict the
# file to the current user only. Fails closed on any security check.
#
# Dot-sources scripts/manifest.ps1 (single source of truth) for the
# provider env-key -> auth.json provider mapping ($PROVIDER_MAP).

[CmdletBinding()]
param(
  [string]$RepoRoot    = (Split-Path -Parent $PSScriptRoot),
  [string]$HomeRoot    = $env:USERPROFILE,
  [string]$SecretsFile = (Join-Path $RepoRoot 'secrets.env'),
  [string]$DataDir     = (Join-Path $HomeRoot '.local\share\opencode'),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# Never let native stderr (e.g. icacls noise) become a terminating error.
$PSNativeCommandUseErrorActionPreference = $false

function Abort([string]$Message) {
  [Console]::Error.WriteLine("ERROR: write-auth.ps1: $Message")
  exit 1
}

try {
  # --- dot-source the manifest (single source of truth) ---
  $manifestPath = Join-Path $RepoRoot 'scripts\manifest.ps1'
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    Abort "manifest.ps1 not found at '$manifestPath' (RepoRoot='$RepoRoot')"
  }
  . $manifestPath
  if (-not $PROVIDER_MAP -or $PROVIDER_MAP.Count -eq 0) {
    Abort "manifest.ps1 did not define PROVIDER_MAP"
  }

  # --- read api-type provider keys from secrets.env (never echo values) ---
  $provided = @{}
  if (Test-Path -LiteralPath $SecretsFile) {
    Get-Content -LiteralPath $SecretsFile | ForEach-Object {
      $line = $_.Trim()
      if ($line -eq '' -or $line.StartsWith('#')) { return }
      $eq = $line.IndexOf('=')
      if ($eq -lt 1) { return }
      $key   = $line.Substring(0, $eq).Trim()
      $value = $line.Substring($eq + 1).Trim()
      if ($PROVIDER_MAP.ContainsKey($key) -and $value -ne '') {
        $provided[$key] = $value
      }
    }
  } else {
    Write-Warning "SecretsFile '$SecretsFile' not found - no new providers to add."
  }

  # --- load existing auth.json (preserve everything, incl. oauth) ---
  $authPath = Join-Path $DataDir 'auth.json'
  $existing = @{}
  if (Test-Path -LiteralPath $authPath) {
    $raw = Get-Content -LiteralPath $authPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
      Abort "existing auth.json at '$authPath' is empty - refusing to guess; aborting"
    }
    try { $obj = $raw | ConvertFrom-Json } catch {
      Abort "existing auth.json at '$authPath' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -ne $obj) {
      if ($obj -is [string] -or $obj -is [System.Array]) {
        Abort "existing auth.json at '$authPath' has an unexpected shape; aborting"
      }
      $obj.PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value }
    }
  }

  # --- overlay ONLY the provided api keys ---
  $merged = @{}
  foreach ($name in $existing.Keys) { $merged[$name] = $existing[$name] }
  foreach ($envKey in $PROVIDER_MAP.Keys) {
    if ($provided.ContainsKey($envKey)) {
      $merged[$PROVIDER_MAP[$envKey]] = @{ type = 'api'; key = $provided[$envKey] }
    }
  }

  if ($DryRun) {
    if ($merged.Count -eq 0) {
      Write-Host 'DryRun: result contains no providers; nothing would be written.'
    } else {
      Write-Host "DryRun: would write '$authPath' with providers:"
      foreach ($name in ($merged.Keys | Sort-Object)) {
        $t = if ($merged[$name].type) { [string]$merged[$name].type } else { 'unknown' }
        Write-Host ("  - {0} ({1})" -f $name, $t)
      }
    }
    Write-Host 'DryRun: no files written, no ACL changes.'
    exit 0
  }

  if ($merged.Count -eq 0) {
    Write-Host 'No providers to write and no existing auth.json - nothing to do.'
    exit 0
  }

  # --- write JSON (create DataDir if missing) ---
  if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
  }
  $json = $merged | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($authPath, $json, (New-Object System.Text.UTF8Encoding($false)))

  # --- ACL hardening: restrict to the current user ONLY (fail-closed) ---
  if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) {
    Abort "icacls not available - cannot restrict '$authPath' to the current user; aborting (fail-closed)."
  }
  $principal = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { "$env:COMPUTERNAME\$env:USERNAME" }

  & icacls $authPath /inheritance:r /grant:r "$($principal):(R,W)" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Abort "icacls grant failed (exit $LASTEXITCODE) for '$authPath'; aborting (fail-closed)."
  }

  $verifyLines = @(& icacls $authPath)
  if ($LASTEXITCODE -ne 0) {
    Abort "icacls verification failed (exit $LASTEXITCODE) for '$authPath'; aborting (fail-closed)."
  }
  $aces = @((($verifyLines -join "`n") -split '\s+') | Where-Object { $_ -match '^.+:\([^()]*\)$' })
  if ($aces.Count -eq 0) {
    Abort "ACL verification found no access-control entries for '$authPath'; aborting (fail-closed)."
  }
  $allowed  = @($principal, "$env:COMPUTERNAME\$env:USERNAME")
  $foreign  = @()
  foreach ($ace in $aces) {
    $acePrincipal = $ace.Substring(0, $ace.IndexOf(':'))
    $isAllowed = $false
    foreach ($u in $allowed) { if ($acePrincipal -ieq $u) { $isAllowed = $true; break } }
    if (-not $isAllowed) { $foreign += $acePrincipal }
  }
  if ($foreign.Count -gt 0) {
    Abort "ACL verification failed for '$authPath': foreign principal(s) still have access: $($foreign -join ', '); aborting (fail-closed)."
  }

  # --- summary (names/types only - never key values) ---
  Write-Host "auth.json written to '$authPath' with providers:"
  foreach ($name in ($merged.Keys | Sort-Object)) {
    $t = if ($merged[$name].type) { [string]$merged[$name].type } else { 'unknown' }
    Write-Host ("  - {0} ({1})" -f $name, $t)
  }
  Write-Host "Access restricted to '$principal' only (verified via icacls)."
  exit 0
} catch {
  Abort $_.Exception.Message
}
