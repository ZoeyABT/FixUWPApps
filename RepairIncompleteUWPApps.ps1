[CmdletBinding()]
param(
    # Enable detailed logging (use -Verbose for built-in verbose output)
)

# Start transcript logging
$logPath = "$env:TEMP\UWPAppRepair-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

Write-Host "=== UWP APPS VALIDATION AND REPAIR ==="
Write-Host "Started at: $(Get-Date)"
Write-Host "Server: $env:COMPUTERNAME"
Write-Host "Log file: $logPath"
Write-Host ""

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
        Write-Host "  Starting repair for $AppName..."
        
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
        
        Write-Host "    Installation mode: $(if($isRepair){'Repair'}else{'Fresh Install'})"
        
        # Start installation
        $installOp = $appInstallManager.StartProductInstallAsync(
            $StoreId,
            $null,
            $null,
            "PowerShellScript",
            $installOptions
        )
        
        Write-Host "    Installation started, waiting for completion..."
        
        # Wait briefly for installation to start
        Start-Sleep -Seconds 3
        
        # Poll for completion with shorter timeout for repair operations
        $timeout = 180000  # 3 minutes
        $interval = 1000   # 1 second
        $elapsed = 0
        
        $foundSuccess = $false
        while ($elapsed -lt $timeout -and -not $foundSuccess) {
            if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
                $repairResult.Success = $true
                $repairResult.Details = "Successfully installed/repaired"
                $foundSuccess = $true
                Write-Host "    SUCCESS: $AppName repair completed!"
                break
            }
            
            Start-Sleep -Milliseconds $interval
            $elapsed += $interval
            
            # Progress indicator every 30 seconds
            if ($elapsed % 30000 -eq 0) {
                $secondsElapsed = $elapsed / 1000
                Write-Host "    Still working... ($secondsElapsed seconds elapsed)"
            }
        }
        
        if (-not $repairResult.Success) {
            # Final check after timeout
            if (Test-PackageProvisioned -ProvisionedPackageName $ProvisionedPackageName) {
                $repairResult.Success = $true
                $repairResult.Details = "Completed after timeout period"
                Write-Host "    SUCCESS: $AppName found after timeout!"
            } else {
                $repairResult.Details = "Timeout - installation did not complete within 3 minutes"
                Write-Host "    TIMEOUT: $AppName repair did not complete"
            }
        }
        
    }
    catch {
        $repairResult.Details = "Error: $($_.Exception.Message)"
        Write-Host "    ERROR: $AppName repair failed - $($_.Exception.Message)"
    }
    
    $repairResult.EndTime = Get-Date
    return $repairResult
}

# Step 1: Validate all packages
Write-Host "=== STEP 1: VALIDATING PACKAGES ==="
$incompletePackages = @()

foreach ($packageKey in $packageDefinitions.Keys) {
    $package = $packageDefinitions[$packageKey]
    Write-Host "Checking $($package.DisplayName)..." -NoNewline
    
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
            Write-Host " COMPLETE" -ForegroundColor Green
            Write-Host "  Executable: $($validationResult.ExecutablePath)"
        }
        "Incomplete" {
            Write-Host " INCOMPLETE - NEEDS REPAIR" -ForegroundColor Yellow
            Write-Host "  Package folder: $($validationResult.PackageFolder)"
            $incompletePackages += $packageKey
        }
        "Package_Not_Found" {
            Write-Host " NOT FOUND - NEEDS INSTALLATION" -ForegroundColor Red
            $incompletePackages += $packageKey
        }
        "WindowsApps_Not_Found" {
            Write-Host " ERROR - WindowsApps folder not found" -ForegroundColor Red
        }
        "Error" {
            Write-Host " ERROR - $($validationResult.Details)" -ForegroundColor Red
        }
    }
    
    $results += $result
}

# Step 2: Repair incomplete packages
Write-Host ""
Write-Host "=== STEP 2: REPAIRING INCOMPLETE PACKAGES ==="

if ($incompletePackages.Count -eq 0) {
    Write-Host "All packages are complete - no repairs needed!" -ForegroundColor Green
} else {
    Write-Host "Found $($incompletePackages.Count) packages that need repair:"
    $incompletePackages | ForEach-Object { Write-Host "  - $($packageDefinitions[$_].DisplayName)" }
    Write-Host ""
    
    foreach ($packageKey in $incompletePackages) {
        $package = $packageDefinitions[$packageKey]
        Write-Host "Repairing $($package.DisplayName)..."
        
        $repairResult = Repair-UWPApp -StoreId $package.StoreId -AppName $package.DisplayName -ProvisionedPackageName $package.ProvisionedPackageName -PackageName $package.PackageName
        $repairAttempts += $repairResult
        
        # Brief pause between repairs
        Start-Sleep -Seconds 2
    }
}

# Step 3: Final validation
Write-Host ""
Write-Host "=== STEP 3: FINAL VALIDATION ==="

# Give time for executable files to appear after provisioning
if ($repairAttempts.Count -gt 0) {
    Write-Host "Waiting 10 seconds for executable files to become available..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

$finalResults = @()

foreach ($packageKey in $packageDefinitions.Keys) {
    $package = $packageDefinitions[$packageKey]
    Write-Host "Final check for $($package.DisplayName)..." -NoNewline
    
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
            Write-Host " COMPLETE" -ForegroundColor Green
        }
        "Incomplete" {
            Write-Host " STILL INCOMPLETE" -ForegroundColor Yellow
        }
        "Package_Not_Found" {
            Write-Host " STILL NOT FOUND" -ForegroundColor Red
        }
        default {
            Write-Host " $($finalValidation.Status)" -ForegroundColor Gray
        }
    }
    
    $finalResults += $finalResult
}

# Summary Report
Write-Host ""
Write-Host "=== SUMMARY REPORT ==="
Write-Host "Completed at: $(Get-Date)"
Write-Host ""

# Package status summary
$completeCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Complete" }).Count
$incompleteCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Incomplete" }).Count
$notFoundCount = ($finalResults | Where-Object { $_.FinalStatus -eq "Package_Not_Found" }).Count

Write-Host "Final Package Status:"
Write-Host "  Complete: $completeCount/4 packages" -ForegroundColor $(if($completeCount -eq 4){'Green'}else{'Yellow'})
if ($incompleteCount -gt 0) {
    Write-Host "  Incomplete: $incompleteCount packages" -ForegroundColor Yellow
}
if ($notFoundCount -gt 0) {
    Write-Host "  Not Found: $notFoundCount packages" -ForegroundColor Red
}

# Repair summary
if ($repairAttempts.Count -gt 0) {
    Write-Host ""
    Write-Host "Repair Results:"
    # Manual counting to avoid PowerShell 5.1 issues
    $successfulRepairs = 0
    $failedRepairs = 0
    
    foreach ($attempt in $repairAttempts) {
        if ($attempt.Success -eq $true) {
            $successfulRepairs++
        } else {
            $failedRepairs++
        }
    }
    
    Write-Host "  Debug - Manual counting results:" -ForegroundColor Gray
    Write-Host "    Successful: $successfulRepairs, Failed: $failedRepairs" -ForegroundColor Gray
    $totalAttempts = $repairAttempts.Count
    
    Write-Host "  Total repair attempts: $totalAttempts" -ForegroundColor Cyan
    Write-Host "  Successful repairs: $successfulRepairs" -ForegroundColor $(if($successfulRepairs -eq $totalAttempts){'Green'}else{'Yellow'})
    Write-Host "  Failed repairs: $failedRepairs" -ForegroundColor $(if($failedRepairs -eq 0){'Green'}else{'Red'})
    
    if ($failedRepairs -gt 0) {
        Write-Host "  Failed apps:"
        $repairAttempts | Where-Object { $_.Success -eq $false } | ForEach-Object {
            Write-Host "    - $($_.AppName): $($_.Details)" -ForegroundColor Red
        }
    }
    
    # Debug: Show all repair attempts
    Write-Host "  Debug - Repair Attempts Array:"
    for ($i = 0; $i -lt $repairAttempts.Count; $i++) {
        $attempt = $repairAttempts[$i]
        Write-Host "    [$i] $($attempt.AppName): Success=$($attempt.Success), Details=$($attempt.Details)" -ForegroundColor Gray
    }
    
    # Additional debug for the counting issue
    Write-Host "  Debug - Success Count Calculation:" -ForegroundColor Gray
    $successCount = 0
    $repairAttempts | ForEach-Object { 
        Write-Host "    Checking: $($_.AppName) - Success value: '$($_.Success)' (Type: $($_.Success.GetType().Name))" -ForegroundColor Gray
        if ($_.Success -eq $true) { 
            $successCount++ 
            Write-Host "      ^ This counts as SUCCESS (running total: $successCount)" -ForegroundColor Gray
        }
    }
    Write-Host "    Final calculated success count: $successCount" -ForegroundColor Gray
}

# Export detailed results
$csvPath = "$env:TEMP\UWPAppRepair-Results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$finalResults | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ""
Write-Host "Detailed results exported to: $csvPath"

# Overall result
Write-Host ""
$initialCompleteCount = ($results | Where-Object { $_.Status -eq "Complete" }).Count

if ($completeCount -eq 4) {
    Write-Host "🎉 ALL UWP APPS ARE NOW COMPLETE!" -ForegroundColor Green
    $exitCode = 0
} elseif ($completeCount -gt $initialCompleteCount) {
    Write-Host "✅ SOME APPS WERE SUCCESSFULLY REPAIRED" -ForegroundColor Yellow
    Write-Host "   Improved from $initialCompleteCount/4 to $completeCount/4 complete packages." -ForegroundColor Yellow
    if ($completeCount -lt 4) {
        Write-Host "   However, some apps still need attention." -ForegroundColor Yellow
    }
    $exitCode = 1
} elseif ($repairAttempts.Count -gt 0) {
    Write-Host "⚠️  REPAIR ATTEMPTS MADE BUT NO IMPROVEMENT" -ForegroundColor Yellow
    Write-Host "   Apps may need manual intervention or different approach." -ForegroundColor Yellow
    $exitCode = 2
} else {
    Write-Host "ℹ️  NO REPAIRS NEEDED" -ForegroundColor Green
    Write-Host "   All incomplete apps were already identified but no repairs attempted." -ForegroundColor Green
    $exitCode = 0
}

Write-Host ""
Write-Host "Log file saved to: $logPath"

Stop-Transcript

# Keep window open for review
Write-Host ""
Write-Host "Press any key to close the window..." -ForegroundColor Yellow
try {
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
} catch {
    # Fallback if ReadKey isn't available (some execution contexts)
    Read-Host "Press Enter to close"
}

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
