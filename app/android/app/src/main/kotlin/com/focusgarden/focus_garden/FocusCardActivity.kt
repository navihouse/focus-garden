package com.focusgarden.focus_garden

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/** A notification click opens a compact card without touching the timer clock. */
class FocusCardActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var elapsed: TextView
    private lateinit var remaining: TextView
    private lateinit var title: TextView
    private lateinit var pause: Button
    private lateinit var elapsedLabel: TextView
    private lateinit var remainingLabel: TextView
    private val ticker = object : Runnable {
        override fun run() { render(); handler.postDelayed(this, 500) }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setFinishOnTouchOutside(true)
        fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(20), dp(24), dp(12))
            setBackgroundColor(Color.rgb(24, 33, 28))
        }
        fun label(text: String, size: Float = 14f) = TextView(this).apply {
            this.text = text; textSize = size; setTextColor(Color.WHITE); gravity = Gravity.CENTER
        }
        title = label("专注花园", 18f); root.addView(title)
        val times = LinearLayout(this).apply { setPadding(0, dp(22), 0, dp(18)) }
        elapsedLabel = label("已专注"); remainingLabel = label("本次剩余")
        elapsed = label("00:00", 28f).apply { typeface = Typeface.MONOSPACE }
        remaining = label("00:00", 28f).apply { typeface = Typeface.MONOSPACE }
        for ((caption, value) in listOf(elapsedLabel to elapsed, remainingLabel to remaining)) {
            val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            column.addView(caption); column.addView(value)
            times.addView(column, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(times)
        val buttons = LinearLayout(this)
        pause = Button(this).apply { setOnClickListener {
            try {
                val runtime = FocusRuntime.get(this@FocusCardActivity)
                if (runtime.phase == "paused") runtime.resume() else runtime.pause()
                render()
            } catch (_: Exception) { Toast.makeText(this@FocusCardActivity, "操作未完成，请打开应用重试", Toast.LENGTH_SHORT).show() }
        }}
        val open = Button(this).apply {
            text = "打开应用"; setOnClickListener {
                startActivity(Intent(this@FocusCardActivity, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                finish()
            }
        }
        buttons.addView(pause, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        buttons.addView(open, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(buttons); setContentView(root)
        window.setLayout((resources.displayMetrics.widthPixels * .92).toInt(), WindowManager.LayoutParams.WRAP_CONTENT)
    }
    private fun clock(ms: Long, countDown: Boolean = false): String {
        val seconds = (ms.coerceAtLeast(0) + if(countDown) 999 else 0) / 1000
        return "%02d:%02d".format(seconds / 60, seconds % 60)
    }
    private fun render() {
        val runtime = FocusRuntime.get(this)
        if (!runtime.active()) { finish(); return }
        title.text = runtime.taskName()
        elapsedLabel.text = if(runtime.isRest) "已休息" else "已专注"
        remainingLabel.text = if(runtime.isRest) "休息剩余" else "本次剩余"
        elapsed.text = clock(runtime.notificationElapsed())
        remaining.text = clock(runtime.remaining(), true)
        pause.text = if(runtime.phase == "paused") "继续计时" else "暂停计时"
    }
    override fun onStart() { super.onStart(); handler.post(ticker) }
    override fun onStop() { handler.removeCallbacks(ticker); super.onStop() }
}
