#!/usr/bin/env sh
set -eu
exec "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)/scripts/publish-client.sh" oreslang "$@"
