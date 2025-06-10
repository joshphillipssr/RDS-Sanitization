## Root Module: RdsSanitization.psm1

# Exported functions
Export-ModuleMember -Function Get-RdsUserProfileState, Remove-StaleUserProfiles

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
    query user | ForEach-Object {
        if ($_ -match '^\s*(\S+)\s+(\S+)?\s+(\d+)\s+(\w+)') {
            [PSCustomObject]@{
                Username   = $matches[1]
                Session    = if ($matches[2]) { $matches[2] } else { "-" }
                SessionId  = $matches[3]
                State      = $matches[4]
            }
        }
    } | Format-Table Username, Session, SessionId, State -AutoSize
}

Export-ModuleMember -Function Get-FSLogixStatus, Get-RDSUserSessions
