package com.example.app_gif

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.sqrt

/** Relative orientation is stable without integrating acceleration into position. */
class PhoneSwingController(context: Context) : SensorEventListener {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val projection = SwingPoseProjection()
    private var active = false
    private var hasPose = false
    private var pending = 0
    private var lastHit = 0L
    private var direction = 1
    private var x = 0.0
    private var y = 0.0
    private var roll = 0.0
    private var first = true

    fun start(): Boolean {
        stop()
        val rotation = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return false
        active = manager.registerListener(this, rotation, SensorManager.SENSOR_DELAY_GAME)
        for (type in listOf(Sensor.TYPE_GYROSCOPE, Sensor.TYPE_LINEAR_ACCELERATION)) {
            manager.getDefaultSensor(type)?.let {
                manager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
            }
        }
        projection.reset(); first = true; hasPose = false
        lastHit = SystemClock.elapsedRealtime()
        return active
    }
    fun calibrate() {
        projection.calibrate(); x = 0.0; y = 0.0; roll = 0.0; pending = 0
        first = true; lastHit = SystemClock.elapsedRealtime()
    }
    fun read(): Map<String,Any> {
        val hit = pending; pending = 0
        return mapOf("available" to (active && hasPose), "x" to x, "y" to y, "roll" to roll, "swing" to hit)
    }
    fun stop() { manager.unregisterListener(this); active = false; pending = 0 }
    private fun hit(strength: Double) {
        val now = SystemClock.elapsedRealtime()
        if (strength < 1 || now-lastHit < 170) return
        lastHit = now
        pending = direction * (450+strength*170).toInt().coerceAtMost(1000)
    }
    override fun onSensorChanged(event: SensorEvent) {
        if (!active) return
        when(event.sensor.type) {
            Sensor.TYPE_GAME_ROTATION_VECTOR, Sensor.TYPE_ROTATION_VECTOR -> {
                val q = FloatArray(4)
                SensorManager.getQuaternionFromVector(q, event.values)
                val pose = projection.sample(q.map { it.toDouble() }.toDoubleArray())
                val alpha = if (first) 1.0 else 0.55
                x += (pose[0]-x)*alpha; y += (pose[1]-y)*alpha; roll += (pose[2]-roll)*alpha
                first = false; hasPose = true
            }
            Sensor.TYPE_GYROSCOPE -> {
                val gx = event.values[0].toDouble(); val gy = event.values[1].toDouble()
                if (abs(gy) > 0.35) direction = if (gy < 0) -1 else 1
                hit(sqrt(gx*gx+gy*gy)/2.2)
            }
            Sensor.TYPE_LINEAR_ACCELERATION -> hit(abs(event.values[2].toDouble())/3.6)
        }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
