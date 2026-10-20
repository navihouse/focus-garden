package com.focusgarden.focus_garden

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

/** Short generated notification cues, independent of the music player. */
object CompletionSounds {
    private data class Note(val start: Double, val frequency: Double, val duration: Double)
    private const val rate = 48000
    private fun synth(notes: List<Note>, seconds: Double) = ShortArray((seconds * rate).toInt()) { i ->
        var sample = 0.0
        for (note in notes) {
            val t = i.toDouble() / rate - note.start
            if (t < 0 || t >= note.duration) continue
            val angle = 2 * Math.PI * note.frequency * t
            val envelope = min(t / .0007, 1.0) * exp(-10 * t) * min((note.duration - t) / .015, 1.0)
            sample += 30000 * envelope * (.58 * sin(angle) + .29 * sin(2.01 * angle) + .13 * sin(3.93 * angle))
        }
        sample.coerceIn(-32760.0, 32760.0).toInt().toShort()
    }
    private val task by lazy { synth(listOf(Note(0.0, 1567.98, .42)), .42) }
    private val focus by lazy { synth(listOf(Note(0.0, 880.0, .20), Note(.25, 1318.51, .25)), .50) }
    private val rest by lazy { synth(listOf(Note(0.0, 1318.51, .16), Note(.20, 1046.5, .16), Note(.40, 783.99, .22)), .62) }
    fun play(kind: String) {
        val pcm = when(kind) { "task" -> task; "focus" -> focus; "rest" -> rest; else -> error("Unknown cue") }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.size * 2).build()
        try {
            check(track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING) == pcm.size) { "Audio cue could not be loaded" }
            track.play()
        } catch(e: Exception) { track.release(); throw e }
        Handler(Looper.getMainLooper()).postDelayed({ track.release() }, pcm.size * 1000L / rate + 250)
    }
}
