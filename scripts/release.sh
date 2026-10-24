#!/bin/bash
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.2.1
#
# Run on an up-to-date main after merging dev. Sets VitalLensVersion.current (the version the SDK sends to the
# API as part of its origin) and the version in the README install snippet, commits them and tags the commit.
# Nothing is pushed; push as the script suggests.
set -euo pipefail

VERSION="${1:-}"
FILE="Sources/VitalLensInference/VitalLensVersion.swift"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <version>  (e.g. 0.2.1)" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Run this on main (currently on $(git branch --show-current))." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree is not clean." >&2
  exit 1
fi
git fetch --quiet origin --tags
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "main is not level with origin/main. Pull (or push) first." >&2
  exit 1
fi
if git rev-parse --quiet --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "Tag v$VERSION already exists." >&2
  exit 1
fi

perl -pi -e "s/(static let current = \")[^\"]*(\")/\${1}$VERSION\${2}/" "$FILE"
if ! grep -q "static let current = \"$VERSION\"" "$FILE"; then
  echo "Could not set the version in $FILE." >&2
  git checkout -- "$FILE"
  exit 1
fi

# The install snippet in the README
perl -pi -e "s/(vitallens-ios\.git\", from: \")[^\"]*(\")/\${1}$VERSION\${2}/" README.md
if ! grep -q "vitallens-ios.git\", from: \"$VERSION\"" README.md; then
  echo "Could not set the version in README.md." >&2
  git checkout -- "$FILE" README.md
  exit 1
fi

git add "$FILE" README.md
git commit --quiet -m "$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"

echo "Created commit and tag v$VERSION. Next:"
echo "  git push origin main --follow-tags"
echo "  git switch dev && git merge main && git push origin dev"
