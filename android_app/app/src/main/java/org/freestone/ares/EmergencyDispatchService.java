package org.freestone.ares;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

public class EmergencyDispatchService extends Service {
    private static final String TAG = "ARES_DispatchService";
    private static final String CHANNEL_MONITOR = "ares_dispatch_monitor";
    private static final String CHANNEL_EMERGENCY = "ares_emergency_alerts";
    private static final int NOTIF_ID_FOREGROUND = 1001;
    private static final int NOTIF_ID_ALERT = 2002;

    private static final String FIREBASE_URL = "https://freestone-ares-tactical-default-rtdb.firebaseio.com";

    private boolean isRunning = false;
    private Thread monitorThread;

    private int lastKnownLevel = -1;
    private String lastIncidentFingerprint = null;

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "EmergencyDispatchService onCreate: Initializing active CAD dispatch monitoring");
        createNotificationChannels();
        startForeground(NOTIF_ID_FOREGROUND, buildMonitorNotification());
        startMonitoringLoop();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!isRunning) {
            startMonitoringLoop();
        }
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        super.onTaskRemoved(rootIntent);
        Log.w(TAG, "App task removed (swiped from recents). Restarting EmergencyDispatchService to guarantee alert delivery.");
        Intent restartService = new Intent(getApplicationContext(), EmergencyDispatchService.class);
        restartService.setPackage(getPackageName());
        PendingIntent restartPending = PendingIntent.getService(
                getApplicationContext(),
                1,
                restartService,
                PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_IMMUTABLE
        );
        AlarmManager alarmManager = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
        if (alarmManager != null) {
            alarmManager.set(AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + 1500, restartPending);
        }
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "EmergencyDispatchService onDestroy");
        isRunning = false;
        if (monitorThread != null) {
            monitorThread.interrupt();
            monitorThread = null;
        }
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;

            // 1. Silent Ongoing Monitor Channel
            NotificationChannel monitorChan = new NotificationChannel(
                    CHANNEL_MONITOR,
                    "CAD Dispatch Standby Monitor",
                    NotificationManager.IMPORTANCE_LOW
            );
            monitorChan.setDescription("Maintains continuous background monitoring for Freestone County ARES emergency activations");
            monitorChan.setShowBadge(false);
            nm.createNotificationChannel(monitorChan);

            // 2. High Priority Loud Emergency Alert Channel
            NotificationChannel emergencyChan = new NotificationChannel(
                    CHANNEL_EMERGENCY,
                    "Freestone ARES Emergency Activations",
                    NotificationManager.IMPORTANCE_HIGH
            );
            emergencyChan.setDescription("Immediate siren, heads-up banner, and vibration for Level 1/2 activations and CAD callouts");
            emergencyChan.enableLights(true);
            emergencyChan.setLightColor(Color.RED);
            emergencyChan.enableVibration(true);
            emergencyChan.setVibrationPattern(new long[]{0, 600, 250, 600, 250, 1000});
            emergencyChan.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);

            Uri alertSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
            if (alertSound == null) {
                alertSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
            }
            AudioAttributes audioAttr = new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .build();
            emergencyChan.setSound(alertSound, audioAttr);

            nm.createNotificationChannel(emergencyChan);
        }
    }

    private Notification buildMonitorNotification() {
        Intent launchIntent = new Intent(this, MainActivity.class);
        launchIntent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        return new NotificationCompat.Builder(this, CHANNEL_MONITOR)
                .setContentTitle("Freestone County ARES")
                .setContentText("Emergency Dispatch & CAD Standby Active")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pi)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
    }

    private void startMonitoringLoop() {
        if (isRunning) return;
        isRunning = true;

        monitorThread = new Thread(new Runnable() {
            @Override
            public void run() {
                Log.i(TAG, "Monitoring daemon thread started. Polling Firebase REST API every 6s.");
                while (isRunning) {
                    try {
                        checkActivationLevel();
                        checkActiveIncident();
                    } catch (Exception e) {
                        Log.w(TAG, "Monitor cycle notice: " + e.getMessage());
                    }

                    try {
                        Thread.sleep(6000);
                    } catch (InterruptedException ie) {
                        break;
                    }
                }
                Log.i(TAG, "Monitoring daemon thread terminated.");
            }
        });
        monitorThread.setName("ARES-Firebase-Monitor");
        monitorThread.start();
    }

    private void checkActivationLevel() {
        String jsonStr = httpGet(FIREBASE_URL + "/activation_level.json");
        if (jsonStr == null || jsonStr.trim().isEmpty() || jsonStr.equals("null")) return;

        try {
            JSONObject obj = new JSONObject(jsonStr);
            int level = obj.optInt("level", 3);
            String badgeText = obj.optString("badgeText", "LEVEL " + level);
            String subtext = obj.optString("dashSubtext", "Emergency Posture Change");

            if (lastKnownLevel == -1) {
                lastKnownLevel = level;
                return;
            }

            if (level != lastKnownLevel) {
                int oldLevel = lastKnownLevel;
                lastKnownLevel = level;

                // Level 1 or 2 is an emergency activation change!
                if (level == 1 || level == 2) {
                    postEmergencyAlertNotification(
                            "🚨 EMERGENCY ACTIVATION: " + badgeText,
                            subtext + " • Tap to launch CAD Console & respond immediately."
                    );
                } else if (level == 3 && (oldLevel == 1 || oldLevel == 2)) {
                    postStatusUpdateNotification(
                            "🟢 FREESTONE ARES: STEADY STATE",
                            "Emergency posture deactivated. County returned to Level 3 Monitoring standby."
                    );
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Error parsing activation_level: " + e.getMessage());
        }
    }

    private void checkActiveIncident() {
        String jsonStr = httpGet(FIREBASE_URL + "/active_incident.json");
        if (jsonStr == null || jsonStr.trim().isEmpty() || jsonStr.equals("null")) return;

        try {
            JSONObject obj = new JSONObject(jsonStr);
            boolean isClosed = obj.optBoolean("isClosed", false);
            String title = obj.optString("title", "");
            String level = obj.optString("level", "");
            String staging = obj.optString("staging", "Fairfield EOC");
            String mission = obj.optString("mission", "Standby for tactical communications.");
            int updateCount = obj.optInt("updateCount", 0);
            String lastUpdated = obj.optString("lastUpdated", "");

            if (isClosed || title.toUpperCase().contains("ROUTINE OPERATIONS") || level.toUpperCase().contains("LEVEL 3 - MONITORING") || level.toUpperCase().contains("LEVEL 4")) {
                // Routine steady state - clear any active incident notification
                NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
                if (nm != null) {
                    nm.cancel(NOTIF_ID_ALERT);
                }
                lastIncidentFingerprint = "ROUTINE";
                return;
            }

            String fingerprint = title + "_" + level + "_" + updateCount + "_" + lastUpdated;
            if (lastIncidentFingerprint == null) {
                lastIncidentFingerprint = fingerprint;
                return;
            }

            if (!fingerprint.equals(lastIncidentFingerprint)) {
                lastIncidentFingerprint = fingerprint;
                postEmergencyAlertNotification(
                        "🚨 ACTIVE CALLOUT: " + title,
                        "📍 Staging: " + staging + "\nDirective: " + mission
                );
            }
        } catch (Exception e) {
            Log.w(TAG, "Error parsing active_incident: " + e.getMessage());
        }
    }

    private void postEmergencyAlertNotification(String title, String body) {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;

        Intent launchIntent = new Intent(this, MainActivity.class);
        launchIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(
                this,
                (int) System.currentTimeMillis(),
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Uri alertSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        if (alertSound == null) {
            alertSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION);
        }

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_EMERGENCY)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setVibrate(new long[]{0, 600, 250, 600, 250, 1000})
                .setSound(alertSound);

        nm.notify(NOTIF_ID_ALERT, builder.build());
    }

    private void postStatusUpdateNotification(String title, String body) {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;

        Intent launchIntent = new Intent(this, MainActivity.class);
        launchIntent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_MONITOR)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT);

        nm.notify(2003, builder.build());
    }

    private String httpGet(String urlStr) {
        HttpURLConnection conn = null;
        BufferedReader reader = null;
        try {
            URL url = new URL(urlStr + "?t=" + System.currentTimeMillis());
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);
            conn.setUseCaches(false);
            conn.setRequestProperty("Accept", "application/json");

            if (conn.getResponseCode() == 200) {
                reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                return sb.toString();
            }
        } catch (Exception e) {
            // Network failure or timeout
        } finally {
            if (reader != null) {
                try { reader.close(); } catch (Exception ignored) {}
            }
            if (conn != null) {
                conn.disconnect();
            }
        }
        return null;
    }
}
