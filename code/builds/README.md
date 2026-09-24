# Phone builds

Installable builds are attached to [release v1.0.0](https://github.com/Cosmin-Mare/TIPTOE/releases/tag/v1.0.0), not stored in this folder.

## Android

`tiptoe-release.apk`

Install it on a phone by opening the file and allowing installs from that source. This release is signed with the debug key so it could be built without a Play upload keystore. Replace that signing config before a Play Store upload.

## iOS

`tiptoe.ipa`

This is an App Store package (`com.tiptoe.tiptoe`, version 1.0.0). Drag it into Apple Transporter, then distribute it from App Store Connect. It is not a sideload build.
