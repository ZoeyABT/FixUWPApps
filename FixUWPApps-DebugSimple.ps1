[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ScreenSketch", "Photos", "Calculator", "Notepad")]
    [string]$PackageName,
    [switch]$ProvisionForAllUsers
)

# Simple debug wrapper to catch crashes
try {
    Write-Host "STARTING DEBUG SESSION..." -ForegroundColor Green
    Start-Transcript -Path "$env:TEMP\uwp-debug-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    
    Write-Host "Parameters received: PackageName=$PackageName" -ForegroundColor Cyan
    
    # Run the main script logic...
    # (Include the original script content here)
    
    $packageIds = @{
        "ScreenSketch" = @{ PackageName = "Microsoft.ScreenSketch"; StoreId = "9MZ95KL8MR0L"; DisplayName = "Snipping Tool" }
        "Photos" = @{ PackageName = "Microsoft.Windows.Photos"; StoreId = "9WZDNCRFJBH4"; DisplayName = "Microsoft Photos" }
        "Calculator" = @{ PackageName = "Microsoft.WindowsCalculator"; StoreId = "9WZDNCRFHVN5"; DisplayName = "Windows Calculator" }
        "Notepad" = @{ PackageName = "Microsoft.WindowsNotepad"; StoreId = "9MSMLRH6LZF3"; DisplayName = "Windows Notepad" }
    }
    
    $packageInfo = $packageIds[$PackageName]
    Write-Host "Package info: $($packageInfo.DisplayName)" -ForegroundColor Cyan
    
    # Test the problematic API loading
    Write-Host "Testing API loading..." -ForegroundColor Yellow
    [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
    Write-Host "API loaded successfully!" -ForegroundColor Green
    
    $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
    Write-Host "AppInstallManager created successfully!" -ForegroundColor Green
    
    Write-Host "Script completed without crashing!" -ForegroundColor Green
    
} catch {
    Write-Host "CAUGHT ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Full Error: $($_ | Out-String)" -ForegroundColor Red
} finally {
    Stop-Transcript
    Write-Host "Press Enter to close..."
    Read-Host
}
