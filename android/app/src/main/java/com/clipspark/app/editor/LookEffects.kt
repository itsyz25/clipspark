package com.clipspark.app.editor

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.Effect
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.HslAdjustment
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Look effects shared by preview (ExoPlayer.setVideoEffects) and export
 * (Transformer), so both pipelines apply the exact same GPU math.
 *
 * Brightness / contrast / saturation are Media3's built-in GL effects.
 * Motion blur is a small custom directional shader (17 taps along the chosen
 * angle) — no extra dependency, no network, runs on the device GPU.
 */
fun buildLookEffects(look: Look): List<Effect> = buildList {
    if (abs(look.brightness) > 0.001f) {
        add(Brightness(look.brightness.coerceIn(-1f, 1f)))
    }
    if (abs(look.contrast - 1f) > 0.001f) {
        add(Contrast((look.contrast - 1f).coerceIn(-1f, 1f)))
    }
    if (abs(look.saturation - 1f) > 0.001f) {
        add(
            HslAdjustment.Builder()
                .adjustSaturation(((look.saturation - 1f) * 100f).coerceIn(-100f, 100f))
                .build()
        )
    }
    if (look.motionBlur > 0.005f) {
        add(DirectionalMotionBlur(look.motionBlur.coerceIn(0f, 1f), look.motionBlurAngle))
    }
}

/** Adjustable, directional shutter-style motion blur. */
class DirectionalMotionBlur(
    private val strength: Float,
    angleDegrees: Float,
) : GlEffect {

    private val angle = Math.toRadians(angleDegrees.toDouble())

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        DirectionalBlurShaderProgram(useHdr, strength, angle)

    override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = strength <= 0.001f
}

/**
 * Single-pass GLSL motion blur: averages 17 samples along `uStep`.
 * Radius is 2% of the frame height at full strength (the same proportion the
 * iOS Core Image path uses), so preview and export match.
 */
private class DirectionalBlurShaderProgram(
    useHdr: Boolean,
    private val strength: Float,
    private val angleRadians: Double,
) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity= */ 1) {

    private val glProgram: GlProgram = try {
        GlProgram(VERTEX_SHADER, FRAGMENT_SHADER)
    } catch (e: GlUtil.GlException) {
        throw VideoFrameProcessingException(e)
    }
    private var inputWidth = 1
    private var inputHeight = 1

    init {
        glProgram.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
        val identity = GlUtil.create4x4IdentityMatrix()
        glProgram.setFloatsUniform("uTransformationMatrix", identity)
        glProgram.setFloatsUniform("uTexTransformationMatrix", identity)
    }

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        this.inputWidth = inputWidth.coerceAtLeast(1)
        this.inputHeight = inputHeight.coerceAtLeast(1)
        return Size(inputWidth, inputHeight)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            glProgram.use()
            glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex= */ 0)
            val radiusPx = 0.02f * strength * inputHeight
            val stepX = radiusPx * cos(angleRadians).toFloat() / inputWidth
            val stepY = radiusPx * sin(angleRadians).toFloat() / inputHeight
            glProgram.setFloatsUniform("uStep", floatArrayOf(stepX, stepY))
            glProgram.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    private companion object {
        private val VERTEX_SHADER = """
            #version 100
            attribute vec4 aFramePosition;
            uniform mat4 uTransformationMatrix;
            uniform mat4 uTexTransformationMatrix;
            varying vec2 vTexSamplingCoord;
            void main() {
              gl_Position = uTransformationMatrix * aFramePosition;
              vec4 texturePosition = vec4(aFramePosition.x * 0.5 + 0.5,
                                          aFramePosition.y * 0.5 + 0.5, 0.0, 1.0);
              vTexSamplingCoord = (uTexTransformationMatrix * texturePosition).xy;
            }
        """.trimIndent()

        private val FRAGMENT_SHADER = """
            #version 100
            precision mediump float;
            uniform sampler2D uTexSampler;
            uniform vec2 uStep;
            varying vec2 vTexSamplingCoord;
            void main() {
              vec4 sum = vec4(0.0);
              for (int i = -8; i <= 8; i++) {
                float f = float(i) / 8.0;
                sum += texture2D(uTexSampler, vTexSamplingCoord + uStep * f);
              }
              gl_FragColor = sum / 17.0;
            }
        """.trimIndent()
    }
}
