package com.orailnoor.privateagent

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.SystemClock
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File

/** Redacted diagnostics: 128 KiB ring plus one explicit export <=128 KiB. */
object DiagnosticTrace {
    const val FILE_BYTES = 64 * 1024
    const val RING_BYTES = 2 * FILE_BYTES
    private val activeSteps = mutableMapOf<String, Int>()
    private fun prefs(c: Context) = c.getSharedPreferences("diagnostic_trace", Context.MODE_PRIVATE)
    private fun dir(c: Context) = File(c.filesDir, "diagnostics").apply { mkdirs() }
    fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)
    @Synchronized fun setEnabled(c: Context, enabled: Boolean) {
        prefs(c).edit().putBoolean("enabled", enabled).apply()
        if (!enabled) activeSteps.clear()
    }
    private val numeric = setOf("step", "duration_ms", "tokens", "controls", "editable", "voice_controls", "characters", "plan_revision", "local_failures", "event_type")
    private val flags = setOf("accepted", "keyboard_open", "readback_matches", "window_active", "window_focused", "voice_allowed", "target_focused", "target_editable", "supports_set_text")
    private val codes = setOf("action", "reason", "status", "transport", "role", "screen", "before", "after", "label_role", "requested_role")
    private val codeValues = setOf(
        "click_text", "click_at", "tap_at", "type_text", "press_back", "press_home", "press_enter", "scroll", "swipe", "open_app", "wait", "replan", "done", "failed", "unknown",
        "native_rejected", "accepted", "voice_control_blocked", "not_found", "keyboard_open", "display_unsupported", "invalid_coordinates", "dispatch_rejected", "gesture_cancelled", "gesture_timeout", "native_exception", "service_unavailable",
        "none", "accessibility_click", "accessibility_ancestor", "gesture_touch", "accessibility_set_text", "global_action", "app_launcher", "text_input", "voice_search", "control",
        "started", "succeeded", "cancelled", "running", "blocked", "completed", "step_limit", "format_error", "ai_error", "unsupported", "candidate", "local_repair", "strategy_replan", "control_rejected", "ineffective_control", "cycle_detected", "model_replan", "early_replan_deferred", "branch_exhausted", "completion_evidence_missing", "completion_evidence_mismatch", "query_mismatch", "query_confirmed", "connection_error", "timeout", "http_error", "parse_error", "unreadable", "search_navigation", "tv_guide", "history", "back", "search_action")
    private fun credentialLike(value: String) = Regex("(?i)(sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9_]{16,}|bearer\\s+\\S+|AIza[a-z0-9_-]{20,})").containsMatchIn(value)
    // Values are schema-bound, never arbitrary model reasoning, UI text or params.
    private fun clean(fields: Map<String, Any?>): Map<String, Any> = buildMap {
        for ((key, value) in fields) {
            if (value is String && credentialLike(value)) continue
            when {
                key in numeric && value is Number -> put(key, value.toLong().coerceIn(0, 10_000_000))
                key in flags && value is Boolean -> put(key, value)
                key in codes && value is String && (value in codeValues || (key in setOf("screen", "before", "after") && Regex("^S[0-9]{1,4}$").matches(value))) -> put(key, value)
                key == "package" && value is String && Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$").matches(value) -> put(key, value.take(160))
                key == "class" && value is String && Regex("^[a-zA-Z0-9_.$]{1,160}$").matches(value) -> put(key, value)
                key == "view_id" && value is String && Regex("^[a-zA-Z][a-zA-Z0-9_.]*:id/[a-zA-Z0-9_]{1,96}$").matches(value) -> put(key, value)
                key in setOf("bounds", "requested_point") && value is List<*> && value.size == (if (key == "bounds") 4 else 2) && value.all { it is Number && it.toDouble().isFinite() } -> put(key, value.map { (it as Number).toInt().coerceIn(-10000, 10000) })
            }
        }
    }
    @Synchronized fun append(c: Context, task: String, event: String, fields: Map<String, Any?> = emptyMap()) {
        if (!enabled(c) || credentialLike(task) || credentialLike(event) || !Regex("^[a-zA-Z0-9_-]{1,80}$").matches(task) || !Regex("^[a-z_]{1,48}$").matches(event)) return
        try {
            val doc = JSONObject(clean(fields)).put("task", task).put("event", event)
                .put("time_ms", System.currentTimeMillis()).put("elapsed_ms", SystemClock.elapsedRealtime())
            val bytes = (doc.toString() + "\n").toByteArray(Charsets.UTF_8)
            if (bytes.size > 2048) return
            val current = File(dir(c), "current.jsonl")
            val previous = File(dir(c), "previous.jsonl")
            if (current.length() > FILE_BYTES) current.delete()
            if (previous.length() > FILE_BYTES) previous.delete()
            if (current.length() + bytes.size > FILE_BYTES) {
                previous.delete()
                if (current.exists() && !current.renameTo(previous)) return
            }
            current.appendBytes(bytes)
            when (event) {
                "task_start" -> { if (activeSteps.size >= 4) activeSteps.remove(activeSteps.keys.first()); activeSteps[task] = 0 }
                "observation" -> if (activeSteps.containsKey(task)) activeSteps[task] = (fields["step"] as? Number)?.toInt() ?: 0
                "task_end" -> activeSteps.remove(task)
            }
        } catch (_: Exception) { /* Diagnostics must not break device control. */ }
    }
    @Synchronized fun windowEvent(c: Context, type: Int, pkg: String?, cls: String?) {
        if (!enabled(c)) return
        for ((task, step) in activeSteps.toMap()) {
            append(c, task, "window_event", mapOf("step" to step, "event_type" to type, "package" to pkg, "class" to cls))
        }
    }
    @Synchronized fun state(c: Context): Map<String, Any> = mapOf(
        "enabled" to enabled(c), "bytes" to listOf("previous.jsonl", "current.jsonl").sumOf { File(dir(c), it).length() },
        "max_bytes" to RING_BYTES, "export_name" to "PrivateAgent-diagnostics.jsonl")
    @Synchronized fun clear(c: Context) {
        listOf("previous.jsonl", "current.jsonl").forEach { File(dir(c), it).delete() }
        activeSteps.clear()
        prefs(c).getString("export_uri", null)?.let { value ->
            c.contentResolver.delete(Uri.parse(value), null, null)
        }
        prefs(c).edit().remove("export_uri").apply()
    }
    /** User-triggered export only. Reuses one owned Downloads item. */
    @Synchronized fun export(c: Context): String {
        check(android.os.Build.VERSION.SDK_INT >= 29) { "Export requires Android 10 or later" }
        val resolver = c.contentResolver
        var uri = prefs(c).getString("export_uri", null)?.let { Uri.parse(it) }
        if (uri != null) {
            resolver.query(uri!!, arrayOf(MediaStore.MediaColumns._ID), null, null, null).use { cursor ->
                checkNotNull(cursor) { "Could not inspect diagnostic export" }
                if (!cursor.moveToFirst()) uri = null
            }
        }
        if (uri == null) {
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "PrivateAgent-diagnostics.jsonl")
                put(MediaStore.MediaColumns.MIME_TYPE, "application/x-ndjson")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }) ?: error("Could not create diagnostic export")
            prefs(c).edit().putString("export_uri", uri.toString()).apply()
        }
        resolver.openOutputStream(uri!!, "wt").use { out ->
            checkNotNull(out)
            for (name in listOf("previous.jsonl", "current.jsonl")) {
                val file = File(dir(c), name)
                if (file.exists()) file.inputStream().use { it.copyTo(out) }
            }
        }
        val name = resolver.query(uri!!, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null).use { cursor ->
            if (cursor != null && cursor.moveToFirst()) cursor.getString(0) else "PrivateAgent-diagnostics.jsonl"
        }
        return "Download/$name"
    }
}
