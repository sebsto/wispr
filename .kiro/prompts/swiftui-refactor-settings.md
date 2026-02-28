Refactor this SwiftUI screen with a **design-first approach**. Follow Apple's HIG for iOS: clean hierarchy, generous spacing (16-20pt), SF Symbols, semantic colors (.primary, .secondary), rounded corners (12-16pt), subtle shadows/elevations, and smooth animations.

DO NOT TOUCH ANY OTHER FILE, just the SwiftUI and preview in the indicated file.
Use Subagent to analyze the situation and another subagent to make the changes.
Use the SwiftUI Expert Skill to guide your decision

**Current code to refactor:**
UI/SettingsView.swit

**Design goals (prioritize these before code cleanup):**
1. Make it **visually stunning**: Modern glassmorphism or neumorphism with gradients/blurs; balanced whitespace; focal point for key actions.
2. **User-friendly flow**: Logical tap targets (44x44pt min), clear visual hierarchy (large title > body > captions), intuitive navigation.
3. **Adaptive & polished**: Perfect safe area handling, dark/light mode, Dynamic Type, accessibility labels.
4. **Micro-interactions**: Subtle scale/hover effects on buttons, smooth transitions.

**Output requirements:**
- Complete refactored SwiftUI code as a single, copy-paste ready View.
- Extract reusable components (e.g., CustomButton, CardView).
- Include Xcode Preview with multiple device sizes.
- Explain 2-3 key design improvements you made and why.

---

## Refactor Summary (2026-02-28)

### Key Design Improvements

#### 1. Glassmorphic Card System (`SettingsCard`)
Replaced the default `Form` with a `ScrollView` + custom `SettingsCard` wrapper. Each section is now a frosted-glass card with:
- `.ultraThinMaterial` background for depth and translucency
- Gradient stroke border (brighter top-left, fading bottom-right) that adapts to dark/light mode
- Subtle `shadow(radius: 10, y: 4)` for elevation
- 14pt rounded corners for a modern feel

#### 2. Color-coded Section Headers with Visual Hierarchy
Each section gets a `SectionHeader` with a tinted SF Symbol icon (orange for Hotkey, blue for Audio, purple for Model, green for Language, gray for General). Icons use `.gradient` for a subtle depth effect and `@ScaledMetric` sizing for Dynamic Type. This creates immediate visual landmarks so users can scan sections at a glance.

#### 3. Micro-interactions and Smooth Transitions
- **Language section**: Toggling auto-detect uses `withAnimation(.smooth)` to smoothly reveal/collapse the picker and pin toggle with a transition
- **Hotkey recorder**: Pulsing `symbolEffect(.pulse)` on the record icon during recording, plus a hover scale effect (`.onHover` + `.scaleEffect`) for tactile feedback
- **Error messages**: Fade + slide-from-top transition via `.animation(.smooth, value: hotkeyError)`
- All interactive rows have `minHeight: 44` for comfortable tap/click targets

### Reusable Components Extracted
- `SettingsCard<Content>` — Glassmorphic card container with material, gradient border, and shadow
- `SectionHeader` — Tinted icon + headline label with `@ScaledMetric` sizing

### Other Changes
- Replaced verbose manual `Binding` pass-throughs for `showRecordingOverlay` and `launchAtLogin` with `@Bindable`
- Added `@ScaledMetric` for section spacing (Dynamic Type support)
- Added `.scrollBounceBehavior(.basedOnSize)` to prevent unnecessary scroll bounce
- Added dark mode preview variant