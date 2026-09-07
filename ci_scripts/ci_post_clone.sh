#!/bin/bash
# Xcode Cloud cannot interactively trust Swift macros / package plugins, so a
# dependency shipping either fails resolution with "must be enabled before it can
# be used". These prompts cannot be answered in a headless build.
# Note the misspelling in `Validatation` — that is Apple's key, not a typo to fix.
#
# Scope: these keys affect Xcode's own resolution, i.e. the workflow's build
# action. They do NOT cover the `swift test` below, which uses SwiftPM's
# resolution.
#
# SwiftTerm ships a build tool plugin (SwiftTermBuildInfoPlugin), so the graph
# now contains exactly the kind of dependency this guards against. Verified
# 5 Sept 2026: SwiftPM's command line runs build tool plugins without any trust
# prompt — that is an Xcode concept — so `swift test` passes with it in the
# graph. The keys above remain what carries the *build action*.
set -e
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

# BleatKit's tests live in the package and there is no Xcode test target, so an
# archive-only workflow would ship without running a single test.
#
# Scope note: this builds for the macOS host, so it covers BleatKit, BleatUI and
# BleatProcess. The app target is not in the package — its compilation is
# covered by the workflow's own build action, not by this gate. Don't read a
# green run here as "the app compiles". BleatProcess is macOS-only by design
# (Foundation.Process), so it is exercised here and nowhere else.
#
# `:?` rather than a bare expansion: unset, this would `cd /BleatKit` and fail
# with something that looks nothing like the actual problem.
cd "${CI_PRIMARY_REPOSITORY_PATH:?set by Xcode Cloud; run this from a workflow}/BleatKit"
swift test

# **A release build, because a debug one cannot see this class of failure.**
# `swift-frontend` 6.3.3 segfaults optimising BleatUI unless `RemoteList` writes
# its deinit out — see the comment on it — and nothing in the ordinary loop
# would notice: `swift build`, `swift test` and every debug run on a device are
# green either way. The first thing it breaks is the archive, which is the last
# step before TestFlight and the slowest place to find out.
#
# Four seconds, and only the module that has been bitten. Not `swift build -c
# release` for the whole package: the console tool and its dependencies add
# minutes for no extra coverage of the thing being guarded.
swift build -c release --target BleatUI
