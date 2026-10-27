package com.example.app_gif

import kotlin.math.atan2
import kotlin.math.sqrt

/** w,x,y,z quaternions; any initial grip becomes the neutral paddle pose. */
class SwingPoseProjection {
    private var base: DoubleArray? = null
    private var current: DoubleArray? = null
    fun reset() { base = null; current = null }
    fun calibrate() { base = current?.copyOf() }
    fun sample(q: DoubleArray): DoubleArray {
        require(q.size == 4 && q.all { it.isFinite() })
        val norm = sqrt(q.sumOf { it*it })
        if (norm < 0.000001) return doubleArrayOf(0.0,0.0,0.0)
        val v = DoubleArray(4) { q[it]/norm }
        current = v
        if (base == null) base = v.copyOf()
        val b = base!!
        // inverse(base) * current, projected along the phone's screen normal.
        val w = b[0]*v[0]+b[1]*v[1]+b[2]*v[2]+b[3]*v[3]
        val x = b[0]*v[1]-b[1]*v[0]-b[2]*v[3]+b[3]*v[2]
        val y = b[0]*v[2]+b[1]*v[3]-b[2]*v[0]-b[3]*v[1]
        val z = b[0]*v[3]-b[1]*v[2]+b[2]*v[1]-b[3]*v[0]
        val dx = 2*(x*z+w*y); val dy = 2*(y*z-w*x); val dz = 1-2*(x*x+y*y)
        val yaw = atan2(dx,dz)
        val pitch = atan2(-dy,sqrt(dx*dx+dz*dz))
        val twist = atan2(2*(w*z+x*y),1-2*(x*x+z*z))
        return doubleArrayOf((yaw/0.62).coerceIn(-1.0,1.0),
            (-pitch/0.50).coerceIn(-1.0,1.0),(twist/0.9).coerceIn(-1.0,1.0))
    }
}
