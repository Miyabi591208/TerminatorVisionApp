# TerminatorVision

TerminatorVision is an iOS app that overlays a Terminator-style HUD on top of a live camera feed.
It detects people, locks onto a target, renders a red cybernetic interface, plays a looping audio track, and shows live audio waveform readouts.

## Features

- Live camera preview with red Terminator-inspired screen effects
- Person detection with target lock-on HUD
- Recognition readout with threat score, range, offset, and stability
- Segmentation-based silhouette overlay for detected people
- Looping background audio from `overlay1.mp3`
- Real-time audio input panels for `ENV` and `VOICE`

## Project Structure

- `TerminatorVision/ContentView.swift`
  Main screen composition and HUD layout
- `TerminatorVision/CameraManager.swift`
  Camera session setup and frame delivery
- `TerminatorVision/Detector.swift`
  YOLO + Vision based person detection and telemetry generation
- `TerminatorVision/OverlayView.swift`
  Target overlays, recognition panels, waveform HUD, and visual effects
- `TerminatorVision/AudioManager.swift`
  Background audio playback and microphone waveform analysis
- `TerminatorVision/Models/yolov8n.mlpackage`
  Core ML model used as part of the detection pipeline
- `TerminatorVision/Media/Sounds/overlay1.mp3`
  Looping audio track

## Requirements

- Xcode
- iPhone with camera and microphone access
- iOS device support matching the project deployment target

## Permissions

The app requests:

- Camera access for live preview and detection
- Microphone access for waveform HUD input

## Run

1. Open `TerminatorVision.xcodeproj` in Xcode.
2. Select the `TerminatorVision` scheme.
3. Build and run on a physical iPhone.
4. Grant camera and microphone permissions when prompted.

## Notes

- The app is designed for portrait use.
- Audio playback and microphone monitoring run at the same time.
- Detection and HUD behavior are tuned for a cinematic look rather than strict measurement accuracy.
