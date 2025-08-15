[CmdletBinding()]
param(
    # Enable verbose logging
    [switch]$Verbose
)

if ($Verbose) {
    $VerbosePreference = 'Continue'
}

# Start transcript logging
$logPath = "$env:TEMP\UWPAppRepair-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

Write-Output "=== UWP APPS VALIDATION AND REPAIR ==="
Write-Output "Started at: $(Get-Date)"
Write-Output "Server: $env:COMPUTERNAME"
Write-Output "Log file: $logPath"
Write-Output ""

# Define the packages to check and repair
$packageDefinitions = @{
    "ScreenSketch" = @{
        PackageName = "Microsoft.ScreenSketch"
        StoreId = "9MZ95KL8MR0L"
        DisplayName = "Snipping Tool"
        ProvisionedPackageName = "ScreenSketch"
        ExpectedExecutables = @('SnippingTool.exe')
    }
    "Photos" = @{
        PackageName = "Microsoft.Windows.Photos"
        StoreId = "9WZDNCRFJBH4"
        DisplayName = "Microsoft Photos"
        ProvisionedPackageName = "Photos"
        ExpectedExecutables = @('Photos.exe')
    }
    "Calculator" = @{
        PackageName = "Microsoft.WindowsCalculator"
        StoreId = "9WZDNCRFHVN5"
        DisplayName = "Windows Calculator"
        ProvisionedPackageName = "Calculator"
        ExpectedExecutables = @('CalculatorApp.exe')
    }
    "Notepad" = @{
        PackageName = "Microsoft.WindowsNotepad"
        StoreId = "9MSMLRH6LZF3"
        DisplayName = "Windows Notepad"
        ProvisionedPackageName = "Notepad"
        ExpectedExecutables = @('Notepad.exe')
    }
}

$windowsAppsPath = 'C:\Program Files\WindowsApps'
$results = @()
$repairAttempts = @()

function Test-PackageComplete {
    param(
        [string]$PackageName,
        [array]$ExpectedExecutables
    )
    
    try {
        # Check if WindowsApps folder exists
        if (-not (Test-Path $windowsAppsPath)) {
            return @{ Status = "WindowsApps_Not_Found"; Details = "WindowsApps folder not found"; ExecutablePath = "" }
        }
        
        # Look for packages that start with the target package name
        $matchingPackages = Get-ChildItem -Path $windowsAppsPath -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "$PackageName*" }
        
        if (-not $matchingPackages) {
            return @{ Status = "Package_Not_Found"; Details = "No package folders found"; ExecutablePath = "" }
        }
        
        # Search for expected executables
        foreach ($package in $matchingPackages) {
            foreach ($exeName in $ExpectedExecutables) {
                $foundExe = Get-ChildItem -Path $package.FullName -Filter $exeName -File -Recurse -ErrorAction SilentlyContinue
                if ($foundExe) {
                    return @{ 
                        Status = "Complete"
                        Details = "Package and executable found"
                        ExecutablePath = $foundExe[0].FullName
                        PackageFolder = $package.FullName
                    }
                }
            }
        }
        
        # Package folder exists but no executable found - this is "incomplete"
        return @{ 
            Status = "Incomplete"
            Details = "Package folder found but no executable"
            ExecutablePath = ""
            PackageFolder = $matchingPackages[0].FullName
        }
        
    }
    catch {
        return @{ Status = "Error"; Details = $_.Exception.Message; ExecutablePath = "" }
    }
}

function Test-PackageProvisioned {
    param([string]$ProvisionedPackageName)
    
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

function Repair-UWPApp {
    param(
        [string]$StoreId,
        [string]$AppName,
        [string]$ProvisionedPackageName,
        [string]$PackageName
    )
    
    $repairResult = @{
        AppName = $AppName
        Action = "Repair"
        Success = $false
        Details = ""
        StartTime = Get-Date
        EndTime = $null
    }
    
    try {
        Write-Output "  Starting repair for $AppName..."
        
        # Load Store APIs
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions, Windows.ApplicationModel.Store.Preview.InstallControl, ContentType=WindowsRuntime] | Out-Null
        
        $appInstallManager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
        
        # Check if app is already installed to determine repair mode
        $existingApp = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
        $isRepair = $null -ne $existingApp
        
        # Create AppInstallOptions
        $installOptions = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallOptions]::new()
        $installOptions.InstallForAllUsers = $true
        $installOptions.Repair = $isRepair
        
        Write-Output "    Installation mode: $(if($isRepair){'Repair'}else{'Fresh Install'})"
        
        # Start installation
        $installOp = $appInstallManager.StartProductInstallAsync(
            $StoreId,
            $null,
            $null,
            "PowerShellScript",
            $installOptions
        )
        
        Write-Output "    Installation started, waiting for completion..."
        
        # Wait briefly for installation to start
        Start-Sleep -Seconds 3
        
        # Poll for completion with shorter timeout for repair operations
        $timeout = 180000  # 3 minutes
        $interval = 1000   # 1 second
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
                $repairResult.Success = $true
                $repairResult.Details = "Successfully installed/repaired"
                Write-Output "    SUCCESS: $AppName repair completed!"
                break
            }
            
            Start-Sleep -Milliseconds $interval
            $elapsed += $interval
            
            # Progress indicator every 30 seconds
            if ($elapsed % 30000 -eq 0) {
                $secondsElapsed = $elapsed / 1000
                Write-Output "    Still working... ($secondsElapsed seconds elapsed)"
            }
        }
        
        if (-not $repairResult.Success) {
            # Final check after timeout
            if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
                $repairResult.Success = $true
                $repairResult.Details = "Completed after timeout period"
                Write-Output "    SUCCESS: $AppName found after timeout!"
            } else {
                $repairResult.Details = "Timeout - installation did not complete within 3 minutes"
                Write-Output "    TIMEOUT: $AppName repair did not complete"
            }
        }
        
    }
    catch {
        $repairResult.Details = "Error: $($_.Exception.Message)"
        Write-Output "    ERROR: $AppName repair failed - $($_.Exception.Message)"
    }
    
    $repairResult.EndTime = Get-Date
    return $repairResult
}

# Step 1: Validate all packages
Write-Output "=== STEP 1: VALIDATING PACKAGES ==="
$incompletePackages = @()

foreach ($packageKey in $packageDefinitions.Keys) {
    $package = $packageDefinitions[$packageKey]
    Write-Output "Checking $($package.DisplayName)..." -NoNewline
    
    $validationResult = Test-PackageComplete -PackageName $package.PackageName -ExpectedExecutables $package.ExpectedExecutables
    
    $result = [PSCustomObject]@{
        PackageKey = $packageKey
        DisplayName = $package.DisplayName
        Status = $validationResult.Status
        Details = $validationResult.Details
        ExecutablePath = $validationResult.ExecutablePath
        PackageFolder = $validationResult.PackageFolder
    }
    
    switch ($validationResult.Status) {
        "Complete" {
            Write-Output " COMPLETE" -ForegroundColor Green
            Write-Output "  Executable: $($validationResult.ExecutablePath)"
        }
        "Incomplete" {
            Write-Output " INCOMPLETE - NEEDS REPAIR" -ForegroundColor Yellow
            Write-Output "  Package folder: $($validationResult.PackageFolder)"
            $incompletePackages += $packageKey
        }
        "Package_Not_Found" {
            Write-Output " NOT FOUND - NEEDS INSTALLATION" -ForegroundColor Red
            $incompletePackages += $packageKey
        }
        "WindowsApps_Not_Found" {
            Write-Output " ERROR - WindowsApps folder not found" -ForegroundColor Red
        }
        "Error" {
            Write-Output " ERROR - $($validationResult.Details)" -ForegroundColor Red
        }
    }
    
    $results += $result
}

# Step 2: Repair incomplete packages
Write-Output ""
Write-Output "=== STEP 2: REPAIRING INCOMPLETE PACKAGES ==="

if ($incompletePackages.Count -eq 0) {
    Write-Output "All packages are complete - no repairs needed!" -ForegroundColor Green
} else {
    Write-Output "Found $($incompletePackages.Count) packages that need repair:"
    $incompletePackages | ForEach-Object { Write-Output "  - $($packageDefinitions[$_].DisplayName)" }
    Write-Output ""
    
    foreach ($packageKey in $incompletePackages) {
        $package = $packageDefinitions[$packageKey]
        Write-Output "Repairing $($package.DisplayName)..."
        
        $repairResult = Repair-UWPApp -StoreId $package.StoreId -AppName $package.DisplayName -ProvisionedPackageName $package.ProvisionedPackageName -PackageName $package.PackageName
        $repairAttempts += $repairResult
        
        # Brief pause between repairs
        Start-Sleep -Seconds 2
    }
}

# Step 3: Final validation
Write-Output ""
Write-Output "=== STEP 3: FINAL VALIDATION ==="
$finalResults = @()

foreach ($packageKey in $packageDefinitions.Keys) {
    $package = $packageDefinitions[$packageKey]
    Write-Output "Final check for $($package.DisplayName)..." -NoNewline
    
    $finalValidation = Test-PackageComplete -PackageName $package.PackageName -ExpectedExecutables $package.ExpectedExecutables
    
    $finalResult = [PSCustomObject]@{
        PackageKey = $packageKey
        DisplayName = $package.DisplayName
        InitialStatus = ($results | Where-Object { $_.PackageKey -eq $packageKey }).Status
        FinalStatus = $finalValidation.Status
        WasRepaired = $packageKey -in $incompletePackages
        RepairSuccess = if ($packageKey -in $incompletePackages) { ($repairAttempts | Where-Object { $_.AppName -eq $package.DisplayName }).Success } else { $null }
    }
    
    switch ($finalValidation.Status) {
        "Complete" {
            Write-Output " COMPLETE" -ForegroundColor Green
        }
        "Incomplete" {
            Write-Output " STILL INCOMPLETE" -ForegroundColor Yellow
        }
        "Package_Not_Found" {
            Write-Output " STILL NOT FOUND" -ForegroundColor Red
        }
        default {
            Write-Output " $($finalValidation.Status)" -ForegroundColor Gray
        }
    }
    
    $finalResults += $finalResult
}

# Summary Report
Write-Output ""
Write-Output "=== SUMMARY REPORT ==="
Write-Output "Completed at: $(Get-Date)"
Write-Output ""

# Package status summary
$completeCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Complete" }).Count
$incompleteCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Incomplete" }).Count
$notFoundCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Package_Not_Found" }).Count

Write-Output "Final Package Status:"
Write-Output "  Complete: $completeCount/4 packages" -ForegroundColor $(if($completeCount -eq 4){'Green'}else{'Yellow'})
if ($incompleteCount -gt 0) {
    Write-Output "  Incomplete: $incompleteCount packages" -ForegroundColor Yellow
}
if ($notFoundCount -gt 0) {
    Write-Output "  Not Found: $notFoundCount packages" -ForegroundColor Red
}

# Repair summary
if ($repairAttempts.Count -gt 0) {
    Write-Output ""
    Write-Output "Repair Results:"
    $successfulRepairs = ($repairAttempts | Where-Object { $_.Success }).Count
    $failedRepairs = ($repairAttempts | Where-Object { -not $_.Success }).Count
    
    Write-Output "  Successful repairs: $successfulRepairs/$($repairAttempts.Count)" -ForegroundColor $(if($successfulRepairs -eq $repairAttempts.Count){'Green'}else{'Yellow'})
    
    if ($failedRepairs -gt 0) {
        Write-Output "  Failed repairs: $failedRepairs" -ForegroundColor Red
        Write-Output "  Failed apps:"
        $repairAttempts | Where-Object { -not $_.Success } | ForEach-Object {
            Write-Output "    - $($_.AppName): $($_.Details)" -ForegroundColor Red
        }
    }
}

# Export detailed results
$csvPath = "$env:TEMP\UWPAppRepair-Results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$finalResults | Export-Csv -Path $csvPath -NoTypeInformation
Write-Output ""
Write-Output "Detailed results exported to: $csvPath"

# Overall result
Write-Output ""
if ($completeCount -eq 4) {
    Write-Output "🎉 ALL UWP APPS ARE NOW COMPLETE!" -ForegroundColor Green
    $exitCode = 0
} elseif ($completeCount -gt ($results | Where-Object { $_.Status -eq "Complete" }).Count) {
    Write-Output "✅ SOME APPS WERE SUCCESSFULLY REPAIRED" -ForegroundColor Yellow
    Write-Output "   However, some apps still need attention." -ForegroundColor Yellow
    $exitCode = 1
} else {
    Write-Output "❌ NO IMPROVEMENTS MADE" -ForegroundColor Red
    Write-Output "   Manual intervention may be required." -ForegroundColor Red
    $exitCode = 2
}

Write-Output ""
Write-Output "Log file saved to: $logPath"

Stop-Transcript

exit $exitCode

<#
.SYNOPSIS
    Validates and repairs incomplete UWP apps on the local server

.DESCRIPTION
    This script performs a comprehensive check of 4 UWP apps (ScreenSketch, Photos, Calculator, Notepad)
    and automatically repairs any that are incomplete (package folder exists but no executable).

.PARAMETER Verbose
    Enable detailed verbose logging

.EXAMPLE
    .\RepairIncompleteUWPApps.ps1
    
.EXAMPLE
    .\RepairIncompleteUWPApps.ps1 -Verbose

.NOTES
    Requires Administrator privileges
    Combines validation logic from UWPApps.ps1 with repair logic from FixUWPApps-Simplified.ps1
    
    Exit Codes:
    0 = All apps complete
    1 = Some apps repaired but issues remain
    2 = No improvements made
#>
