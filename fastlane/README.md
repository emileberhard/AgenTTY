fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios create_app

```sh
[bundle exec] fastlane ios create_app
```

Create AgenTTY app in App Store Connect and Developer Portal

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload App Store metadata and screenshots

### ios install_ios_profiles

```sh
[bundle exec] fastlane ios install_ios_profiles
```

Repair and install iOS App Store + development provisioning profiles

### ios release_preflight

```sh
[bundle exec] fastlane ios release_preflight
```

Validate release credentials and production build policy

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload AgenTTY to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
