#!/bin/bash
# Xcode Cloud cannot interactively trust Swift macros / package plugins, so a
# dependency shipping either fails resolution with "must be enabled before it can
# be used". These prompts cannot be answered in a headless build.
# Note the misspelling in `Validatation` — that is Apple's key, not a typo to fix.
set -e
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

# BleatKit's tests live in the package and there is no Xcode test target, so an
# archive-only workflow would ship without running a single test.
#
# Scope note: this builds for the macOS host, so it covers BleatKit and
# BleatProcess. The app target is not in the package — its compilation is
# covered by the workflow's own build action, not by this gate. Don't read a
# green run here as "the app compiles". BleatProcess is macOS-only by design
# (Foundation.Process), so it is exercised here and nowhere else.
cd "$CI_PRIMARY_REPOSITORY_PATH/BleatKit"
swift test
