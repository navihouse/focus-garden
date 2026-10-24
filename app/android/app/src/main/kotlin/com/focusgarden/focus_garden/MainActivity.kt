package com.focusgarden.focus_garden

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val runtime = FocusRuntime.get(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "focus_garden/native")
            .setMethodCallHandler { call, result ->
                try {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    when (call.method) {
                        "taskCompleted" -> {
                            CompletionSounds.play("task"); result.success(null)
                        }
                        "timerSettings" -> { runtime.configureBreaks(JSONObject(args)); result.success(null) }
                        "recover" -> result.success(null)
                        "state" -> result.success(toValue(runtime.state()))
                        "start" -> { runtime.start(JSONObject(args)); result.success(null) }
                        "pause" -> { runtime.pause(); result.success(null) }
                        "resume" -> { runtime.resume(); result.success(null) }
                        "end" -> { runtime.end(args["reason"] as? String ?: "early"); result.success(null) }
                        "rest" -> { runtime.rest((args["seconds"] as Number).toInt()); result.success(null) }
                        "ack" -> { runtime.ack(args["id"] as String); result.success(null) }
                        "playlist" -> { runtime.playlist(JSONObject(args)); result.success(null) }
                        "music" -> { runtime.music(JSONObject(args)); result.success(null) }
                        "permissions" -> result.success(mapOf(
                            "notifications" to (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED),
                            "exact" to (Build.VERSION.SDK_INT < 31 || getSystemService(AlarmManager::class.java).canScheduleExactAlarms())
                            ,"liveSupported" to (Build.VERSION.SDK_INT >= 36)
                            ,"liveEnabled" to (Build.VERSION.SDK_INT >= 36 && getSystemService(NotificationManager::class.java).canPostPromotedNotifications())
                        ))
                        "requestLiveUpdates" -> {
                            if (Build.VERSION.SDK_INT >= 36) startActivity(Intent(Settings.ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "requestPermissions" -> {
                            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
                            } else if (Build.VERSION.SDK_INT >= 31 && !getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) {
                                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("NATIVE_ERROR", e.message, null) }
            }
    }
    private fun toValue(value: Any?): Any? = when(value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { toValue(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { toValue(value.get(it)) }
        else -> value
    }
}
