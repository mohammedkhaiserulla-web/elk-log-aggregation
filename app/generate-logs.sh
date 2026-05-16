#!/bin/bash

LOG_LEVELS=("INFO" "WARNING" "ERROR" "DEBUG")
MESSAGES=(
  "User login successful"
  "Database connection established"
  "API request received"
  "Cache miss detected"
  "Payment processed successfully"
  "Authentication failed"
  "Timeout connecting to service"
  "Request rate limit exceeded"
)

echo "Starting log generator..."

while true; do
  LEVEL=${LOG_LEVELS[$RANDOM % ${#LOG_LEVELS[@]}]}
  MESSAGE=${MESSAGES[$RANDOM % ${#MESSAGES[@]}]}
  TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "${TIMESTAMP} [${LEVEL}] ${MESSAGE}"
  sleep 2
done