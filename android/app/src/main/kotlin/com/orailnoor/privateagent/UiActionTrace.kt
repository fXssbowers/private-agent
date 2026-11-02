package com.orailnoor.privateagent

import android.content.Context
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo

/** Per-call context; ThreadLocal is scoped to synchronous native resolution.
 * Async callbacks capture the instance, never a global "last action". */
class UiActionTrace(val context: Context, val task: String, val step: Int, val action: String, val voiceAllowed: Boolean) {
    var reason = "native_rejected"
    var transport = "none"
    var target: Map<String, Any?> = emptyMap()
    private var point: Map<String, Any?> = emptyMap()
    fun resolved(node: AccessibilityNodeInfo, via: String) {
        val window = node.window
        target = UiControlSemantics.descriptor(node) + mapOf("window_active" to window?.isActive, "window_focused" to window?.isFocused)
        window?.recycle()
        transport = via
        DiagnosticTrace.append(context, task, "resolved_target", target + mapOf("step" to step, "action" to action, "transport" to transport, "status" to "candidate"))
    }
    fun beforeDispatch() = DiagnosticTrace.append(context, task, "dispatch", target + point + mapOf("step" to step, "action" to action, "transport" to transport, "voice_allowed" to voiceAllowed))
    fun requestedPoint(x: Float, y: Float) {
        if (!x.isFinite() || !y.isFinite()) return
        point = mapOf("requested_point" to listOf(x, y))
        DiagnosticTrace.append(context, task, "interaction_request", point + mapOf("step" to step, "action" to action))
    }
    fun requestedText(text: String) = DiagnosticTrace.append(context, task, "interaction_request", mapOf("step" to step, "action" to action, "requested_role" to UiControlSemantics.labelRole(listOf(text.lowercase()))))
    fun finish(accepted: Boolean): Map<String, Any?> {
        if (accepted) reason = "accepted"
        DiagnosticTrace.append(context, task, "native_result", mapOf("step" to step, "action" to action, "accepted" to accepted, "reason" to reason, "transport" to transport))
        val method = if (transport == "accessibility_ancestor") "accessibility_click" else transport
        return mapOf("accepted" to accepted, "reason" to reason, "role" to (target["role"] ?: "unknown"),
            "transport" to transport, "control_key" to if (target.isEmpty()) "" else "${target["package"]}|${target["view_id"]}|${target["class"]}|${target["bounds"]}|$method")
    }
    fun <T> scoped(block: () -> T): T {
        val previous = current.get(); current.set(this)
        try { return block() } finally { current.set(previous) }
    }
    companion object { val current = ThreadLocal<UiActionTrace?>() }
}

object UiControlSemantics {
    private val leanbackEditors = setOf("androidx.leanback.widget.StreamingTextView", "androidx.leanback.widget.SearchEditText", "android.support.v17.leanback.widget.StreamingTextView", "android.support.v17.leanback.widget.SearchEditText")
    fun textInput(node: AccessibilityNodeInfo): Boolean = node.isEditable ||
        node.className?.toString() in leanbackEditors ||
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }
    private fun labels(node: AccessibilityNodeInfo) = listOf(node.text, node.contentDescription)
        .map { it?.toString().orEmpty().trim().lowercase() }
    private fun containsLeanbackEditor(node: AccessibilityNodeInfo, depth: Int): Boolean {
        if (node.className?.toString() in leanbackEditors) return true
        if (depth <= 0) return false
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = containsLeanbackEditor(child, depth - 1); child.recycle()
            if (found) return true
        }
        return false
    }
    private fun searchActionMarker(node: AccessibilityNodeInfo, depth: Int): Boolean {
        if (labels(node).any { it in setOf("search action", "azione di ricerca") }) return true
        if (depth <= 0) return false
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = searchActionMarker(child, depth - 1); child.recycle()
            if (found) return true
        }
        return false
    }
    fun voiceControl(node: AccessibilityNodeInfo): Boolean {
        // An editable field may have a voice-related hint; it is still text input.
        if (textInput(node)) return false
        val id = node.viewIdResourceName.orEmpty().lowercase()
        val cls = node.className?.toString().orEmpty().lowercase()
        val text = labels(node)
        if (cls.contains("speechorb") || cls.contains("voicesearch") ||
            Regex("(^|_)(speech_orb|voice_search|microphone|mic_button)(_|$)").containsMatchIn(id.substringAfterLast('/')) ||
            text.any { it in setOf("voice search", "ricerca vocale", "microphone", "microfono", "start voice search", "avvia ricerca vocale") }) return true

        // Leanback's speech orb can expose only the generic 'Search action'
        // description, next to its editable/streaming text field.
        val bounds = Rect(); node.getBoundsInScreen(bounds)
        if (bounds.width() <= 0 || bounds.height() <= 0 || bounds.width() > bounds.height() * 2 ||
            bounds.height() > bounds.width() * 2 || !searchActionMarker(node, 2)) return false
        // Scope the ambiguous marker to its immediate orb/search-bar pair,
        // not an unrelated editor elsewhere on the page.
        val markerOnImage = node.className?.toString()?.endsWith("ImageView") == true
        val orb = if (markerOnImage) node.parent else AccessibilityNodeInfo.obtain(node)
        if (orb == null) return false
        if (orb.className?.toString()?.endsWith("FrameLayout") != true) { orb.recycle(); return false }
        val bar = orb.parent
        orb.recycle()
        if (bar == null) return false
        val found = containsLeanbackEditor(bar, 3)
        bar.recycle()
        return found
    }
    fun labelRole(labels: List<String>): String {
        for (label in labels) {
            when (label.trim()) {
                "search", "cerca", "ricerca" -> return "search_navigation"
                "tv guide", "guida tv" -> return "tv_guide"
                "history", "cronologia" -> return "history"
                "back", "indietro" -> return "back"
                "search action", "azione di ricerca" -> return "search_action"
                "voice search", "ricerca vocale", "microphone", "microfono" -> return "voice_search"
            }
        }
        return "none"
    }
    fun descriptor(node: AccessibilityNodeInfo): Map<String, Any?> {
        val rect = Rect(); node.getBoundsInScreen(rect)
        return mapOf("package" to node.packageName?.toString(), "class" to node.className?.toString(),
            "view_id" to node.viewIdResourceName, "bounds" to listOf(rect.left, rect.top, rect.right, rect.bottom),
            "target_focused" to node.isFocused, "target_editable" to node.isEditable, "supports_set_text" to node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT },
            "label_role" to if (textInput(node)) "none" else labelRole(labels(node)),
            "role" to if (textInput(node)) "text_input" else if (voiceControl(node)) "voice_search" else "control")
    }
}
