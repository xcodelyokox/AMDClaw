#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_NAME     = "openclaw-amd-bootstrap"
$SCRIPT_VERSION  = "0.5.0"
$WSL_DISTRO      = "Ubuntu-24.04"
$RESUME_TASK     = "OpenClawAMDBootstrapResume"
$BASH_SCRIPT_URL = "https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh"
$LMSTUDIO_PORT   = if ($env:LMSTUDIO_PORT) { $env:LMSTUDIO_PORT } else { 1234 }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Fatal { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Self-elevate to Administrator if needed
# ---------------------------------------------------------------------------
function Assert-Admin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Info "Not running as Administrator — relaunching elevated..."
        $ps = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $ps
        exit 0
    }
}

# ---------------------------------------------------------------------------
# WSL2 feature installation
# Returns $true if a reboot is required before continuing.
# ---------------------------------------------------------------------------
function Install-WSL2Feature {
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & wsl --version 2>&1
    $wslExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    if ($wslExitCode -eq 0) {
        Write-Info "WSL2 is already installed and ready."
        return $false
    }

    Write-Info "WSL2 not detected — enabling Windows features and installing WSL2 kernel..."

    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
    $vmFeature  = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform

    $needsReboot = $false

    if ($wslFeature.State -ne 'Enabled') {
        Write-Info "Enabling Microsoft-Windows-Subsystem-Linux..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
        if ($result.RestartNeeded) { $needsReboot = $true }
    }

    if ($vmFeature.State -ne 'Enabled') {
        Write-Info "Enabling VirtualMachinePlatform..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
        if ($result.RestartNeeded) { $needsReboot = $true }
    }

    if ($needsReboot) {
        return $true
    }

    Write-Info "Installing WSL2 kernel update..."
    & wsl --install --no-distribution 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { return $true }

    & wsl --set-default-version 2 | Out-Null

    return $false
}

# ---------------------------------------------------------------------------
# Ubuntu 24.04 distro installation
# ---------------------------------------------------------------------------
function Install-UbuntuDistro {
    $rawList = & wsl --list --quiet 2>&1
    $distroList = ($rawList | Out-String).Replace("`0", "")

    if ($distroList -match [regex]::Escape($WSL_DISTRO)) {
        Write-Info "$WSL_DISTRO is already installed."
        return
    }

    Write-Info "Installing $WSL_DISTRO (this may take a few minutes)..."
    & wsl --install -d $WSL_DISTRO --no-launch
    if ($LASTEXITCODE -ne 0) {
        Write-Fatal "Failed to install $WSL_DISTRO. Exit code: $LASTEXITCODE"
    }

    & wsl --set-version $WSL_DISTRO 2 2>&1 | Out-Null

    Write-Host ""
    Write-Info "Ubuntu 24.04 has been installed."
    Write-Info "A Ubuntu terminal window will now open."
    Write-Info "Create your Unix username and password when prompted, then close that window."
    Write-Host ""
    Read-Host "Press Enter to open Ubuntu and begin setup"
    Start-Process wsl.exe -ArgumentList "-d $WSL_DISTRO"

    Write-Host ""
    Read-Host "Once you have finished setting up your Ubuntu username and password, press Enter here to continue"
    Write-Host ""
    Write-Info "$WSL_DISTRO setup complete."
}

# ---------------------------------------------------------------------------
# Reboot-resume via a one-shot scheduled task
# ---------------------------------------------------------------------------
function Register-ResumeTask {
    Write-Info "Registering post-reboot resume task: $RESUME_TASK"
    $action   = New-ScheduledTaskAction `
                    -Execute "powershell.exe" `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask `
        -TaskName $RESUME_TASK `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -RunLevel Highest `
        -Force | Out-Null
}

function Remove-ResumeTask {
    if (Get-ScheduledTask -TaskName $RESUME_TASK -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $RESUME_TASK -Confirm:$false
        Write-Info "Removed post-reboot resume task."
    }
}

# ---------------------------------------------------------------------------
# Detect LM Studio endpoint and determine the host IP for WSL2 access.
# Returns the base URL (e.g. http://172.x.x.x:1234/v1).
# ---------------------------------------------------------------------------
function Find-LMStudioEndpoint {
    # 1. Verify LM Studio API is reachable on localhost
    Write-Info "Checking if LM Studio is running on port $LMSTUDIO_PORT..."
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:$LMSTUDIO_PORT/v1/models" -TimeoutSec 5
        $modelCount = 0
        if ($response.data) { $modelCount = $response.data.Count }
        Write-Info "LM Studio API is reachable with $modelCount model(s) loaded."
        if ($modelCount -eq 0) {
            Write-Warn "No models are loaded in LM Studio. Please load a model before continuing."
            Read-Host "Press Enter after loading a model in LM Studio"
            $response = Invoke-RestMethod -Uri "http://localhost:$LMSTUDIO_PORT/v1/models" -TimeoutSec 5
            if (-not $response.data -or $response.data.Count -eq 0) {
                Write-Fatal "Still no models loaded in LM Studio. Load a model and rerun."
            }
        }
    } catch {
        Write-Fatal "LM Studio is not reachable at http://localhost:$LMSTUDIO_PORT/v1/models. Please start LM Studio, load a model, ensure 'Serve on Local Network' is enabled, and rerun this script."
    }

    # 2. Determine Windows host IP that WSL2 can reach
    $hostIP = $null

    # Try the vEthernet (WSL) adapter first
    $wslAdapter = Get-NetIPAddress -InterfaceAlias "vEthernet (WSL)*" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Select-Object -First 1
    if ($wslAdapter) {
        $hostIP = $wslAdapter.IPAddress
        Write-Info "Found WSL virtual adapter IP: $hostIP"
    }

    # Fallback: first non-loopback IPv4
    if (-not $hostIP) {
        $fallback = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } |
                    Select-Object -First 1
        if ($fallback) {
            $hostIP = $fallback.IPAddress
            Write-Info "Using fallback IP: $hostIP"
        }
    }

    if (-not $hostIP) {
        Write-Fatal "Could not determine a host IP for WSL2 to reach LM Studio. Set LMSTUDIO_BASE_URL manually."
    }

    $baseUrl = "http://${hostIP}:${LMSTUDIO_PORT}"

    # 3. Test connectivity from WSL2
    Write-Info "Testing LM Studio connectivity from WSL2..."
    $testResult = & wsl -d $WSL_DISTRO -- bash -c "curl -fsS --max-time 5 '$baseUrl/v1/models' >/dev/null 2>&1 && echo OK || echo FAIL" 2>&1
    $testStr = ($testResult | Out-String).Trim()

    if ($testStr -ne "OK") {
        Write-Warn "LM Studio is not reachable from WSL2 at $baseUrl"
        Write-Warn "This is usually caused by Windows Firewall blocking inbound connections on port $LMSTUDIO_PORT."
        Write-Host ""
        $answer = Read-Host "Add a firewall rule to allow port $LMSTUDIO_PORT? [Y/n]"
        if ($answer -notmatch '^[Nn]') {
            New-NetFirewallRule `
                -DisplayName "LM Studio API (WSL2)" `
                -Direction Inbound `
                -LocalPort $LMSTUDIO_PORT `
                -Protocol TCP `
                -Action Allow `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Info "Firewall rule added. Retesting..."

            $retestResult = & wsl -d $WSL_DISTRO -- bash -c "curl -fsS --max-time 5 '$baseUrl/v1/models' >/dev/null 2>&1 && echo OK || echo FAIL" 2>&1
            $retestStr = ($retestResult | Out-String).Trim()
            if ($retestStr -ne "OK") {
                Write-Fatal "LM Studio is still not reachable from WSL2 at $baseUrl. Ensure 'Serve on Local Network' is enabled in LM Studio settings and that it listens on 0.0.0.0."
            }
        } else {
            Write-Warn "Skipping firewall rule. The bash script will retry connectivity from inside WSL."
        }
    }

    Write-Info "LM Studio endpoint for WSL2: $baseUrl"
    return $baseUrl
}

# ---------------------------------------------------------------------------
# Run the bash script inside WSL2, forwarding the LM Studio base URL.
# ---------------------------------------------------------------------------
function Invoke-BashScript {
    param([string]$LMStudioBaseURL)

    Write-Info "Launching openclaw-amd.sh inside $WSL_DISTRO..."

    # Build env var prefix — forward all overrides the bash script supports
    $envParts = @("LMSTUDIO_BASE_URL='$LMStudioBaseURL'")

    $forwardVars = @(
        'OPENCLAW_AMD_MODEL_ID',
        'OPENCLAW_AMD_CONTEXT_TOKENS',
        'OPENCLAW_AMD_MODEL_MAX_TOKENS',
        'OPENCLAW_AMD_MAX_AGENTS',
        'OPENCLAW_AMD_MAX_SUBAGENTS',
        'OPENCLAW_AMD_GATEWAY_PORT',
        'OPENCLAW_AMD_GATEWAY_BIND',
        'OPENCLAW_AMD_SKIP_TUNING',
        'LMSTUDIO_PORT'
    )

    foreach ($varName in $forwardVars) {
        $val = [Environment]::GetEnvironmentVariable($varName)
        if ($val) {
            $envParts += "$varName='$val'"
        }
    }

    $envPrefix = $envParts -join ' '

    & wsl -d $WSL_DISTRO -- bash -lc "$envPrefix curl -fsSL '$BASH_SCRIPT_URL' | bash"

    if ($LASTEXITCODE -eq 10) {
        # Exit code 10 = bash script enabled systemd and asked for wsl --shutdown
        Write-Info "WSL restarting to activate systemd..."
        & wsl --shutdown
        Start-Sleep -Seconds 3
        Write-Info "Resuming openclaw-amd.sh after systemd restart..."
        & wsl -d $WSL_DISTRO -- bash -lc "$envPrefix curl -fsSL '$BASH_SCRIPT_URL' | bash"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Fatal "openclaw-amd.sh failed (exit $LASTEXITCODE). Check the output above."
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-Admin

# If we resumed after reboot, clean up the scheduled task first
Remove-ResumeTask

# Step 1 — WSL2
$rebootRequired = Install-WSL2Feature
if ($rebootRequired) {
    Register-ResumeTask
    Write-Warn "A reboot is required to finish enabling WSL2."
    Write-Warn "This script will resume automatically after you log back in."
    $answer = Read-Host "Reboot now? [Y/n]"
    if ($answer -notmatch '^[Nn]') {
        Restart-Computer -Force
    } else {
        Write-Info "Reboot skipped. Rerun this script after rebooting."
    }
    exit 0
}

# Step 2 — Ubuntu 24.04
Install-UbuntuDistro

# Step 3 — Detect LM Studio and get endpoint URL for WSL2
$lmStudioUrl = Find-LMStudioEndpoint

# Step 4 — openclaw-amd.sh
Invoke-BashScript -LMStudioBaseURL $lmStudioUrl

Write-Info "$SCRIPT_NAME $SCRIPT_VERSION complete."
