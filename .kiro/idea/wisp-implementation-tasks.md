# Wispr Voice Dictation macOS App - Detailed Implementation Task List

## Phase 1: Project Setup & Dependencies

### Task 1.1: Create Xcode Project Structure
**Files to create:**
- `WisprApp.xcodeproj`
- `WisprApp/WisprApp.swift` (main app entry point)
- `WisprApp/Info.plist`
- `WisprApp/WisprApp.entitlements`

**Implementation:**
```swift
// WisprApp.swift
import SwiftUI

@main
struct WisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

**Dependencies:** None
**Key configurations:** Set LSUIElement to true in Info.plist

### Task 1.2: Configure Entitlements and Permissions
**Files to modify:**
- `WisprApp.entitlements`
- `Info.plist`

**Implementation:**
```xml
<!-- WisprApp.entitlements -->
<key>com.apple.security.device.microphone</key>
<true/>
<key>com.apple.security.automation.apple-events</key>
<true/>
```

**Dependencies:** Task 1.1

### Task 1.3: Add WhisperKit Dependency
**Files to modify:**
- `Package.swift` or Xcode project settings

**Implementation:**
Add WhisperKit via Swift Package Manager: `https://github.com/argmaxinc/WhisperKit`

**Dependencies:** Task 1.1

## Phase 2: Core Services - Audio, Whisper, Permissions

### Task 2.1: Create Audio Recording Service
**Files to create:**
- `Services/AudioRecordingService.swift`

**Classes/Structs:**
```swift
import AVFoundation

class AudioRecordingService: ObservableObject {
    private var audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    
    init() {
        inputNode = audioEngine.inputNode
    }
    
    func startRecording() throws {
        // Configure audio session and start recording
    }
    
    func stopRecording() -> URL? {
        // Stop recording and return audio file URL
    }
}
```

**Dependencies:** Task 1.2

### Task 2.2: Create Whisper Transcription Service
**Files to create:**
- `Services/TranscriptionService.swift`

**Classes/Structs:**
```swift
import WhisperKit

class TranscriptionService: ObservableObject {
    private var whisperKit: WhisperKit?
    @Published var isTranscribing = false
    
    func initialize() async {
        whisperKit = try? await WhisperKit()
    }
    
    func transcribe(audioURL: URL) async -> String? {
        // Transcribe audio and return text
    }
}
```

**Dependencies:** Task 1.3, Task 2.1

### Task 2.3: Create Permission Manager
**Files to create:**
- `Services/PermissionManager.swift`

**Classes/Structs:**
```swift
import AVFoundation

class PermissionManager: ObservableObject {
    @Published var microphonePermission: AVAudioSession.RecordPermission = .undetermined
    
    func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                self.microphonePermission = granted ? .granted : .denied
            }
        }
    }
}
```

**Dependencies:** Task 1.2

### Task 2.4: Create Text Insertion Service
**Files to create:**
- `Services/TextInsertionService.swift`

**Classes/Structs:**
```swift
import Cocoa

class TextInsertionService {
    func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdV = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        cmdV?.flags = .maskCommand
        cmdV?.post(tap: .cghidEventTap)
    }
}
```

**Dependencies:** Task 1.2

## Phase 3: UI Components - Menu Bar, Recording View, Settings

### Task 3.1: Create Menu Bar Manager
**Files to create:**
- `UI/MenuBarManager.swift`

**Classes/Structs:**
```swift
import SwiftUI

class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Wispr")
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: ""))
        statusItem?.menu = menu
    }
    
    @objc func startRecording() {
        // Trigger recording
    }
}
```

**Dependencies:** Task 2.1

### Task 3.2: Create Recording View
**Files to create:**
- `UI/RecordingView.swift`

**Classes/Structs:**
```swift
import SwiftUI

struct RecordingView: View {
    @StateObject private var audioService = AudioRecordingService()
    @State private var isVisible = false
    
    var body: some View {
        VStack {
            Circle()
                .fill(audioService.isRecording ? Color.red : Color.gray)
                .frame(width: 60, height: 60)
            
            Text(audioService.isRecording ? "Recording..." : "Ready")
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}
```

**Dependencies:** Task 2.1, Task 3.1

### Task 3.3: Create Settings View
**Files to create:**
- `UI/SettingsView.swift`

**Classes/Structs:**
```swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("hotkey") private var hotkey = "Space"
    @AppStorage("autoInsert") private var autoInsert = true
    
    var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Recording Hotkey:")
                    TextField("Hotkey", text: $hotkey)
                }
            }
            
            Section("Behavior") {
                Toggle("Auto-insert text", isOn: $autoInsert)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
```

**Dependencies:** None

### Task 3.4: Create Window Manager
**Files to create:**
- `UI/WindowManager.swift`

**Classes/Structs:**
```swift
import SwiftUI

class WindowManager: ObservableObject {
    private var recordingWindow: NSWindow?
    
    func showRecordingView() {
        let contentView = RecordingView()
        recordingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        recordingWindow?.contentView = NSHostingView(rootView: contentView)
        recordingWindow?.center()
        recordingWindow?.makeKeyAndOrderFront(nil)
    }
    
    func hideRecordingView() {
        recordingWindow?.close()
        recordingWindow = nil
    }
}
```

**Dependencies:** Task 3.2

## Phase 4: Integration & Hotkeys

### Task 4.1: Create Hotkey Manager
**Files to create:**
- `Services/HotkeyManager.swift`

**Classes/Structs:**
```swift
import Carbon

class HotkeyManager: ObservableObject {
    private var hotKeyRef: EventHotKeyRef?
    
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x57495350), id: 1) // 'WISP'
        
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    
    func unregisterHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}
```

**Dependencies:** Task 1.2

### Task 4.2: Create Main App Controller
**Files to create:**
- `Controllers/AppController.swift`

**Classes/Structs:**
```swift
import SwiftUI

class AppController: ObservableObject {
    @Published var isRecording = false
    
    private let audioService = AudioRecordingService()
    private let transcriptionService = TranscriptionService()
    private let textInsertionService = TextInsertionService()
    private let windowManager = WindowManager()
    private let hotkeyManager = HotkeyManager()
    
    func startRecording() {
        isRecording = true
        windowManager.showRecordingView()
        try? audioService.startRecording()
    }
    
    func stopRecording() {
        isRecording = false
        windowManager.hideRecordingView()
        
        if let audioURL = audioService.stopRecording() {
            Task {
                if let text = await transcriptionService.transcribe(audioURL: audioURL) {
                    textInsertionService.insertText(text)
                }
            }
        }
    }
}
```

**Dependencies:** All previous tasks

### Task 4.3: Integrate Services with UI
**Files to modify:**
- `WisprApp.swift`
- `UI/MenuBarManager.swift`

**Implementation:**
```swift
// Update WisprApp.swift
@main
struct WisprApp: App {
    @StateObject private var appController = AppController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarManager = MenuBarManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarManager.setupMenuBar()
    }
}
```

**Dependencies:** Task 4.2

## Phase 5: Testing & Polish

### Task 5.1: Add Error Handling
**Files to modify:**
- All service files

**Implementation:**
Add proper error handling and user feedback for:
- Microphone permission denied
- Whisper model loading failures
- Audio recording errors
- Text insertion failures

**Dependencies:** All Phase 2-4 tasks

### Task 5.2: Add Loading States and Feedback
**Files to modify:**
- `UI/RecordingView.swift`
- `Controllers/AppController.swift`

**Implementation:**
```swift
// Add to RecordingView
@State private var transcriptionStatus = "Ready"

Text(transcriptionStatus)
    .foregroundColor(.secondary)
```

**Dependencies:** Task 5.1

### Task 5.3: Optimize Performance
**Files to modify:**
- `Services/TranscriptionService.swift`
- `Services/AudioRecordingService.swift`

**Implementation:**
- Implement audio buffer management
- Add Whisper model caching
- Optimize memory usage during transcription

**Dependencies:** Task 5.2

### Task 5.4: Add Accessibility Support
**Files to modify:**
- All UI files

**Implementation:**
- Add VoiceOver labels
- Implement keyboard navigation
- Add high contrast support

**Dependencies:** Task 5.3

### Task 5.5: Final Integration Testing
**Files to create:**
- `Tests/WisprAppTests.swift`

**Implementation:**
Create integration tests for:
- End-to-end recording and transcription flow
- Hotkey registration and triggering
- Settings persistence
- Permission handling

**Dependencies:** All previous tasks

## Key Dependencies Summary:
1. WhisperKit for speech recognition
2. AVFoundation for audio recording
3. Carbon for global hotkeys
4. SwiftUI for modern UI components
5. Combine for reactive programming

## Critical Implementation Notes:
- All audio processing should happen on background queues
- UI updates must be dispatched to main queue
- Proper cleanup of audio resources is essential
- Hotkey registration requires careful memory management
- Text insertion needs accessibility permissions
