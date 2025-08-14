[CmdletBinding()]
param(
    # Specifies the package name to install (e.g., ScreenSketch, Photos, Calculator, Notepad)
    [Parameter(Mandatory = $true)]
    [ValidateSet("ScreenSketch", "Photos", "Calculator", "Notepad")]
    [string]$PackageName,
    
    # Whether to provision the package for all users after installation
    [switch]$ProvisionForAllUsers
)

$packageIds = @{
    "ScreenSketch" = @{
        PackageName = "Microsoft.ScreenSketch"
        StoreId = "9MZ95KL8MR0L"
        DisplayName = "Snipping Tool"
    }
    "Photos" = @{
        PackageName = "Microsoft.Windows.Photos"
        StoreId = "9WZDNCRFJBH4"
        DisplayName = "Microsoft Photos"
    }
    "Calculator" = @{
        PackageName = "Microsoft.WindowsCalculator"
        StoreId = "9WZDNCRFHVN5"
        DisplayName = "Windows Calculator"
    }
    "Notepad" = @{
        PackageName = "Microsoft.WindowsNotepad"
        StoreId = "9MSMLRH6LZF3"
        DisplayName = "Windows Notepad"
    }
}

function Install-MicrosoftStoreApp {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StoreId,
        
        [string]$AppName = "",
        [switch]$ProvisionForAllUsers
    )
    
    # Check if already installed
    $existing = Get-AppxPackage | Where-Object { $_.PackageFullName -like "*$StoreId*" }
    if ($existing) {
        Write-Host "App already installed: $($existing.Name)" -ForegroundColor Yellow
        return $true
    }
    
    Write-Host "Installing Store ID: $StoreId $(if($AppName){"($AppName)"})" -ForegroundColor Cyan
    
    # Load Store APIs
    [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
    $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
    
    try {
        # Start installation using the current API (StartProductInstallAsync)
        # Parameters: productId, catalogId, flightId, clientId, repair, forceUseOfNonRemovableStorage, correlationVector, targetVolume
        $installOp = $appInstallManager.StartProductInstallAsync(
            $StoreId,           # productId
            $null,              # catalogId (can be null for store apps)
            $null,              # flightId (null for regular apps, not flight builds)
            "PowerShellScript", # clientId (identifier for the caller)
            $false,             # repair (false for new install)
            $false,             # forceUseOfNonRemovableStorage
            [Guid]::NewGuid().ToString(), # correlationVector for telemetry
            $null               # targetVolume (null uses default)
        )
        
        # Wait for operation to complete
        while ($installOp.Status -eq [Windows.Foundation.AsyncStatus]::Started) {
            Start-Sleep -Milliseconds 500
            Write-Host "." -NoNewline
        }
        Write-Host ""
        
        if ($installOp.Status -eq [Windows.Foundation.AsyncStatus]::Completed) {
            $installItems = $installOp.GetResults()
            
            # StartProductInstallAsync returns a collection, get the first item
            $installItem = $installItems[0]
            
            # Monitor progress
            $lastPercent = -1
            while ($installItem.InstallState -ne [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Completed -and
                   $installItem.InstallState -ne [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Error) {
                
                $percent = [Math]::Round($installItem.PercentComplete, 0)
                if ($percent -ne $lastPercent) {
                    Write-Progress -Activity "Installing $(if($AppName){$AppName}else{$StoreId})" -Status "$percent%" -PercentComplete $percent
                    $lastPercent = $percent
                }
                Start-Sleep -Milliseconds 500
            }
            
            Write-Progress -Activity "Installing" -Completed
            
            if ($installItem.InstallState -eq [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Completed) {
                Write-Host "✓ Installation completed!" -ForegroundColor Green
                
                # Provision if requested
                if ($ProvisionForAllUsers) {
                    Write-Host "Provisioning for all users..." -ForegroundColor Cyan
                    Start-Sleep -Seconds 2
                    
                    $package = Get-AppxPackage | Where-Object { $_.PackageFullName -like "*$StoreId*" } | Select-Object -First 1
                    if ($package) {
                        [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType=WindowsRuntime] | Out-Null
                        $pm = New-Object Windows.Management.Deployment.PackageManager
                        $provisionOp = $pm.ProvisionPackageForAllUsersAsync($package.PackageFamilyName)
                        
                        while ($provisionOp.Status -eq [Windows.Foundation.AsyncStatus]::Started) {
                            Start-Sleep -Milliseconds 500
                        }
                        
                        if ($provisionOp.Status -eq [Windows.Foundation.AsyncStatus]::Completed) {
                            Write-Host "✓ Provisioned for all users!" -ForegroundColor Green
                        }
                    }
                }
                return $true
            }
        }
        
        Write-Host "✗ Installation failed" -ForegroundColor Red
        return $false
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
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
    
    # Check if already installed by package name
    $existing = Get-AppxPackage -Name $packageInfo.PackageName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "SUCCESS: $($packageInfo.DisplayName) is already installed - $($existing.PackageFullName)"
        
        # Check provisioning status if requested
        if ($ProvisionForAllUsers) {
            $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$($packageInfo.PackageName.Split('.')[1])*" }
            if ($provisioned) {
                Write-Output "SUCCESS: Package is already provisioned for all users"
            } else {
                Write-Output "INFO: Installing provisioning for existing package..."
                & .\ProvisionPackage.ps1 -PackageName $packageInfo.PackageName.Split('.')[1]
            }
        }
        exit 0
    }
    
    # Install the package
    $installResult = Install-MicrosoftStoreApp -StoreId $packageInfo.StoreId -AppName $packageInfo.DisplayName -ProvisionForAllUsers:$ProvisionForAllUsers
    
    if ($installResult) {
        Write-Output "SUCCESS: $($packageInfo.DisplayName) installed successfully"
        
        # Verify installation
        $installed = Get-AppxPackage -Name $packageInfo.PackageName -ErrorAction SilentlyContinue
        if ($installed) {
            Write-Output "VERIFIED: Package found at $($installed.InstallLocation)"
        }
        
        if ($ProvisionForAllUsers) {
            $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$($packageInfo.PackageName.Split('.')[1])*" }
            if ($provisioned) {
                Write-Output "VERIFIED: Package provisioned for all users"
            }
        }
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
.\FixUWPApps.ps1 -PackageName "ScreenSketch"
.\FixUWPApps.ps1 -PackageName "Photos" -ProvisionForAllUsers
.\FixUWPApps.ps1 -PackageName "Calculator"
.\FixUWPApps.ps1 -PackageName "Notepad" -ProvisionForAllUsers

Azure runCommand usage:
& ([ScriptBlock]::Create((Invoke-WebRequest "https://raw.githubusercontent.com/YourRepo/FixUWPApps/main/FixUWPApps.ps1" -UseBasicParsing).Content)) -PackageName "ScreenSketch"
#>