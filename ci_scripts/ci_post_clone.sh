#!/bin/sh
set -eu

# Xcode Cloud post-clone hook.
#
# *.xcodeproj/ is gitignored — XcodeGen regenerates it from project.yml on
# every build. Without this step Xcode Cloud has no project to open.
#
# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud to the checkout root.

if [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
    echo "ci_post_clone: CI_PRIMARY_REPOSITORY_PATH is unset; aborting." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
