#!/bin/bash

# Main performance testing orchestration script with persistent containers

echo "=========================================="
echo "HASHCAT PERFORMANCE COMPARISON TEST"
echo "Single Container vs Parallel Processing"
echo "=========================================="

# Function to cleanup hashcat processes (not containers)
cleanup_processes() {
    echo "Cleaning up any running hashcat processes..."
    docker exec hashcat-single pkill -f hashcat 2>/dev/null || true
    docker exec hashcat-parallel-1 pkill -f hashcat 2>/dev/null || true
    docker exec hashcat-parallel-2 pkill -f hashcat 2>/dev/null || true
    
    # Clear previous results
    rm -f results/*.txt results/password_found_*
}

# Function to ensure containers are running
ensure_containers_running() {
    echo "Checking container status..."
    
    # Check if containers exist and are running
    SINGLE_RUNNING=$(docker ps -q -f name=hashcat-single)
    PARALLEL1_RUNNING=$(docker ps -q -f name=hashcat-parallel-1)
    PARALLEL2_RUNNING=$(docker ps -q -f name=hashcat-parallel-2)
    
    if [ -z "$SINGLE_RUNNING" ] || [ -z "$PARALLEL1_RUNNING" ] || [ -z "$PARALLEL2_RUNNING" ]; then
        echo "Starting containers (first time setup)..."
        docker-compose up -d
        echo "Waiting for containers to initialize..."
        sleep 5
    else
        echo "All containers already running - no cold start needed!"
    fi
    
    # Verify all containers are healthy
    if ! docker exec hashcat-single echo "Container ready" >/dev/null 2>&1; then
        echo "ERROR: hashcat-single container not responding"
        exit 1
    fi
    if ! docker exec hashcat-parallel-1 echo "Container ready" >/dev/null 2>&1; then
        echo "ERROR: hashcat-parallel-1 container not responding"
        exit 1
    fi
    if ! docker exec hashcat-parallel-2 echo "Container ready" >/dev/null 2>&1; then
        echo "ERROR: hashcat-parallel-2 container not responding"
        exit 1
    fi
    
    echo "All containers are ready!"
}

# Function to wait for file creation with timeout
wait_for_file() {
    local file="$1"
    local timeout="$2"
    local count=0
    
    while [ ! -f "$file" ] && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    [ -f "$file" ]
}

# Clean up processes (not containers) for fresh test
cleanup_processes

# Step 1: Ensure containers are running (no rebuild unless needed)
echo ""
echo "Step 1: Ensuring containers are available..."
ensure_containers_running

# Step 2: Prepare wordlists for testing
echo ""
echo "Step 2: Preparing wordlists for single and parallel processing..."

WORDLIST_FILE="massive_wordlist.txt"
OUTPUT_DIR="wordlists"

echo "Creating wordlist files dynamically..."

# Create wordlists directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Get total number of lines
TOTAL_LINES=$(wc -l < "$WORDLIST_FILE")
HALF_LINES=$((TOTAL_LINES / 2))

echo "Total passwords: $TOTAL_LINES"
echo "Creating wordlists for testing..."

# Create single container wordlist (copy of original for consistency)
cp "$WORDLIST_FILE" "$OUTPUT_DIR/single_wordlist.txt"
echo "Single container wordlist: $TOTAL_LINES passwords"

# Split the wordlist for parallel processing
head -n $HALF_LINES "$WORDLIST_FILE" > "$OUTPUT_DIR/wordlist_part1.txt"
tail -n +$((HALF_LINES + 1)) "$WORDLIST_FILE" > "$OUTPUT_DIR/wordlist_part2.txt"

# Verify all files were created
SINGLE_LINES=$(wc -l < "$OUTPUT_DIR/single_wordlist.txt")
PART1_LINES=$(wc -l < "$OUTPUT_DIR/wordlist_part1.txt")
PART2_LINES=$(wc -l < "$OUTPUT_DIR/wordlist_part2.txt")

echo "Single wordlist: $SINGLE_LINES passwords"
echo "Parallel part 1: $PART1_LINES passwords"
echo "Parallel part 2: $PART2_LINES passwords"
echo "Total parallel: $((PART1_LINES + PART2_LINES)) passwords"

if [ ! -f "$OUTPUT_DIR/single_wordlist.txt" ] || [ ! -f "$OUTPUT_DIR/wordlist_part1.txt" ] || [ ! -f "$OUTPUT_DIR/wordlist_part2.txt" ]; then
    echo "ERROR: Failed to create wordlist files"
    exit 1
fi

echo "Wordlist preparation completed successfully!"

# Step 3: Run single container test
echo ""
echo "Step 3: Running SINGLE container performance test..."
echo "======================================================="

# Make scripts executable
chmod +x scripts/*.sh

# Run single container test (containers already running)
docker exec hashcat-single bash /hashcat-test/scripts/test_single.sh

SINGLE_RESULT_FILE="results/single_container_result.txt"
if [ -f "$SINGLE_RESULT_FILE" ]; then
    echo "Single container test completed!"
    echo "Results saved to: $SINGLE_RESULT_FILE"
else
    echo "ERROR: Single container test failed"
fi

# Step 4: Clean up for parallel test
echo ""
echo "Step 4: Preparing for PARALLEL container test..."
rm -f results/password_found_* results/parallel_*_result.txt

# Step 5: Run parallel containers test
echo ""
echo "Step 5: Running PARALLEL containers performance test..."
echo "======================================================="

# Start both parallel tests simultaneously
echo "Starting parallel processing on both containers..."

# Record parallel start time
PARALLEL_START=$(date +%s.%N)

# Run both parts in parallel (containers already running)
docker exec -d hashcat-parallel-1 bash /hashcat-test/scripts/test_parallel_part1.sh
docker exec -d hashcat-parallel-2 bash /hashcat-test/scripts/test_parallel_part2.sh

echo "Both containers are now processing their respective wordlist halves..."

# Monitor progress and wait for completion
echo "Monitoring parallel execution..."
TIMEOUT=300  # 5 minutes timeout
COUNT=0

# Monitor containers - stop when password found OR both finish
PASSWORD_FOUND=false
FIRST_CONTAINER_FOUND=""

while [ $COUNT -lt $TIMEOUT ]; do
    PART1_DONE=false
    PART2_DONE=false
    PART1_FOUND_PASSWORD=false
    PART2_FOUND_PASSWORD=false
    
    # Check if part 1 is done and if password was found
    if [ -f "results/parallel_part1_result.txt" ]; then
        if grep -q "PERFORMANCE SUMMARY" "results/parallel_part1_result.txt" 2>/dev/null; then
            PART1_DONE=true
            if [ -f "results/password_found_part1" ]; then
                PART1_FOUND_PASSWORD=true
                PASSWORD_FOUND=true
                FIRST_CONTAINER_FOUND="Container 1"
            fi
        fi
    fi
    
    # Check if part 2 is done and if password was found
    if [ -f "results/parallel_part2_result.txt" ]; then
        if grep -q "PERFORMANCE SUMMARY" "results/parallel_part2_result.txt" 2>/dev/null; then
            PART2_DONE=true
            if [ -f "results/password_found_part2" ]; then
                PART2_FOUND_PASSWORD=true
                PASSWORD_FOUND=true
                FIRST_CONTAINER_FOUND="Container 2"
            fi
        fi
    fi
    
    # Stop monitoring when password is found OR both containers finish
    if [ "$PASSWORD_FOUND" = true ]; then
        echo "Password found by $FIRST_CONTAINER_FOUND! Stopping monitoring..."
        # Kill the other container's hashcat process to simulate real parallel behavior
        if [ "$FIRST_CONTAINER_FOUND" = "Container 1" ]; then
            docker exec hashcat-parallel-2 pkill -f hashcat 2>/dev/null || true
        else
            docker exec hashcat-parallel-1 pkill -f hashcat 2>/dev/null || true
        fi
        echo "Parallel search completed successfully."
        break
    elif [ "$PART1_DONE" = true ] && [ "$PART2_DONE" = true ]; then
        echo "Both parallel containers completed - no password found."
        break
    fi
    
    # Show progress every 3 seconds for more responsive feedback
    if [ $((COUNT % 3)) -eq 0 ]; then
        STATUS_MSG="Monitoring parallel containers... (${COUNT}s) "
        if [ "$PART1_DONE" = true ]; then STATUS_MSG="${STATUS_MSG}[C1: DONE] "; else STATUS_MSG="${STATUS_MSG}[C1: RUNNING] "; fi
        if [ "$PART2_DONE" = true ]; then STATUS_MSG="${STATUS_MSG}[C2: DONE]"; else STATUS_MSG="${STATUS_MSG}[C2: RUNNING]"; fi
        echo "$STATUS_MSG"
    fi
    
    sleep 1
    ((COUNT++))
done

# Record parallel end time
PARALLEL_END=$(date +%s.%N)

# Calculate parallel duration
PARALLEL_DURATION=$(echo "$PARALLEL_END - $PARALLEL_START" | bc)

# Step 6: Generate comparison report
echo ""
echo "Step 6: Generating performance comparison report..."
echo "=================================================="

REPORT_FILE="results/performance_comparison_report.txt"

cat > "$REPORT_FILE" << EOF
========================================
HASHCAT PERFORMANCE COMPARISON REPORT
========================================
Generated at: $(date)

TEST CONFIGURATION:
- Hash Type: WPA-PBKDF2-PMKID+EAPOL (mode 22000)
- Target Hash: test.hc22000
- Wordlist Size: $(wc -l < massive_wordlist.txt) passwords
- Container Resources: 2 CPU cores, 2GB RAM each

==========================================
SINGLE CONTAINER RESULTS:
==========================================
EOF

if [ -f "$SINGLE_RESULT_FILE" ]; then
    cat "$SINGLE_RESULT_FILE" >> "$REPORT_FILE"
else
    echo "Single container test results not available" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << EOF

==========================================
PARALLEL CONTAINERS RESULTS:
==========================================
Total Parallel Execution Time: ${PARALLEL_DURATION} seconds

--- CONTAINER 1 (First Half) ---
EOF

if [ -f "results/parallel_part1_result.txt" ]; then
    cat "results/parallel_part1_result.txt" >> "$REPORT_FILE"
else
    echo "Parallel container 1 results not available" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" << EOF

--- CONTAINER 2 (Second Half) ---
EOF

if [ -f "results/parallel_part2_result.txt" ]; then
    cat "results/parallel_part2_result.txt" >> "$REPORT_FILE"
else
    echo "Parallel container 2 results not available" >> "$REPORT_FILE"
fi

# Extract timing information and create summary
echo ""
echo "===========================================" >> "$REPORT_FILE"
echo "PERFORMANCE COMPARISON SUMMARY:" >> "$REPORT_FILE"
echo "===========================================" >> "$REPORT_FILE"

# Extract single container time
if [ -f "$SINGLE_RESULT_FILE" ] && grep -q "Total execution time:" "$SINGLE_RESULT_FILE"; then
    SINGLE_TIME=$(grep "Total execution time:" "$SINGLE_RESULT_FILE" | awk '{print $4}')
    echo "Single Container Time: ${SINGLE_TIME} seconds" >> "$REPORT_FILE"
else
    SINGLE_TIME="N/A"
    echo "Single Container Time: N/A" >> "$REPORT_FILE"
fi

echo "Parallel Total Time: ${PARALLEL_DURATION} seconds" >> "$REPORT_FILE"

# Add explanation of parallel timing
if [ "$PASSWORD_FOUND" = true ]; then
    echo "Parallel Timing Method: Stopped when $FIRST_CONTAINER_FOUND found password" >> "$REPORT_FILE"
else
    echo "Parallel Timing Method: Both containers completed (no password found)" >> "$REPORT_FILE"
fi

# Calculate performance improvement
if [ "$SINGLE_TIME" != "N/A" ]; then
    IMPROVEMENT=$(echo "scale=2; ($SINGLE_TIME - $PARALLEL_DURATION) / $SINGLE_TIME * 100" | bc 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "Performance Improvement: ${IMPROVEMENT}%" >> "$REPORT_FILE"
        
        if (( $(echo "$PARALLEL_DURATION < $SINGLE_TIME" | bc -l) )); then
            echo "RESULT: Parallel processing is FASTER" >> "$REPORT_FILE"
        else
            echo "RESULT: Single container is FASTER" >> "$REPORT_FILE"
        fi
    fi
fi

# Check password discovery
if [ -f "results/password_found_part1" ] || [ -f "results/password_found_part2" ]; then
    echo "Password Discovery: Found in parallel processing" >> "$REPORT_FILE"
    # Show which container found it
    if [ -f "results/password_found_part1" ]; then
        echo "Password found by: Container 1 (First Half)" >> "$REPORT_FILE"
    elif [ -f "results/password_found_part2" ]; then
        echo "Password found by: Container 2 (Second Half)" >> "$REPORT_FILE"
    fi
elif grep -qE "^[^:]+:[^:]+:[^:]+:[^:]+$" "$SINGLE_RESULT_FILE" 2>/dev/null; then
    echo "Password Discovery: Found in single container" >> "$REPORT_FILE"
    # Extract and show the password
    CRACKED_LINE=$(grep -E "^[^:]+:[^:]+:[^:]+:[^:]+$" "$SINGLE_RESULT_FILE" | head -1)
    PASSWORD=$(echo "$CRACKED_LINE" | cut -d':' -f5)
    echo "Extracted password: $PASSWORD" >> "$REPORT_FILE"
else
    echo "Password Discovery: Not found in either test" >> "$REPORT_FILE"
fi

# Display final report
echo ""
echo "=========================================="
echo "PERFORMANCE TEST COMPLETED!"
echo "=========================================="
echo ""
cat "$REPORT_FILE"

echo ""
echo "Full detailed report saved to: $REPORT_FILE"
echo ""
echo "Individual result files:"
echo "- Single container: $SINGLE_RESULT_FILE"
echo "- Parallel part 1: results/parallel_part1_result.txt"
echo "- Parallel part 2: results/parallel_part2_result.txt"

# Optional: Keep containers running for manual inspection
echo ""
echo "Containers are still running for inspection."
echo "To stop them, run: docker-compose down"
echo "To access a container, run: docker exec -it [container-name] bash" 