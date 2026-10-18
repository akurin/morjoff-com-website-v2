#!/bin/bash
set -euo pipefail

# hugo/public is committed as built, so build with the Hugo version the theme
# was checked against; a different version can fail or change every page.
HUGO_VERSION="0.168.0"
HUGO="${HUGO:-hugo}"

# Read the version first: piping into `grep -q` under pipefail can fail when
# grep exits before hugo has finished writing.
found="$("$HUGO" version 2>&1 || true)"
if [[ "$found" != *"v${HUGO_VERSION}-"*"+extended"* ]]; then
	echo "Hugo extended v${HUGO_VERSION} is required, found: ${found:-none}" >&2
	echo "Download: https://github.com/gohugoio/hugo/releases/tag/v${HUGO_VERSION}" >&2
	echo "or point HUGO at that binary: HUGO=/path/to/hugo ./build.sh" >&2
	exit 1
fi

# Start from an empty public/ so pages removed from content don't linger.
rm -rf hugo/public
(cd hugo && "$HUGO")
