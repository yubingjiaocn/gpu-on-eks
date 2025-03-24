#!/bin/bash

# Set variables
LOG_GROUP_NAME="/aws/events/ec2-fleet-events-v2"
OUTPUT_FILE="ec2_fleet_events.json"
REGION="us-west-2"

echo "Dumping EC2 Fleet events from $LOG_GROUP_NAME to $OUTPUT_FILE..."

# Get all log streams
log_streams=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP_NAME" \
  --region "$REGION" \
  --query "logStreams[*].logStreamName" \
  --output text)

# Create or clear the output file
> "$OUTPUT_FILE"

# Process each log stream
for stream in $log_streams; do
  echo "Processing log stream: $stream"
  
  # Get all events from this stream and append to the output file
  aws logs get-log-events \
    --log-group-name "$LOG_GROUP_NAME" \
    --log-stream-name "$stream" \
    --region "$REGION" \
    --query "events[*]" \
    --output json >> "$OUTPUT_FILE.tmp"
    
  # Remove the closing and opening brackets between streams to make valid JSON
  if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    # If this isn't the first stream, we need to add a comma between arrays
    sed -i '$ s/\]$/,/' "$OUTPUT_FILE"
    sed -i '1 s/^\[//' "$OUTPUT_FILE.tmp"
  fi
  
  cat "$OUTPUT_FILE.tmp" >> "$OUTPUT_FILE"
  rm "$OUTPUT_FILE.tmp"
done

# Ensure the file is valid JSON by wrapping in brackets
sed -i '1 s/^/[/' "$OUTPUT_FILE"
if ! grep -q "\]$" "$OUTPUT_FILE"; then
  echo "]" >> "$OUTPUT_FILE"
fi

echo "All events have been dumped to $OUTPUT_FILE"