#!/usr/bin/env bash
# Double-click on macOS, or run from any terminal. Prompts stay on the client.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$here/run.sh" --interactive "$@"
