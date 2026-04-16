#!/bin/bash

PORT=8080
TIMEOUT=5

echo "🔍 Checking for process using port $PORT..."

# Find process using the port
PID=$(lsof -ti:$PORT 2>/dev/null)

if [ -z "$PID" ]; then
    echo "✓ Port $PORT is free"
else
    echo "⚠️  Found process(es) using port $PORT: $PID"

    # Try graceful shutdown first
    echo "Attempting graceful shutdown..."
    kill -TERM $PID 2>/dev/null

    # Wait for graceful shutdown
    sleep 2

    # Check if process still exists
    if kill -0 $PID 2>/dev/null; then
        echo "⚠️  Graceful shutdown failed, force killing..."
        kill -9 $PID
        sleep 1
    else
        echo "✓ Process terminated gracefully"
    fi
fi

# Final check
if lsof -ti:$PORT >/dev/null 2>&1; then
    echo "❌ ERROR: Port $PORT is still in use"
    echo "Try: lsof -ti:$PORT | xargs kill -9"
    exit 1
fi

echo ""
echo "🚀 Starting Swift server..."
swift run
