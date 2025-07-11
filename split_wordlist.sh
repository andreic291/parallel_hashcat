#!/bin/bash

# Script to split wordlist into two equal parts for parallel processing

WORDLIST_FILE="../massive_wordlist.txt"
OUTPUT_DIR="../wordlists"

echo "Splitting wordlist for parallel processing..."

# Get total number of lines
TOTAL_LINES=$(wc -l < "$WORDLIST_FILE")
HALF_LINES=$((TOTAL_LINES / 2))

echo "Total passwords: $TOTAL_LINES"
echo "Each half will have: $HALF_LINES passwords"

# Split the wordlist
head -n $HALF_LINES "$WORDLIST_FILE" > "$OUTPUT_DIR/wordlist_part1.txt"
tail -n +$((HALF_LINES + 1)) "$WORDLIST_FILE" > "$OUTPUT_DIR/wordlist_part2.txt"

# Verify split
PART1_LINES=$(wc -l < "$OUTPUT_DIR/wordlist_part1.txt")
PART2_LINES=$(wc -l < "$OUTPUT_DIR/wordlist_part2.txt")

echo "Part 1 has: $PART1_LINES passwords"
echo "Part 2 has: $PART2_LINES passwords"
echo "Total split: $((PART1_LINES + PART2_LINES)) passwords"

echo "Wordlist split completed!" 