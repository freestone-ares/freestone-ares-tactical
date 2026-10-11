import UIKit
import UserNotifications
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    private var monitorTimer: Timer?
    private var lastKnownLevel: Int = -1
    private var lastIncidentFingerprint: String? = nil
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private let firebaseUrl = "https://freestone-ares-tactical-default-rtdb.firebaseio.com"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 1. Configure Notification Center for High-Priority Emergency Alerts
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                NSLog("[Freestone ARES] Notification authorization granted by operator.")
            } else if let error = error {
                NSLog("[Freestone ARES] Notification authorization error: \(error.localizedDescription)")
            }
        }

        // 2. ActiveAlert Background Persistence: Configure Audio Session so app remains active in background
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[Freestone ARES] Background audio session configuration notice: \(error.localizedDescription)")
        }

        // 3. Start continuous background dispatch monitoring
        startDispatchMonitoring()

        return true
    }

    // MARK: - Background CAD Dispatch Monitor
    func startDispatchMonitoring() {
        guard monitorTimer == nil else { return }

        // Initial immediate checks
        checkActivationLevel()
        checkActiveIncident()

        // Continuous timer (runs both foreground and background due to background audio capability)
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.checkActivationLevel()
            self?.checkActiveIncident()
        }
        RunLoop.main.add(monitorTimer!, forMode: .common)
    }

    private func checkActivationLevel() {
        guard let url = URL(string: "\(firebaseUrl)/activation_level.json?t=\(Int(Date().timeIntervalSince1970))") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let level = json["level"] as? Int ?? 3
                    let badgeText = json["badgeText"] as? String ?? "LEVEL \(level)"
                    let subtext = json["dashSubtext"] as? String ?? "Emergency Posture Changed"

                    if self.lastKnownLevel == -1 {
                        self.lastKnownLevel = level
                        return
                    }

                    if level != self.lastKnownLevel {
                        let oldLevel = self.lastKnownLevel
                        self.lastKnownLevel = level

                        if level == 1 || level == 2 {
                            self.sendLocalEmergencyAlert(
                                title: "🚨 EMERGENCY ACTIVATION: \(badgeText)",
                                body: "\(subtext)\nTap to open CAD console and respond immediately."
                            )
                        } else if level == 3 && (oldLevel == 1 || oldLevel == 2) {
                            self.sendLocalEmergencyAlert(
                                title: "🟢 FREESTONE ARES: STEADY STATE",
                                body: "Emergency posture deactivated. County returned to Level 3 Monitoring standby."
                            )
                        }
                    }
                }
            } catch {}
        }.resume()
    }

    private func checkActiveIncident() {
        guard let url = URL(string: "\(firebaseUrl)/active_incident.json?t=\(Int(Date().timeIntervalSince1970))") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let isClosed = json["isClosed"] as? Bool ?? false
                    let title = json["title"] as? String ?? ""
                    let level = json["level"] as? String ?? ""
                    let staging = json["staging"] as? String ?? "Fairfield EOC"
                    let mission = json["mission"] as? String ?? "Standby for tactical communications."
                    let updateCount = json["updateCount"] as? Int ?? 0
                    let lastUpdated = json["lastUpdated"] as? String ?? ""

                    let titleUpper = title.uppercased()
                    let levelUpper = level.uppercased()

                    if isClosed || titleUpper.contains("ROUTINE") || levelUpper.contains("LEVEL 3 - MONITORING") || levelUpper.contains("LEVEL 4") {
                        self.lastIncidentFingerprint = "ROUTINE"
                        return
                    }

                    let fingerprint = "\(title)_\(level)_\(updateCount)_\(lastUpdated)"
                    if self.lastIncidentFingerprint == nil {
                        self.lastIncidentFingerprint = fingerprint
                        return
                    }

                    if fingerprint != self.lastIncidentFingerprint {
                        self.lastIncidentFingerprint = fingerprint
                        self.sendLocalEmergencyAlert(
                            title: "🚨 ACTIVE CALLOUT: \(title)",
                            body: "📍 Staging: \(staging)\nMission: \(mission)"
                        )
                    }
                }
            } catch {}
        }.resume()
    }

    private func sendLocalEmergencyAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        content.badge = 1

        let request = UNNotificationRequest(
            identifier: "ares_alert_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[Freestone ARES] Notification delivery error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner and play sound even while the app is in the foreground
        completionHandler([.banner, .sound, .badge, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: - Background Task Lifecycle
    func applicationDidEnterBackground(_ application: UIApplication) {
        bgTask = application.beginBackgroundTask(withName: "FreestoneARESDispatchMonitor") { [weak self] in
            if let task = self?.bgTask, task != .invalid {
                application.endBackgroundTask(task)
                self?.bgTask = .invalid
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if bgTask != .invalid {
            application.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        // Force immediate check on foreground return
        checkActivationLevel()
        checkActiveIncident()
    }

    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
