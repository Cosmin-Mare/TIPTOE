# Phone builds

Release builds of the TIPTOE phone app (`app/`).

## Android

`android/tiptoe-release.apk`

Install it on a phone with USB debugging, or open the file on the phone and allow installs from that source. This release is signed with the debug key so it can be built without a private upload keystore. Replace that signing config before a Play Store upload.

## iOS

`ios/tiptoe.ipa`

This is an App Store package (`com.tiptoe.tiptoe`, version 1.0.0). Install it by dragging the file into Apple Transporter, then distributing it from App Store Connect. It is not a sideload build.
