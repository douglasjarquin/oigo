import AVFAudio
import ApplicationServices
import CoreGraphics

let microphone = switch AVAudioApplication.shared.recordPermission {
case .granted: "granted"
case .denied: "denied"
case .undetermined: "undetermined"
@unknown default: "unknown"
}
print("MICROPHONE_CHECKPOINT=" + microphone)
print("AX_CHECKPOINT=" + (AXIsProcessTrusted() ? "granted" : "denied"))
print("EVENT_CHECKPOINT=" + (CGPreflightPostEventAccess() ? "granted" : "denied"))
print("SCREEN_RECORDING_CHECKPOINT=" + (CGPreflightScreenCaptureAccess() ? "granted" : "denied"))
