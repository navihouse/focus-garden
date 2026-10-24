package com.focusgarden.focus_garden

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.*
import android.util.AtomicFile
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** Owns the clock and audio outside the Flutter activity. No silent audio is used. */
class FocusService : Service() {
    companion object { var instance: FocusService? = null }
    private var session: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotificationKey = ""
    override fun onCreate() {
        super.onCreate(); instance = this
        val runtime = FocusRuntime.get(this)
        session = MediaSession.Builder(this, runtime.player).build()
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FocusGarden:Countdown")
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("focus_timer", "专注计时", NotificationManager.IMPORTANCE_LOW))
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("focus_done_cues_v2", "到点提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null); enableVibration(false)
            })
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val runtime = FocusRuntime.get(this)
        when(intent?.action) {
            "pause" -> runtime.pause()
            "resume" -> runtime.resume()
            "end" -> runtime.end("early")
            "music" -> runtime.music(JSONObject().put("action", "toggle"))
            "deadline" -> runtime.tick()
        }
        update()
        // Never silently resume a timer after process death.
        return START_NOT_STICKY
    }
    fun update() {
        val r = FocusRuntime.get(this)
        if (!r.active()) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); return }
        val open = PendingIntent.getActivity(this, 0, Intent(this, FocusCardActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(name: String) = PendingIntent.getService(this, name.hashCode(), Intent(this, FocusService::class.java).setAction(name), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val seconds = (r.remaining() + 999) / 1000
        val text = "%02d:%02d".format(seconds / 60, seconds % 60)
        val paused = r.phase == "paused"
        val elapsedSeconds = r.notificationElapsed() / 1000
        val elapsedText = "%02d:%02d".format(elapsedSeconds / 60, elapsedSeconds % 60)
        val key = "${r.phase}|${r.isRest}|$text|$elapsedText|${r.taskName()}|${r.player.isPlaying}"
        if (key == lastNotificationKey) return
        lastNotificationKey = key
        val times = "${if(r.isRest) "已休息" else "已专注"} $elapsedText    ｜    剩余 $text"
        // Standard BigTextStyle keeps Android 16 Live Updates eligibility.
        // Custom RemoteViews would prevent system promotion on ColorOS/MagicOS.
        val builder = Notification.Builder(this, "focus_timer")
            .setSmallIcon(R.drawable.ic_focus_notification).setContentTitle("${if(r.isRest) "休息" else "专注"}${if(paused) " · 已暂停" else "进行中"}")
            .setContentText(times).setStyle(Notification.BigTextStyle().bigText("$times\n${r.taskName()}\n点击查看专注卡片"))
            .setShowWhen(false).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, if(paused) "继续计时" else "暂停计时", action(if(paused) "resume" else "pause")).build())
            .addAction(Notification.Action.Builder(null, if(r.player.isPlaying) "暂停音乐" else "播放音乐", action("music")).build())
            .addAction(Notification.Action.Builder(null, "结束", action("end")).build())
        if (Build.VERSION.SDK_INT >= 36) builder.setRequestPromotedOngoing(!r.isRest && r.phase == "focus")
        val n = builder.build()
        if (Build.VERSION.SDK_INT >= 34) {
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                (if(r.player.isPlaying) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0)
            startForeground(7, n, types)
        } else if (Build.VERSION.SDK_INT >= 29) { startForeground(7, n, if(r.player.isPlaying) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0) }
        else { startForeground(7, n) }
        if (!paused && wakeLock?.isHeld != true) wakeLock?.acquire(181L * 60 * 1000)
        if (paused && wakeLock?.isHeld == true) wakeLock?.release()
    }
    fun completed(text: String) {
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        getSystemService(NotificationManager::class.java).notify(8, Notification.Builder(this, "focus_done_cues_v2")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm).setContentTitle("专注花园").setContentText(text)
            .setContentIntent(open).setAutoCancel(true).build())
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        session?.release(); session = null; instance = null
        val runtime = FocusRuntime.get(this)
        if(runtime.active()) runtime.end("interrupted")
        super.onDestroy()
    }
}

class DeadlineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { FocusService.instance?.let { FocusRuntime.get(context).tick() } }
}

class FocusRuntime private constructor(private val context: Context) {
    companion object {
        private var singleton: FocusRuntime? = null
        fun get(context: Context): FocusRuntime = singleton ?: FocusRuntime(context.applicationContext).also { singleton = it }
    }
    val player: ExoPlayer = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
        setHandleAudioBecomingNoisy(true)
        repeatMode = Player.REPEAT_MODE_ALL
    }
    var phase = "idle"
    var isRest = false
    private var base: JSONObject? = null
    private var spans = JSONArray()
    private var pauses = JSONArray()
    private var openWall = 0L
    private var openTick = 0L
    private var pauseWall = 0L
    private var closedMs = 0L
    private var plannedMs = 0L
    private var restLeft = 0L
    private var restTick = 0L
    private var restDuration = 0L
    private var cycle = 0
    private var shortBreakSeconds = 300
    private var longBreakSeconds = 900
    private var muted = false
    private var error = ""
    private var checkpoint: JSONObject? = null
    private var events = JSONArray()
    private var lastSave = 0L
    private val journal = AtomicFile(File(context.filesDir, "focus-runtime.json"))
    private val handler = Handler(Looper.getMainLooper())
    private fun now() = System.currentTimeMillis()
    private fun tickNow() = SystemClock.elapsedRealtime()
    private fun iso(ms: Long) = Instant.ofEpochMilli(ms).toString()
    private fun millis(text: String) = Instant.parse(text).toEpochMilli()

    init {
        if (journal.baseFile.exists()) {
            try {
                val saved = JSONObject(journal.openRead().bufferedReader().use { it.readText() })
                events = saved.optJSONArray("events") ?: JSONArray(); cycle = saved.optInt("cycle")
                saved.optJSONObject("checkpoint")?.let {
                    it.put("reason", "interrupted").put("completed", false)
                    events.put(JSONObject().put("id", it.getString("id")).put("session", it))
                }
                persist()
            } catch(e: Exception) {
                error = "后台记录恢复失败：${e.message}。原日志已保留。"
                journal.baseFile.copyTo(File(context.filesDir, "focus-runtime-corrupt-${now()}.json"), overwrite = false)
            }
        }
        player.addListener(object : Player.Listener {
            override fun onPlayerError(e: PlaybackException) {
                error = "无法播放所选音乐：${e.localizedMessage}。计时继续。"; player.pause()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                // Hardware media buttons must obey the same focus/music linkage.
                if (isPlaying && (phase != "focus" || muted)) player.pause()
                FocusService.instance?.update()
            }
        })
        handler.post(object : Runnable {
            override fun run() { tick(); handler.postDelayed(this, 500) }
        })
    }
    fun active() = phase == "focus" || phase == "rest" || phase == "paused"
    fun taskName(): String = base?.optString("taskName", "自由专注") ?: "下一阶段由你手动开始"
    private fun elapsed(): Long = min(plannedMs, closedMs + if(phase == "focus") max(0, tickNow() - openTick) else 0)
    fun notificationElapsed(): Long = if(isRest) max(0, restDuration - remaining()) else elapsed()
    fun remaining(): Long = if(isRest) max(0, restLeft - if(phase == "rest") max(0, tickNow() - restTick) else 0) else max(0, plannedMs - elapsed())
    private fun orderedNow(): Long = max(now(), if(spans.length() > 0) millis(spans.getJSONObject(spans.length()-1).getString("end")) else base?.optString("started")?.let(::millis) ?: now())
    private fun closeSpan() {
        val used = min(max(0, tickNow() - openTick), plannedMs - closedMs)
        if (used > 0) spans.put(JSONObject().put("start", iso(openWall)).put("end", iso(openWall + used)))
        closedMs += used
    }
    private fun snapshot(reason: String = "interrupted"): JSONObject? {
        val original = base ?: return null
        val currentSpans = JSONArray(spans.toString())
        if(phase == "focus") {
            val used = elapsed() - closedMs
            if(used > 0) currentSpans.put(JSONObject().put("start", iso(openWall)).put("end", iso(openWall + used)))
        }
        val last = if(currentSpans.length() > 0) millis(currentSpans.getJSONObject(currentSpans.length()-1).getString("end")) else millis(original.getString("started"))
        val end = if(reason == "completed") last else max(orderedNow(), max(last, pauseWall))
        val currentPauses = JSONArray(pauses.toString())
        if(pauseWall > 0) currentPauses.put(JSONObject().put("start", iso(pauseWall)).put("end", iso(end)))
        return JSONObject(original.toString()).put("ended", iso(end)).put("spans", currentSpans).put("pauses", currentPauses)
            .put("reason", reason).put("completed", reason == "completed")
    }
    private fun persist() {
        val data = JSONObject().put("checkpoint", checkpoint ?: JSONObject.NULL).put("events", events).put("cycle", cycle)
        val stream = journal.startWrite()
        try { stream.write(data.toString().toByteArray(Charsets.UTF_8)); journal.finishWrite(stream) }
        catch(e: Exception) { journal.failWrite(stream); throw e }
    }
    private fun saveCheckpoint() { checkpoint = if(!isRest && active()) snapshot() else null; persist(); lastSave = tickNow() }
    private fun refreshService() {
        if(active()) {
            if(FocusService.instance == null) context.startForegroundService(Intent(context, FocusService::class.java))
            else FocusService.instance?.update()
        } else FocusService.instance?.update()
    }
    private fun alarmIntent() = PendingIntent.getBroadcast(context, 9, Intent(context, DeadlineReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun schedule() {
        val manager = context.getSystemService(AlarmManager::class.java)
        manager.cancel(alarmIntent())
        if(phase != "focus" && phase != "rest") return
        val at = tickNow() + remaining()
        if(Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()) manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarmIntent())
        else manager.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarmIntent())
    }
    fun configureBreaks(args: JSONObject) {
        val short = args.optInt("shortBreakSeconds", shortBreakSeconds)
        val long = args.optInt("longBreakSeconds", longBreakSeconds)
        require(short in 1..10800 && long in 1..10800)
        shortBreakSeconds = short; longBreakSeconds = long
    }
    fun start(args: JSONObject) {
        check(!active()) { "已有计时正在进行" }
        val seconds = args.getInt("seconds"); require(seconds in 1..10800)
        configureBreaks(args)
        spans = JSONArray(); pauses = JSONArray(); closedMs = 0; pauseWall = 0; isRest = false
        plannedMs = seconds * 1000L; openWall = now(); openTick = tickNow()
        base = JSONObject(args.toString()).removeAndReturn("seconds")
            .removeAndReturn("shortBreakSeconds").removeAndReturn("longBreakSeconds")
            .put("plannedSeconds", seconds).put("started", iso(openWall)).put("ended", iso(openWall))
            .put("excluded", false).put("completed", false).put("reason", "interrupted").put("pauses", JSONArray()).put("spans", JSONArray())
        phase = "focus"; error = ""; saveCheckpoint(); refreshService(); schedule()
        if(!muted && player.mediaItemCount > 0) player.play()
    }
    fun pause() {
        if(phase == "rest") { restLeft = remaining(); phase = "paused" }
        else if(phase == "focus") { closeSpan(); pauseWall = orderedNow(); phase = "paused" }
        else return
        player.pause(); saveCheckpoint(); schedule(); refreshService()
    }
    fun resume() {
        if(phase != "paused") return
        if(isRest) { restTick = tickNow(); phase = "rest" }
        else {
            openWall = max(orderedNow(), pauseWall); openTick = tickNow()
            pauses.put(JSONObject().put("start", iso(pauseWall)).put("end", iso(openWall))); pauseWall = 0
            phase = "focus"
            if(!muted && player.mediaItemCount > 0) player.play()
        }
        saveCheckpoint(); schedule(); refreshService()
    }
    fun rest(seconds: Int) {
        check(!active()); require(seconds in 1..10800)
        base = null; checkpoint = null; isRest = true; phase = "rest"
        restDuration = seconds * 1000L; restLeft = restDuration; restTick = tickNow()
        player.pause(); persist(); schedule(); refreshService()
    }
    fun end(reason: String = "early") {
        if(!active()) return
        val record = if(!isRest) snapshot(reason) else null
        if(record != null) {
            events.put(JSONObject().put("id", record.getString("id")).put("session", record))
            if(reason == "completed") cycle++
        }
        val restWasActive = isRest
        val autoRest = reason == "completed" && !restWasActive
        // No idle gap: the player's callback must not stop the service between phases.
        phase = if(autoRest) "rest" else "ended"; isRest = autoRest; checkpoint = null; base = null
        if(autoRest) {
            restDuration = (if(cycle % 4 == 0) longBreakSeconds else shortBreakSeconds) * 1000L
            restLeft = restDuration; restTick = tickNow()
        }
        persist(); schedule()
        try { player.pause() } catch(e: Exception) { error = "音乐暂停失败；计时继续。" }
        if(reason == "completed") {
            try { CompletionSounds.play(if(restWasActive) "rest" else "focus") }
            catch(e: Exception) { error = "计时阶段已更新，提示音暂时无法播放。" }
            try { FocusService.instance?.completed(if(restWasActive) "休息结束，请手动开始下一次专注。" else "本次专注已完成，已自动开始${if(cycle % 4 == 0) "长" else "短"}休息。") }
            catch(e: Exception) { error = "计时阶段已更新，通知暂时无法显示。" }
        }
        refreshService()
    }
    fun tick() {
        if((phase == "focus" || phase == "rest") && remaining() == 0L) end("completed")
        if(active() && !isRest && tickNow() - lastSave >= 15000) saveCheckpoint()
        if(active()) FocusService.instance?.update()
    }
    fun ack(id: String) {
        events = JSONArray((0 until events.length()).filter { events.getJSONObject(it).getString("id") != id }.map { events.getJSONObject(it) })
        persist()
    }
    fun playlist(args: JSONObject) {
        val wasPlaying = player.isPlaying
        val tracks = args.getJSONArray("tracks")
        val media = (0 until tracks.length()).map { MediaItem.fromUri(File(tracks.getJSONObject(it).getString("path")).toURI().toString()) }
        if(media.isEmpty()) { player.clearMediaItems(); return }
        player.setMediaItems(media, args.optInt("index").coerceIn(0, max(0, media.size - 1)), 0)
        player.volume = args.optDouble("volume", .6).toFloat()
        if(media.isNotEmpty()) { player.prepare(); if(wasPlaying && phase == "focus" && !muted) player.play() }
    }
    fun music(args: JSONObject) {
        when(args.getString("action")) {
            "toggle" -> if(player.isPlaying) player.pause() else if(phase == "focus" && !muted) player.play()
            "next" -> player.seekToNextMediaItem()
            "previous" -> player.seekToPreviousMediaItem()
            "select" -> { val i = args.getInt("value"); if(i in 0 until player.mediaItemCount) player.seekTo(i, 0) }
            "volume" -> player.volume = args.getDouble("value").toFloat()
            "shuffle" -> player.shuffleModeEnabled = args.getBoolean("shuffle")
            "repeat" -> player.repeatMode = when(args.getString("repeat")) { "one" -> Player.REPEAT_MODE_ONE; "off" -> Player.REPEAT_MODE_OFF; else -> Player.REPEAT_MODE_ALL }
            "mute" -> { muted = args.getBoolean("muted"); if(muted) player.pause() else if(phase == "focus") player.play() }
        }
        if(phase != "focus") player.pause()
    }
    fun state(): JSONObject {
        tick()
        return JSONObject().put("phase", phase).put("isRest", isRest).put("remainingMs", if(active()) remaining() else plannedMs)
            .put("durationMs", if(isRest) restDuration else plannedMs).put("taskName", taskName()).put("cycle", cycle)
            .put("livePromoted", Build.VERSION.SDK_INT >= 36 && context.getSystemService(NotificationManager::class.java)
                .activeNotifications.any { it.id == 7 && (it.notification.flags and Notification.FLAG_PROMOTED_ONGOING) != 0 })
            .put("musicPlaying", player.isPlaying).put("trackIndex", max(0, player.currentMediaItemIndex))
            .put("events", JSONArray(events.toString())).put("error", error.also { error = "" })
    }
    private fun JSONObject.removeAndReturn(key: String): JSONObject { remove(key); return this }
}
