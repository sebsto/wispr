# Wispr Voice Dictation App - Technical Design Document

## 1. System Architecture Diagram (Text-Based)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Wispr Application                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   UI Layer      │  │  Service Layer  │  │  System Layer   │ │
│  │                 │  │                 │  │                 │ │
│  │ • MainWindow    │  │ • AudioService  │  │ • HotkeyMonitor │ │
│  │ • RecordingView │◄─┤ • WhisperService│  │ • PermissionMgr │ │
│  │ • SettingsView  │  │ • TextInsertion │  │ • AccessibilityAPI│ │
│  │ • StatusBar     │  │ • StateManager  │  │ • AudioSession  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│           │                     │                     │         │
│           └─────────────────────┼─────────────────────┘         │
│                                 │                               │
├─────────────────────────────────┼─────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                 Core Data Models                            │ │
│  │ • AppState • RecordingState • Settings • TranscriptionJob  │ │
│  └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ External Deps   │  │   macOS APIs    │  │   File System   │ │
│  │ • whisper.cpp   │  │ • AVFoundation  │  │ • UserDefaults  │ │
│  │ • Swift Package │  │ • Accessibility │  │ • Bundle        │ │
│  │   Manager       │  │ • Carbon Events │  │ • Documents     │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## 2. Component Breakdown with Responsibilities

### UI Layer Components

**MainWindow**
- Root window container
- Manages window positioning and visibility
- Handles window lifecycle events

**RecordingView** 
- Floating overlay UI during recording
- Real-time waveform visualization
- Recording timer and status indicators
- Cancel/stop recording controls

**SettingsView**
- Preferences panel for configuration
- Hotkey customization interface
- Whisper model selection
- Audio input device selection

**StatusBarItem**
- Menu bar presence and quick access
- Status indicators (recording, processing)
- Quick settings and quit options

### Service Layer Components

**AudioService**
- Audio recording management
- Real-time audio level monitoring
- Audio format conversion and buffering
- Integration with AVAudioEngine

**WhisperService**
- whisper.cpp integration and management
- Model loading and caching
- Transcription job queue processing
- Performance optimization

**TextInsertionService**
- Accessibility API integration
- Cursor position detection
- Text insertion at active location
- Application context awareness

**StateManager**
- Centralized state management using ObservableObject
- Coordinates between services
- Manages application lifecycle states

### System Layer Components

**HotkeyMonitor**
- Global hotkey registration and monitoring
- Carbon Events API integration
- Customizable key combination handling
- Event filtering and processing

**PermissionManager**
- Microphone access permission handling
- Accessibility permission management
- User guidance for permission setup
- Permission status monitoring

## 3. Data Flow for Recording → Transcription → Insertion

```
User Presses Hotkey
        │
        ▼
┌───────────────────┐
│ HotkeyMonitor     │ ──► Validates permissions
│ detects keypress  │     and app state
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ StateManager      │ ──► Updates UI state
│ starts recording  │     Shows RecordingView
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ AudioService      │ ──► Captures audio data
│ begins capture    │     Provides real-time levels
└───────────────────┘
        │
        ▼
User Releases Hotkey
        │
        ▼
┌───────────────────┐
│ AudioService      │ ──► Stops recording
│ finalizes buffer  │     Prepares audio data
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ WhisperService    │ ──► Processes audio
│ transcribes audio │     Returns text result
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ TextInsertion     │ ──► Finds active cursor
│ inserts text      │     Inserts transcribed text
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ StateManager      │ ──► Resets to idle state
│ completes cycle   │     Hides UI overlay
└───────────────────┘
```

## 4. Class/Struct Design for Key Components

### Core Data Models

```swift
// Application state management
@MainActor
class AppState: ObservableObject {
    @Published var currentState: AppStateType = .idle
    @Published var isRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var lastError: WisprError?
    @Published var settings: AppSettings
}

enum AppStateType {
    case idle, recording, processing, error
}

// Recording session data
struct RecordingSession {
    let id: UUID
    let startTime: Date
    var duration: TimeInterval
    var audioLevels: [Float]
    var audioData: Data?
    var transcriptionResult: String?
}

// Application settings
struct AppSettings: Codable {
    var hotkey: HotkeyConfiguration
    var whisperModel: WhisperModel
    var audioInputDevice: String?
    var insertionBehavior: TextInsertionBehavior
}

struct HotkeyConfiguration: Codable {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    var isEnabled: Bool
}
```

### Service Classes

```swift
// Audio recording service
class AudioService: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    
    @Published var currentLevel: Float = 0.0
    @Published var isRecording: Bool = false
    
    func startRecording() async throws -> RecordingSession
    func stopRecording() async -> Data?
    func getCurrentAudioLevel() -> Float
}

// Whisper transcription service  
class WhisperService {
    private var whisperContext: WhisperContext?
    private let processingQueue = DispatchQueue(label: "whisper.processing")
    
    func loadModel(_ model: WhisperModel) async throws
    func transcribe(_ audioData: Data) async throws -> String
    func isModelLoaded() -> Bool
}

// Text insertion service
class TextInsertionService {
    func insertText(_ text: String) async throws
    func getActiveApplication() -> NSRunningApplication?
    func validateAccessibilityPermissions() -> Bool
}
```

### UI Components

```swift
// Main recording overlay
struct RecordingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var audioService: AudioService
    
    var body: some View {
        VStack {
            WaveformView(audioLevel: audioService.currentLevel)
            RecordingTimer(startTime: appState.recordingStartTime)
            RecordingControls()
        }
    }
}

// Settings panel
struct SettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Form {
            HotkeyConfigurationSection()
            WhisperModelSection()
            AudioDeviceSection()
            TextInsertionSection()
        }
    }
}
```

## 5. State Management Approach

### ObservableObject Pattern
- **AppState**: Central state container using `@ObservableObject`
- **Service Objects**: Individual services as `@ObservableObject` for UI binding
- **Settings**: Persistent configuration using `@AppStorage` and UserDefaults

### State Flow Architecture
```swift
@MainActor
class StateManager: ObservableObject {
    @Published var appState = AppState()
    
    private let audioService = AudioService()
    private let whisperService = WhisperService()
    private let textService = TextInsertionService()
    
    func handleHotkeyPressed() async {
        // Coordinate state transitions
        appState.currentState = .recording
        await startRecording()
    }
    
    func handleHotkeyReleased() async {
        // Process transcription and insertion
        await stopRecordingAndProcess()
        appState.currentState = .idle
    }
}
```

### Reactive UI Updates
- SwiftUI views automatically update based on `@Published` properties
- Combine publishers for complex state transformations
- `@StateObject` and `@ObservedObject` for proper lifecycle management

## 6. Permission Handling Flow

### Permission Types Required
1. **Microphone Access**: AVAudioSession authorization
2. **Accessibility Access**: AXIsProcessTrusted for text insertion
3. **Input Monitoring**: Global hotkey detection

### Permission Flow Implementation
```swift
class PermissionManager: ObservableObject {
    @Published var microphoneStatus: PermissionStatus = .notDetermined
    @Published var accessibilityStatus: PermissionStatus = .notDetermined
    
    func requestAllPermissions() async {
        await requestMicrophonePermission()
        await requestAccessibilityPermission()
    }
    
    func checkPermissionStatus() -> Bool {
        return microphoneStatus == .authorized && 
               accessibilityStatus == .authorized
    }
}

enum PermissionStatus {
    case notDetermined, denied, authorized
}
```

### User Guidance Strategy
- Clear permission request dialogs with explanations
- Step-by-step setup instructions for accessibility access
- Fallback UI states when permissions are denied
- Deep links to System Preferences when needed

## 7. Error Handling Strategy

### Error Types and Recovery
```swift
enum WisprError: LocalizedError {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case audioRecordingFailed(Error)
    case transcriptionFailed(Error)
    case textInsertionFailed(Error)
    case whisperModelLoadFailed(Error)
    
    var errorDescription: String? {
        // User-friendly error messages
    }
    
    var recoverySuggestion: String? {
        // Actionable recovery steps
    }
}
```

### Error Handling Patterns
- **Result Types**: Use `Result<Success, WisprError>` for fallible operations
- **Async Throws**: Leverage Swift's async/await error propagation
- **UI Error States**: Dedicated error views with recovery actions
- **Logging**: Structured logging for debugging without user data

### Graceful Degradation
- Continue operation when non-critical features fail
- Provide alternative workflows when permissions are limited
- Cache successful configurations to avoid repeated failures

## 8. Threading Model

### Main Thread (UI)
- All SwiftUI view updates
- State management operations
- User interaction handling

### Background Queues
```swift
// Audio processing queue
private let audioQueue = DispatchQueue(label: "wispr.audio", qos: .userInitiated)

// Whisper processing queue  
private let whisperQueue = DispatchQueue(label: "wispr.whisper", qos: .userInitiated)

// File I/O queue
private let fileQueue = DispatchQueue(label: "wispr.file", qos: .utility)
```

### Async/Await Integration
- Service methods use async/await for clean asynchronous code
- `@MainActor` annotations ensure UI updates on main thread
- Structured concurrency with TaskGroup for parallel operations

### Performance Considerations
- Audio recording on dedicated high-priority queue
- Whisper processing on background queue to avoid UI blocking
- Efficient memory management for audio buffers
- Lazy loading of Whisper models

## 9. File Structure

```
Wispr/
├── App/
│   ├── WisprApp.swift                 # App entry point
│   ├── AppDelegate.swift             # macOS app lifecycle
│   └── Info.plist                    # App configuration
├── Core/
│   ├── Models/
│   │   ├── AppState.swift            # Central state model
│   │   ├── RecordingSession.swift    # Recording data
│   │   ├── Settings.swift            # App settings
│   │   └── WisprError.swift           # Error definitions
│   ├── Services/
│   │   ├── AudioService.swift        # Audio recording
│   │   ├── WhisperService.swift      # Speech transcription
│   │   ├── TextInsertionService.swift # Text insertion
│   │   ├── HotkeyMonitor.swift       # Global hotkey handling
│   │   └── PermissionManager.swift   # Permission management
│   └── Managers/
│       └── StateManager.swift        # Central state coordination
├── UI/
│   ├── Views/
│   │   ├── MainWindow.swift          # Main window container
│   │   ├── RecordingView.swift       # Recording overlay
│   │   ├── SettingsView.swift        # Preferences panel
│   │   └── Components/
│   │       ├── WaveformView.swift    # Audio visualization
│   │       ├── RecordingTimer.swift  # Timer display
│   │       └── HotkeyField.swift     # Hotkey input
│   ├── ViewModels/
│   │   ├── RecordingViewModel.swift  # Recording logic
│   │   └── SettingsViewModel.swift   # Settings logic
│   └── Resources/
│       ├── Assets.xcassets           # App icons and images
│       └── Localizable.strings       # Localized strings
├── Extensions/
│   ├── NSEvent+Extensions.swift      # Event handling helpers
│   ├── AVAudioEngine+Extensions.swift # Audio utilities
│   └── UserDefaults+Extensions.swift # Settings persistence
├── Utilities/
│   ├── Logger.swift                  # Logging utilities
│   ├── Constants.swift               # App constants
│   └── Helpers.swift                 # General utilities
└── Tests/
    ├── WisprTests/                    # Unit tests
    └── WisprUITests/                  # UI tests
```

## 10. External Dependencies

### Primary Dependencies

**whisper.cpp Integration**
```swift
// Package.swift dependency
.package(url: "https://github.com/ggerganov/whisper.cpp", from: "1.5.0")
```
- Local speech-to-text processing
- Multiple model size options (tiny, base, small, medium, large)
- Optimized for Apple Silicon performance
- No network requirements

**System Frameworks**
- **AVFoundation**: Audio recording and processing
- **Accessibility**: Text insertion and cursor detection  
- **Carbon**: Global hotkey monitoring
- **Combine**: Reactive programming patterns
- **SwiftUI**: Modern declarative UI framework

### Optional Dependencies

**Logging Framework**
```swift
.package(url: "https://github.com/apple/swift-log", from: "1.5.0")
```

**Settings Management**
```swift
.package(url: "https://github.com/sindresorhus/Defaults", from: "7.0.0")
```

### Dependency Management Strategy
- Minimize external dependencies for security and maintenance
- Prefer Apple's first-party frameworks when possible
- Use Swift Package Manager for dependency resolution
- Pin specific versions for reproducible builds
- Regular security audits of third-party dependencies

### Whisper Model Management
- Bundle lightweight models (tiny, base) with app
- Download larger models on-demand with user consent
- Local model storage in Application Support directory
- Model validation and integrity checking
- Fallback to smaller models if larger ones fail

This technical design provides a comprehensive foundation for building the Wispr voice dictation app with proper separation of concerns, robust error handling, and adherence to macOS development best practices.
