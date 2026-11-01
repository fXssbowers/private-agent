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
                    check(action { control.clickByText("Film", it) }) { "Editable focus rejected" }
                    SystemClock.sleep(1500)
                    check(action { done -> done(control.typeText("Interstellar", "Film")) }) { "Text entry rejected" }
                    SystemClock.sleep(400)
                    checkQuery(control, "after typing")
                    check(nodes(control).any { it["className"] == "KeyboardStatus" }) { "Open TV keyboard was not detected" }
                    check(nodes(control).none { it["text"]?.toString() == "q" }) { "TV keyboard keys leaked into app controls" }
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
        layout.addView(button); layout.addView(editor); layout.addView(search); layout.addView(result); layout.addView(virtual); layout.addView(status)
        setContentView(layout)
    }
}
