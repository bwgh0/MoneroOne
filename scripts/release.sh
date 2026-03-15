#!/bin/bash
set -e

# Usage: ./scripts/release.sh <build-number> [version]
# Example: ./scripts/release.sh 22          → tags v1.0.2-22
#          ./scripts/release.sh 1 1.1.0     → tags v1.1.0-1

BUILD="$1"
VERSION="${2:-1.0.2}"

if [ -z "$BUILD" ]; then
    echo "Usage: ./scripts/release.sh <build-number> [version]"
    echo ""
    echo "CI extracts the version and build from the tag automatically."
    echo "No need to edit any files — just tag and push."
    echo ""
    # Show the last few tags for context
    echo "Recent tags:"
    git tag --sort=-creatordate | head -5
    exit 1
fi

TAG="v${VERSION}-${BUILD}"

# Check we're on main
BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
    echo "Error: not on main (on $BRANCH)"
    exit 1
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: uncommitted changes. Commit or stash first."
    exit 1
fi

echo "Tagging $TAG and pushing..."
git tag "$TAG"
git push origin main "$TAG"
echo "Done. CI will build version $VERSION (build $BUILD) and deploy to TestFlight."
