#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "🧪 Running Assert-Based Logic & Isolation Tests..."
/usr/bin/swift run LogicTests
