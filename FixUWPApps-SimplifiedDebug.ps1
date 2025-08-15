[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ScreenSketch", "Photos", "Calculator", "Notepad")]
    [string]$PackageName
)

# Start transcript immediately to catch everything
$logPath = "$env:TEMP\FixUWPApps-SimplifiedDebug-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

try {
    Write-Host "=== SIMPLIFIED DEBUG SESSION STARTED ===" -ForegroundColor Green
    Write-Host "PackageName: $PackageName" -ForegroundColor Cyan
    Write-Host "Log Path: $logPath" -ForegroundColor Yellow
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Magenta
    Write-Host "Current User: $env:USERNAME" -ForegroundColor Magenta
    Write-Host "Is Admin: $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)" -ForegroundColor Magenta

    $packageIds = @{
        "ScreenSketch" = @{
            PackageName = "Microsoft.ScreenSketch"
            StoreId = "9MZ95KL8MR0L"
            DisplayName = "Snipping Tool"
            ProvisionedPackageName = "ScreenSketch"
        }
        "Photos" = @{
            PackageName = "Microsoft.Windows.Photos"
            StoreId = "9WZDNCRFJBH4"
            DisplayName = "Microsoft Photos"
            ProvisionedPackageName = "Photos"
        }
        "Calculator" = @{
            PackageName = "Microsoft.WindowsCalculator"
            StoreId = "9WZDNCRFHVN5"
            DisplayName = "Windows Calculator"
            ProvisionedPackageName = "Calculator"
        }
        "Notepad" = @{
            PackageName = "Microsoft.WindowsNotepad"
            StoreId = "9MSMLRH6LZF3"
            DisplayName = "Windows Notepad"
            ProvisionedPackageName = "Notepad"
        }
    }

    Write-Host "Package definitions loaded successfully" -ForegroundColor Green

    function Test-PackageProvisioned {
        param([string]$ProvisionedPackageName)
        
        try {
            Write-Host "Testing if package '$ProvisionedPackageName' is provisioned..." -ForegroundColor Yellow
            $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { 
                $_.PackageName -like "*$ProvisionedPackageName*" 
            }
            $result = ($null -ne $provisioned)
            Write-Host "Provisioned check result: $result" -ForegroundColor $(if($result){'Green'}else{'Yellow'})
            return $result
        }
        catch {
            Write-Host "ERROR in Test-PackageProvisioned: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }

    Write-Host "Test-PackageProvisioned function defined" -ForegroundColor Green

    # Get package details
    $packageInfo = $packageIds[$PackageName]
    if (-not $packageInfo) {
        Write-Host "ERROR: Unknown package name '$PackageName'" -ForegroundColor Red
        exit 1
    }

    Write-Host "Package Info Retrieved:" -ForegroundColor Cyan
    Write-Host "  DisplayName: $($packageInfo.DisplayName)" -ForegroundColor White
    Write-Host "  StoreId: $($packageInfo.StoreId)" -ForegroundColor White
    Write-Host "  ProvisionedPackageName: $($packageInfo.ProvisionedPackageName)" -ForegroundColor White

    # Check current status but always proceed with installation (may be broken)
    Write-Host "Checking current provisioned status..." -ForegroundColor Cyan
    $isCurrentlyProvisioned = Test-PackageProvisioned -ProvisionedPackageName $packageInfo.ProvisionedPackageName
    if ($isCurrentlyProvisioned) {
        Write-Host "Package is currently provisioned but proceeding with installation/repair..." -ForegroundColor Yellow
    } else {
        Write-Host "Package not currently provisioned, proceeding with installation..." -ForegroundColor Cyan
    }

    # Test API loading BEFORE trying to install
    Write-Host "Testing Windows Store API loading..." -ForegroundColor Yellow
    try {
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        Write-Host "API types loaded successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "FATAL ERROR: Cannot load Windows Store API: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "This system may not support Microsoft Store installation APIs" -ForegroundColor Red
        exit 1
    }

    try {
        $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
        Write-Host "AppInstallManager instance created successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "FATAL ERROR: Cannot create AppInstallManager: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Check if app is already installed to determine repair mode
    Write-Host "Checking if app is currently installed..." -ForegroundColor Yellow
    $existingApp = Get-AppxPackage -Name $packageInfo.PackageName -ErrorAction SilentlyContinue
    $isRepair = $null -ne $existingApp
    
    if ($isRepair) {
        Write-Host "App is already installed - will use REPAIR mode" -ForegroundColor Yellow
        Write-Host "Existing app: $($existingApp.PackageFullName)" -ForegroundColor Gray
    } else {
        Write-Host "App not currently installed - will use FRESH INSTALL mode" -ForegroundColor Cyan
    }

    # Create AppInstallOptions
    Write-Host "Creating AppInstallOptions..." -ForegroundColor Yellow
    try {
        $installOptions = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions]::new()
        $installOptions.InstallForAllUsers = $true
        $installOptions.Repair = $isRepair
        Write-Host "AppInstallOptions created: InstallForAllUsers=$($installOptions.InstallForAllUsers), Repair=$($installOptions.Repair)" -ForegroundColor Green
    }
    catch {
        Write-Host "FATAL ERROR: Cannot create AppInstallOptions: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Start installation
    Write-Host "Starting installation of $($packageInfo.DisplayName)..." -ForegroundColor Cyan
    try {
        $installOp = $appInstallManager.StartProductInstallAsync(
            $packageInfo.StoreId,
            $null,
            $null,
            "PowerShellScript",
            $installOptions
        )
        Write-Host "Installation operation started with AppInstallOptions (not checking status)" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR starting installation: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # Simple wait
    Write-Host "Waiting 5 seconds for installation to begin..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5

    # Polling logic
    Write-Host "Starting polling for provisioned package..." -ForegroundColor Cyan
    $timeout = 30000  # 30 seconds for testing (much shorter than 5 minutes)
    $interval = 1000  # 1 second for testing (instead of 100ms)
    $elapsed = 0

    while ($elapsed -lt $timeout) {
        Write-Host "Polling attempt at $($elapsed/1000) seconds..." -ForegroundColor Gray
        
        if (Test-PackageProvisioned -ProvisionedPackageName $packageInfo.ProvisionedPackageName) {
            Write-Host "SUCCESS: $($packageInfo.DisplayName) is now provisioned!" -ForegroundColor Green
            exit 0
        }
        
        Start-Sleep -Milliseconds $interval
        $elapsed += $interval
    }

    Write-Host "TIMEOUT: Package not found after $($timeout/1000) seconds" -ForegroundColor Red
    
    # Final check
    if (Test-PackageProvisioned -ProvisionedPackageName $packageInfo.ProvisionedPackageName) {
        Write-Host "SUCCESS: Package found in final check!" -ForegroundColor Green
        exit 0
    }

    Write-Host "FAILURE: Package installation did not complete successfully" -ForegroundColor Red
    exit 1

} catch {
    Write-Host "FATAL EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Full Exception: $($_ | Out-String)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
} finally {
    Write-Host "=== DEBUG SESSION ENDING ===" -ForegroundColor Green
    Write-Host "Transcript saved to: $logPath" -ForegroundColor Yellow
    Stop-Transcript
    
    # Keep window open
    Write-Host "Press any key to close window..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
