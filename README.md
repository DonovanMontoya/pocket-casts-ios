# Pocket Casts iOS — ad-skipping experiment

This is my personal fork of [Pocket Casts for iOS](https://github.com/Automattic/pocket-casts-ios), where I’m testing automatic ad detection and skipping. It is an experiment, unaffiliated with Pocket Casts or Automattic.

The experiment lives on [`feat/ad-skipping`](https://github.com/DonovanMontoya/pocket-casts-ios/tree/feat/ad-skipping). It transcribes downloaded episode audio on the iPhone with Apple Speech, checks transcript text for ads using OpenAI Decisions, and skips detected segments during playback. It also compares publisher-provided transcripts when available. Detected segments appear in episode details, the player timeline, and the chapters tab.

Trying it requires iOS 26 or later and your own API key with access to the classification endpoint. Configure the key in **Settings → Ad Skipping**; it is stored in the device Keychain. Transcript text is sent to the external classification service; audio is transcribed on the device. API usage is billed to your account. Detection can miss ads or mistake episode content for ads; the settings include a confidence threshold and per-podcast controls.

The `config/Personal/` files are my local signing setup, not a ready-to-use distribution configuration. Use your own signing identity and bundle identifiers when building for a device.

The upstream code and modifications to it remain under the [Mozilla Public License 2.0](LICENSE.md). Existing copyright and license notices are retained. The build instructions below come from upstream.

## Setup

If you don't already have it, you need to install Bundler:

`gem install bundler`

Next you'll need to install all the dependencies needed for [_fastlane_](https://docs.fastlane.tools/) using this script:

`make install_dependencies`

### Secrets

Internal contributors need to install and set up [`a8c-secrets`](https://github.com/Automattic/a8c-secrets), then decrypt the project secrets before building:

`a8c-secrets decrypt`

Re-run it whenever the secrets are rotated; the build does not decrypt them for you.

External contributors don't need the secrets; see [below](#external-contributors).

## External contributors

If you're an external contributor run `make external_contributor`. After that you should be able to build and run the project.

## Swift Formatting

We use [SwiftLint](https://github.com/realm/SwiftLint) to ensure code is spaced and formatted the same way and follows the same [general conventions](https://github.com/Automattic/swiftlint-config). We have a script that will run it over the whole project.

Once the required dependencies are installed via `bundle exec pod install`, you can run:

`make format`

You should do this before making a pull request.

## Running

Open the `.xcodeproj` file, select the Pocket Casts project and the Simulator Device you want to run on, and hit the play button.

## Localization

You can learn more about localization at [docs/Localization.md](./docs/localization.md)

## Protocol Buffers

The app uses [Google Protocol Buffers](https://developers.google.com/protocol-buffers) to define our server objects.

To update server objects you'll need to install the protobuf command line tool as well as the [Swift Protobuf](https://github.com/apple/swift-protobuf) translators. This can be done via Homebrew with:

```
brew install protobuf
brew install swift-protobuf
```

To update the protobuf files you can then run:

Replace the `{API_PATH}` with the full path to the `pocketcasts-api/api/modules/protobuf/src/main/proto` folder

```
make update_proto API_PATH={API_PATH}
```

## Debugging

### Logs

Logs can be found in the app as a view and shared from there through the system sheet or mail:
* Profile > Help & Feedback > ⋯ > Logs

When debugging analytics, the `tracksLogging` feature flag will enable logging for these events.

### Export Files

An export can be created with the database, settings plist, and logs for debugging purposes:
* Profile > Help & Feedback > ⋯ > Export Database - the export will include all log files and settings
* Profile > Settings > Developer > Export Bundle

These exports can also be imported to the app, replacing the database and settings with the ones from the file. This will prompt the user before replacement.
* Open the file with Pocket Casts directly from Files
* Drag and drop the file on the Simulator
* Profile > Settings > Developer > Import Bundle

### Crash Log Symbolication

All [releases](https://github.com/Automattic/pocket-casts-ios/releases) include dSYMs inside of the `xcarchive` file.

These can be used along with the [MacSymbolicator](https://github.com/inket/MacSymbolicator) app to symbolicate any crash logs.
