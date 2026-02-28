Refactor this SwiftUI screen with a **design-first approach**. Follow Apple's HIG for iOS: clean hierarchy, generous spacing (16-20pt), SF Symbols, semantic colors (.primary, .secondary), rounded corners (12-16pt), subtle shadows/elevations, and smooth animations.

I like the current breadcrump at the top and the big system icon for each step, the labels are good too. Keep them.

Use Subagent to analyze the situation and another subagent to make the changes.

Use the SwiftUI Expert Skill to guide your decision

**Current code to refactor:**
UI/Onboarding/**
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


--


# Onboarding Flow UI Refactoring Summary

## Changes Made

### New File: `OnboardingComponents.swift`
Extracted 3 reusable components:
- **`OnboardingIconBadge`** — SF Symbol inside a gradient-filled circle with `@ScaledMetric` sizing for Dynamic Type support
- **`OnboardingContinueButtonStyle`** — Capsule accent button with scale-on-press micro-interaction (0.96x) and proper disabled state dimming
- **`OnboardingSecondaryButtonStyle`** — Ghost button with subtle press highlight for Back/Skip

### Modified: `OnboardingFlow.swift`
- Removed hard `Divider()` lines for a cleaner, more spacious layout
- **Step indicator**: Connected dots with capsule track segments between them; current step gets an accent ring highlight; completed segments turn green
- **Step transitions**: Direction-aware asymmetric slide + fade (`move(edge:) + opacity`) so forward slides right-to-left, backward slides left-to-right
- **Navigation bar**: All buttons use the new custom styles with press-scale micro-interactions
- Better scroll behavior (`.scrollBounceBehavior(.basedOnSize)`, hidden indicators)

### Modified: All 6 Step Views
- Plain icons replaced with **`OnboardingIconBadge`** (gradient circle + shadow creates a strong visual focal point)
- Permission granted states get `.transition(.scale.combined(with: .opacity))` for smooth reveal
- `OnboardingContinueButtonStyle` on all action buttons (Grant Access, Open Settings, Download)
- Model rows: `onTapGesture` → proper `Button` (accessibility win), enhanced card styling with selection border + "Downloaded" pill badge
- Test dictation: pulsing badge animation during recording (respects Reduce Motion)
- Completion: spring scale-up celebration animation on appear
- Wider content frames (420pt) and increased `lineSpacing(5)` throughout

## 3 Key Design Improvements

1. **Gradient icon badges** — The biggest visual upgrade. Each step's SF Symbol now sits inside a gradient-filled circle with a soft shadow, creating an immediate focal point and visual depth that draws the eye through the flow.

2. **Direction-aware step transitions** — Instead of an instant swap, steps now slide + fade in the direction of navigation (forward = right-to-left, back = left-to-right). This gives spatial context and makes the wizard feel fluid. All animations respect the `reduceMotion` accessibility setting via the existing `motionRespectingAnimation` modifier.

3. **Micro-interaction button styles** — The capsule-shaped buttons with spring scale-on-press feedback (0.96x) replace the stock `.borderedProminent` style. This subtle physical response makes every tap feel intentional and polished, while maintaining 44pt minimum touch targets for accessibility.
