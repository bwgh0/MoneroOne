#!/bin/bash
set -e

# Load environment variables
if [ -f "$HOME/.appstoreconnect/.env" ]; then
    export $(cat "$HOME/.appstoreconnect/.env" | xargs)
fi

# Configuration
SCHEME="MoneroOne"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/MoneroOne.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$PROJECT_DIR/ExportOptions.plist"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== MoneroOne TestFlight Upload ===${NC}"

# Check for API key credentials
if [ -z "$APP_STORE_CONNECT_API_KEY_ID" ] || [ -z "$APP_STORE_CONNECT_ISSUER_ID" ]; then
    echo -e "${RED}Error: Missing API credentials${NC}"
    echo "Set these environment variables:"
    echo "  export APP_STORE_CONNECT_API_KEY_ID=your_key_id"
    echo "  export APP_STORE_CONNECT_ISSUER_ID=your_issuer_id"
    echo ""
    echo "And place your .p8 key file at: ~/.appstoreconnect/private_keys/AuthKey_\$KEY_ID.p8"
    exit 1
fi

API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
if [ ! -f "$API_KEY_PATH" ]; then
    echo -e "${RED}Error: API key file not found at $API_KEY_PATH${NC}"
    exit 1
fi

# Clean build directory
echo -e "${YELLOW}Cleaning build directory...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive
echo -e "${YELLOW}Archiving...${NC}"
xcodebuild -project "$PROJECT_DIR/MoneroOne.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    archive

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo -e "${RED}Archive failed${NC}"
    exit 1
fi
echo -e "${GREEN}Archive created${NC}"

# Export IPA
echo -e "${YELLOW}Exporting IPA...${NC}"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

# exportArchive with -allowProvisioningUpdates uploads directly
# so we just check if the export succeeded

echo -e "${GREEN}=== Upload Complete ===${NC}"
echo "Check App Store Connect for the new build"
