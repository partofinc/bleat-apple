// The console tool's own version, independent of the app's MARKETING_VERSION:
// the two ship on different channels and need not move together. They must
// move together when the pairing payload changes, since a phone and a host
// that disagree on it cannot pair.
//
// `Scripts/release-cli.sh` refuses to publish unless its tag is `cli-` plus
// this string. Not `v…`: a `v` tag starts the app's Xcode Cloud release.
#if !os(iOS)
let bleatVersion = "1.0.1"
#endif
