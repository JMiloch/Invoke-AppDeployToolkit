# PSADT Enterprise Framework

> An extended [PSAppDeployToolkit](https://psappdeploytoolkit.com/) template for enterprise-grade software packaging and deployment.

[![PSADT](https://img.shields.io/badge/PSADT-4.1.7-blue?style=flat-square)](https://psappdeploytoolkit.com/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://microsoft.com/powershell)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?style=flat-square&logo=windows&logoColor=white)](https://microsoft.com)
[![ConfigMgr](https://img.shields.io/badge/SCCM%2FConfigMgr-Ready-0078D4?style=flat-square&logo=microsoft&logoColor=white)](https://microsoft.com)
[![License: Freeware](https://img.shields.io/badge/License-Freeware-green?style=flat-square)](LICENSE)

---

## What This Is

Standard PSADT gives you a solid foundation. This framework extends it with the logic that enterprise deployments actually need — but that you normally have to build yourself, package by package.

The goal: **one template, consistent behavior, zero surprises at 3 AM.**

---

## Key Features

### 🔍 5-Layer Application Verification (`Check-Application`)

Before installing — and after — the framework verifies the application state through up to five independent checks, each optional and independently configurable:

| Layer | Method | Purpose |
|-------|--------|---------|
| 1 | **App Name** | Matches installed application name in Add/Remove Programs |
| 2 | **Control Panel Name** | Validates display name when it differs from internal app name |
| 3 | **Executable + Version** | Checks binary exists and matches expected version (FileVersion or ProductVersion) |
| 4 | **Registry Key/Value** | Validates custom registry entries set by installer |
| 5 | **MSI GUID** | Direct product code lookup for MSI-based packages |

All five run sequentially. First failure = `NotInstalled`. All pass = `Installed`. Any exception = `Error` with graceful exit.

---

### ⚙️ Auto-Detection Install/Uninstall Engine

The `Install-Application` and `Uninstall-Application` functions automatically detect whether the source file is `.msi` or `.exe` and route accordingly — no manual branching needed per package.

**Install routing:**
- `.msi` → `Start-ADTMsiProcess` with optional MST transform and custom parameters
- `.exe` → `Start-ADTProcess` with optional silent parameters and exit code handling

**Uninstall routing:**
- Custom EXE uninstaller path specified → uses that
- MSI GUID specified → uninstalls by product code
- Otherwise → auto-detects by app name and/or vendor from Add/Remove Programs

---

### 📦 Multi-Site / Management Point Awareness

For environments with multiple SCCM sites or regional deployment servers, the framework reads the client's registered Management Point from registry and routes installation behavior accordingly.

```powershell
$SMSDPMP = Get-ADTRegistryKey -Key 'HKLM:SOFTWARE\Microsoft\SMS\DP' -Name 'ManagementPoints'

switch ($SMSDPMP) {
    "SiteServer-HQ"    { # HQ-specific install logic }
    "SiteServer-North" { # Regional install logic }
    default            { Write-ADTLogEntry -Message "Unknown MP" -Severity 2 }
}
```

Useful for: different source paths per site, regional license servers, location-dependent configuration.

---

### 🗂️ Built-in Software Inventory Registry

Every successful deployment writes structured metadata to a central registry path, creating a queryable software inventory independent of SCCM's hardware inventory cycle:

```
HKLM\Software\{Company}\Deployment\{Vendor}_{AppName}_{Version}_{Arch}_{Lang}_{Rev}\
    AppID           = APP100001
    AppName         = ...
    AppVendor       = ...
    AppVersion      = ...
    AppRevision     = 01
    Install Date    = 27.11.2025 14:32
    Install ExitCode = 0
    IsInstalled     = 1
```

Queryable via PowerShell, SCCM compliance baselines, or any registry-capable inventory tool.

---

### 🏷️ Standardized Package Naming

Package names follow a consistent convention enforced by the framework:

```
{Vendor}_{AppName}_{Version}_{Arch}_{Lang}_{Revision}
Example: Microsoft_365Apps_16.0.18429_x64_MUI_01
```

This name is used as the registry key for inventory, making cross-environment reporting consistent.

---

## Configuration Reference

All package behavior is controlled through the `$adtSession` hashtable at the top of the script. No need to modify function internals.

```powershell
$adtSession = @{
    # Application Identity
    AppName                = 'MyApp'
    AppVendor              = 'MyVendor'
    AppVersion             = '1.0.0'
    AppArch                = 'x64'          # x64 / x86
    AppLang                = 'MUI'
    AppRevision            = '01'

    # Control Panel Override (if display name differs)
    appNameControlPanel    = ''
    appVendorControlPanel  = ''

    # Installation
    StandardInstall        = $true          # $false = use MP-aware routing
    installFileName        = 'setup.msi'    # file in .\Files\
    customInstallParameter = '/qn REBOOT=ReallySuppress'
    transforms             = 'custom.mst'   # optional MST

    # Uninstallation
    unInstallFileName      = ''             # leave empty for auto-detect
    customUninstallParameter = '/quiet'

    # Verification — all optional, enable what applies
    CheckAppbyDefault      = $true
    mainExecutablePath     = 'C:\Program Files\MyApp\myapp.exe'
    appVersionCheck        = '1.0.0.0'
    useFileVersion         = $true          # $false = use ProductVersion

    checkRegistryHive      = 'HKLM'
    checkRegistryKey       = 'Software\MyVendor\MyApp'
    checkRegistryValueName = 'Version'
    checkRegistryValueData = '1.0.0'

    CheckMSIGuid           = '{GUID-HERE}'  # MSI product code, or leave empty

    # Process Management
    AppProcessesToClose    = @('myapp')
    AppSuccessExitCodes    = @(0)
    AppRebootExitCodes     = @(1641, 3010)

    # Inventory
    PSADTAppID             = 'APP100001'    # APP + 6-digit consecutive number
}
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1641` / `3010` | Success, reboot required |
| `60001` | Unhandled exception in deployment |
| `60008` | PSADT session initialization failed |
| `70001` | Post-install verification failed (NotInstalled) |
| `70002` | Verification check threw an error |
| `70003` | Multi-site deployment: Management Point not found |

---

## Repository Structure

```
PSADT-Enterprise-Framework/
│
├── README.md
├── Invoke-AppDeployToolkit.ps1      ← Main framework template
│
├── docs/
│   ├── architecture.md              ← Framework design decisions
│   ├── configuration-guide.md       ← Full parameter reference
│   ├── check-application.md         ← 5-layer verification deep-dive
│   └── multisite-deployment.md      ← MP-aware deployment guide
│
└── examples/
    ├── example-msi-simple.ps1        ← Basic MSI package
    ├── example-exe-with-transforms.ps1
    ├── example-multisite.ps1
    └── example-registry-verification.ps1
```

---

## Requirements

- **PSAppDeployToolkit** 4.1.7+ (included per-package or from PSModulePath)
- **PowerShell** 5.1+
- **Windows** 10 / 11 / Server 2016+
- **SCCM/ConfigMgr** client (for MP-aware features)
- Local admin rights on target system

---

## How It Differs from Stock PSADT

| Feature | Stock PSADT | This Framework |
|---------|-------------|----------------|
| Install detection | Manual per package | 5-layer automatic |
| EXE vs MSI routing | Manual switch | Auto-detected |
| Uninstall logic | Manual per package | Auto-detect by name/vendor/GUID |
| Post-install verification | Optional, manual | Built-in, automatic |
| Software inventory | None | Registry-based, queryable |
| Multi-site routing | Not included | MP-aware switch logic |
| Package naming | Free-form | Enforced convention |
| Exit codes | Basic | Extended with semantic codes |

---

## Usage

1. Copy `Invoke-AppDeployToolkit.ps1` into your PSADT package folder
2. Fill in the `$adtSession` variables at the top
3. Add your source files to the `.\Files\` folder
4. Test: `.\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Interactive`
5. Deploy via SCCM as usual

For multi-site routing: set `StandardInstall = $false` and fill in the `switch` block in `Install-ADTDeployment`.

---

## License

**Freeware** — free for personal and commercial use.  
Built from real enterprise experience. Provided as-is.

---

## Author

**Miloch** · [github.com/JMiloch](https://github.com/JMiloch)  
Senior Endpoint & Workplace Engineer · SCCM / Intune / Packaging / PowerShell
