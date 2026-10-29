
## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```
   git clone https://github.com/avdept/jellyboxplayer.git
   ```
3. Create a new branch for your contribution:
   ```
   git checkout -b feature/your-feature-name
   ```

## Build Toolchain

Android builds use the versions pinned in `android/settings.gradle` and
`android/gradle/wrapper/gradle-wrapper.properties`:

| Tool | Version | Floor enforced by Flutter 3.47 |
| --- | --- | --- |
| Flutter SDK | 3.47.x | Gradle ≥ 8.14, AGP ≥ 8.11.1, KGP ≥ 2.2.20 |
| Gradle | 9.3.1 | warns below 9.1.0 |
| Android Gradle plugin | 9.1.0 | warns below 9.0.1 |
| Kotlin Gradle plugin | 2.4.0 | warns below 2.3.20 |
| JDK / bytecode | 17 | errors below 17 |
| `compileSdk` / `targetSdk` | 36 | — |
| `minSdk` | 24 | warns below 24 |

`android.newDsl=false` and `android.builtInKotlin=false` in
`android/gradle.properties` are temporary opt-outs that keep the Flutter Gradle
plugin working on AGP 9. AGP 10 removes both flags and the legacy DSL, so the
app must move to the modern DSL and Built-in Kotlin before that upgrade lands;
plugins that still apply the Kotlin Gradle plugin (audio_session, flutter_udid,
flutter_volume_controller, in_app_review,
shared_preferences_android, and the vendored flutter_chrome_cast /
home_screen_widgets modules) need Built-in Kotlin support first.

## Making Changes

1. Make your changes in your branch.
2. Test your changes thoroughly.
3. Commit your changes with a clear and descriptive commit message:
   ```
   git commit -m "Add feature: description of your changes"
   ```

## Submitting a Pull Request

1. Push your changes to your fork on GitHub:
   ```
   git push origin feature/your-feature-name
   ```
2. Go to the original repository on GitHub and create a new pull request.
3. Provide a clear description of your changes in the pull request.

## Code Style

- Follow the existing code style in the project.
- Use meaningful variable and function names.
- Comment your code where necessary.

## Reporting Bugs

If you find a bug, please create an issue on GitHub with the following information:
- A clear, descriptive title
- Steps to reproduce the bug
- Expected behavior
- Actual behavior
- Any relevant logs or screenshots

## Feature Requests

We welcome feature requests! Please create an issue on GitHub with a clear description of the feature and why it would be beneficial to the project.

Thank you for contributing to Jellybox Player
