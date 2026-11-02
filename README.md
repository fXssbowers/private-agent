# PrivateAgent

PrivateAgent is an open-source Android automation agent built with Flutter. It utilizes the DeepSeek API and native Android Accessibility Services to interpret screen layouts and execute multi-step tasks across any installed application via natural language commands.


## Android TV work in this fork

The `codex/android-tv-controls` branch adds experimental TV control fixes:
accessible controls are activated before touch gestures; gestures report their
completion or cancellation; generic Enter and direct keyboard-key interaction are rejected on TV to prevent focused-letter insertion; searches use explicit application submit controls;
application results take priority over keyboard suggestions. Failed, cancelled,
and step-limited tasks remain failures in the chat. Task-local screen/action history
lets the model recognize repeated navigation routes. A third identical action on
the same observed screen is blocked, including across intervening screens or waits;
three blocked proposals stop the task. The model can choose another visible route
within the existing step limit. Saved actions require fresh screen verification.

Persistent app memory stores contextual navigation lessons in the app's private
`app_memory/<package>.json` files: at most 8 KiB per app and 64 KiB total, measured
as UTF-8 bytes, including a staging copy during replacement. Older observations
and app files are pruned at the limits. Five relevant notes at most accompany a
step; app-version changes fence off old lessons. Memory does not add AI requests.
Observed lessons use control-layout fingerprints and navigation outcomes, never
raw screen dumps, movie/channel titles or typed queries. Text-based learning is limited to known navigation labels such as Search/Back;
content titles are never learned as text targets. An accepted click
or changed layout is not evidence that the user's goal succeeded.

Settings → App memory lets users inspect lessons, add conditional navigation advice
and clear one app's notes, including notes from a previous app version. User-entered advice is kept distinct from observed
transitions and still requires checking the visible screen. User advice can be
scoped to search/text entry, navigation menus, other screens or any screen.
Matching observed evidence retains a prompt slot even when many user hints exist. Old goal-matched
`skills_memory.jsonl` macros are retained unchanged for rollback, but are neither
replayed nor expanded. Recent task history is capped at 128 KiB and 50 records,
with bounded traces; its statistics describe retained tasks, not lifetime totals.

Storage serializes same-process Flutter engines with exclusive lock-file creation
and synchronous small transactions. The app's Android components run in one OS
process. A full app restart recovers abandoned locks from the prior process; a busy
lock is never stolen from a live engine. File/storage failures disable learning for
that observation without changing the task outcome. App memory is a hint, not an
input capability: TiviMate navigation still needs real-device validation.

The tested configuration uses the Custom provider, base URL
`https://api.openai.com/v1`, model `gpt-6.1-terra`, and a 4096-token response limit.
The Terra payload adaptation is restricted to that exact provider/model pair.
Configure credentials in the app. These control fixes use the existing
accessibility service and do not require Shizuku or root.

Build and unit-test with Flutter 3.47.9:

```sh
flutter test
flutter build apk --release --target-platform android-arm
```

Real-device tests live in `android/app/src/androidTest`. Build their target/test
APK pair with `-PnativeControlTests=true` to avoid cross-APK R8 class optimizations.
The instrumentation emits `stage=waiting_for_accessibility`: after its process
restart, rebind the already-enabled PrivateAgent service while preserving other
accessibility services. Normal release builds remain optimized. Full task results
must be checked on the destination screen; acceptance of an Android action alone
is insufficient. Voice input and compatibility with other TV models require
separate validation.

## Architecture

The system operates on a continuous feedback loop:
1. The user issues a command (via voice, text, or Telegram remote access).
2. The agent captures the current screen hierarchy, calculating the exact spatial coordinates of all interactive elements.
3. The layout data is transmitted to the AI provider alongside the current task context and the result of the previous action.
4. The AI determines the next optimal action (e.g., clicking specific coordinates, inputting text, scrolling).
5. The native Android layer executes the action.
6. The loop repeats until the task is marked as complete.

## Capabilities

- **Screen Reading:** Parses the Android UI tree to map clickable, scrollable, and editable elements.
- **Coordinate-Based Interaction:** Simulates physical screen taps based on coordinate geometry, mitigating issues with missing text labels or inaccessible icons.
- **Remote Access:** Integrates with the Telegram Bot API via background polling, allowing users to issue commands and monitor task execution progress remotely.
- **Voice Control:** Native speech-to-text integration for hands-free operation.

## Installation

Download the latest APK directly from the [Releases Page](https://github.com/orailnoor/private-agent/releases).

Choose `app-universal-release.apk` when it is available. It supports ARM64,
32-bit ARM, and x86_64 devices in one package. If a release only provides split
APKs, most modern Android phones—including Snapdragon devices—must use
`app-arm64-v8a-release.apk`.

PrivateAgent supports Android 8.0 (API 26) and newer. Current release builds are
also checked for Android 15/16's 16 KB native-library alignment requirement.

## Setup Instructions (How to use for FREE)

This app requires an AI brain to operate. You can use it **100% for free** by using OpenRouter's free models.

1. Install the APK on your Android device (API 30+ recommended).
2. Go to [OpenRouter.ai](https://openrouter.ai/) and create a free account.
3. Generate a free API Key.
4. Launch PrivateAgent and go to the **Settings** screen.
5. Tap the **"OpenRouter"** quick-select chip under Base URL.
6. Paste your API Key.
7. Type `openai/gpt-oss-120b:free` (or any other free model) into the Model field.
8. Enable the **"PrivateAgent Screen Control"** service in your Android Accessibility Settings.

### “Restricted setting” when enabling Screen Control

Android may block accessibility access for apps installed from an APK. This is
an operating-system safety restriction:

1. Open **Settings → Apps → PrivateAgent**.
2. Open the three-dot menu in the top-right corner.
3. Tap **Allow restricted settings** and confirm.
4. Return to PrivateAgent and open **Accessibility Settings** again.
5. Enable **PrivateAgent Screen Control**.

PrivateAgent now shows these instructions and provides shortcuts to both App
Info and Accessibility Settings during onboarding.

## Telegram Integration

To enable remote access:
1. Acquire a bot token from BotFather on Telegram.
2. Input the token in the PrivateAgent Settings screen and enable the integration toggle.
3. The application will maintain a background polling connection to the Telegram API to receive commands.

## License

This project is open-source and available for modification.
