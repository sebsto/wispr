Refactor this SwiftUI screen with a **design-first approach**. Follow Apple's HIG for iOS: clean hierarchy, generous spacing (16-20pt), SF Symbols, semantic colors (.primary, .secondary), rounded corners (12-16pt), subtle shadows/elevations, and smooth animations.

IMHO, this one is not too bad. But search for area of improvements.

Use the SwiftUI Expert Skill to guide yoru decision.

Use Subagent to analyze the situation and another subagent to make the changes.

**Current code to refactor:**
UI/ModelManagementView.swift
UI/ModelDownloadProgessView.swift

DO NOT TOUCH ANY OTHER FILE, just the SwiftUI and preview in the indicated file.

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

## Changes Made

### Files Modified
- `wispr/UI/ModelManagementView.swift`
- `wispr/UI/ModelDownloadProgressView.swift`

### Key Design Improvements

#### 1. Gradient Circle Status Icons
**Before:** Flat SF Symbols at `font(.title2)` with color tinting only.
**After:** Icons centered in `@ScaledMetric`-sized (32pt) circles with `.gradient` fills — white icon on green/blue gradient for active/downloaded, subtle gray circle for not-downloaded.

**Why:** The colored circle badges create an immediate visual hierarchy — you can scan the list and instantly distinguish model states by color and visual weight. The gradient fill adds depth that flat color tinting lacks, and `@ScaledMetric` ensures the icons scale properly with Dynamic Type.

#### 2. Custom `GradientProgressBar` with Capsule Shape
**Before:** System `ProgressView(value:).progressViewStyle(.linear)` — a thin line.
**After:** An 8pt capsule-shaped bar with a gradient accent fill and soft 15%-opacity track, animated with `.easeInOut`.

**Why:** The system linear progress view is thin and visually flat. The capsule progress bar is more substantial, the gradient fill adds visual interest, and the rounded shape is cohesive with the pill badges and circle icons.

#### 3. macOS Hover Feedback + Completion Transition
**Before:** No hover interaction on rows; abrupt state change on download complete.
**After:** Subtle `.primaryTextColor.opacity(0.04)` background on hover (animated with `.easeOut(duration: 0.15)`); completion view enters with `.opacity.combined(with: .scale(scale: 0.95))` transition.

**Why:** On macOS, hover feedback is the primary interaction cue. The subtle background tint provides discoverability without distraction. The completion transition adds a micro-interaction that makes the "download done" moment feel polished.

### Other Improvements
- **Static `ByteCountFormatter`** — was being allocated on every call during active downloads
- **`@ScaledMetric` for icon sizing** — accessibility-correct scaling with Dynamic Type
- **Increased padding** (10/12 → 12/14pt) and **corner radius** (10 → 12pt) for more generous spacing per HIG
- **Dark mode + combined state previews** added for both files