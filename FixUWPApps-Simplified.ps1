[CmdletBinding()]
param(
    # Specifies the package name to install (e.g., ScreenSketch, Photos, Calculator, Notepad)
    [Parameter(Mandatory = $true)]
    [ValidateSet("ScreenSketch", "Photos", "Calculator", "Notepad")]
    [string]$PackageName
)

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

function Test-PackageProvisioned {
    param(
        [string]$ProvisionedPackageName
    )
    
    try {
        $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { 
            $_.PackageName -like "*$ProvisionedPackageName*" 
        }
        return ($null -ne $provisioned)
    }
    catch {
        Write-Verbose "Error checking provisioned packages: $($_.Exception.Message)"
        return $false
    }
}

function Install-MicrosoftStoreApp {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StoreId,
        
        [Parameter(Mandatory=$true)]
        [string]$AppName,
        
        [Parameter(Mandatory=$true)]
        [string]$ProvisionedPackageName,
        
        [Parameter(Mandatory=$true)]
        [string]$PackageName
    )
    
    try {
        Write-Output "Installing Store ID: $StoreId ($AppName)"
        
        # Load Store APIs
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        
        $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
        
        # Check if app is already installed to determine if we need repair
        $existingApp = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
        $isRepair = $null -ne $existingApp
        
        if ($isRepair) {
            Write-Output "App is already installed - performing repair installation"
        } else {
            Write-Output "App not found - performing fresh installation"
        }
        
        # Create AppInstallOptions with proper flags
        $installOptions = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions]::new()
        $installOptions.InstallForAllUsers = $true
        $installOptions.Repair = $isRepair
        
        Write-Output "InstallOptions configured: InstallForAllUsers=$($installOptions.InstallForAllUsers), Repair=$($installOptions.Repair)"
        
        # Start installation with AppInstallOptions
        $installOp = $appInstallManager.StartProductInstallAsync(
            $StoreId,           # productId
            $null,              # catalogId
            $null,              # flightId
            "PowerShellScript", # clientId
            $installOptions     # AppInstallOptions
        )
        
        Write-Output "Installation started, waiting for completion..."
        
        # Simple wait approach - don't try to inspect the COM object
        # Just wait a bit for the installation to start properly
        Start-Sleep -Seconds 5
        
        # Now poll for the provisioned package with timeout
        $timeout = 300000  # 5 minutes in milliseconds
        $interval = 100    # 100ms between checks
        $elapsed = 0
        
        Write-Output "Polling for provisioned package (timeout: 5 minutes)..."
        
        while ($elapsed -lt $timeout) {
            if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
                Write-Output "SUCCESS: $AppName is now provisioned and available!"
                return $true
            }
            
            Start-Sleep -Milliseconds $interval
            $elapsed += $interval
            
            # Progress indicator every 10 seconds
            if ($elapsed % 10000 -eq 0) {
                $secondsElapsed = $elapsed / 1000
                Write-Output "  Still waiting... ($secondsElapsed seconds elapsed)"
            }
        }
        
        # Timeout reached
        Write-Output "TIMEOUT: Installation did not complete within 5 minutes"
        
        # One final check to see if it actually did install
        if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
            Write-Output "SUCCESS: $AppName found after timeout - installation completed!"
            return $true
        }
        
        return $false
        
    }
    catch {
        Write-Output "ERROR: Installation failed - $($_.Exception.Message)"
        return $false
    }
}

# Main execution logic
try {
    Write-Output "Starting UWP app installation for: $PackageName"
    
    # Get package details
    $packageInfo = $packageIds[$PackageName]
    if (-not $packageInfo) {
        Write-Output "ERROR: Unknown package name '$PackageName'"
        exit 1
    }
    
    Write-Output "Package: $($packageInfo.DisplayName) (Store ID: $($packageInfo.StoreId))"
    
    # Always attempt installation (even if already provisioned, as it may be broken)
    Write-Output "Attempting installation/repair of $($packageInfo.DisplayName)..."
    
    # Install the package
    $installResult = Install-MicrosoftStoreApp -StoreId $packageInfo.StoreId -AppName $packageInfo.DisplayName -ProvisionedPackageName $packageInfo.ProvisionedPackageName -PackageName $packageInfo.PackageName
    
    if ($installResult) {
        Write-Output "FINAL VERIFICATION: $($packageInfo.DisplayName) installed and provisioned successfully"
        exit 0
    } else {
        Write-Output "ERROR: Failed to install $($packageInfo.DisplayName)"
        exit 1
    }
    
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}

<#
Usage Examples:
.\FixUWPApps-Simplified.ps1 -PackageName "ScreenSketch"
.\FixUWPApps-Simplified.ps1 -PackageName "Photos"
.\FixUWPApps-Simplified.ps1 -PackageName "Calculator"
.\FixUWPApps-Simplified.ps1 -PackageName "Notepad"

Remote execution:
& ([ScriptBlock]::Create((Invoke-WebRequest "https://raw.githubusercontent.com/ZoeyABT/FixUWPApps/main/FixUWPApps-Simplified.ps1" -UseBasicParsing -Headers @{"Cache-Control"="no-cache"}).Content)) -PackageName "Notepad"
#>
