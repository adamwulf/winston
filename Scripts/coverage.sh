#!/bin/sh
# Runs the package tests on macOS with coverage, then prints line coverage for every file in
# Sources/. Extra arguments go to `swift test`, for example: Scripts/coverage.sh --filter VoiceLoopTests
#
# Code inside `#if os(iOS)` isn't compiled here, so it isn't counted. See "Testing" in README.md
# for the iOS simulator run.
set -eu
cd "$(dirname "$0")/.."

swift test --build-path .build --enable-code-coverage "$@"

json=$(swift test --build-path .build --show-codecov-path)
coverage=$(dirname "$json")
products=$(dirname "$coverage")

# Every test bundle holds the code of the targets it tests. llvm-cov takes the first as its
# binary and the rest as -object.
first=""
set --
for bundle in "$products"/*.xctest; do
    binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
    if [ -z "$first" ]; then
        first=$binary
    else
        set -- "$@" -object "$binary"
    fi
done

xcrun llvm-cov report -instr-profile "$coverage/default.profdata" "$first" "$@" Sources
