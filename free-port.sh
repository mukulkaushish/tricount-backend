#!/bin/bash

PORT=${1:-8080}

echo "🔍 Checking port $PORT..."

PID=$(lsof -ti:$PORT 2>/dev/null)

if [ -z "$PID" ]; then
    echo "✓ Port $PORT is already free"
    exit 0
fi

echo "⚠️  Found process using port $PORT: $PID"
echo "Killing process..."

kill -9 $PID 2>/dev/null
sleep 1

if lsof -ti:$PORT >/dev/null 2>&1; then
    echo "❌ Failed to free port $PORT"
    exit 1
else
    echo "✓ Port $PORT is now free"
    exit 0
fi
