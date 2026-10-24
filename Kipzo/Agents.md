# Kipzo Architecture and Requirements

## Purpose

Kipzo is an iPhone-based prototype for a LEGO-powered face-following robot.

The current version is intentionally small in scope:
- use the iPhone front camera
- detect a visible face on-device
- compute a horizontal alignment signal
- rotate a single LEGO WeDo-connected motor to follow the target

The project is not yet a full mobile robot.
It is currently a rotating face-following prototype.

---

## Current Functional Requirements

1. The application must run in landscape mode only.
2. The front camera must be used by default.
3. The application must wait for WeDo readiness before showing the camera preview.
4. Face detection must run fully on-device.
5. A detected face must generate a horizontal turn signal.
6. The motor must stop when no face is detected.
7. The motor must stop inside a center dead-zone to avoid constant jitter.
8. A visible on-screen debug overlay must exist during development.

---

## Current Non-Functional Requirements

1. BLE logic and face-tracking logic must remain separated.
2. Working BLE code should not be casually rewritten.
3. Camera startup order must be deterministic.
4. Logging must be limited enough to avoid excessive process termination.
5. The codebase must remain understandable for rapid iteration.

---

## Architecture

### 1. App Entry Layer
**Files**
- `KipzoApp.swift`
- `OrientationLock.swift`

**Responsibilities**
- start the app
- apply the landscape-only orientation policy
- bridge SwiftUI and UIKit orientation behavior

---

### 2. UI Orchestration Layer
**File**
- `ContentView.swift`

**Responsibilities**
- react to WeDo connection state
- start the face tracker at the correct time
- delay preview creation until the camera session is running
- convert turn signals into motor commands
- display status and telemetry

**Important Rule**
This layer coordinates systems.
It should not implement raw BLE details or camera internals.

---

### 3. Vision and Camera Layer
**File**
- `FaceTracker.swift`

**Responsibilities**
- configure the AVCapture session
- attach the front camera input
- enable metadata face detection
- publish face bounds for overlay rendering
- publish turn and drive signals

**Important Rule**
This layer should not send robot commands directly.

---

### 4. BLE Robot Layer
**File**
- `WedoManager.swift`

**Responsibilities**
- scan for the LEGO hub
- connect and initialize the motor port
- expose connection state to SwiftUI
- receive normalized turn commands
- convert those commands into hub motor commands

**Important Rule**
This layer should not know anything about face rectangles or UI layout.

---

## Tracking Model

### Input
The system currently uses:
- normalized face bounds from `AVCaptureMetadataOutput`

From those bounds:
- `midX` controls horizontal alignment
- `width` acts as a rough apparent-size estimate

### Output
The system currently publishes:
- `turnSignal`
- `driveSignal`

At the moment, the robot uses only `turnSignal`.

---

## Current Motor Control Policy

Single-motor mode:

- if no face exists -> stop
- if the face is near the center -> stop
- if the face is offset left/right -> rotate accordingly

This is intentionally conservative and debug-friendly.

---

## Why AVCaptureMetadataOutput Instead of Vision

The current prototype uses metadata face detection because:
- it is lightweight
- it is simple to integrate into the capture pipeline
- it is fast enough for this prototype
- it provides normalized rectangles directly

Trade-offs:
- it is less flexible than a richer Vision pipeline
- it is not identity recognition
- it may require more care for preview/overlay alignment

---

## Known Fragile Area

The most fragile part of the current project is not BLE.
It is the alignment between:

- camera preview orientation
- preview mirroring
- metadata coordinate conversion
- visible overlay drawing

If face logs exist but no green box is shown,
the likely problem is overlay coordinate handling or preview setup timing.

---

## Recommended Development Sequence

### Phase 1
Make the green face box stable and visible.

### Phase 2
Verify that horizontal motor direction is correct.

### Phase 3
Tune dead-zone and proportional turning strength.

### Phase 4
Upgrade to dual-motor motion if needed.

---

## Coding Principles

1. Keep layers separated.
2. Do not rewrite working BLE code without need.
3. Prefer simple deterministic behavior over complexity.
4. Add logs only when they answer a specific debugging question.
5. Always preserve at least one fixed debug overlay during visual debugging.
6. Keep camera startup order explicit and stable.

---

## Expected WedoManager Interface

The current UI expects `WedoManager` to expose at least:

- `@Published var state`
- `@Published var statusText`
- `@Published var leftMotorPower`
- `func start()`
- `func stopAll()`
- `func setSingleMotorTurn(turn: Double)`

The exact BLE implementation may vary, but the API contract above should remain stable.
