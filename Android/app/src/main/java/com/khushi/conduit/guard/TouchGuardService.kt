package com.khushi.conduit.guard

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.TouchInteractionController
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.MotionEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager

/**
 * Makes this phone ignore its own touchscreen while Conduit for Mac mirrors
 * it with the screen off.
 *
 * Turning the panel off leaves the touchscreen live on some phones (measured
 * on a Galaxy S24 Ultra), and adb cannot disable an input device. Android
 * passes touches from the phone's own screen through accessibility before
 * any app sees them, but input injected from the Mac skips that step — so
 * this service swallows the phone's touches while the Mac keeps control.
 *
 * It only runs while [TouchGuardLease] holds: Conduit for Mac turns the
 * service on, renews the lease while the screen is off, and turns the service
 * off afterwards. It stands down by itself when the lease runs out, when the
 * power button is pressed, or when it was turned on by hand. It reads nothing
 * on the screen: it asks only for the two events that say a touch started
 * and ended, which Android requires before it will route touches here.
 */
class TouchGuardService : AccessibilityService() {

    private val handler = Handler(Looper.getMainLooper())
    private var controller: TouchInteractionController? = null
    private var receiverRegistered = false

    /** The power button means someone has the phone in hand. */
    private val powerButton = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = standDown("power button")
    }

    private val leaseCheck = object : Runnable {
        override fun run() {
            if (TouchGuardLease.isActive()) {
                handler.postDelayed(this, LEASE_CHECK_MS)
            } else {
                standDown("lease ended")
            }
        }
    }

    override fun onServiceConnected() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Log.i(TAG, "touch guard needs Android 13")
            disableSelf()
            return
        }
        if (!TouchGuardLease.isActive()) {
            Log.i(TAG, "touch guard turned on without Conduit for Mac; turning it off")
            disableSelf()
            return
        }

        // Registered as the only callback, so the framework hands every touch
        // here and nowhere else. Made only now: Android 12 has no such class,
        // and a field holding one would crash the service before this check.
        controller = getTouchInteractionController(Display.DEFAULT_DISPLAY).also {
            it.registerCallback(mainExecutor, object : TouchInteractionController.Callback {
                override fun onMotionEvent(event: MotionEvent) = Unit
                override fun onStateChanged(state: Int) = Unit
            })
        }
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON) }
        registerReceiver(powerButton, filter, Context.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
        handler.postDelayed(leaseCheck, LEASE_CHECK_MS)

        active = this
        Log.i(TAG, "ready; touch exploration on: ${touchExplorationOn}")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        tearDown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        tearDown()
        super.onDestroy()
    }

    private fun standDown(reason: String) {
        Log.i(TAG, "touches work again: $reason")
        tearDown()
        disableSelf()
    }

    private fun tearDown() {
        handler.removeCallbacks(leaseCheck)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) controller?.unregisterAllCallbacks()
        controller = null
        if (receiverRegistered) {
            unregisterReceiver(powerButton)
            receiverRegistered = false
        }
        if (active === this) active = null
    }

    /**
     * Whether Android is routing touches through accessibility at all. Until
     * it is, this service is bound but sees nothing — so the Mac is told the
     * guard is not up rather than being let believe it is.
     */
    private val touchExplorationOn: Boolean
        get() = getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled == true

    companion object {
        private const val TAG = "ConduitTouchGuard"
        private const val LEASE_CHECK_MS = 5_000L

        /** The running guard, if touches are being ignored right now. Main thread only. */
        private var active: TouchGuardService? = null

        val isGuarding: Boolean get() = active?.touchExplorationOn == true

        /** Ends the guard now. Main thread only. */
        fun release() {
            active?.standDown("released by Conduit for Mac")
        }
    }
}
