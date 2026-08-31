import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

let microphone = switch AVAudioApplication.shared.recordPermission {
case .granted: "granted"
case .denied: "denied"
case .undetermined: "undetermined"
@unknown default: "unknown"
}
print("MICROPHONE_CHECKPOINT=" + microphone)
print("AX_CHECKPOINT=" + (AXIsProcessTrusted() ? "granted" : "denied"))
print("EVENT_CHECKPOINT=" + (CGPreflightPostEventAccess() ? "granted" : "denied"))
let speech = switch SFSpeechRecognizer.authorizationStatus() {
case .authorized: SFSpeechRecognizer(locale: .current)?.isAvailable == true ? "ready" : "unavailable"
case .denied: "denied"
case .restricted: "restricted"
case .notDetermined: "undetermined"
@unknown default: "unknown"
}
let input = AVCaptureDevice.default(for: .audio) == nil ? "unavailable" : "ready"
print("SPEECH_CHECKPOINT=" + speech)
print("INPUT_CHECKPOINT=" + input)
print("HARDWARE_CHECKPOINT=" + input)
print("INPUT_MONITORING_CHECKPOINT=not-required-no-event-tap")
print("SCREEN_RECORDING_CHECKPOINT=not-required-oigo-owned-capture")
