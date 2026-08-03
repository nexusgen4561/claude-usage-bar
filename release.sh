#!/bin/bash
# Cuts a release: tags the source, repoints the Homebrew formula at the new
# tarball, and publishes a GitHub release.
#
#   ./release.sh 1.1.1 "One-line summary of what changed"
#
# Requires the tap to be tapped locally (brew tap nexusgen4561/tap) and gh
# to be authenticated.
set -euo pipefail

VERSION="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-}"
REPO="nexusgen4561/claude-usage-bar"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TAP="$(brew --repository)/Library/Taps/nexusgen4561/homebrew-tap"
FORMULA="$TAP/Formula/claude-usage-bar.rb"

if [ ! -f "$FORMULA" ]; then
    echo "error: no tap at $TAP" >&2
    echo "       run: brew tap nexusgen4561/tap" >&2
    exit 1
fi
if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
    echo "error: working tree is dirty — commit before releasing" >&2
    exit 1
fi

echo "==> Tagging v$VERSION"
git -C "$SRC_DIR" tag -a "v$VERSION" -m "v$VERSION"
git -C "$SRC_DIR" push origin HEAD
git -C "$SRC_DIR" push origin "v$VERSION"

# GitHub generates the tarball on demand, so it can 404 for a moment after the
# tag lands. Retry, and verify it really is a tarball — piping a failed curl
# into shasum would otherwise checksum an empty stream and "succeed".
echo "==> Checksumming the release tarball"
URL="https://github.com/$REPO/archive/refs/tags/v$VERSION.tar.gz"
TARBALL="$(mktemp)"
trap 'rm -f "$TARBALL"' EXIT
SHA=""
for _ in 1 2 3 4 5; do
    if curl -fsL -o "$TARBALL" "$URL" && [ -s "$TARBALL" ] && tar tzf "$TARBALL" >/dev/null 2>&1; then
        SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
        break
    fi
    sleep 3
done
if [ -z "$SHA" ]; then
    echo "error: could not download $URL" >&2
    exit 1
fi
echo "    $SHA"

echo "==> Bumping the formula"
/usr/bin/sed -i '' \
    -e "s|/archive/refs/tags/v[^\"]*\.tar\.gz|/archive/refs/tags/v$VERSION.tar.gz|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
    "$FORMULA"
brew audit --strict nexusgen4561/tap/claude-usage-bar
git -C "$TAP" commit -qam "claude-usage-bar $VERSION"
git -C "$TAP" push origin HEAD

echo "==> Publishing the release"
gh release create "v$VERSION" --repo "$REPO" --title "v$VERSION" --notes "${NOTES:-See the commit log.}

Update with:
\`\`\`bash
brew update && brew upgrade claude-usage-bar
\`\`\`

Then restart the widget — Quit from its menu, then \`claude-usage-bar\`."

echo "==> Released v$VERSION"
