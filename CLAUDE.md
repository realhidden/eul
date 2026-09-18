# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build the app
xcodebuild -scheme eul -project ./eul.xcodeproj -sdk macosx build

# Format code (via BuildTools SPM package)
cd BuildTools && swift run -c release swiftformat ../

# Lint format (CI check)
cd BuildTools && swift run -c release swiftformat ../ --lint

# Release build (no signing)
xcodebuild -scheme eul -project ./eul.xcodeproj -sdk macosx build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"
```

CI runs on `macos-latest` with Xcode 12.4 (for Big Sur compatibility). Open `eul.xcodeproj` in Xcode to run/debug.

## Architecture

**eul** is a macOS menu bar hardware monitor built with SwiftUI (min deployment: macOS 10.15).

### Targets

| Target | Purpose |
|--------|---------|
| `eul` | Main app — menu bar items, preferences window, hardware polling |
| `SharedLibrary` | Shared framework — models, widget data, reusable UI components |
| `BatteryWidget`, `CpuWidget`, `MemoryWidget`, `NetworkWidget` | macOS 11+ Big Sur widgets |
| `SelfUpdate` | Auto-update UI (separate process) |
| `BuildTools` | SwiftFormat as a local SPM dependency |

### Main App Structure (eul/)

```
eul/
  AppDelegate.swift        # @NSApplicationMain, window + lifecycle + polling loops
  Store/                   # ObservableObject stores (Combine @Published)
  Schema/                  # Enums, models, protocols
    TextComponents/        # Per-component text display configs
  Views/
    StatusBar/             # NSStatusBar item SwiftUI views (per component)
    Menu/                  # Drop-down menu views (per component)
    Preference/            # Preferences window views
    Chart/                 # LineChart SwiftUI view
  Components/              # Reusable SwiftUI components
  StatusBar/               # NSStatusBar management (StatusBarManager, StatusBarItem)
  Extension/               # Swift extensions
  Utilities/               # Hardware interaction (SMC, IOKit, shell, GPU info)
  ViewModifier/            # Custom SwiftUI view modifiers
```

### Data Flow

1. **Hardware polling** — `AppDelegate` runs timed refresh loops posting `.SMCShouldRefresh` and `.NetworkShouldRefresh` notifications
2. **SmcControl** singleton reads sensor data via SMCKit, posts `.StoreShouldRefresh`
3. **Stores** (e.g. `CpuStore`, `BatteryStore`) observe refresh notifications via `Refreshable` protocol, update `@Published` properties
4. **StatusBarManager** subscribes to store changes, re-renders `NSStatusBar` items with SwiftUI views
5. **SharedStore** enum holds all store singletons, also provides `withGlobalEnvironmentObjects()` view modifier to inject all stores as `@EnvironmentObject`

### Key Singletons

- `SmcControl.shared` — SMC hardware interface (temperatures, fan speeds)
- `StatusBarManager.shared` — menu bar item lifecycle
- `SharedStore.*` — all store instances (battery, cpu, gpu, memory, network, disk, fan, bluetooth, preference, ui, components, etc.)

### Preferences

Persisted to `UserDefaults` as JSON under key `"preference"`. `PreferenceStore` handles load/save, with change observation via Combine. Supports temperature unit, language, text display mode, refresh rates, component visibility, appearance mode, and update settings.

### Dependencies (SPM)

- **SMCKit** — temperature sensor and fan reading via AppleSMC
- **SwiftyJSON** — JSON serialization for preferences and GitHub API
- **Localize-Swift** — i18n (20+ languages in `Resource/`)

### Widgets (macOS 11+)

Each widget target shares data through `SharedLibrary/Container` which accepts widget `Entry` types and makes them available to `TimelineProvider`. Widget sections are built with `WidgetSectionView`.

### Localization

`Resource/` contains `.lproj` directories with `Localizable.strings` for each language. Strings are localized via `Localize-Swift` using `.localized()` calls throughout the codebase.
