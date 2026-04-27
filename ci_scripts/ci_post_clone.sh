#!/bin/sh
set -e

# Xcode Cloud post-clone hook.
#
# *.xcodeproj/ is gitignored — XcodeGen regenerates it from project.yml on
# every build. Without this step Xcode Cloud has no project to open.
#
# CI_PRIMARY_REPOSITORY_PATH is set by Xcode Cloud to the checkout root.

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
