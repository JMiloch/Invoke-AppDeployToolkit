[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

$adtSession = @{
    # App variables.
    AppName    = ''
    AppVendor  = ''
    AppVersion = ''

    # Use if the AppName or AppVendor deviate from the standard display name
    appNameControlPanel   = ''     # Set if display name in Control Panel differs from AppName
    appVendorControlPanel = ''     # Set if publisher in Control Panel differs from AppVendor

    AppArch             = 'x64'
    AppLang             = 'MUI'
    AppRevision         = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes  = @(1641, 3010)
    AppProcessesToClose = @()      # Example: @('excel', @{ Name = 'winword'; Description = 'Microsoft Word' })
    AppScriptVersion    = '1.0.0'
    AppScriptDate       = (Get-Date -Format 'yyyy-MM-dd')
    AppScriptAuthor     = ''       # Packager name or team
    RequireAdmin        = $true

    # Install Titles (only set to override toolkit defaults)
    InstallName  = ''
    InstallTitle = ''

    # Script variables
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters
    DeployAppScriptVersion      = '4.1.7'

    ##================================================
    ## MARK: Package Configuration
    ##================================================

    PSADTAppID   = 'APP000001'           # APP + 6-digit consecutive number
    ProcessToStop = @{ Name = 'null' }   # Process to close before install. Example: @{ Name = 'winword' }

    # --- Installation ---
    StandardInstall        = $true       # $false = use Management Point-aware routing
    installFileName        = ''          # .msi or .exe filename from .\Files\ folder
    customInstallParameter = ''          # e.g. '/qn /norestart REBOOT=ReallySuppress' or '/s'
    transforms             = ''          # MST transform filename (optional)
    ignoreExitCodes        = ''          # Comma-separated exit codes to treat as success (EXE only)

    # --- Application Verification (Check-Application) ---
    # All checks are optional. Enable only what applies to this package.
    CheckAppbyDefault     = $true        # Run verification before and after install
    mainExecutablePath    = ''           # Full path to main EXE: 'C:\Program Files\Vendor\app.exe'
    appVersionCheck       = ''           # Expected version string, e.g. '1.0.0.123'
    useFileVersion        = $true        # $true = FileVersion, $false = ProductVersion

    # Registry check (optional)
    checkRegistryHive      = 'HKLM'     # HKLM or HKCU
    checkRegistryKey       = ''          # e.g. 'Software\Vendor\AppName'
    checkRegistryValueName = ''          # Registry value name to check
    checkRegistryValueData = ''          # Expected value data

    # MSI GUID check (optional, MSI packages only)
    CheckMSIGuid = ''                    # e.g. '{90160000-000F-0000-1000-0000000FF1CE}'

    # --- Uninstallation ---
    unInstallFileName        = ''        # Leave empty for auto-detect. Set to EXE path for custom uninstallers.
    customUninstallParameter = ''        # Uninstall silent switch, e.g. '/quiet' or '/S'
}

##================================================
## Global Variables
##================================================
[string]$global:CompanyName      = 'Company' # <---- Change to your Company
[string]$global:DeployInvRegPath = "HKEY_LOCAL_MACHINE\Software\$CompanyName\Deployment"
$global:PSADTPackageName         = "$($adtSession.AppVendor)_$($adtSession.AppName)_$($adtSession.AppVersion)_$($adtSession.AppArch)_$($adtSession.AppLang)_$($adtSession.AppRevision)"
$global:CompDomain               = (Get-WmiObject Win32_ComputerSystem).Domain

##================================================
## MARK: Install
##================================================
function Install-ADTDeployment
{
    [CmdletBinding()]
    param()

    ##--------------------------------------------
    ## Pre-Install
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    Set-DeploymentInventoryRegPath
    Show-ADTInstallationWelcome -CheckDiskSpace
    Show-ADTInstallationWelcome -CloseProcesses $($adtSession.ProcessToStop) -Silent

    # Application state check
    if ($adtSession.CheckAppbyDefault) {
        Write-ADTLogEntry -Message "Checking application state before installation..." -Severity 1
        $checkApplicationResult = Check-Application

        if ($checkApplicationResult -eq 'Error') {
            Write-ADTLogEntry -Message "Pre-install check failed with error. Aborting." -Severity 3
            Close-ADTSession -ExitCode 70002
            return
        }
    }
    else {
        Write-ADTLogEntry -Message "Application check skipped (CheckAppbyDefault = false)" -Severity 1
        $checkApplicationResult = 'NotInstalled'
    }

    ## <Add Pre-Installation tasks here>

    ##--------------------------------------------
    ## Install
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -WindowTitle "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    if ($adtSession.StandardInstall) {
        # Standard installation (auto-routing based on file extension)
        if ($checkApplicationResult -eq 'NotInstalled') {
            Write-ADTLogEntry -Message "Starting standard installation..." -Severity 1
            Install-Application
        }
        else {
            Write-ADTLogEntry -Message "Application already installed. Skipping." -Severity 1
        }
    }
    else {
        # Management Point-aware installation
        # Use when installation behavior differs per SCCM site
        if ($checkApplicationResult -eq 'NotInstalled') {
            Write-ADTLogEntry -Message "Starting MP-aware installation..." -Severity 1

            $SMSDPMP = Get-ADTRegistryKey -Key 'HKLM:SOFTWARE\Microsoft\SMS\DP' -Name 'ManagementPoints'

            if ([string]::IsNullOrWhiteSpace($SMSDPMP)) {
                Write-ADTLogEntry -Message "No Management Point found in registry. Cannot continue." -Severity 3
                Close-ADTSession -ExitCode 70003
                return
            }

            Write-ADTLogEntry -Message "Management Point detected: $SMSDPMP"

            switch ($SMSDPMP) {
                "SiteServer-HQ" {
                    Write-ADTLogEntry -Message "Using HQ site server: $SMSDPMP"
                    # Add HQ-specific install actions here
                }
                "SiteServer-North" {
                    Write-ADTLogEntry -Message "Using North site server: $SMSDPMP"
                    # Add regional install actions here
                }
                "SiteServer-South" {
                    Write-ADTLogEntry -Message "Using South site server: $SMSDPMP"
                    # Add regional install actions here
                }
                default {
                    Write-ADTLogEntry -Message "Unknown Management Point: $SMSDPMP" -Severity 2
                }
            }
        }
        else {
            Write-ADTLogEntry -Message "Application already installed. Skipping." -Severity 1
        }
    }

    ## <Add Post-Installation tasks here>

    ##--------------------------------------------
    ## Post-Install — Verification
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    if ($adtSession.CheckAppbyDefault) {
        Write-ADTLogEntry -Message "Verifying installation..." -Severity 1
        $verifyResult = Check-Application

        switch ($verifyResult) {
            'Installed' {
                Write-ADTLogEntry -Message "Installation verified successfully." -Severity 1
                Register-AppInstallation
                Register-SuccessOfAppInstallation
                Write-ADTLogEntry -Message "$($adtSession.AppVendor) $($adtSession.AppName) $($adtSession.AppVersion) — installed." -Severity 1
                Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Installation complete.' -ButtonRightText 'OK' -NoWait -Timeout 5
            }
            'NotInstalled' {
                Write-ADTLogEntry -Message "Post-install verification failed — application not found." -Severity 3
                Close-ADTSession -ExitCode 70001
            }
            'Error' {
                Write-ADTLogEntry -Message "Post-install verification check threw an error." -Severity 3
                Close-ADTSession -ExitCode 70002
            }
        }
    }
    else {
        Write-ADTLogEntry -Message "Application check skipped (CheckAppbyDefault = false)" -Severity 1
        Register-AppInstallation
        Register-SuccessOfAppInstallation
        Write-ADTLogEntry -Message "Installation completed." -Severity 1
        Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Installation complete.' -ButtonRightText 'OK' -NoWait -Timeout 5
    }
}

##================================================
## MARK: Uninstall
##================================================
function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param()

    ##--------------------------------------------
    ## Pre-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    Show-ADTInstallationWelcome -CloseProcesses $($adtSession.ProcessToStop) -Silent

    ## <Add Pre-Uninstallation tasks here>

    ##--------------------------------------------
    ## Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -WindowTitle "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    Uninstall-Application

    ##--------------------------------------------
    ## Post-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
    Unregister-Installation
    Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Uninstall complete.' -ButtonRightText 'OK' -NoWait -Timeout 5

    ## <Add Post-Uninstallation tasks here>
}

##================================================
## MARK: Repair
##================================================
function Repair-ADTDeployment
{
    [CmdletBinding()]
    param()

    ##--------------------------------------------
    ## Pre-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    Show-ADTInstallationWelcome -CloseProcesses $($adtSession.ProcessToStop) -Silent

    ## <Add Pre-Repair tasks here>

    ##--------------------------------------------
    ## Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -WindowTitle "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    ## <Add Repair tasks here>

    ##--------------------------------------------
    ## Post-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Add Post-Repair tasks here>

    Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Repair complete.' -ButtonRightText 'OK' -NoWait -Timeout 5
}


##================================================
## MARK: Functions
##================================================

##------------------------------------------------
## Install-Application
## Auto-detects .msi or .exe and routes accordingly
##------------------------------------------------
Function Install-Application {
    [CmdletBinding()]
    param()

    try {
        Write-ADTLogEntry -Message "Source folder: $($adtSession.DirFiles)"
        Write-ADTLogEntry -Message "Install file: $($adtSession.installFileName)"

        $installFilePath = Join-Path -Path $adtSession.DirFiles -ChildPath $adtSession.installFileName
        Write-ADTLogEntry -Message "Full path: $installFilePath"

        if (-not (Test-Path -Path $installFilePath)) {
            Write-ADTLogEntry -Message "Installation file not found: $installFilePath" -Severity 3
            throw "Installation file not found: $installFilePath"
        }

        $fileExtension = (Get-Item $installFilePath).Extension.ToLower()
        Write-ADTLogEntry -Message "Detected file type: $fileExtension"

        switch ($fileExtension) {
            '.msi' {
                $splatParams = @{ Action = 'Install'; FilePath = $installFilePath }

                if (-not [string]::IsNullOrWhiteSpace($adtSession.transforms)) {
                    $mstFilePath = Join-Path -Path $adtSession.DirFiles -ChildPath $adtSession.transforms
                    if (Test-Path -Path $mstFilePath) {
                        $splatParams['Transforms'] = $mstFilePath
                        Write-ADTLogEntry -Message "Applying MST transform: $($adtSession.transforms)"
                    }
                    else {
                        Write-ADTLogEntry -Message "Transform file not found: $mstFilePath" -Severity 2
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($adtSession.customInstallParameter)) {
                    $splatParams['ArgumentList'] = $adtSession.customInstallParameter
                    Write-ADTLogEntry -Message "Custom parameters: $($adtSession.customInstallParameter)"
                }

                Write-ADTLogEntry -Message "Installing (MSI): $($adtSession.AppName)"
                Start-ADTMsiProcess @splatParams
            }

            '.exe' {
                $splatParams = @{ FilePath = $installFilePath }

                if (-not [string]::IsNullOrWhiteSpace($adtSession.customInstallParameter)) {
                    $splatParams['ArgumentList'] = $adtSession.customInstallParameter
                    Write-ADTLogEntry -Message "Custom parameters: $($adtSession.customInstallParameter)"
                }

                if (-not [string]::IsNullOrWhiteSpace($adtSession.ignoreExitCodes)) {
                    $splatParams['IgnoreExitCodes'] = $adtSession.ignoreExitCodes
                    Write-ADTLogEntry -Message "Ignoring exit codes: $($adtSession.ignoreExitCodes)"
                }

                Write-ADTLogEntry -Message "Installing (EXE): $($adtSession.AppName)"
                Start-ADTProcess @splatParams
            }

            default {
                Write-ADTLogEntry -Message "Unsupported file extension: $fileExtension" -Severity 3
                throw "Unsupported file extension: $fileExtension. Supported: .msi, .exe"
            }
        }

        Write-ADTLogEntry -Message "$($adtSession.AppName) installation completed." -Severity 1
    }
    catch {
        Write-ADTLogEntry -Message "Install-Application failed: $($_.Exception.Message)" -Severity 3
        throw
    }
}

##------------------------------------------------
## Uninstall-Application
## Auto-detects uninstall method from config
##------------------------------------------------
Function Uninstall-Application {
    [CmdletBinding()]
    param()

    try {
        Write-ADTLogEntry -Message "Starting Uninstall-Application" -Severity 1

        # Resolve display names (use Control Panel variants if specified)
        [string]$appNameToSearch = if (-not [string]::IsNullOrWhiteSpace($adtSession.appNameControlPanel)) {
            Write-ADTLogEntry -Message "Using Control Panel app name: $($adtSession.appNameControlPanel)"
            $adtSession.appNameControlPanel
        }
        else {
            Write-ADTLogEntry -Message "Using app name: $($adtSession.appName)"
            $adtSession.appName
        }

        [string]$vendorToSearch = if (-not [string]::IsNullOrWhiteSpace($adtSession.appVendorControlPanel)) {
            Write-ADTLogEntry -Message "Using Control Panel vendor: $($adtSession.appVendorControlPanel)"
            $adtSession.appVendorControlPanel
        }
        else {
            Write-ADTLogEntry -Message "Using vendor: $($adtSession.appVendor)"
            $adtSession.appVendor
        }

        $splatParams = @{ Verbose = $true }

        # Route 1: Custom EXE uninstaller
        if (-not [string]::IsNullOrWhiteSpace($adtSession.unInstallFileName)) {
            Write-ADTLogEntry -Message "Using custom EXE uninstaller: $($adtSession.unInstallFileName)"
            $splatParams['ApplicationType'] = 'EXE'
            $splatParams['FilterScript']    = { $_.DisplayName -like "*$appNameToSearch*" }.GetNewClosure()

            if (-not [string]::IsNullOrWhiteSpace($adtSession.customUninstallParameter)) {
                $splatParams['ArgumentList'] = $adtSession.customUninstallParameter
            }
        }
        # Route 2: Auto-detect by name and/or vendor
        else {
            if (-not [string]::IsNullOrWhiteSpace($appNameToSearch) -and -not [string]::IsNullOrWhiteSpace($vendorToSearch)) {
                $splatParams['FilterScript'] = {
                    ($_.DisplayName -like "*$appNameToSearch*") -and ($_.Publisher -like "*$vendorToSearch*")
                }.GetNewClosure()
                Write-ADTLogEntry -Message "Auto-detecting by name '$appNameToSearch' AND vendor '$vendorToSearch'"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($appNameToSearch)) {
                $splatParams['Name'] = $appNameToSearch
                Write-ADTLogEntry -Message "Auto-detecting by name: '$appNameToSearch'"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($vendorToSearch)) {
                $splatParams['FilterScript'] = { $_.Publisher -like "*$vendorToSearch*" }.GetNewClosure()
                Write-ADTLogEntry -Message "Auto-detecting by vendor: '$vendorToSearch'"
            }
            else {
                Write-ADTLogEntry -Message "Insufficient information for uninstallation." -Severity 3
                throw "AppName and AppVendor are both empty — cannot auto-detect uninstaller"
            }

            if (-not [string]::IsNullOrWhiteSpace($adtSession.customUninstallParameter)) {
                $splatParams['ArgumentList'] = $adtSession.customUninstallParameter
            }
        }

        Uninstall-ADTApplication @splatParams
        Write-ADTLogEntry -Message "Uninstallation completed successfully." -Severity 1
    }
    catch {
        Write-ADTLogEntry -Message "Uninstall-Application failed: $($_.Exception.Message)" -Severity 3
        throw
    }
}

##------------------------------------------------
## Check-Application
## 5-layer verification: Name → ControlPanel → Executable+Version → Registry → MSI GUID
## Returns: 'Installed' | 'NotInstalled' | 'Error'
##------------------------------------------------
Function Check-Application {
    [CmdletBinding()]
    param()

    try {
        Write-ADTLogEntry -Message "======== Check-Application START ========" -Severity 1
        Write-ADTLogEntry -Message "Target: $($adtSession.appName)" -Severity 1

        # Layer 1: Application Name
        Write-ADTLogEntry -Message "--- Layer 1: App Name Check ---" -Severity 1
        if (-not (Get-ADTApplication -Name $adtSession.appName)) {
            Write-ADTLogEntry -Message "NOT FOUND: '$($adtSession.appName)'" -Severity 2
            return 'NotInstalled'
        }
        Write-ADTLogEntry -Message "FOUND: '$($adtSession.appName)'" -Severity 1

        # Layer 2: Control Panel Name (optional)
        if (-not [string]::IsNullOrWhiteSpace($adtSession.appNameControlPanel)) {
            Write-ADTLogEntry -Message "--- Layer 2: Control Panel Name Check ---" -Severity 1
            $cpApp = Get-ADTApplication -Name $adtSession.appNameControlPanel

            if (-not $cpApp -or $cpApp.DisplayName -ne $adtSession.appNameControlPanel) {
                Write-ADTLogEntry -Message "NOT FOUND: Control Panel name '$($adtSession.appNameControlPanel)'" -Severity 2
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "FOUND: Control Panel name verified" -Severity 1
        }

        # Layer 3: Main Executable + Version (optional)
        if (-not [string]::IsNullOrWhiteSpace($adtSession.mainExecutablePath)) {
            Write-ADTLogEntry -Message "--- Layer 3: Executable Check ---" -Severity 1

            if (-not (Test-Path -Path $adtSession.mainExecutablePath -PathType Leaf)) {
                Write-ADTLogEntry -Message "NOT FOUND: '$($adtSession.mainExecutablePath)'" -Severity 2
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "FOUND: Executable exists" -Severity 1

            if (-not [string]::IsNullOrWhiteSpace($adtSession.appVersionCheck)) {
                $versionInfo  = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($adtSession.mainExecutablePath)
                $actualVersion = if ($adtSession.useFileVersion) { $versionInfo.FileVersion } else { $versionInfo.ProductVersion }

                Write-ADTLogEntry -Message "FileVersion: '$($versionInfo.FileVersion)' | ProductVersion: '$($versionInfo.ProductVersion)'"
                Write-ADTLogEntry -Message "Using: $(if ($adtSession.useFileVersion) { 'FileVersion' } else { 'ProductVersion' }) = '$actualVersion'"
                Write-ADTLogEntry -Message "Expected: '$($adtSession.appVersionCheck)'"

                if ($actualVersion -ne $adtSession.appVersionCheck) {
                    Write-ADTLogEntry -Message "VERSION MISMATCH: found '$actualVersion', expected '$($adtSession.appVersionCheck)'" -Severity 2
                    return 'NotInstalled'
                }
                Write-ADTLogEntry -Message "Version check passed." -Severity 1
            }
        }

        # Layer 4: Registry (optional)
        if (-not [string]::IsNullOrWhiteSpace($adtSession.checkRegistryKey)) {
            Write-ADTLogEntry -Message "--- Layer 4: Registry Check ---" -Severity 1

            $hive = if (-not [string]::IsNullOrWhiteSpace($adtSession.checkRegistryHive)) { $adtSession.checkRegistryHive } else { 'HKLM' }
            $fullRegPath = switch ($hive.ToUpper()) {
                'HKLM' { "HKLM:\$($adtSession.checkRegistryKey)" }
                'HKCU' { "HKCU:\$($adtSession.checkRegistryKey)" }
                default {
                    Write-ADTLogEntry -Message "Invalid registry hive: '$hive'. Use HKLM or HKCU." -Severity 3
                    return 'Error'
                }
            }

            if (-not (Test-Path -Path $fullRegPath -PathType Container)) {
                Write-ADTLogEntry -Message "NOT FOUND: Registry key '$fullRegPath'" -Severity 2
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "FOUND: Registry key exists" -Severity 1

            if (-not [string]::IsNullOrWhiteSpace($adtSession.checkRegistryValueName)) {
                try {
                    $regValue    = Get-ItemProperty -Path $fullRegPath -Name $adtSession.checkRegistryValueName -ErrorAction Stop
                    $actualData  = $regValue.$($adtSession.checkRegistryValueName)
                    Write-ADTLogEntry -Message "Value '$($adtSession.checkRegistryValueName)' = '$actualData'"

                    if (-not [string]::IsNullOrWhiteSpace($adtSession.checkRegistryValueData)) {
                        if ($actualData -ne $adtSession.checkRegistryValueData) {
                            Write-ADTLogEntry -Message "VALUE MISMATCH: found '$actualData', expected '$($adtSession.checkRegistryValueData)'" -Severity 2
                            return 'NotInstalled'
                        }
                        Write-ADTLogEntry -Message "Registry value data check passed." -Severity 1
                    }
                }
                catch {
                    Write-ADTLogEntry -Message "NOT FOUND: Registry value '$($adtSession.checkRegistryValueName)'" -Severity 2
                    return 'NotInstalled'
                }
            }
        }

        # Layer 5: MSI GUID (optional)
        if (-not [string]::IsNullOrWhiteSpace($adtSession.CheckMSIGuid)) {
            Write-ADTLogEntry -Message "--- Layer 5: MSI GUID Check ---" -Severity 1
            Write-ADTLogEntry -Message "GUID: '$($adtSession.CheckMSIGuid)'"

            $msiProduct = Get-ADTApplication -ProductCode $adtSession.CheckMSIGuid
            if (-not $msiProduct) {
                Write-ADTLogEntry -Message "NOT FOUND: MSI GUID '$($adtSession.CheckMSIGuid)'" -Severity 2
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "FOUND: $($msiProduct.DisplayName)" -Severity 1
        }

        Write-ADTLogEntry -Message "======== Check-Application PASSED ========" -Severity 1
        return 'Installed'
    }
    catch {
        Write-ADTLogEntry -Message "Check-Application threw an exception: $($_.Exception.Message)" -Severity 3
        return 'Error'
    }
}

##------------------------------------------------
## Set-DeploymentInventoryRegPath
## Ensures the base inventory registry path exists
##------------------------------------------------
Function Set-DeploymentInventoryRegPath {
    [CmdletBinding()]
    param()

    try {
        Set-ADTRegistryKey -Key $DeployInvRegPath
        Write-ADTLogEntry -Message "Inventory registry path verified: $DeployInvRegPath" -Severity 1
    }
    catch {
        Write-ADTLogEntry -Message "Failed to create inventory registry path: $($_.Exception.Message)" -Severity 3
    }
}

##------------------------------------------------
## Register-AppInstallation
## Writes package metadata to inventory registry
##------------------------------------------------
Function Register-AppInstallation {
    [CmdletBinding()]
    param()

    try {
        $SIKey = "$DeployInvRegPath\$PSADTPackageName"
        Write-ADTLogEntry -Message "Writing package metadata to registry: $SIKey"

        Set-ADTRegistryKey -Key $SIKey -Name 'AppID'      -Value "$($adtSession.PSADTAppID)"  -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'AppName'    -Value "$($adtSession.AppName)"     -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'AppVendor'  -Value "$($adtSession.AppVendor)"   -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'AppVersion' -Value "$($adtSession.AppVersion)"  -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'AppRevision'-Value "$($adtSession.AppRevision)" -Type String
    }
    catch {
        Write-ADTLogEntry -Message "Register-AppInstallation failed: $($_.Exception.Message)" -Severity 3
    }
}

##------------------------------------------------
## Register-SuccessOfAppInstallation
## Writes install timestamp and exit code to registry
##------------------------------------------------
Function Register-SuccessOfAppInstallation {
    [CmdletBinding()]
    param()

    try {
        $SIKey          = "$DeployInvRegPath\$PSADTPackageName"
        $installDate    = (Get-Date -Format 'dd.MM.yyyy HH:mm')
        $currentExitCode = if ($adtSession.ExitCode) { $adtSession.ExitCode } else { '0' }

        Set-ADTRegistryKey -Key $SIKey -Name 'Install Date'     -Value "$installDate"     -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'Install ExitCode' -Value "$currentExitCode" -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'IsInstalled'      -Value '1'                -Type String

        Write-ADTLogEntry -Message "Installation registered: $PSADTPackageName at $installDate" -Severity 1
    }
    catch {
        Write-ADTLogEntry -Message "Register-SuccessOfAppInstallation failed: $($_.Exception.Message)" -Severity 3
    }
}

##------------------------------------------------
## Unregister-Installation
## Updates inventory registry on uninstall
##------------------------------------------------
Function Unregister-Installation {
    [CmdletBinding()]
    param()

    try {
        $SIKey           = "$DeployInvRegPath\$PSADTPackageName"
        $uninstallDate   = (Get-Date -Format 'dd.MM.yyyy HH:mm')
        $currentExitCode = if ($adtSession.ExitCode) { $adtSession.ExitCode } else { '0' }

        Set-ADTRegistryKey -Key $SIKey -Name 'Uninstall Date'     -Value "$uninstallDate"   -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'Uninstall ExitCode' -Value "$currentExitCode" -Type String
        Set-ADTRegistryKey -Key $SIKey -Name 'IsInstalled'        -Value '0'                -Type String

        Write-ADTLogEntry -Message "Uninstallation registered: $PSADTPackageName at $uninstallDate" -Severity 1
    }
    catch {
        Write-ADTLogEntry -Message "Unregister-Installation failed: $($_.Exception.Message)" -Severity 3
    }
}


##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference    = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{
            ModuleName    = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
            Guid          = '8c3c366b-8606-4576-9f2d-4051144f7ca2'
            ModuleVersion = '4.1.7'
        } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{
            ModuleName    = 'PSAppDeployToolkit'
            Guid          = '8c3c366b-8606-4576-9f2d-4051144f7ca2'
            ModuleVersion = '4.1.7'
        } -Force
    }

    $iadtParams  = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession  = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession  = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

try
{
    # Load any PSADT extensions found in subdirectories
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    $mainErrorMessage = "Unhandled error in [$($MyInvocation.MyCommand.Name)].`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
