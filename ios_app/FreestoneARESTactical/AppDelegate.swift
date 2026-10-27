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
    private var sirenPlayer: AVAudioPlayer?

    private let firebaseUrl = "https://freestone-ares-tactical-default-rtdb.firebaseio.com"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 1. Configure Notification Center for High-Priority Emergency Alerts
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                NSLog("[Freestone ARES] Notification authorization granted by operator (including Critical Alerts).")
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
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

    var senderSuppressionExpiry: Date = Date.distantPast

    func suppressSenderAlert(duration: Double = 90.0) {
        senderSuppressionExpiry = Date().addingTimeInterval(duration)
        NSLog("[Freestone ARES] Sender alert suppression engaged for \(duration)s.")
    }

    func isSenderSuppressed() -> Bool {
        return Date() < senderSuppressionExpiry
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

                    if self.isSenderSuppressed() {
                        self.lastKnownLevel = level
                        return
                    }

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

                    // 1. Sender suppression: transmitting device never alerts
                    if self.isSenderSuppressed() {
                        self.lastIncidentFingerprint = fingerprint
                        return
                    }

                    if self.lastIncidentFingerprint == nil {
                        self.lastIncidentFingerprint = fingerprint
                        return
                    }

                    if fingerprint != self.lastIncidentFingerprint {
                        self.lastIncidentFingerprint = fingerprint

                        // 2. Play subtle P25 chirp for field SITREPs
                        if let updates = json["updates"] as? [[String: Any]], let topUpdate = updates.first {
                            let isSitrepOnly = topUpdate["isSitrepOnly"] as? Bool ?? false
                            if isSitrepOnly {
                                NSLog("[Freestone ARES] checkActiveIncident: Field SITREP received, playing P25 talk-permit chirp.")
                                self.playSitrepBeep()
                                return
                            }
                        }

                        // 3. Siren sounds ONLY on initial emergency dispatch (updateCount <= 1)
                        if updateCount <= 1 {
                            self.playEmergencySiren()
                            self.sendLocalEmergencyAlert(
                                title: "🚨 ACTIVE CALLOUT: \(title)",
                                body: "📍 Staging: \(staging)\nMission: \(mission)"
                            )
                        } else {
                            NSLog("[Freestone ARES] checkActiveIncident: Subsequent update #\(updateCount), playing P25 talk-permit chirp.")
                            self.playSitrepBeep()
                        }
                    }
                }
            } catch {}
        }.resume()
    }

    // MARK: - Native Audio Players (Bypasses Hardware Mute Switch)
    private var sitrepPlayer: AVAudioPlayer?

    func playSitrepBeep() {
        if isSenderSuppressed() { return }
        guard let url = Bundle.main.url(forResource: "sitrep", withExtension: "caf") ?? Bundle.main.url(forResource: "sitrep", withExtension: "wav") else {
            NSLog("[Freestone ARES] Sitrep audio file (sitrep.caf / sitrep.wav) not found in bundle.")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sitrepPlayer?.stop()
            sitrepPlayer = try AVAudioPlayer(contentsOf: url)
            sitrepPlayer?.numberOfLoops = 0
            sitrepPlayer?.volume = 1.0
            sitrepPlayer?.play()
            NSLog("[Freestone ARES] Playing native Motorola ASTRO P25 sitrep talk-permit chirp.")
        } catch {
            NSLog("[Freestone ARES] Failed to play sitrep audio: \(error.localizedDescription)")
        }
    }

    func playEmergencySiren() {
        if isSenderSuppressed() { return }
        guard let url = Bundle.main.url(forResource: "siren", withExtension: "caf") ?? Bundle.main.url(forResource: "siren", withExtension: "wav") else {
            NSLog("[Freestone ARES] Siren audio file (siren.caf / siren.wav) not found in bundle.")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sirenPlayer?.stop()
            sirenPlayer = try AVAudioPlayer(contentsOf: url)
            sirenPlayer?.numberOfLoops = 0 // Play the 3.5s Quick-Call II dispatch tone
            sirenPlayer?.volume = 1.0
            sirenPlayer?.play()
            NSLog("[Freestone ARES] Playing native Quick-Call II emergency tone via AVAudioPlayer (bypasses silent switch).")
        } catch {
            NSLog("[Freestone ARES] Failed to play siren audio: \(error.localizedDescription)")
        }
    }

    func stopEmergencySiren() {
        sirenPlayer?.stop()
        sirenPlayer = nil
        sitrepPlayer?.stop()
        sitrepPlayer = nil
    }

    func sendLocalEmergencyAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName("siren.caf"))
        content.badge = 1
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

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
        if isSenderSuppressed() {
            NSLog("[Freestone ARES] willPresent: Sender suppression active, totally muting foreground alert.")
            completionHandler([])
            return
        }
        // Show banner and play sound for recipients
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

    func applicationDidBecomeActive(_ application: UIApplication) {
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
        } else {
            application.applicationIconBadgeNumber = 0
        }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - APNs Remote Push Notifications (ActiveAlert Cloud Push)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()
        NSLog("[Freestone ARES] Successfully received APNs device token: \(token)")
        registerTokenWithFirebase(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[Freestone ARES] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NSLog("[Freestone ARES] Received remote push notification from Apple APNs: \(userInfo)")
        // Immediate priority check and alert sound
        checkActivationLevel()
        checkActiveIncident()
        completionHandler(.newData)
    }

    private func registerTokenWithFirebase(token: String) {
        guard let url = URL(string: "\(firebaseUrl)/device_tokens/\(token).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "token": token,
            "platform": "iOS",
            "model": UIDevice.current.model,
            "systemVersion": UIDevice.current.systemVersion,
            "lastSeen": Int(Date().timeIntervalSince1970)
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            URLSession.shared.dataTask(with: request) { _, _, error in
                if let error = error {
                    NSLog("[Freestone ARES] Error saving APNs token to Firebase: \(error.localizedDescription)")
                } else {
                    NSLog("[Freestone ARES] APNs device token registered in Firebase RTDB.")
                }
            }.resume()
        } catch {}
    }

    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
