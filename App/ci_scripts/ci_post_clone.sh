#!/bin/sh

# Write the gitignored App/Config/Secrets.xcconfig from Xcode Cloud environment
# variables (TG_API_ID plain, TG_API_HASH marked Secret). A file is needed because
# environment variables have the lowest build-setting precedence, so Shared.xcconfig's
# TG_API_ID = 0 default would win over them. Never echo the values.

set -e

if [ -z "$TG_API_ID" ] || [ -z "$TG_API_HASH" ]; then
    echo "error: TG_API_ID and TG_API_HASH must be set in the Xcode Cloud workflow environment"
    exit 1
fi

secrets_xcconfig="$CI_PRIMARY_REPOSITORY_PATH/App/Config/Secrets.xcconfig"
printf 'TG_API_ID = %s\nTG_API_HASH = %s\n' "$TG_API_ID" "$TG_API_HASH" > "$secrets_xcconfig"
echo "Wrote $secrets_xcconfig"
