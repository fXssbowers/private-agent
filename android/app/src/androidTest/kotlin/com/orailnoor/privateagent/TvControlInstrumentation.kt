package com.orailnoor.privateagent

import android.app.Activity
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Runs on a real TV; has no AI calls and never reads app preferences. */
class TvControlInstrumentation : Instrumentation() {
    private lateinit var options: Bundle
    override fun onCreate(arguments: Bundle?) { options = arguments ?: Bundle(); start() }
    override fun onStart() {
        val report = Bundle()
        try {
            getUiAutomation(android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            sendStatus(0, Bundle().apply { putString("stage", "waiting_for_accessibility") })
            var service: AgentAccessibilityService? = null
            for (i in 0 until 100) {
                service = AgentAccessibilityService.instance
                if (service != null) break
                SystemClock.sleep(100)
            }
            val control = checkNotNull(service) { "Accessibility service did not bind" }
            when (options.getString("scenario", "fixture")) {
                "diagnostics" -> {
                    runDiagnostics(control)
                    report.putString("result", "PASS: bounded/redacted trace; voice blocked by text/coordinates/structural role; editable voice hint typed directly; explicit voice opt-in isolated")
                }
                "stremio" -> {
                    targetContext.startActivity(Intent().setComponent(ComponentName("com.stremio.one", "com.stremio.tv.MainActivity")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    SystemClock.sleep(4000)
                    check(action { control.clickAtCoordinates(85f, 210f, it) }) { "Search click rejected" }
                    SystemClock.sleep(1200)
                    check(nodes(control).any { it["isEditable"] == true }) { "Search did not open" }
                    check(action { done -> done(control.typeText("Interstellar")) }) { "Text entry failed" }
                    SystemClock.sleep(1200)
                    val submitted = action { control.pressEnter(it) }
                    if (!submitted) {
                        val field = nodes(control).first { it["isEditable"] == true }
                        val fb = field["bounds"] as Map<*, *>
                        val buttons = nodes(control).filter { node ->
                            if (node["className"] != "Button" || node["isClickable"] != true) return@filter false
                            val bounds = node["bounds"] as? Map<*, *> ?: return@filter false
                            (bounds["top"] as Int) >= (fb["top"] as Int) &&
                                (bounds["bottom"] as Int) <= (fb["bottom"] as Int) &&
                                (bounds["left"] as Int) >= (fb["left"] as Int) &&
                                (bounds["right"] as Int) <= (fb["right"] as Int)
                        }
                        check(buttons.size == 1) { "No unambiguous explicit search button" }
                        val bounds = buttons.single()["bounds"] as Map<*, *>
                        val bx = ((bounds["left"] as Int) + (bounds["right"] as Int)) / 2f
                        val by = ((bounds["top"] as Int) + (bounds["bottom"] as Int)) / 2f
                        check(action { control.clickAtCoordinates(bx, by, it) }) { "Explicit search button rejected" }
                    }
                    SystemClock.sleep(3000)
                    val screen = nodes(control)
                    check(screen.any { it["text"]?.toString() == "Interstellar" }) { "Expected title absent" }
                    check(screen.none { it["text"]?.toString()?.contains("Interstellarq") == true }) { "Submit typed a letter" }
                    check(screen.none { it["text"]?.toString() == "History" }) { "Search remained on history instead of results" }
                    report.putString("result", "PASS: Stremio query intact and explicit search opened results")
                }
                else -> {
                    targetContext.startActivity(Intent().setComponent(ComponentName(context.packageName, TvControlFixtureActivity::class.java.name)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    SystemClock.sleep(1500)
                    val button = nodes(control).first { it["text"]?.toString()?.equals("Activate fixture", true) == true }
                    val bounds = button["bounds"] as Map<*, *>
                    val x = ((bounds["left"] as Int) + (bounds["right"] as Int)) / 2f
                    val y = ((bounds["top"] as Int) + (bounds["bottom"] as Int)) / 2f
                    check(action { control.clickAtCoordinates(x, y, it) }) { "Node click rejected" }
                    SystemClock.sleep(300)
                    check(nodes(control).any { it["text"] == "ACTIVATED" }) { "Wrong control activated" }
                    if (nodes(control).any { it["className"] == "KeyboardStatus" }) {
                        check(action { done -> done(control.pressBack()) }) { "Could not close fixture keyboard" }
                        SystemClock.sleep(1000)
                    }
                    val touchTarget = nodes(control).first { it["text"] == "Touch alternative" }
                    val tb = touchTarget["bounds"] as Map<*, *>
                    val tx = ((tb["left"] as Int) + (tb["right"] as Int)) / 2f
                    val ty = ((tb["top"] as Int) + (tb["bottom"] as Int)) / 2f
                    check(action { control.clickByText("Touch alternative", it) })
                    check(nodes(control).any { it["text"] == "ACK_WITHOUT_SELECTION" }) { "Accessible-click fixture did not acknowledge" }
                    sendStatus(0, Bundle().apply { putString("touch_stage", "x=$tx y=$ty display=${control.resources.displayMetrics.widthPixels}x${control.resources.displayMetrics.heightPixels} touchscreen=${control.resources.configuration.touchscreen} keyboard=${nodes(control).any { it["className"] == "KeyboardStatus" }}") })
                    if (control.canDispatchTouch()) {
                        check(action { control.tapAtCoordinates(tx, ty, it) }) { "Direct touch rejected" }
                        SystemClock.sleep(300)
                        check(nodes(control).any { it["text"] == "TOUCH_SELECTED" }) { "Direct touch did not bypass accessible click" }
                        sendStatus(0, Bundle().apply { putString("touch_result", "PASS: physical touch bypassed accessible acknowledgement") })
                    } else {
                        check(!action { control.tapAtCoordinates(tx, ty, it) }) { "Non-touch display claimed success" }
                        check(nodes(control).any { it["text"] == "ACK_WITHOUT_SELECTION" })
                        sendStatus(0, Bundle().apply { putString("touch_result", "UNSUPPORTED: display is not configured as touchscreen; actual touch NOT validated") })
                    }
                    check(!action { control.tapAtCoordinates(-1f, ty, it) }) { "Invalid touch accepted" }
                    check(!action { control.tapAtCoordinates(100000f, ty, it) }) { "Out-of-display touch accepted" }
                    check(action { control.clickByText("Film", it) }) { "Editable focus rejected" }
                    SystemClock.sleep(1500)
                    check(action { done -> done(control.typeText("Interstellar", "Film")) }) { "Text entry rejected" }
                    SystemClock.sleep(400)
                    checkQuery(control, "after typing")
                    check(nodes(control).any { it["className"] == "KeyboardStatus" }) { "Open TV keyboard was not detected" }
                    check(nodes(control).none { it["text"]?.toString() == "q" }) { "TV keyboard keys leaked into app controls" }
                    check(!action { control.tapAtCoordinates(600f, 750f, it) }) { "Direct touch bypassed TV keyboard guard" }
                    checkQuery(control, "after guarded direct touch")
                    check(!action { control.clickByText("q", it) }) { "Keyboard letter was exposed as app control" }
                    action { control.clickAtCoordinates(600f, 750f, it) }
                    SystemClock.sleep(400)
                    checkQuery(control, "after rejected keyboard interaction")
                    val field = nodes(control).first { it["isEditable"] == true }
                    val fieldBounds = field["bounds"] as Map<*, *>
                    val fieldX = ((fieldBounds["left"] as Int) + (fieldBounds["right"] as Int)) / 2f
                    val fieldY = ((fieldBounds["top"] as Int) + (fieldBounds["bottom"] as Int)) / 2f
                    action { control.clickAtCoordinates(fieldX, fieldY, it) }
                    SystemClock.sleep(400)
                    checkQuery(control, "after clicking field with keyboard open")
                    check(!action { control.pressEnter(it) }) { "TV generic Enter was not rejected" }
                    SystemClock.sleep(400)
                    checkQuery(control, "after refused generic submit")
                    check(action { control.clickByText("Search fixture", it) }) { "Explicit submit rejected" }
                    SystemClock.sleep(400)
                    checkQuery(control, "after explicit submit")
                    SystemClock.sleep(300)
                    check(nodes(control).any { it["text"] == "SUBMITTED:Interstellar" }) { "Submit did not reach editor" }
                    check(action { done -> done(control.typeText("Interstellar", "Film")) })
                    check(action { control.clickByText("Interstellar", it) }) { "Result activation rejected" }
                    SystemClock.sleep(300)
                    check(nodes(control).any { it["text"] == "RESULT_SELECTED" }) { "Editable query intercepted result" }
                    check(action { control.clickByText("Virtual control", it) }) { "Virtual action rejected" }
                    SystemClock.sleep(300)
                    check(nodes(control).any { it["text"] == "VIRTUAL_SELECTED" }) { "Virtual control not activated" }
                    check(!action { control.clickByText("missing control", it) }) { "Missing control reported success" }
                    check(!action { control.clickAtCoordinates(-1f, 10f, it) }) { "Invalid coordinate reported success" }
                    report.putString("result", "PASS: node activation, TV Enter safely rejected, explicit submit, query integrity, virtual controls, negative controls")
                }
            }
            finish(Activity.RESULT_OK, report)
        } catch (error: Throwable) {
            report.putString("result", "FAIL: ${error.javaClass.simpleName}: ${error.message}")
            finish(Activity.RESULT_CANCELED, report)
        }
    }
    private fun runDiagnostics(control: AgentAccessibilityService) {
        val fixtureDir = java.io.File(targetContext.cacheDir, "diagnostic_fixture")
        val context = object : android.content.ContextWrapper(targetContext) {
            override fun getFilesDir() = fixtureDir.apply { mkdirs() }
            override fun getSharedPreferences(name: String, mode: Int) = targetContext.getSharedPreferences("fixture_$name", mode)
        }
        val wasEnabled = DiagnosticTrace.enabled(context)
        val task = "diagnostic_fixture"
        val canary = "sk-testDiagnosticCanary123456789"
        DiagnosticTrace.setEnabled(context, true)
        try {
            DiagnosticTrace.clear(context)
            for (i in 0 until 2000) DiagnosticTrace.append(context, task, "quota_test", mapOf("step" to i, "action" to "click_at", "reason" to "accepted"))
            check((DiagnosticTrace.state(context)["bytes"] as Long) <= DiagnosticTrace.RING_BYTES) { "Diagnostic quota exceeded" }
            DiagnosticTrace.clear(context)
            DiagnosticTrace.append(context, task, "privacy_test", mapOf("status" to "started", "api_key" to canary, "text" to canary, "reason" to canary, "transcript" to canary, "class" to "ghp_testDiagnosticCanary123456789"))
            DiagnosticTrace.append(context, canary, "privacy_test", mapOf("action" to "click_at"))
            targetContext.startActivity(Intent().setComponent(ComponentName(this.context.packageName, DiagnosticFixtureActivity::class.java.name)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            SystemClock.sleep(1500)
            fun perform(action: String, params: Map<String, Any?>, voice: Boolean = false): Map<String, Any?> {
                val latch = CountDownLatch(1)
                var result = emptyMap<String, Any?>()
                runOnMainSync { control.performUiAction(action, params, "", 1, voice) { result = it; latch.countDown() } }
                check(latch.await(4, TimeUnit.SECONDS)) { "Detailed action timed out" }
                DiagnosticTrace.append(context, task, "native_result", result)
                return result
            }
            fun bounds(label: String): Map<*, *> {
                for (i in 0 until 20) {
                    val found = nodes(control).firstOrNull { it["text"]?.toString()?.equals(label, true) == true || it["contentDescription"]?.toString()?.equals(label, true) == true }
                    if (found != null) return found["bounds"] as Map<*, *>
                    SystemClock.sleep(200)
                }
                error("Fixture control unavailable")
            }
            val mic = bounds("Voice search")
            val mx = ((mic["left"] as Int) + (mic["right"] as Int)) / 2.0
            val my = ((mic["top"] as Int) + (mic["bottom"] as Int)) / 2.0
            for ((action, params) in listOf("click_text" to mapOf("text" to "Voice search"), "click_at" to mapOf("x" to mx, "y" to my), "tap_at" to mapOf("x" to mx, "y" to my), "click_text" to mapOf("text" to "Azione di ricerca"))) {
                val result = perform(action, params)
                check(result["accepted"] == false && result["reason"] == "voice_control_blocked") { "Voice guard failed for $action" }
            }
            check(perform("click_text", mapOf("text" to "Search action"))["accepted"] == true) { "Ordinary search submit was mistaken for voice" }
            check(nodes(control).any { it["text"] == "SUBMIT_SELECTED" }) { "Ordinary search submit did not activate" }
            check(perform("click_text", mapOf("text" to "Fallback search area"))["reason"] == "voice_control_blocked") { "Text fallback bypassed microphone protection" }
            val normalBounds = bounds("Normal control")
            val nx = ((normalBounds["left"] as Int) + (normalBounds["right"] as Int)) / 2f
            val ny = ((normalBounds["top"] as Int) + (normalBounds["bottom"] as Int)) / 2f
            // Capture the production trace context into the isolated test ring.
            val touchTrace = UiActionTrace(context, task, 1, "tap_at", false)
            val touchLatch = CountDownLatch(1)
            var touchResult = emptyMap<String, Any?>()
            runOnMainSync { touchTrace.scoped { control.tapAtCoordinates(nx, ny) { touchResult = touchTrace.finish(it); touchLatch.countDown() } } }
            check(touchLatch.await(4, TimeUnit.SECONDS))
            check(touchResult["role"] == "control" && touchResult["control_key"].toString().isNotEmpty()) { "Touch target was not resolved" }
            check(touchTrace.target["bounds"] == listOf(normalBounds["left"], normalBounds["top"], normalBounds["right"], normalBounds["bottom"])) { "Touch attributed to a different control" }
            val typed = perform("type_text", mapOf("text" to canary, "field_hint" to "Parla per cercare"))
            check(typed["accepted"] == true && typed["role"] == "text_input") { "Voice hint prevented direct text input" }
            check(nodes(control).any { it["text"] == canary }) { "Text did not reach field" }
            check(nodes(control).none { it["text"] == "VOICE_SELECTED" || it["text"] == "ORB_SELECTED" }) { "Text entry activated voice" }
            if (nodes(control).any { it["className"] == "KeyboardStatus" }) {
                action { done -> done(control.pressBack()) }; SystemClock.sleep(500)
            }
            val allowed = perform("click_text", mapOf("text" to "Voice search"), true)
            check(allowed["accepted"] == true) { "Explicit voice opt-in rejected" }
            check(perform("click_text", mapOf("text" to "Normal control"))["accepted"] == true)
            check(perform("click_text", mapOf("text" to "Voice search"))["reason"] == "voice_control_blocked")
            check(nodes(control).any { it["text"] == "SAFE_SELECTED" }) { "Per-call voice permission leaked" }
            DiagnosticTrace.append(context, task, "task_end", mapOf("status" to "succeeded"))
            val dir = java.io.File(context.filesDir, "diagnostics")
            val files = listOf(java.io.File(dir, "current.jsonl"), java.io.File(dir, "previous.jsonl")).filter { it.exists() }
            val data = files.joinToString("\n") { it.readText() }
            check(files.sumOf { it.length() } <= DiagnosticTrace.RING_BYTES) { "Trace ring exceeded bound" }
            check(!data.contains(canary) && !data.contains("ghp_testDiagnosticCanary123456789") && !data.contains("\"api_key\"") && !data.contains("\"transcript\"")) { "Sensitive values entered trace" }
            check(data.contains("voice_control_blocked") && data.contains("text_input")) { "Trace lacks resolved interaction evidence" }
            check(data.contains("requested_point") && data.contains("resolved_target")) { "Trace lacks touch request/target evidence" }
        } finally {
            DiagnosticTrace.setEnabled(context, wasEnabled)
            fixtureDir.deleteRecursively()
        }
    }

    private fun checkQuery(service: AgentAccessibilityService, stage: String) {
        val fields = nodes(service).filter { it["isEditable"] == true }.map { it["text"]?.toString().orEmpty() }
        sendStatus(0, Bundle().apply { putString("query_stage", "$stage: $fields") })
        check(fields.any { it == "Interstellar" }) { "Query changed $stage: $fields" }
    }
    private fun nodes(service: AgentAccessibilityService): List<Map<String, Any?>> {
        var result = emptyList<Map<String, Any?>>()
        runOnMainSync { result = service.dumpScreen() }
        return result
    }
    private fun action(block: ((Boolean) -> Unit) -> Unit): Boolean {
        val done = CountDownLatch(1)
        var result = false
        runOnMainSync { block { result = it; done.countDown() } }
        check(done.await(4, TimeUnit.SECONDS)) { "Native action did not reply" }
        return result
    }
}

class TvControlFixtureActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val status = TextView(this).apply { text = "IDLE" }
        val button = Button(this).apply {
            text = "Activate fixture"
            setOnClickListener { status.text = "ACTIVATED" }
        }
        val editor = EditText(this).apply {
            hint = "Film"; setSingleLine(true); imeOptions = EditorInfo.IME_ACTION_SEARCH
            setImeActionLabel("Search", EditorInfo.IME_ACTION_SEARCH)
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_SEARCH) { status.text = "SUBMITTED:$text"; true } else false
            }
        }
        val search = Button(this).apply {
            text = "Search fixture"
            setOnClickListener { status.text = "SUBMITTED:${editor.text}" }
        }
        val result = Button(this).apply {
            text = "Interstellar (2014)"
            setOnClickListener { status.text = "RESULT_SELECTED" }
        }
        val virtual = object : TextView(this) {
            override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
                if (action == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK) {
                    status.text = "VIRTUAL_SELECTED"; return true
                }
                return super.performAccessibilityAction(action, arguments)
            }
        }.apply { text = "Virtual control"; isClickable = false }
        val touchAlternative = object : TextView(this) {
            override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
                if (action == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK) {
                    status.text = "ACK_WITHOUT_SELECTION"; return true
                }
                return super.performAccessibilityAction(action, arguments)
            }
            override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
                if (event.action == android.view.MotionEvent.ACTION_UP) status.text = "TOUCH_SELECTED"
                return true
            }
        }.apply { text = "Touch alternative"; isClickable = true; minHeight = 80 }
        layout.addView(button); layout.addView(editor); layout.addView(search); layout.addView(result); layout.addView(virtual); layout.addView(touchAlternative); layout.addView(status)
        setContentView(layout)
    }
}

class DiagnosticFixtureActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val status = TextView(this).apply { text = "IDLE" }
        val editor = EditText(this).apply { hint = "Parla per cercare"; setSingleLine(true) }
        val voice = Button(this).apply { text = "Voice search"; setOnClickListener { status.text = "VOICE_SELECTED" } }
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val orb = android.widget.FrameLayout(this).apply {
            isFocusable = true; isClickable = true
            layoutParams = LinearLayout.LayoutParams(124, 124)
            setOnClickListener { status.text = "ORB_SELECTED" }
        }
        orb.addView(android.widget.ImageView(this).apply { contentDescription = "Azione di ricerca" }, android.widget.FrameLayout.LayoutParams(80, 80))
        row.addView(orb)
        row.addView(object : EditText(this) {
            override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo?) {
                super.onInitializeAccessibilityNodeInfo(info)
                info?.className = "androidx.leanback.widget.StreamingTextView"
            }
        }.apply { hint = "Other input" }, LinearLayout.LayoutParams(800, 124))
        val ordinaryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val ordinaryOrb = android.widget.FrameLayout(this).apply {
            isClickable = true; isFocusable = true
            setOnClickListener { status.text = "SUBMIT_SELECTED" }
        }
        ordinaryOrb.addView(android.widget.ImageView(this).apply { contentDescription = "Search action" }, android.widget.FrameLayout.LayoutParams(80, 80))
        ordinaryRow.addView(ordinaryOrb, LinearLayout.LayoutParams(124, 124))
        ordinaryRow.addView(EditText(this).apply { hint = "Regular search" }, LinearLayout.LayoutParams(800, 124))
        val normal = Button(this).apply { text = "Normal control"; setOnClickListener { status.text = "SAFE_SELECTED" } }
        val fallbackArea = android.widget.FrameLayout(this).apply { contentDescription = "Fallback search area" }
        fallbackArea.addView(Button(this).apply { text = "Microphone"; setOnClickListener { status.text = "VOICE_SELECTED" } }, android.widget.FrameLayout.LayoutParams(124, 124))
        layout.addView(editor); layout.addView(voice); layout.addView(row); layout.addView(ordinaryRow); layout.addView(normal); layout.addView(fallbackArea, LinearLayout.LayoutParams(124, 124)); layout.addView(status)
        setContentView(layout)
    }
}
