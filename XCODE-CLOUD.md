# YourDartClub — Xcode Cloud

Repository: https://github.com/pithmedia/YourDartClub_ios
Branch: main. Project: YourDartClub.xcodeproj. Shared scheme: YourDartClub.

The repository root is the local ios/ directory, not the Laravel root.
Xcode Cloud builds the committed project and assets. Do not run
generate-project.py in CI: it is a local maintenance utility that also reads
the website logo from the parent Laravel project.

ci_scripts/ci_post_clone.sh downloads the pinned Google Cast and Protobuf
dependencies with SHA-256 verification, then runs the Swift package tests.
A failed setup or test stops the Cloud action. Vendor binaries, signing keys,
local archives, screenshots and Android reference bundles stay out of Git.

Use an Archive action for iOS with App Store Connect distribution. Cloud build
numbers must be higher than any already uploaded build. A successful archive
can be selected in App Store Connect after processing; it does not submit the
app for review or publish it automatically.
