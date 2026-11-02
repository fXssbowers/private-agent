package com.orailnoor.privateagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.provider.Settings
import android.graphics.Bitmap
import android.hardware.HardwareBuffer
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream

class AgentAccessibilityService : AccessibilityService() {

    private val ownPackageName = "com.orailnoor.privateagent"

    companion object {
        var instance: AgentAccessibilityService? = null
            private set
            
        var eventListener: ((Map<String, Any>) -> Unit)? = null

        fun isRunning(): Boolean = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val listener = eventListener ?: return
        
        // Filter out events from our own app so we don't record the Stop Overlay button clicks
        if (event.packageName?.toString() == "com.orailnoor.privateagent") return
        
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                val node = event.source
                var text = node?.text?.toString() ?: node?.contentDescription?.toString() ?: ""
                if (text.isEmpty() && event.text.isNotEmpty()) {
                    text = event.text.joinToString(" ")
                }
                
                val rect = Rect()
                node?.getBoundsInScreen(rect)
                val cx = rect.centerX()
                val cy = rect.centerY()
                
                // Only record if we have valid text or valid coordinates
                if (text.isNotEmpty() || (cx != 0 || cy != 0)) {
                    val map = mapOf(
                        "type" to "click",
                        "text" to text,
                        "x" to cx,
                        "y" to cy
                    )
                    listener(map)
                }
                node?.recycle()
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                val map = mapOf("type" to "scroll")
                listener(map)
            }
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    private fun isTelevisionDevice(): Boolean =
        packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_TELEVISION)

    private fun isKeyboardPackage(root: AccessibilityNodeInfo): Boolean {
        val imePackage = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')
        return !imePackage.isNullOrEmpty() && root.packageName?.toString() == imePackage
    }

    private fun isKeyboardWindow(window: AccessibilityWindowInfo, root: AccessibilityNodeInfo): Boolean =
        window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD || isKeyboardPackage(root)

    private fun keyboardOpenOnTv(): Boolean {
        if (!isTelevisionDevice()) return false
        for (window in windows) {
            val root = window.root ?: continue
            val keyboard = isKeyboardWindow(window, root)
            root.recycle()
            if (keyboard) return true
        }
        return false
    }

    // ─── Screen Reading ──────────────────────────────────────────

    /** Dump the current screen as a flat list of UI elements */
    fun dumpScreen(): List<Map<String, Any?>> {
        val nodes = mutableListOf<Map<String, Any?>>()
        val allWindows = windows
        if (allWindows == null || allWindows.isEmpty()) {
            val root = rootInActiveWindow ?: return emptyList()
            if (root.packageName?.toString() != ownPackageName &&
                !(isTelevisionDevice() && isKeyboardPackage(root))) {
                traverseNode(root, nodes, 0)
            }
            root.recycle()
            return nodes
        }
        
        var keyboardReported = false
        for (window in allWindows) {
            val root = window.root ?: continue
            if (isTelevisionDevice() && isKeyboardWindow(window, root)) {
                if (!keyboardReported) {
                    nodes.add(mapOf("index" to nodes.size, "text" to "TV keyboard open: use app Search control.",
                        "className" to "KeyboardStatus", "isClickable" to false, "isEditable" to false,
                        "isScrollable" to false, "depth" to 0))
                    keyboardReported = true
                }
                root.recycle()
                continue
            }
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            traverseNode(root, nodes, 0)
            root.recycle()
        }
        return nodes
    }

    private fun traverseNode(
        node: AccessibilityNodeInfo,
        nodes: MutableList<Map<String, Any?>>,
        depth: Int
    ) {
        val rect = Rect()
        node.getBoundsInScreen(rect)

        val text = node.text?.toString() ?: ""
        val contentDesc = node.contentDescription?.toString() ?: ""
        val className = node.className?.toString() ?: ""
        val viewId = node.viewIdResourceName ?: ""

        // Filter out completely hidden or zero-size nodes (like scrolled-out WebView elements)
        val isZeroSize = rect.width() <= 0 || rect.height() <= 0
        if (!node.isVisibleToUser || isZeroSize) {
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                traverseNode(child, nodes, depth + 1)
                child.recycle()
            }
            return
        }

        // Only include nodes that have text/description or are interactive
        if (text.isNotEmpty() || contentDesc.isNotEmpty() ||
            node.isClickable || node.isEditable || node.isScrollable
        ) {
            nodes.add(
                mapOf(
                    "index" to nodes.size,
                    "text" to text,
                    "contentDescription" to contentDesc,
                    "className" to className.substringAfterLast('.'),
                    "viewId" to viewId,
                    "isClickable" to node.isClickable,
                    "isEditable" to node.isEditable,
                    "isScrollable" to node.isScrollable,
                    "isCheckable" to node.isCheckable,
                    "isChecked" to node.isChecked,
                    "isFocused" to node.isFocused,
                    "isSelected" to node.isSelected,
                    "bounds" to mapOf(
                        "left" to rect.left,
                        "top" to rect.top,
                        "right" to rect.right,
                        "bottom" to rect.bottom
                    ),
                    "depth" to depth
                )
            )
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            traverseNode(child, nodes, depth + 1)
            child.recycle()
        }
    }

    /** Capture screenshot as Base64 string */
    @RequiresApi(Build.VERSION_CODES.R)
    fun takeScreenshot(callback: (String?) -> Unit) {
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshotResult: ScreenshotResult) {
                    val hardwareBuffer = screenshotResult.hardwareBuffer
                    val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshotResult.colorSpace)
                        ?.copy(Bitmap.Config.ARGB_8888, false)
                    
                    hardwareBuffer.close()

                    if (bitmap != null) {
                        // Compress to lower quality JPEG to save bytes for the API
                        val byteArrayOutputStream = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 60, byteArrayOutputStream)
                        val byteArray = byteArrayOutputStream.toByteArray()
                        val base64String = Base64.encodeToString(byteArray, Base64.NO_WRAP)
                        callback(base64String)
                    } else {
                        callback(null)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    callback(null)
                }
            }
        )
    }

    // ─── Actions ─────────────────────────────────────────────────

    /** Resolve an actual accessible control before falling back to a gesture. */
    fun clickByText(targetText: String, callback: (Boolean) -> Unit) {
        if (targetText.isBlank()) { callback(false); return }
        val orderedWindows = windows.sortedBy { if (it.type == AccessibilityWindowInfo.TYPE_APPLICATION) 0 else 1 }
        for (skipEditable in listOf(true, false)) {
            for (window in orderedWindows) {
                for (exact in listOf(true, false)) {
                    val root = window.root ?: continue
                    if (root.packageName?.toString() == ownPackageName ||
                (isTelevisionDevice() && isKeyboardWindow(window, root))) {
                        root.recycle(); continue
                    }
                    val node = findTextNode(root, targetText, exact, skipEditable)
                    root.recycle()
                    if (node != null) {
                        val clicked = clickNodeOrParent(node)
                        val rect = Rect()
                        node.getBoundsInScreen(rect)
                        node.recycle()
                        if (clicked) callback(true)
                        else if (!rect.isEmpty && !keyboardOpenOnTv()) dispatchTap(rect.centerX().toFloat(), rect.centerY().toFloat(), callback)
                        else callback(false)
                        return
                    }
                }
            }
        }
        callback(false)
    }

    private fun findTextNode(node: AccessibilityNodeInfo, target: String, exact: Boolean, skipEditable: Boolean): AccessibilityNodeInfo? {
        if (!node.isVisibleToUser || (skipEditable && node.isEditable)) return null
        val labels = listOf(node.text?.toString().orEmpty(), node.contentDescription?.toString().orEmpty())
        val matches = labels.any { if (exact) it.equals(target, true) else it.contains(target, true) }
        if (matches && (!skipEditable || !node.isEditable)) return AccessibilityNodeInfo.obtain(node)
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findTextNode(child, target, exact, skipEditable)
            child.recycle()
            if (found != null) return found
        }
        return null
    }

    private fun clickNodeOrParent(node: AccessibilityNodeInfo): Boolean {
        var target: AccessibilityNodeInfo? = AccessibilityNodeInfo.obtain(node)
        var originalNode = true
        while (target != null) {
            // Virtual controls can implement ACTION_CLICK without isClickable.
            val clicked = target.isVisibleToUser && target.isEnabled && (originalNode || target.isClickable) &&
                target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            val parent = if (clicked) null else target.parent
            target.recycle()
            if (clicked) return true
            target = parent
            originalNode = false
        }
        return false
    }

    private fun findClickableAt(node: AccessibilityNodeInfo, x: Int, y: Int): AccessibilityNodeInfo? {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        if (!node.isVisibleToUser || !bounds.contains(x, y)) return null
        for (i in node.childCount - 1 downTo 0) {
            val child = node.getChild(i) ?: continue
            val found = findClickableAt(child, x, y)
            child.recycle()
            if (found != null) return found
        }
        return if (node.isClickable && node.isEnabled) AccessibilityNodeInfo.obtain(node) else null
    }

    fun clickAtCoordinates(x: Float, y: Float, callback: (Boolean) -> Unit) {
        if (!x.isFinite() || !y.isFinite() || x < 0 || y < 0 ||
            (isTelevisionDevice() && windows.isEmpty())) { callback(false); return }
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName ||
                (isTelevisionDevice() && isKeyboardWindow(window, root))) { root.recycle(); continue }
            val node = findClickableAt(root, x.toInt(), y.toInt())
            root.recycle()
            if (node != null) {
                val clicked = clickNodeOrParent(node)
                node.recycle()
                if (clicked) { callback(true); return }
                break
            }
        }
        if (keyboardOpenOnTv()) callback(false) else dispatchTap(x, y, callback)
    }

    // Android 11 checks Configuration.TOUCHSCREEN_FINGER independently of
    // the accessibility service's granted gesture permission.
    fun canDispatchTouch(): Boolean = resources.configuration.touchscreen ==
        android.content.res.Configuration.TOUCHSCREEN_FINGER

    /** Explicit physical touch alternative: never reinterpret it as ACTION_CLICK. */
    fun tapAtCoordinates(x: Float, y: Float, callback: (Boolean) -> Unit) {
        val display = resources.displayMetrics
        if (!x.isFinite() || !y.isFinite() || x < 0 || y < 0 ||
            x >= display.widthPixels || y >= display.heightPixels || !canDispatchTouch() ||
            (isTelevisionDevice() && windows.isEmpty()) || keyboardOpenOnTv()) {
            callback(false); return
        }
        dispatchTap(x, y, callback)
    }

    private fun dispatchTap(x: Float, y: Float, callback: (Boolean) -> Unit) {
        val path = Path().apply { moveTo(x, y) }
        dispatchCompletedGesture(GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 100)).build(), callback)
    }

    private fun dispatchCompletedGesture(gesture: GestureDescription, callback: (Boolean) -> Unit) {
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        fun finish(success: Boolean) {
            if (!finished) { finished = true; callback(success) }
        }
        val timeout = Runnable { finish(false) }
        handler.postDelayed(timeout, 2500)
        try {
            val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription) {
                    handler.removeCallbacks(timeout); finish(true)
                }
                override fun onCancelled(gestureDescription: GestureDescription) {
                    handler.removeCallbacks(timeout); finish(false)
                }
            }, handler)
            if (!accepted) { handler.removeCallbacks(timeout); finish(false) }
        } catch (_: RuntimeException) {
            handler.removeCallbacks(timeout); finish(false)
        }
    }

    fun typeText(text: String, fieldHint: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName ||
                (isTelevisionDevice() && isKeyboardWindow(window, root))) {
                root.recycle()
                continue
            }

            var editNode = findEditableNode(root, fieldHint)
            if (editNode == null && !fieldHint.isNullOrEmpty()) {
                editNode = findEditableNode(root, null)
            }

            if (editNode != null) {
                editNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle()
                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                val success = editNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    /** Submit an editable application field, never a focused letter in the IME. */
    fun pressEnter(callback: (Boolean) -> Unit) {
        // On TV the generic Enter action can activate the keyboard's focused
        // letter instead of submitting the editor. Leave the query intact and
        // let the agent activate the application's explicit search control.
        if (isTelevisionDevice()) {
            callback(false)
            return
        }
        for (window in windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            val root = window.root ?: continue
            val actionNode = findKeyboardActionNode(root)
            root.recycle()
            if (actionNode != null) {
                val submitted = actionNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                actionNode.recycle()
                if (submitted) { callback(true); return }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val root = window.root ?: continue
                if (root.packageName?.toString() == ownPackageName ||
                (isTelevisionDevice() && isKeyboardWindow(window, root))) { root.recycle(); continue }
                val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                val submitted = focused?.isEditable == true && focused.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                focused?.recycle()
                root.recycle()
                if (submitted) { callback(true); return }
            }
        }
        // A guessed coordinate can press a letter on a TV keyboard. Fail explicitly.
        callback(false)
    }

    private fun findKeyboardActionNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (!node.isVisibleToUser) return null
        val label = (node.text?.toString().orEmpty().ifEmpty {
            node.contentDescription?.toString().orEmpty()
        }).trim().lowercase()
        val labels = setOf("search", "enter", "go", "done", "send", "next", "cerca", "invio", "vai", "fine", "invia", "avanti")
        if (node.isClickable && node.isEnabled && label in labels) return AccessibilityNodeInfo.obtain(node)
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findKeyboardActionNode(child)
            child.recycle()
            if (found != null) return found
        }
        return null
    }

    private fun findEditableNode(
        node: AccessibilityNodeInfo,
        hint: String?
    ): AccessibilityNodeInfo? {
        if (node.isEditable) {
            if (hint == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            val hintText = node.hintText?.toString() ?: ""
            if (text.contains(hint, ignoreCase = true) ||
                desc.contains(hint, ignoreCase = true) ||
                hintText.contains(hint, ignoreCase = true)
            ) {
                return node
            }
            // If no hint match but this is the first editable, return it
            if (hint.isNullOrEmpty()) return node
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findEditableNode(child, hint)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Scroll forward on the first scrollable element, or a specific one by text */
    fun scroll(direction: String, targetText: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName ||
                (isTelevisionDevice() && isKeyboardWindow(window, root))) {
                root.recycle()
                continue
            }
            val scrollNode = findScrollableNode(root, targetText)
            if (scrollNode != null) {
                val action = when (direction.lowercase()) {
                    "down", "forward" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    "up", "backward" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    else -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                }
                val success = scrollNode.performAction(action)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    private fun findScrollableNode(
        node: AccessibilityNodeInfo,
        targetText: String?
    ): AccessibilityNodeInfo? {
        if (node.isScrollable) {
            if (targetText == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            if (text.contains(targetText, ignoreCase = true) ||
                desc.contains(targetText, ignoreCase = true)
            ) {
                return node
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findScrollableNode(child, targetText)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Press the global back button */
    fun pressBack(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** Press the global home button */
    fun pressHome(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /** Open recent apps */
    fun openRecents(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_RECENTS)
    }

    /** Open notifications */
    fun openNotifications(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
    }

    /** Swipe gesture */
    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, callback: (Boolean) -> Unit, durationMs: Long = 300) {
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        dispatchCompletedGesture(gesture, callback)
    }

    /** Long press at coordinates */
    fun longPressAt(x: Float, y: Float): Boolean {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 1000))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** Get the currently focused app's package name */
    fun getCurrentPackage(): String? {
        var ownApplicationSeen = false
        var fallbackApplication: String? = null

        for (window in windows) {
            val root = window.root ?: continue
            if (isTelevisionDevice() && isKeyboardWindow(window, root)) {
                root.recycle()
                continue
            }
            val pkg = root.packageName?.toString()
            root.recycle()

            if (pkg == null || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) {
                continue
            }

            // An active PrivateAgent application window is the main Flutter app.
            // Return it so TaskExecutor can press Home before taking its first dump.
            // The floating overlay is a system overlay, not an application window.
            if (window.isActive || window.isFocused) {
                return pkg
            }

            if (pkg == ownPackageName) {
                ownApplicationSeen = true
            } else if (fallbackApplication == null) {
                fallbackApplication = pkg
            }
        }

        return fallbackApplication ?: if (ownApplicationSeen) ownPackageName else null
    }
}
