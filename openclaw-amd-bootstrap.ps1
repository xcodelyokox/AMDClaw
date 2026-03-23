#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_NAME     = "openclaw-amd-bootstrap"
$SCRIPT_VERSION  = "0.1.0"
$WSL_DISTRO      = "Ubuntu-24.04"
$RESUME_TASK     = "OpenClawAMDBootstrapResume"
$BASH_SCRIPT_URL = "https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh"

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
    # wsl --version is only available when the Store version of WSL is installed
    # and the kernel is ready. Use it as the "all good" signal.
    $ver = & wsl --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "WSL2 is already installed and ready."
        return $false
    }

    Write-Info "WSL2 not detected — enabling Windows features and installing WSL2 kernel..."

    # Enable the two required Windows optional features
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

    # Features already enabled — install/update the WSL2 kernel package from the Store
    Write-Info "Installing WSL2 kernel update..."
    & wsl --install --no-distribution 2>&1 | Write-Host
    # wsl --install may itself signal a reboot requirement; treat any failure as needing one
    if ($LASTEXITCODE -ne 0) { return $true }

    # Set WSL 2 as the default version
    & wsl --set-default-version 2 | Out-Null

    return $false
}

# ---------------------------------------------------------------------------
# Ubuntu 24.04 distro installation
# ---------------------------------------------------------------------------
function Install-UbuntuDistro {
    # wsl --list --quiet outputs UTF-16LE; strip null bytes before matching
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

    # Ensure WSL 2 is used for this distro
    & wsl --set-version $WSL_DISTRO 2 2>&1 | Out-Null

    # Launch Ubuntu in a new window so the user can complete the OOBE
    # (create a Unix username and password)
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
# Run the bash script inside WSL2 as the default user.
# sudo will prompt for the user's password wherever the bash script needs it.
# ---------------------------------------------------------------------------
function Invoke-BashScript {
    Write-Info "Launching openclaw-amd.sh inside $WSL_DISTRO..."

    # Pull and run the bash script as the default (non-root) user
    & wsl -d $WSL_DISTRO -- bash -lc "curl -fsSL '$BASH_SCRIPT_URL' | bash"

    if ($LASTEXITCODE -eq 10) {
        # Exit code 10 = bash script enabled systemd and asked for wsl --shutdown
        Write-Info "WSL restarting to activate systemd..."
        & wsl --shutdown
        Start-Sleep -Seconds 3
        Write-Info "Resuming openclaw-amd.sh after systemd restart..."
        & wsl -d $WSL_DISTRO -- bash -lc "curl -fsSL '$BASH_SCRIPT_URL' | bash"
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

# Step 3 — openclaw-amd.sh
Invoke-BashScript

Write-Info "$SCRIPT_NAME $SCRIPT_VERSION complete."
