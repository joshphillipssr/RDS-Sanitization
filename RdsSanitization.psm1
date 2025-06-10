## Root Module: RdsSanitization.psm1

# Internal helper functions would be dot-sourced here or defined inline in a complete layout

## Function: Get-RdsUserProfileState
function Get-RdsUserProfileState {
    <#
    .SYNOPSIS
        Audits user profiles on the local RDS server.

    .DESCRIPTION
        Returns information on FSLogix status, local fallback profiles, profile age, etc.
    #>
    $profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.Special -eq $false }

    foreach ($profile in $profiles) {
        $userName = ($profile.LocalPath -split '\\')[-1]
        $isLoaded = $profile.Loaded
        $isLocal = $profile.LocalPath -like '*local_*'

        [PSCustomObject]@{
            UserName  = $userName
            ProfilePath = $profile.LocalPath
            IsLoaded = $isLoaded
            IsFallback = $isLocal
            LastUsed = $profile.LastUseTime
        }
    }
}

## Function: Remove-StaleUserProfiles
function Remove-StaleUserProfiles {
    <#
    .SYNOPSIS
        Removes stale fallback profiles from the system.

    .DESCRIPTION
        Deletes profiles not loaded, matching 'local_*' pattern, and older than a threshold.
    #>
    param(
        [int]$DaysOld = 3
    )

    $cutoff = (Get-Date).AddDays(-$DaysOld)
    $profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
        $_.LocalPath -like '*local_*' -and $_.Loaded -eq $false -and $_.LastUseTime -lt $cutoff
    }

    foreach ($profile in $profiles) {
        try {
            Write-Host "Removing profile: $($profile.LocalPath)" -ForegroundColor Cyan
            Remove-CimInstance -InputObject $profile
        }
        catch {
            Write-Warning "Failed to remove $($profile.LocalPath): $_"
        }
    }
}

function Get-FSLogixDiagnostics {
    <#
    .SYNOPSIS
    Retrieves basic FSLogix service status and config.

    .OUTPUTS
    Object with FSLogix service and config summary.
    #>
    [CmdletBinding()]
    param ()

    $service = Get-Service -Name frxsvc -ErrorAction SilentlyContinue
    $configPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
    $config = Get-ItemProperty -Path $configPath -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        ServiceStatus   = $service.Status
        RedirTemp       = $config.RedirTemp
        VHDLocations    = $config.VHDLocations -join "; "
        Enabled         = $config.Enabled
    }
}

function Get-FSLogixProfileEvents {
    <#
    .SYNOPSIS
    Fetches FSLogix profile load/unload events (IDs 25, 26, 27, 28, 31, 32, 57).

    .PARAMETER Username
    Optionally filter by username.

    .PARAMETER Days
    Days back to search in the event log.

    .OUTPUTS
    Event log entries.
    #>
    [CmdletBinding()]
    param (
        [string]$Username,
        [int]$Days = 3
    )

    $filterHashtable = @{
        LogName   = 'Microsoft-FSLogix-Apps/Operational'
        Id        = @(25, 26, 27, 28, 31, 32, 57)
        StartTime = (Get-Date).AddDays(-$Days)
    }

    $events = Get-WinEvent -FilterHashtable $filterHashtable -ErrorAction SilentlyContinue |
        Where-Object {
            if ($Username) {
                $_.Message -match $Username
            } else {
                $true
            }
        }

    return $events
}

function Test-FSLogixTempRedirection {
    <#
    .SYNOPSIS
    Verifies if RedirTemp is enabled and inspects folder status for each profile.

    .OUTPUTS
    Redirection status per active profile.
    #>
    [CmdletBinding()]
    param ()

    $profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.Loaded -eq $true }

    foreach ($profile in $profiles) {
        $user = $profile.LocalPath -split '\\' | Select-Object -Last 1
        $localTemp = "C:\Users\local_$user"
        $exists = Test-Path $localTemp

        [PSCustomObject]@{
            User          = $user
            LocalTempPath = $localTemp
            Exists        = $exists
        }
    }
}

function Get-FSLogixStatus {
    # Checks if FSLogix is installed and service is running
    $service = Get-Service -Name frxsvc -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Output "FSLogix is not installed."
    } else {
        Write-Output "FSLogix Service Status: $($service.Status)"
    }
}

function Get-RDSUserSessions {
    $sessions = quser 2>&1

    if ($sessions -is [System.Management.Automation.ErrorRecord]) {
        Write-Error "Failed to execute 'quser'. Ensure the command is available and you're running with appropriate permissions."
        return
    }

    $parsed = $sessions | Select-Object -Skip 1 | ForEach-Object {
        $line = $_ -replace "^>\s*", "" -replace "\s{2,}", ","
        $parts = $line.Split(",")

        [PSCustomObject]@{
            Username     = $parts[0].Trim()
            SessionName  = if ($parts[1] -match '^(\d+)$') { "-" } else { $parts[1].Trim() }
            SessionId    = if ($parts[1] -match '^(\d+)$') { [int]$parts[1] } else { [int]$parts[2] }
            State        = switch -Wildcard ($line) {
                "*Disc*" { "Disconnected"; break }
                "*Active*" { "Active"; break }
                "*Idle*" { "Idle"; break }
                default { "Unknown" }
            }
        }
    }

    $parsed | Format-Table -AutoSize
}


function Disconnect-RDSUserSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [switch]$All,

        [Parameter(Mandatory=$false)]
        [string[]]$Username
    )

    $sessions = (quser) -replace '\s{2,}', ',' | ConvertFrom-Csv -Header 'USERNAME','SESSIONNAME','ID','STATE','IDLE','LOGON_TIME'
    $disconnectedSessions = $sessions | Where-Object { $_.STATE -eq 'Disc' }

    if ($Username) {
        $disconnectedSessions = $disconnectedSessions | Where-Object { $Username -contains $_.USERNAME }
    }

    foreach ($session in $disconnectedSessions) {
        Write-Host "Logging off user '$($session.USERNAME)' (Session ID: $($session.ID))..." -ForegroundColor Yellow
        try {
            logoff $session.ID
            Write-Host "Successfully logged off Session ID $($session.ID)" -ForegroundColor Green
        } catch {
            Write-Host "Failed to log off Session ID $($session.ID): $_" -ForegroundColor Red
        }
    }

    if (-not $disconnectedSessions) {
        Write-Host "No matching disconnected sessions found." -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function Get-RdsUserProfileState, Remove-StaleUserProfiles, Get-FSLogixStatus, Get-RDSUserSessions, Disconnect-RDSUserSession, Get-FSLogixDiagnostics, Get-FSLogixProfileEvents, Test-FSLogixTempRedirection
