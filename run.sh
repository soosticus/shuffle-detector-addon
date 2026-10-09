#!/bin/sh
# Launch the companion from the source tree. Usage: ./run.sh [--cli|--test|--setup] [args]
dir=$(cd "$(dirname "$0")" && pwd)
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1; then exec "$py" "$dir/run.py" "$@"; fi
done
echo "Python 3.9+ not found." >&2
exit 1
