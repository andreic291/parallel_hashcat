# Function to cleanup hashcat processes (not containers)
function Cleanup-Processes {
    docker exec hashcat-single pkill -f hashcat 2>$null
    docker exec hashcat-parallel-1 pkill -f hashcat 2>$null
    docker exec hashcat-parallel-2 pkill -f hashcat 2>$null
    
    # Clear previous results
    if (Test-Path "results") {
        Remove-Item "results\*.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "results\password_found_*" -Force -ErrorAction SilentlyContinue
    }
}

# Function to ensure containers are running
function Ensure-Containers-Running {
    Write-Host "Checking container status..." -ForegroundColor Cyan
    
    # Check if containers exist and are running
    $SINGLE_RUNNING = docker ps -q -f name=hashcat-single
    $PARALLEL1_RUNNING = docker ps -q -f name=hashcat-parallel-1
    $PARALLEL2_RUNNING = docker ps -q -f name=hashcat-parallel-2
    
    if (-not $SINGLE_RUNNING -or -not $PARALLEL1_RUNNING -or -not $PARALLEL2_RUNNING) {
        Write-Host "Starting containers (first time setup)..." -ForegroundColor Yellow
        docker-compose up -d
        Write-Host "Waiting for containers to initialize..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    } else {
        Write-Host "All containers already running - no cold start needed!" -ForegroundColor Green
    }
    
    # Verify all containers are healthy
    if (-not (docker exec hashcat-single echo "Container ready" 2>$null)) {
        Write-Host "ERROR: hashcat-single container not responding" -ForegroundColor Red
        exit 1
    }
    if (-not (docker exec hashcat-parallel-1 echo "Container ready" 2>$null)) {
        Write-Host "ERROR: hashcat-parallel-1 container not responding" -ForegroundColor Red
        exit 1
    }
    if (-not (docker exec hashcat-parallel-2 echo "Container ready" 2>$null)) {
        Write-Host "ERROR: hashcat-parallel-2 container not responding" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "All containers are ready!" -ForegroundColor Green
}

# Function to wait for file creation with timeout
function Wait-ForFile {
    param(
        [string]$FilePath,
        [int]$TimeoutSeconds
    )
    
    $count = 0
    while ((-not (Test-Path $FilePath)) -and ($count -lt $TimeoutSeconds)) {
        Start-Sleep -Seconds 1
        $count++
    }
    
    return (Test-Path $FilePath)
}

# Clean up processes (not containers) for fresh test
Cleanup-Processes

# Step 1: Ensure containers are running (no rebuild unless needed)
Write-Host ""
Write-Host "Ensuring containers are available..." -ForegroundColor Cyan
Ensure-Containers-Running

# Step 2: Prepare wordlists for testing
Write-Host ""
Write-Host "Preparing wordlists for single and parallel processing..." -ForegroundColor Cyan

$WORDLIST_FILE = "massive_wordlist.txt"
$OUTPUT_DIR = "wordlists"

# Create wordlists directory if it doesn't exist
if (-not (Test-Path $OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
}

# Get total number of lines
$TOTAL_LINES = (Get-Content $WORDLIST_FILE | Measure-Object).Count
$HALF_LINES = [math]::Floor($TOTAL_LINES / 2)

Write-Host "Total passwords: $TOTAL_LINES"
Write-Host "Creating wordlists for testing..."

# Create single container wordlist (copy of original for consistency)
Copy-Item $WORDLIST_FILE "$OUTPUT_DIR\single_wordlist.txt"
Write-Host "Single container wordlist: $TOTAL_LINES passwords"

# Split the wordlist for parallel processing
$content = Get-Content $WORDLIST_FILE
$content[0..($HALF_LINES-1)] | Out-File "$OUTPUT_DIR\wordlist_part1.txt" -Encoding UTF8
$content[$HALF_LINES..($TOTAL_LINES-1)] | Out-File "$OUTPUT_DIR\wordlist_part2.txt" -Encoding UTF8

# Verify all files were created
$SINGLE_LINES = (Get-Content "$OUTPUT_DIR\single_wordlist.txt" | Measure-Object).Count
$PART1_LINES = (Get-Content "$OUTPUT_DIR\wordlist_part1.txt" | Measure-Object).Count
$PART2_LINES = (Get-Content "$OUTPUT_DIR\wordlist_part2.txt" | Measure-Object).Count

Write-Host "Single wordlist: $SINGLE_LINES passwords"
Write-Host "Parallel part 1: $PART1_LINES passwords"
Write-Host "Parallel part 2: $PART2_LINES passwords"
Write-Host "Total parallel: $($PART1_LINES + $PART2_LINES) passwords"

if (-not (Test-Path "$OUTPUT_DIR\single_wordlist.txt") -or 
    -not (Test-Path "$OUTPUT_DIR\wordlist_part1.txt") -or 
    -not (Test-Path "$OUTPUT_DIR\wordlist_part2.txt")) {
    Write-Host "ERROR: Failed to create wordlist files" -ForegroundColor Red
    exit 1
}

Write-Host "Wordlist preparation completed successfully!" -ForegroundColor Green

# Step 3: Run single container test
Write-Host ""
Write-Host "Running SINGLE container performance test..." -ForegroundColor Cyan

# Make scripts executable (equivalent to chmod +x scripts/*.sh)
# This is handled by the container's bash environment

# Run single container test (containers already running)
docker exec hashcat-single bash /hashcat-test/scripts/test_single.sh

$SINGLE_RESULT_FILE = "results\single_container_result.txt"
if (Test-Path $SINGLE_RESULT_FILE) {
    Write-Host "Single container test completed!" -ForegroundColor Green
    Write-Host "Results saved to: $SINGLE_RESULT_FILE"
} else {
    Write-Host "ERROR: Single container test failed" -ForegroundColor Red
}

# Step 4: Clean up for parallel test
Write-Host ""
Write-Host "Preparing for PARALLEL container test..." -ForegroundColor Cyan
Remove-Item "results\password_found_*" -Force -ErrorAction SilentlyContinue
Remove-Item "results\parallel_*_result.txt" -Force -ErrorAction SilentlyContinue

# Step 5: Run parallel containers test
Write-Host ""
Write-Host "Running PARALLEL containers performance test..." -ForegroundColor Cyan

# Start both parallel tests simultaneously
Write-Host "Starting parallel processing on both containers..."

# Record parallel start time
$PARALLEL_START = Get-Date

# Run both parts in parallel (containers already running)
docker exec -d hashcat-parallel-1 bash /hashcat-test/scripts/test_parallel_part1.sh
docker exec -d hashcat-parallel-2 bash /hashcat-test/scripts/test_parallel_part2.sh

Write-Host "Both containers are now processing their respective wordlist halves..."

# Monitor progress and wait for completion
Write-Host "Monitoring parallel execution..."
$TIMEOUT = 300  # 5 minutes timeout
$COUNT = 0

# Monitor containers - stop when password found OR both finish
$PASSWORD_FOUND = $false
$FIRST_CONTAINER_FOUND = ""

while ($COUNT -lt $TIMEOUT) {
    $PART1_DONE = $false
    $PART2_DONE = $false
    $PART1_FOUND_PASSWORD = $false
    $PART2_FOUND_PASSWORD = $false
    
    # Check if part 1 is done and if password was found
    if (Test-Path "results\parallel_part1_result.txt") {
        $part1Content = Get-Content "results\parallel_part1_result.txt" -ErrorAction SilentlyContinue
        if ($part1Content -match "PERFORMANCE SUMMARY") {
            $PART1_DONE = $true
            if (Test-Path "results\password_found_part1") {
                $PART1_FOUND_PASSWORD = $true
                $PASSWORD_FOUND = $true
                $FIRST_CONTAINER_FOUND = "Container 1"
            }
        }
    }
    
    # Check if part 2 is done and if password was found
    if (Test-Path "results\parallel_part2_result.txt") {
        $part2Content = Get-Content "results\parallel_part2_result.txt" -ErrorAction SilentlyContinue
        if ($part2Content -match "PERFORMANCE SUMMARY") {
            $PART2_DONE = $true
            if (Test-Path "results\password_found_part2") {
                $PART2_FOUND_PASSWORD = $true
                $PASSWORD_FOUND = $true
                $FIRST_CONTAINER_FOUND = "Container 2"
            }
        }
    }
    
    # Stop monitoring when password is found OR both containers finish
    if ($PASSWORD_FOUND) {
        Write-Host "Password found by $FIRST_CONTAINER_FOUND! Stopping monitoring..." -ForegroundColor Green
        # Kill the other container's hashcat process to simulate real parallel behavior
        if ($FIRST_CONTAINER_FOUND -eq "Container 1") {
            docker exec hashcat-parallel-2 pkill -f hashcat 2>$null
        } else {
            docker exec hashcat-parallel-1 pkill -f hashcat 2>$null
        }
        Write-Host "Parallel search completed successfully." -ForegroundColor Green
        break
    } elseif ($PART1_DONE -and $PART2_DONE) {
        Write-Host "Both parallel containers completed - no password found." -ForegroundColor Yellow
        break
    }
    
    # Show progress every 3 seconds for more responsive feedback
    if (($COUNT % 3) -eq 0) {
        $STATUS_MSG = "Monitoring parallel containers... (${COUNT}s) "
        if ($PART1_DONE) { $STATUS_MSG += "[C1: DONE] " } else { $STATUS_MSG += "[C1: RUNNING] " }
        if ($PART2_DONE) { $STATUS_MSG += "[C2: DONE]" } else { $STATUS_MSG += "[C2: RUNNING]" }
        Write-Host $STATUS_MSG
    }
    
    Start-Sleep -Seconds 1
    $COUNT++
}

# Record parallel end time
$PARALLEL_END = Get-Date

# Calculate parallel duration
$PARALLEL_DURATION = ($PARALLEL_END - $PARALLEL_START).TotalSeconds

# Step 6: Generate comparison report
Write-Host ""
Write-Host "Generating performance comparison report..." -ForegroundColor Cyan

$REPORT_FILE = "results\performance_comparison_report.txt"

# Create report header
@"
========================================
HASHCAT PERFORMANCE COMPARISON REPORT
========================================
Generated at: $(Get-Date)

TEST CONFIGURATION:
- Hash Type: WPA-PBKDF2-PMKID+EAPOL (mode 22000)
- Target Hash: test.hc22000
- Wordlist Size: $((Get-Content massive_wordlist.txt | Measure-Object).Count) passwords
- Container Resources: 2 CPU cores, 2GB RAM each

==========================================
SINGLE CONTAINER RESULTS:
==========================================
"@ | Out-File $REPORT_FILE -Encoding UTF8

if (Test-Path $SINGLE_RESULT_FILE) {
    Get-Content $SINGLE_RESULT_FILE | Add-Content $REPORT_FILE
} else {
    "Single container test results not available" | Add-Content $REPORT_FILE
}

@"

==========================================
PARALLEL CONTAINERS RESULTS:
==========================================
Total Parallel Execution Time: $($PARALLEL_DURATION.ToString("F2")) seconds

--- CONTAINER 1 (First Half) ---
"@ | Add-Content $REPORT_FILE

if (Test-Path "results\parallel_part1_result.txt") {
    Get-Content "results\parallel_part1_result.txt" | Add-Content $REPORT_FILE
} else {
    "Parallel container 1 results not available" | Add-Content $REPORT_FILE
}

"`n--- CONTAINER 2 (Second Half) ---" | Add-Content $REPORT_FILE

if (Test-Path "results\parallel_part2_result.txt") {
    Get-Content "results\parallel_part2_result.txt" | Add-Content $REPORT_FILE
} else {
    "Parallel container 2 results not available" | Add-Content $REPORT_FILE
}

# Extract timing information and create summary
@"

===========================================
PERFORMANCE COMPARISON SUMMARY:
===========================================
"@ | Add-Content $REPORT_FILE

# Extract single container time
if ((Test-Path $SINGLE_RESULT_FILE) -and ((Get-Content $SINGLE_RESULT_FILE) -match "Total execution time:")) {
    $singleTimeMatch = (Get-Content $SINGLE_RESULT_FILE | Select-String "Total execution time:").Line
    $SINGLE_TIME = ($singleTimeMatch -split '\s+')[3]
    "Single Container Time: $SINGLE_TIME seconds" | Add-Content $REPORT_FILE
} else {
    $SINGLE_TIME = $null
    "Single Container Time: N/A" | Add-Content $REPORT_FILE
}

"Parallel Total Time: $($PARALLEL_DURATION.ToString("F2")) seconds" | Add-Content $REPORT_FILE

# Add explanation of parallel timing
if ($PASSWORD_FOUND) {
    "Parallel Timing Method: Stopped when $FIRST_CONTAINER_FOUND found password" | Add-Content $REPORT_FILE
} else {
    "Parallel Timing Method: Both containers completed (no password found)" | Add-Content $REPORT_FILE
}

# Calculate performance improvement
if ($SINGLE_TIME -and ($SINGLE_TIME -ne "N/A")) {
    try {
        $singleTimeNum = [double]$SINGLE_TIME
        $IMPROVEMENT = (($singleTimeNum - $PARALLEL_DURATION) / $singleTimeNum * 100)
        "Performance Improvement: $($IMPROVEMENT.ToString("F2"))%" | Add-Content $REPORT_FILE
        
        if ($PARALLEL_DURATION -lt $singleTimeNum) {
            "RESULT: Parallel processing is FASTER" | Add-Content $REPORT_FILE
        } else {
            "RESULT: Single container is FASTER" | Add-Content $REPORT_FILE
        }
    } catch {
        "Performance calculation failed" | Add-Content $REPORT_FILE
    }
}

# Check password discovery
if ((Test-Path "results\password_found_part1") -or (Test-Path "results\password_found_part2")) {
    "Password Discovery: Found in parallel processing" | Add-Content $REPORT_FILE
    # Show which container found it
    if (Test-Path "results\password_found_part1") {
        "Password found by: Container 1 (First Half)" | Add-Content $REPORT_FILE
    } elseif (Test-Path "results\password_found_part2") {
        "Password found by: Container 2 (Second Half)" | Add-Content $REPORT_FILE
    }
} elseif ((Test-Path $SINGLE_RESULT_FILE) -and ((Get-Content $SINGLE_RESULT_FILE) -match "^[^:]+:[^:]+:[^:]+:[^:]+$")) {
    "Password Discovery: Found in single container" | Add-Content $REPORT_FILE
    # Extract and show the password
    $crackedLine = (Get-Content $SINGLE_RESULT_FILE | Select-String "^[^:]+:[^:]+:[^:]+:[^:]+$").Line
    if ($crackedLine) {
        $password = $crackedLine.Split(':')[4]
        "Extracted password: $password" | Add-Content $REPORT_FILE
    }
} else {
    "Password Discovery: Not found in either test" | Add-Content $REPORT_FILE
}

# Display final report
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "PERFORMANCE TEST COMPLETED!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Get-Content $REPORT_FILE

Write-Host ""
Write-Host "Full detailed report saved to: $REPORT_FILE" -ForegroundColor Yellow
Write-Host ""