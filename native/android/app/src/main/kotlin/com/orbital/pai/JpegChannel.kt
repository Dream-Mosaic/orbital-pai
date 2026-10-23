package com.orbital.pai

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max

/// "Henry, look at this": the camera plugin's JPEG, made into the one the server is promised
/// (`MethodChannel("henry/jpeg")`: normalize). The Dart side is `PluginCameraService`.
///
/// Three things, all on a worker thread:
/// - the EXIF orientation is baked into the pixels — CameraX writes a rotation tag rather than
///   rotating, and the vision model must not be handed a sideways photo;
/// - the long edge is brought down to `maxEdge` only when it is larger (never up);
/// - it is re-encoded at `quality`, with no EXIF left to disagree with the pixels.
///
/// Pure image work: no camera, no audio, no permission. [AudioRouteOwner] stays the only owner
/// of the mode and route.
class JpegChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "henry/jpeg")
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "normalize" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "no bytes", null)
                    return
                }
                val maxEdge = (call.argument<Any>("maxEdge") as? Number)?.toInt() ?: 800
                val quality = (call.argument<Any>("quality") as? Number)?.toInt() ?: 80
                worker.execute {
                    val out = try {
                        normalize(bytes, maxEdge, quality)
                    } catch (e: Throwable) {
                        null
                    }
                    // A MethodChannel.Result is answered on the platform thread.
                    main.post {
                        if (out != null) result.success(out)
                        else result.error("failed", "could not re-encode", null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun detach() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    companion object {
        fun normalize(jpeg: ByteArray, maxEdge: Int, quality: Int): ByteArray {
            val orientation = ExifInterface(ByteArrayInputStream(jpeg)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
            val w = bounds.outWidth
            val h = bounds.outHeight
            require(w > 0 && h > 0) { "not an image" }

            // Power-of-two subsampling first (cheap, at decode), then an exact scale below.
            var sample = 1
            while (max(w, h) / (sample * 2) >= maxEdge) sample *= 2
            val decoded = BitmapFactory.decodeByteArray(
                jpeg, 0, jpeg.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: throw IllegalArgumentException("undecodable")

            val long = max(decoded.width, decoded.height)
            val matrix = Matrix()
            if (long > maxEdge) {
                val s = maxEdge.toFloat() / long
                matrix.postScale(s, s)
            }
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    matrix.postRotate(90f)
                    matrix.postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    matrix.postRotate(270f)
                    matrix.postScale(-1f, 1f)
                }
            }
            val upright = if (matrix.isIdentity) {
                decoded
            } else {
                Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            }
            val out = ByteArrayOutputStream()
            upright.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
            if (upright !== decoded) upright.recycle()
            decoded.recycle()
            return out.toByteArray()
        }
    }
}
