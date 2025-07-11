#!/bin/bash

# Script to test single container performance

HASH_FILE="test.hc22000"
WORDLIST_FILE="wordlists/single_wordlist.txt"
RESULT_FILE="results/single_container_result.txt"

echo "=== SINGLE CONTAINER PERFORMANCE TEST ===" | tee $RESULT_FILE
echo "Started at: $(date)" | tee -a $RESULT_FILE
echo "" | tee -a $RESULT_FILE

# Record start time
START_TIME=$(date +%s.%N)

# Run hashcat with timing
echo "Running hashcat on full wordlist..." | tee -a $RESULT_FILE
{ time hashcat -a 0 -m 22000 --potfile-disable --status --status-timer=5 $HASH_FILE $WORDLIST_FILE 2>&1; } | tee -a $RESULT_FILE

# Record end time
END_TIME=$(date +%s.%N)

# Calculate duration
DURATION=$(echo "$END_TIME - $START_TIME" | bc)

echo "" | tee -a $RESULT_FILE
echo "=== PERFORMANCE SUMMARY ===" | tee -a $RESULT_FILE
echo "Total execution time: ${DURATION} seconds" | tee -a $RESULT_FILE
echo "Completed at: $(date)" | tee -a $RESULT_FILE

# Check if password was found by looking for the pattern value:value:value:value:value (5 fields)
# More robust regex that matches WPA/WPA2 hashcat output format anywhere in the line
CRACKED_LINE=$(grep -E "[0-9a-f]{32}:[0-9a-f]+:[0-9a-f]+:[^:]+:[^[:space:]]+( |$)" $RESULT_FILE | head -1)
if [ -n "$CRACKED_LINE" ]; then
    echo "STATUS: PASSWORD FOUND" | tee -a $RESULT_FILE
    echo "Cracked line: $CRACKED_LINE" | tee -a $RESULT_FILE
    # Extract the password (5th field - last field after 4 colons) from the hash pattern
    HASH_PATTERN=$(echo "$CRACKED_LINE" | grep -oE "[0-9a-f]{32}:[0-9a-f]+:[0-9a-f]+:[^:]+:[^[:space:]]+")
    PASSWORD=$(echo "$HASH_PATTERN" | cut -d':' -f5)
    echo "Extracted password: $PASSWORD" | tee -a $RESULT_FILE
else
    echo "STATUS: PASSWORD NOT FOUND" | tee -a $RESULT_FILE
fi 