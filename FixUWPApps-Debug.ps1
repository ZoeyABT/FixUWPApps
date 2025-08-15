[CmdletBinding()]
param(
    # Specifies the package name to install (e.g., ScreenSketch, Photos, Calculator, Notepad)
    [Parameter(Mandatory = $true)]
    [ValidateSet("ScreenSketch", "Photos", "Calculator", "Notepad")]
    [string]$PackageName,
    
    # Whether to provision the package for all users after installation
    [switch]$ProvisionForAllUsers,
    
    # Enable debug logging to a file
    [switch]$EnableDebugLog
)

# Start transcript for debugging
if ($EnableDebugLog) {
    $logPath = "$env:TEMP\FixUWPApps-Debug-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $logPath -Append
    Write-Host "DEBUG: Transcript started at $logPath" -ForegroundColor Yellow
}

# Enhanced error handling
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

try {
    Write-Host "DEBUG: Script started with PackageName=$PackageName, ProvisionForAllUsers=$ProvisionForAllUsers" -ForegroundColor Magenta
    Write-Host "DEBUG: PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Magenta
    Write-Host "DEBUG: Execution Policy: $(Get-ExecutionPolicy)" -ForegroundColor Magenta
    Write-Host "DEBUG: Current User: $env:USERNAME" -ForegroundColor Magenta
    Write-Host "DEBUG: Is Admin: $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)" -ForegroundColor Magenta

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
        
        try {
            Write-Host "DEBUG: Starting Install-MicrosoftStoreApp function" -ForegroundColor Magenta
            Write-Host "DEBUG: StoreId=$StoreId, AppName=$AppName" -ForegroundColor Magenta
            
            # Check if already installed
            Write-Host "DEBUG: Checking for existing installation..." -ForegroundColor Magenta
            $existing = Get-AppxPackage | Where-Object { $_.PackageFullName -like "*$StoreId*" }
            if ($existing) {
                Write-Host "App already installed: $($existing.Name)" -ForegroundColor Yellow
                return $true
            }
            
            Write-Host "Installing Store ID: $StoreId $(if($AppName){"($AppName)"})" -ForegroundColor Cyan
            
            # Load Store APIs with enhanced error handling
            Write-Host "DEBUG: Loading Windows Runtime APIs..." -ForegroundColor Magenta
            try {
                [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
                Write-Host "DEBUG: AppInstallManager type loaded successfully" -ForegroundColor Magenta
            }
            catch {
                Write-Host "ERROR: Failed to load AppInstallManager type: $_" -ForegroundColor Red
                Write-Host "DEBUG: This usually means the Windows Store API is not available" -ForegroundColor Red
                throw
            }
            
            try {
                $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
                Write-Host "DEBUG: AppInstallManager instance created successfully" -ForegroundColor Magenta
            }
            catch {
                Write-Host "ERROR: Failed to create AppInstallManager instance: $_" -ForegroundColor Red
                throw
            }
            
            Write-Host "DEBUG: Starting product installation..." -ForegroundColor Magenta
            
            # Start installation using the current API (StartProductInstallAsync)
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
            
            Write-Host "DEBUG: Installation operation started, waiting for completion..." -ForegroundColor Magenta
            
            # Wait for operation to complete with timeout
            $timeout = 300 # 5 minutes
            $elapsed = 0
            while ($installOp.Status -eq [Windows.Foundation.AsyncStatus]::Started -and $elapsed -lt $timeout) {
                Start-Sleep -Seconds 1
                $elapsed++
                if ($elapsed % 10 -eq 0) {
                    Write-Host "DEBUG: Still waiting... ($elapsed seconds elapsed)" -ForegroundColor Magenta
                }
                Write-Host "." -NoNewline
            }
            Write-Host ""
            
            if ($elapsed -ge $timeout) {
                Write-Host "ERROR: Installation timed out after $timeout seconds" -ForegroundColor Red
                return $false
            }
            
            Write-Host "DEBUG: Installation operation status: $($installOp.Status)" -ForegroundColor Magenta
            
            if ($installOp.Status -eq [Windows.Foundation.AsyncStatus]::Completed) {
                Write-Host "DEBUG: Getting installation results..." -ForegroundColor Magenta
                $installItems = $installOp.GetResults()
                
                if ($installItems -and $installItems.Count -gt 0) {
                    # StartProductInstallAsync returns a collection, get the first item
                    $installItem = $installItems[0]
                    Write-Host "DEBUG: Install item obtained, current state: $($installItem.InstallState)" -ForegroundColor Magenta
                    
                    # Monitor progress
                    $lastPercent = -1
                    $progressTimeout = 600 # 10 minutes for progress
                    $progressElapsed = 0
                    
                    while ($installItem.InstallState -ne [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Completed -and
                           $installItem.InstallState -ne [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Error -and
                           $progressElapsed -lt $progressTimeout) {
                        
                        $percent = [Math]::Round($installItem.PercentComplete, 0)
                        if ($percent -ne $lastPercent) {
                            Write-Progress -Activity "Installing $(if($AppName){$AppName}else{$StoreId})" -Status "$percent%" -PercentComplete $percent
                            Write-Host "DEBUG: Progress: $percent%, State: $($installItem.InstallState)" -ForegroundColor Magenta
                            $lastPercent = $percent
                        }
                        Start-Sleep -Seconds 1
                        $progressElapsed++
                    }
                    
                    Write-Progress -Activity "Installing" -Completed
                    Write-Host "DEBUG: Final install state: $($installItem.InstallState)" -ForegroundColor Magenta
                    
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
                    } elseif ($installItem.InstallState -eq [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState]::Error) {
                        Write-Host "ERROR: Installation failed with error state" -ForegroundColor Red
                        if ($installItem.ErrorCode) {
                            Write-Host "ERROR: Error code: $($installItem.ErrorCode)" -ForegroundColor Red
                        }
                        return $false
                    } else {
                        Write-Host "ERROR: Installation timed out in progress monitoring" -ForegroundColor Red
                        return $false
                    }
                } else {
                    Write-Host "ERROR: No installation items returned" -ForegroundColor Red
                    return $false
                }
            } elseif ($installOp.Status -eq [Windows.Foundation.AsyncStatus]::Error) {
                Write-Host "ERROR: Installation operation failed" -ForegroundColor Red
                if ($installOp.ErrorCode) {
                    Write-Host "ERROR: Operation error code: $($installOp.ErrorCode)" -ForegroundColor Red
                }
                return $false
            } else {
                Write-Host "ERROR: Installation operation completed with unexpected status: $($installOp.Status)" -ForegroundColor Red
                return $false
            }
        }
        catch {
            Write-Host "ERROR in Install-MicrosoftStoreApp: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "DEBUG: Full exception: $($_ | Out-String)" -ForegroundColor Red
            return $false
        }
    }

    # Main execution logic
    Write-Output "Starting UWP app installation for: $PackageName"
    
    # Get package details
    $packageInfo = $packageIds[$PackageName]
    if (-not $packageInfo) {
        Write-Output "ERROR: Unknown package name '$PackageName'"
        exit 1
    }
    
    Write-Output "Package: $($packageInfo.DisplayName) (Store ID: $($packageInfo.StoreId))"
    
    # Check if already installed by package name
    Write-Host "DEBUG: Checking if package is already installed..." -ForegroundColor Magenta
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
    
    Write-Host "DEBUG: Package not found, proceeding with installation..." -ForegroundColor Magenta
    
    # Install the package
    $installResult = Install-MicrosoftStoreApp -StoreId $packageInfo.StoreId -AppName $packageInfo.DisplayName -ProvisionForAllUsers:$ProvisionForAllUsers
    
    Write-Host "DEBUG: Install function returned: $installResult" -ForegroundColor Magenta
    
    if ($installResult) {
        Write-Output "SUCCESS: $($packageInfo.DisplayName) installed successfully"
        
        # Verify installation
        $installed = Get-AppxPackage -Name $packageInfo.PackageName -ErrorAction SilentlyContinue
        if ($installed) {
            Write-Output "VERIFIED: Package found at $($installed.InstallLocation)"
        } else {
            Write-Host "WARNING: Installation reported success but package not found" -ForegroundColor Yellow
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
    
    Write-Host "DEBUG: Script completed successfully" -ForegroundColor Magenta
    
} catch {
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "DEBUG: Full exception details:" -ForegroundColor Red
    Write-Host "$($_ | Out-String)" -ForegroundColor Red
    Write-Host "DEBUG: Stack trace:" -ForegroundColor Red
    Write-Host "$($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
} finally {
    if ($EnableDebugLog) {
        Write-Host "DEBUG: Stopping transcript" -ForegroundColor Yellow
        Stop-Transcript
        Write-Host "DEBUG: Log saved to $logPath" -ForegroundColor Yellow
    }
    
    # Keep window open for debugging
    Write-Host "DEBUG: Press any key to close..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

<#
Debug Usage Examples:
.\FixUWPApps-Debug.ps1 -PackageName "Notepad" -EnableDebugLog
.\FixUWPApps-Debug.ps1 -PackageName "ScreenSketch" -EnableDebugLog -Verbose

Remote execution with debug (saves log to temp):
& ([ScriptBlock]::Create((Invoke-WebRequest "https://raw.githubusercontent.com/ZoeyABT/FixUWPApps/main/FixUWPApps-Debug.ps1" -UseBasicParsing).Content)) -PackageName "Notepad" -EnableDebugLog
#>
