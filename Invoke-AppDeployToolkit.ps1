<#

.SYNOPSIS
PSAppDeployToolkit 4.1.8 - job template: install, uninstall or repair one application.

.DESCRIPTION
Based on the PSAppDeployToolkit 4.1.8 template (Initialization and Invocation unchanged, so a toolkit update stays a file swap).
Additions, all driven by the variables in $adtSession:
- Installs the MSI or EXE from .\Files (MSI: properties are added to the PSADT defaults, transforms optional).
- Checks the application before the install (skips when it is already there) and verifies it afterwards.
- Writes an inventory record to the registry on install and updates it on uninstall.
- Uninstalls by product code, by an own uninstaller or by the exact name in Programs and Features.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.NOTES
Exit codes of this template (PSADT recommends 69000 - 69999 for codes of Invoke-AppDeployToolkit.ps1):
- 69001: The application was not found after the installation (verification failed).
- 69002: The application check itself failed (see the log).
- 69003: Management Point routing: no Management Point found in the registry.
Register them as failure codes in Configuration Manager and Intune.

.LINK
https://psappdeploytoolkit.com

#>

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
    AppVendor = ''
    AppName = ''
    AppVersion = ''
    AppArch = 'x64'
    AppLang = 'MUI'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @()  # Example: @('excel', @{ Name = 'winword'; Description = 'Microsoft Word' })
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-10-05'
    AppScriptAuthor = ''       # Packager name or team
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    # InstallName defaults to Vendor_Name_Version_Arch_Lang_Revision; it is also the inventory key.
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'

    ##================================================
    ## MARK: Package configuration
    ## Own keys: PSADT 4.1 adds them to the session as properties. Empty values are dropped by
    ## Remove-ADTHashtableNullOrEmptyValues, so every function reads them through Get-PackageValue.
    ##================================================

    PSADTAppID = 'APP000001'               # APP + 6-digit consecutive number

    # Name in Programs and Features, when it differs from AppName / AppVendor.
    # Used for the check and for the uninstall by name (exact match).
    appNameControlPanel = ''
    appVendorControlPanel = ''

    # --- Installation ---
    StandardInstall = $true                # $false = Management Point routing (see Install-ADTDeployment)
    installFileName = ''                   # .msi or .exe in .\Files
    msiProperties = ''                     # MSI only: 'ALLUSERS=1 INSTALLDIR="C:\Program Files\App"', added to the PSADT defaults
    customInstallParameter = ''            # EXE: silent switches ('/S'). MSI: REPLACES the PSADT defaults (/QN REBOOT=ReallySuppress, logging) - normally leave empty
    transforms = ''                        # MST file(s) in .\Files, comma separated, applied in this order
    ignoreExitCodes = ''                   # Exit codes to treat as success, comma separated (e.g. '1603,1618'), MSI and EXE

    # --- Application check (Test-ApplicationState) ---
    CheckAppbyDefault = $true              # Check before the install (skip when present) and verify afterwards
    CheckMSIGuid = ''                      # MSI product code: strongest check, also used for uninstall and repair
    mainExecutablePath = ''                # 'C:\Program Files\Vendor\App\app.exe'
    appVersionCheck = ''                   # Minimum version of mainExecutablePath, e.g. '1.0.0.123'
    useFileVersion = $true                 # $true = file version, $false = product version
    checkRegistryHive = 'HKLM'             # HKLM or HKCU
    checkRegistryKey = ''                  # 'SOFTWARE\Vendor\App'
    checkRegistryValueName = ''
    checkRegistryValueData = ''

    # --- Uninstallation ---
    unInstallFileName = ''                 # Own uninstaller: full path, or relative to .\Files
    customUninstallParameter = ''          # Its silent switch, e.g. '/S'

    # --- Completion ---
    ShowCompletionPrompt = $true           # PSADT shows no prompt in silent mode anyway
}

# Inventory root in the registry (one key per package, named after InstallName).
[System.String]$script:CompanyName = 'Company'  # <---- Change to your company
[System.String]$script:DeployInvRegPath = "HKLM\SOFTWARE\$script:CompanyName\Deployment"


##================================================
## MARK: Install
##================================================

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## Close the configured processes silently and check the free disk space.
    $saiwParams = @{ CheckDiskSpace = $true; Silent = $true }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams

    ## Check the application before the install.
    $checkBefore = 'NotInstalled'
    if (Get-PackageValue 'CheckAppbyDefault' $true)
    {
        Write-ADTLogEntry -Message 'Checking the application before the installation.'
        $checkBefore = Test-ApplicationState
        if ($checkBefore -eq 'Error')
        {
            Write-ADTLogEntry -Message 'The check before the installation failed; the installation stops.' -Severity 3
            Close-ADTSession -ExitCode 69002   # ends the deployment here
        }
    }

    ## <Perform Pre-Installation tasks here>


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    if ($checkBefore -eq 'Installed')
    {
        Write-ADTLogEntry -Message "$($adtSession.AppName) $($adtSession.AppVersion) is already installed; the installation is skipped."
    }
    elseif (Get-PackageValue 'StandardInstall' $true)
    {
        Install-Application
    }
    else
    {
        ## Management Point routing: when the installation differs per Configuration Manager site.
        $managementPoint = @(Get-ADTRegistryKey -LiteralPath 'HKLM\SOFTWARE\Microsoft\SMS\DP' -Name 'ManagementPoints') -join ', '
        if ([System.String]::IsNullOrWhiteSpace($managementPoint))
        {
            Write-ADTLogEntry -Message 'No Management Point found in the registry; the installation stops.' -Severity 3
            Close-ADTSession -ExitCode 69003
        }
        Write-ADTLogEntry -Message "Management Point: $managementPoint"
        switch -Wildcard ($managementPoint)
        {
            '*SiteServer-HQ*'
            {
                # HQ-specific installation
                Install-Application
            }
            '*SiteServer-North*'
            {
                # Regional installation
                Install-Application
            }
            default
            {
                Write-ADTLogEntry -Message "No routing for Management Point $managementPoint; the standard installation runs." -Severity 2
                Install-Application
            }
        }
    }

    ## <Perform Installation tasks here>


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Installation tasks here>

    ## Verify the installation, then write the inventory record.
    if (Get-PackageValue 'CheckAppbyDefault' $true)
    {
        Write-ADTLogEntry -Message 'Verifying the installation.'
        switch (Test-ApplicationState)
        {
            'Installed'
            {
                Write-ADTLogEntry -Message 'The installation is verified.'
            }
            'NotInstalled'
            {
                Write-ADTLogEntry -Message 'The application was not found after the installation.' -Severity 3
                Close-ADTSession -ExitCode 69001
            }
            default
            {
                Write-ADTLogEntry -Message 'The verification after the installation failed.' -Severity 3
                Close-ADTSession -ExitCode 69002
            }
        }
    }
    Register-AppInstallation

    if (Get-PackageValue 'ShowCompletionPrompt' $true)
    {
        Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Installation complete.' -ButtonRightText 'OK' -NoWait -Timeout 5
    }
}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -Silent
    }

    ## <Perform Pre-Uninstallation tasks here>


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    Uninstall-Application

    ## <Perform Uninstallation tasks here>


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Uninstallation tasks here>

    Unregister-Installation

    if (Get-PackageValue 'ShowCompletionPrompt' $true)
    {
        Show-ADTInstallationPrompt -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)" -Message 'Uninstall complete.' -ButtonRightText 'OK' -NoWait -Timeout 5
    }
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -Silent
    }

    ## <Perform Pre-Repair tasks here>


    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType
    Show-ADTInstallationProgress -Title "$($adtSession.AppVendor) · $($adtSession.AppName) · $($adtSession.AppVersion)"

    ## MSI: repair by product code, else from the MSI in .\Files. EXE: add the repair call here.
    $productCode = Get-PackageValue 'CheckMSIGuid'
    $installFile = Get-PackageValue 'installFileName'
    if ($productCode)
    {
        Start-ADTMsiProcess -Action Repair -ProductCode $productCode
    }
    elseif ($installFile -and $installFile.EndsWith('.msi', [System.StringComparison]::OrdinalIgnoreCase))
    {
        Start-ADTMsiProcess -Action Repair -FilePath (Join-Path -Path $adtSession.DirFiles -ChildPath $installFile)
    }

    ## <Perform Repair tasks here>


    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Repair tasks here>
}


##================================================
## MARK: Functions
##================================================

function Get-PackageValue
{
    <#
    .SYNOPSIS
        A package configuration value, or the default when it is not set (empty values are not in the session).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]$Name,

        [Parameter(Mandatory = $false, Position = 1)]
        [System.Object]$Default = $null
    )

    $property = $adtSession.PSObject.Properties[$Name]
    if ($null -eq $property -or [System.String]::IsNullOrWhiteSpace([System.String]$property.Value))
    {
        return $Default
    }
    return $property.Value
}

function Get-ListValue
{
    <#
    .SYNOPSIS
        A comma separated package value as a list ('a.mst, b.mst' -> 'a.mst', 'b.mst').
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]$Name
    )

    return @(([System.String](Get-PackageValue $Name '')).Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Install-Application
{
    <#
    .SYNOPSIS
        Installs the MSI or EXE from .\Files.
    #>
    [CmdletBinding()]
    param
    (
    )

    $installFile = Get-PackageValue 'installFileName'
    if (!$installFile)
    {
        throw 'installFileName is empty: set the setup file from .\Files.'
    }
    $installFilePath = Join-Path -Path $adtSession.DirFiles -ChildPath $installFile
    if (!(Test-Path -LiteralPath $installFilePath -PathType Leaf))
    {
        throw "The setup file was not found: $installFilePath"
    }

    $ignoreExitCodes = Get-ListValue 'ignoreExitCodes'
    $arguments = Get-PackageValue 'customInstallParameter'
    switch ([System.IO.Path]::GetExtension($installFilePath).ToLowerInvariant())
    {
        '.msi'
        {
            $params = @{ Action = 'Install'; FilePath = $installFilePath }
            $transforms = @(Get-ListValue 'transforms' | ForEach-Object { Join-Path -Path $adtSession.DirFiles -ChildPath $_ })
            foreach ($transform in $transforms)
            {
                if (!(Test-Path -LiteralPath $transform -PathType Leaf))
                {
                    throw "The transform was not found: $transform"
                }
            }
            if ($transforms.Count -gt 0)
            {
                $params.Add('Transforms', $transforms)
            }
            if ($properties = Get-PackageValue 'msiProperties')
            {
                $params.Add('AdditionalArgumentList', $properties)
            }
            if ($arguments)
            {
                Write-ADTLogEntry -Message "customInstallParameter replaces the PSADT MSI defaults: $arguments" -Severity 2
                $params.Add('ArgumentList', $arguments)
            }
            if ($ignoreExitCodes.Count -gt 0)
            {
                $params.Add('IgnoreExitCodes', $ignoreExitCodes)
            }
            Write-ADTLogEntry -Message "Installing $($adtSession.AppName) from $installFile (MSI)."
            Start-ADTMsiProcess @params
        }
        '.exe'
        {
            $params = @{ FilePath = $installFilePath }
            if ($arguments)
            {
                $params.Add('ArgumentList', $arguments)
            }
            if ($ignoreExitCodes.Count -gt 0)
            {
                $params.Add('IgnoreExitCodes', $ignoreExitCodes)
            }
            Write-ADTLogEntry -Message "Installing $($adtSession.AppName) from $installFile (EXE)."
            Start-ADTProcess @params
        }
        default
        {
            throw "Unsupported setup file $installFile; supported are .msi and .exe."
        }
    }
}

function Uninstall-Application
{
    <#
    .SYNOPSIS
        Uninstalls by product code, by an own uninstaller, or by the exact name in Programs and Features.
    #>
    [CmdletBinding()]
    param
    (
    )

    $productCode = Get-PackageValue 'CheckMSIGuid'
    $uninstaller = Get-PackageValue 'unInstallFileName'
    $arguments = Get-PackageValue 'customUninstallParameter'

    if ($uninstaller)
    {
        # Route 1: own uninstaller (full path, or relative to .\Files).
        $path = if ([System.IO.Path]::IsPathRooted($uninstaller)) { $uninstaller } else { Join-Path -Path $adtSession.DirFiles -ChildPath $uninstaller }
        Write-ADTLogEntry -Message "Uninstalling with $path."
        $params = @{ FilePath = $path }
        if ($arguments)
        {
            $params.Add('ArgumentList', $arguments)
        }
        Start-ADTProcess @params
        return
    }

    if ($productCode)
    {
        # Route 2: MSI product code.
        Write-ADTLogEntry -Message "Uninstalling product code $productCode."
        Start-ADTMsiProcess -Action Uninstall -ProductCode $productCode
        return
    }

    # Route 3: by name. Exact when the Programs and Features name is set; otherwise the app name
    # must match together with the publisher, and an ambiguous match stops instead of removing more.
    $exactName = Get-PackageValue 'appNameControlPanel'
    $publisher = Get-PackageValue 'appVendorControlPanel' $adtSession.AppVendor
    $params = if ($exactName)
    {
        @{ Name = $exactName; NameMatch = 'Exact' }
    }
    else
    {
        @{ Name = $adtSession.AppName; NameMatch = 'Contains' }
    }
    if ($publisher)
    {
        $params.Add('FilterScript', { $_.Publisher -like "*$publisher*" }.GetNewClosure())
    }

    $found = @(Get-ADTApplication @params)
    if ($found.Count -eq 0)
    {
        Write-ADTLogEntry -Message "Nothing to uninstall: no application matches '$($params.Name)'." -Severity 2
        return
    }
    if ($found.Count -gt 1 -and !$exactName)
    {
        throw "'$($params.Name)' matches $($found.Count) applications ($(($found.DisplayName) -join ', ')). Set appNameControlPanel to the exact name."
    }

    Write-ADTLogEntry -Message "Uninstalling $(($found.DisplayName) -join ', ')."
    if ($arguments)
    {
        $params.Add('ArgumentList', $arguments)
    }
    Uninstall-ADTApplication @params
}

function Test-ApplicationState
{
    <#
    .SYNOPSIS
        Checks the application. Returns 'Installed', 'NotInstalled' or 'Error'.

    .DESCRIPTION
        Every configured check must pass:
        1. MSI product code (CheckMSIGuid), or else the name in Programs and Features (exact when appNameControlPanel is set).
        2. Main executable, optionally with a minimum version.
        3. Registry key, optionally with value name and data.
    #>
    [CmdletBinding()]
    param
    (
    )

    try
    {
        # 1. Product code, or the name.
        if ($productCode = Get-PackageValue 'CheckMSIGuid')
        {
            if (!(Get-ADTApplication -ProductCode $productCode))
            {
                Write-ADTLogEntry -Message "Check: product code $productCode is not installed."
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "Check: product code $productCode is installed."
        }
        else
        {
            $exactName = Get-PackageValue 'appNameControlPanel'
            $found = if ($exactName)
            {
                Get-ADTApplication -Name $exactName -NameMatch Exact
            }
            else
            {
                Get-ADTApplication -Name $adtSession.AppName
            }
            if (!$found)
            {
                Write-ADTLogEntry -Message "Check: '$(if ($exactName) { $exactName } else { $adtSession.AppName })' is not in Programs and Features."
                return 'NotInstalled'
            }
            Write-ADTLogEntry -Message "Check: found $((@($found).DisplayName) -join ', ')."
        }

        # 2. Main executable and minimum version.
        if ($exe = Get-PackageValue 'mainExecutablePath')
        {
            $exe = [System.Environment]::ExpandEnvironmentVariables($exe)
            if (!(Test-Path -LiteralPath $exe -PathType Leaf))
            {
                Write-ADTLogEntry -Message "Check: $exe does not exist."
                return 'NotInstalled'
            }
            if ($expected = Get-PackageValue 'appVersionCheck')
            {
                $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
                $actual = if (Get-PackageValue 'useFileVersion' $true)
                {
                    [System.Version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
                }
                else
                {
                    [System.Version]::new($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart)
                }
                $minimum = $null
                if (![System.Version]::TryParse($expected, [ref]$minimum))
                {
                    Write-ADTLogEntry -Message "Check: appVersionCheck '$expected' is not a version (e.g. 1.0.0.123)." -Severity 3
                    return 'Error'
                }
                if ($actual -lt $minimum)
                {
                    Write-ADTLogEntry -Message "Check: $exe has version $actual, at least $minimum is expected."
                    return 'NotInstalled'
                }
                Write-ADTLogEntry -Message "Check: $exe has version $actual (at least $minimum)."
            }
        }

        # 3. Registry key, value name and data.
        if ($key = Get-PackageValue 'checkRegistryKey')
        {
            $hive = ([System.String](Get-PackageValue 'checkRegistryHive' 'HKLM')).ToUpperInvariant()
            if ($hive -notin 'HKLM', 'HKCU')
            {
                Write-ADTLogEntry -Message "Check: checkRegistryHive '$hive' must be HKLM or HKCU." -Severity 3
                return 'Error'
            }
            $path = "${hive}:\$key"
            if (!(Test-Path -LiteralPath $path -PathType Container))
            {
                Write-ADTLogEntry -Message "Check: registry key $path does not exist."
                return 'NotInstalled'
            }
            if ($valueName = Get-PackageValue 'checkRegistryValueName')
            {
                $value = Get-ItemProperty -LiteralPath $path -Name $valueName -ErrorAction Ignore
                if ($null -eq $value)
                {
                    Write-ADTLogEntry -Message "Check: registry value $path\$valueName does not exist."
                    return 'NotInstalled'
                }
                $expectedData = Get-PackageValue 'checkRegistryValueData'
                if ($null -ne $expectedData -and [System.String]$value.$valueName -ne [System.String]$expectedData)
                {
                    Write-ADTLogEntry -Message "Check: registry value $path\$valueName is '$($value.$valueName)', '$expectedData' is expected."
                    return 'NotInstalled'
                }
            }
            Write-ADTLogEntry -Message "Check: registry $path matches."
        }

        return 'Installed'
    }
    catch
    {
        Write-ADTLogEntry -Message "The application check failed: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 3
        return 'Error'
    }
}

function Register-AppInstallation
{
    <#
    .SYNOPSIS
        Writes the inventory record after the installation (IsInstalled = 1).
    #>
    [CmdletBinding()]
    param
    (
    )

    $key = "$script:DeployInvRegPath\$($adtSession.InstallName)"
    try
    {
        Set-ADTRegistryKey -LiteralPath $key -Name 'AppID' -Value ([System.String](Get-PackageValue 'PSADTAppID' '')) -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'AppName' -Value $adtSession.AppName -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'AppVendor' -Value $adtSession.AppVendor -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'AppVersion' -Value $adtSession.AppVersion -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'AppRevision' -Value $adtSession.AppRevision -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'Install Date' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'Install ExitCode' -Value ([System.String]$adtSession.GetExitCode()) -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'IsInstalled' -Value '1' -Type String
        Write-ADTLogEntry -Message "Inventory record written to $key."
    }
    catch
    {
        Write-ADTLogEntry -Message "The inventory record could not be written to ${key}: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 2
    }
}

function Unregister-Installation
{
    <#
    .SYNOPSIS
        Updates the inventory record after the uninstallation (IsInstalled = 0).
    #>
    [CmdletBinding()]
    param
    (
    )

    $key = "$script:DeployInvRegPath\$($adtSession.InstallName)"
    try
    {
        Set-ADTRegistryKey -LiteralPath $key -Name 'Uninstall Date' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'Uninstall ExitCode' -Value ([System.String]$adtSession.GetExitCode()) -Type String
        Set-ADTRegistryKey -LiteralPath $key -Name 'IsInstalled' -Value '0' -Type String
        Write-ADTLogEntry -Message "Inventory record updated in $key."
    }
    catch
    {
        Write-ADTLogEntry -Message "The inventory record could not be updated in ${key}: $(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity 2
    }
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
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

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
