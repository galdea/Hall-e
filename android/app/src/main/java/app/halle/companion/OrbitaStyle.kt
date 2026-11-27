package app.halle.companion

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.StateListDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsetsController
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** Orbita's dark-only palette (android/mobile-ui/src/app.css), shared by the native account screens. */
internal object OrbitaColors {
    val BG = 0xFF080E10.toInt()
    val PANEL = 0xFF101B1D.toInt()
    val LINE = 0xFF273B37.toInt()
    val TEXT = 0xFFE4E9D9.toInt()
    val MUTED = 0xFFA4B7B1.toInt()
    val MINT = 0xFF74E5C5.toInt()
    val MINT_PRESSED = 0xFF9AEFD6.toInt()
    val ON_MINT = 0xFF08221A.toInt()
    val PRESSED = 0xFF203B32.toInt()
    val MESSAGE = 0xFF24312B.toInt()
    val DANGER_BG = 0xFF52271E.toInt()
    val DANGER_PRESSED = 0xFF6A3328.toInt()
    val DANGER_TEXT = 0xFFFFB6A6.toInt()
    val ERROR_BG = 0xFF3B211D.toInt()
    val RED = 0xFFFF493C.toInt()
    val RECORDING = 0xFFFF9284.toInt()
}

/** WCAG relative luminance of an opaque ARGB colour. */
internal fun relativeLuminance(argb: Int): Double {
    fun channel(shift: Int): Double {
        val c = ((argb shr shift) and 0xFF) / 255.0
        return if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

/** WCAG contrast ratio between two opaque colours (1..21). */
internal fun contrastRatio(foreground: Int, background: Int): Double {
    val a = relativeLuminance(foreground); val b = relativeLuminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/** Spanish (es-CL) copy for the private agenda that depends on data. Static strings live with the screens. */
internal object AgendaCopy {
    val locale: Locale = Locale.forLanguageTag("es-CL")
    private val clock = DateTimeFormatter.ofPattern("HH:mm")
    private val shortDate = DateTimeFormatter.ofPattern("dd/MM")

    fun phoneStatus(status: MobileMeetingStatus): String = when (status) {
        MobileMeetingStatus.DRAFT -> "Borrador"
        MobileMeetingStatus.STARTING -> "Iniciando"
        MobileMeetingStatus.RECORDING -> "Grabando"
        MobileMeetingStatus.RECORDED -> "Grabada"
        MobileMeetingStatus.INTERRUPTED -> "Interrumpida"
        MobileMeetingStatus.FAILED -> "Falló"
    }

    /** Account recording states from the service; an unknown state is shown as sent. */
    fun recordingStatus(raw: String): String = when (raw) {
        "uploading" -> "Subiendo"
        "queued" -> "En cola"
        "submitting" -> "Enviando al servicio"
        "processing" -> "Transcribiendo"
        "review" -> "Necesita revisión"
        "failed" -> "Falló"
        "completed" -> "Transcrita"
        "disposing" -> "Eliminando"
        else -> raw
    }

    fun providerName(id: String): String = when (id) {
        "deepgram" -> "Deepgram"
        "speechmatics" -> "Speechmatics · UE"
        else -> id
    }

    /** State line of a phone recording under an account meeting; [queue] is its upload queue entry, if any. */
    fun phoneRecordingLine(status: MobileMeetingStatus, queue: JSONObject?, staging: Boolean, uploaded: Boolean): String =
        phoneStatus(status) + " · " + when {
            queue?.has("problem") == true -> "la subida necesita atención (HTTP ${queue.getInt("problem")})"
            queue != null && staging -> "en cola para staging"
            queue != null -> "en cola para " + providerName(queue.getString("provider"))
            uploaded -> "subida a tu cuenta"
            else -> "solo en este teléfono"
        }

    /** Confirmation for deleting an interrupted or failed phone recording of an account meeting. */
    fun deletePhoneCopyMessage(queued: Boolean, uploaded: Boolean): String = buildString {
        append("Esta grabación y su archivo de audio se borran de este teléfono. No se puede deshacer.")
        if (queued) append(" Su subida pendiente se cancela.")
        if (uploaded) append(" La copia que ya subiste a tu cuenta no cambia.")
    }

    /** "viernes 27 de noviembre", with the year only when it is not [today]'s. */
    fun dayLabel(date: LocalDate, today: LocalDate): String = date.format(DateTimeFormatter.ofPattern(
        if (date.year == today.year) "EEEE d 'de' MMMM" else "EEEE d 'de' MMMM 'de' yyyy", locale))

    /** "10:00 – 10:30" on one day; otherwise each end carries its date. */
    fun timeRange(start: ZonedDateTime, end: ZonedDateTime): String =
        if (start.toLocalDate() == end.toLocalDate()) start.format(clock) + " – " + end.format(clock)
        else start.format(shortDate) + " " + start.format(clock) + " – " + end.format(shortDate) + " " + end.format(clock) +
            (if (start.year != end.year) " (${end.year})" else "")

    fun rowDate(start: ZonedDateTime): String = start.format(shortDate)
    fun rowTime(start: ZonedDateTime): String = start.format(clock)
    fun syncedAt(time: LocalTime): String = "Sincronizado a las " + time.withNano(0)
}

internal enum class OrbitaButton { PRIMARY, SECONDARY, TEXT, DANGER, DANGER_QUIET }

/** Builds Orbita-styled native views. Sizes are dp, text sizes sp, so system font scale applies. */
internal class OrbitaKit(private val context: Context) {
    private val metrics = context.resources.displayMetrics
    val regular: Typeface = Typeface.create(Typeface.SANS_SERIF, 400, false)
    val medium: Typeface = Typeface.create(Typeface.SANS_SERIF, 500, false)
    val mono: Typeface = Typeface.MONOSPACE

    fun dp(value: Number): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), metrics).roundToInt()
    private fun sp(value: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, metrics).roundToInt()

    fun rounded(fill: Int, radiusDp: Number, stroke: Int? = null, strokeDp: Number = 1): GradientDrawable = GradientDrawable().apply {
        setColor(fill); cornerRadius = dp(radiusDp).toFloat()
        if (stroke != null) setStroke(max(1, dp(strokeDp)), stroke)
    }

    private fun states(normal: Drawable, pressed: Drawable, focused: Drawable) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), pressed)
        addState(intArrayOf(android.R.attr.state_focused), focused)
        addState(intArrayOf(), normal)
    }

    private fun colors(color: Int) = ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
        intArrayOf(Color.argb(122, Color.red(color), Color.green(color), Color.blue(color)), color))

    fun params(width: Int = LinearLayout.LayoutParams.MATCH_PARENT, top: Int = 0, bottom: Int = 0) =
        LinearLayout.LayoutParams(width, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(top); bottomMargin = dp(bottom) }

    fun text(value: CharSequence, sizeSp: Float = 16f, color: Int = OrbitaColors.TEXT, face: Typeface = regular,
             lineSp: Float = sizeSp * 1.5f): TextView = TextView(context).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        setTextColor(color); typeface = face
        lineHeight = sp(lineSp)
        layoutParams = params()
    }

    /** h1: 34sp, weight 500, letter-spacing −1.2px. */
    fun title(value: CharSequence, sizeSp: Float = 34f) = text(value, sizeSp, face = medium, lineSp = sizeSp * 1.16f).apply {
        letterSpacing = -1.2f / 34f; isAccessibilityHeading = true; layoutParams = params(bottom = 12)
    }

    fun heading(value: CharSequence) = text(value, 18f, face = medium, lineSp = 26f).apply {
        isAccessibilityHeading = true; layoutParams = params(top = 28, bottom = 4)
    }

    /** 11sp monospace uppercase, letter-spacing 1.4px, muted. */
    fun eyebrow(value: CharSequence) = text(value, 11f, OrbitaColors.MUTED, mono, 16.5f).apply {
        isAllCaps = true; letterSpacing = 1.4f / 11f; layoutParams = params(top = 10, bottom = 12)
    }

    fun body(value: CharSequence, sizeSp: Float = 16f) = text(value, sizeSp).apply { layoutParams = params(top = 8, bottom = 8) }
    fun muted(value: CharSequence, sizeSp: Float = 14f) = text(value, sizeSp, OrbitaColors.MUTED).apply { layoutParams = params(top = 4, bottom = 4) }
    fun status(value: CharSequence, color: Int = OrbitaColors.MINT) = text(value, 13f, color, lineSp = 20f).apply {
        layoutParams = params(top = 4, bottom = 4)
    }

    /** Orbita's message band. Polite live region, so TalkBack reads status changes. */
    fun message(value: CharSequence) = text(value, 13f, lineSp = 20f).apply {
        background = rounded(OrbitaColors.MESSAGE, 14)
        setPadding(dp(14), dp(10), dp(14), dp(10))
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        layoutParams = params(top = 4, bottom = 8)
    }

    fun button(kind: OrbitaButton, label: CharSequence, description: CharSequence? = null, onClick: () -> Unit): Button =
        Button(context).apply {
            text = label; isAllCaps = false; stateListAnimator = null
            typeface = medium
            val (fill, pressed, ink, stroke) = when (kind) {
                OrbitaButton.PRIMARY -> listOf(OrbitaColors.MINT, OrbitaColors.MINT_PRESSED, OrbitaColors.ON_MINT, null)
                OrbitaButton.SECONDARY -> listOf(OrbitaColors.PANEL, OrbitaColors.PRESSED, OrbitaColors.TEXT, OrbitaColors.LINE)
                OrbitaButton.TEXT -> listOf(Color.TRANSPARENT, OrbitaColors.PRESSED, OrbitaColors.MINT, null)
                OrbitaButton.DANGER -> listOf(OrbitaColors.DANGER_BG, OrbitaColors.DANGER_PRESSED, OrbitaColors.DANGER_TEXT, null)
                OrbitaButton.DANGER_QUIET -> listOf(Color.TRANSPARENT, OrbitaColors.ERROR_BG, OrbitaColors.DANGER_TEXT, null)
            }
            background = states(rounded(fill!!, 14, stroke), rounded(pressed!!, 14, stroke), rounded(fill, 14, OrbitaColors.MINT, 2))
            setTextColor(colors(ink!!))
            val textButton = kind == OrbitaButton.TEXT
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (textButton) 14f else 16f)
            minWidth = dp(48); minimumWidth = dp(48)
            minHeight = dp(if (textButton) 48 else 54); minimumHeight = minHeight
            gravity = if (textButton) Gravity.START or Gravity.CENTER_VERTICAL else Gravity.CENTER
            setPadding(dp(if (textButton) 4 else 16), dp(10), dp(if (textButton) 4 else 16), dp(10))
            if (description != null) contentDescription = description
            layoutParams = if (textButton) params(LinearLayout.LayoutParams.WRAP_CONTENT, top = 2) else params(top = 14)
            setOnClickListener { onClick() }
        }

    /** Orbita "notice": panel, 1dp line border, 18dp radius and padding. */
    fun card(): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(OrbitaColors.PANEL, 18, OrbitaColors.LINE)
        setPadding(dp(18), dp(14), dp(18), dp(18))
        layoutParams = params(top = 14, bottom = 4)
    }

    private fun divided(fill: Int): Drawable = LayerDrawable(arrayOf(ColorDrawable(OrbitaColors.LINE), ColorDrawable(fill))).apply {
        setLayerInset(1, 0, 0, 0, max(1, dp(1)))
    }

    /** Meeting row: time column, title/project/status, chevron; 1dp line below; announced as one button. */
    fun row(date: String, time: String, title: String, project: String, status: String?, description: String,
            onClick: () -> Unit): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        background = states(divided(OrbitaColors.BG), divided(OrbitaColors.PRESSED), divided(OrbitaColors.PRESSED))
        setPadding(0, dp(18), 0, dp(18))
        minimumHeight = dp(48)
        isClickable = true; isFocusable = true
        contentDescription = description
        accessibilityDelegate = object : View.AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info); info.className = Button::class.java.name
            }
        }
        val clock = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            addView(text(time, 12f, OrbitaColors.TEXT, mono, 19f))
            addView(text(date, 12f, OrbitaColors.MUTED, mono, 19f))
            layoutParams = LinearLayout.LayoutParams(dp(56), LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(10) }
        }
        val main = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            addView(text(title, 16f, face = medium, lineSp = 22f))
            addView(text(project, 12f, OrbitaColors.MUTED, lineSp = 18f).apply { layoutParams = params(top = 4) })
            if (status != null) addView(text(status, 11f, OrbitaColors.MINT, lineSp = 17f).apply { layoutParams = params(top = 3) })
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val chevron = text("›", 22f, OrbitaColors.MUTED, lineSp = 26f).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            gravity = Gravity.END
            layoutParams = LinearLayout.LayoutParams(dp(28), LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        addView(clock); addView(main); addView(chevron)
        layoutParams = params()
        setOnClickListener { onClick() }
    }

    /** Input: panel, 1dp line border (mint when focused), 12dp radius, 52dp minimum height. */
    fun input(hintText: String, value: String = ""): EditText = EditText(context).apply {
        id = View.generateViewId()
        hint = hintText; setSingleLine(); setText(value)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f); typeface = regular
        setTextColor(OrbitaColors.TEXT); setHintTextColor(OrbitaColors.MUTED)
        highlightColor = 0x5574E5C5
        textCursorDrawable = GradientDrawable().apply { setColor(OrbitaColors.MINT); setSize(dp(2), 0) }
        background = StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), rounded(OrbitaColors.PANEL, 12, OrbitaColors.MINT, 2))
            addState(intArrayOf(), rounded(OrbitaColors.PANEL, 12, OrbitaColors.LINE))
        }
        setPadding(dp(13), dp(13), dp(13), dp(13))
        minHeight = dp(52); minimumHeight = minHeight
        layoutParams = params(top = 8)
    }

    /** Labelled field ("Proyecto" above its input), as in Orbita's `.field`. */
    fun field(label: String, input: View): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(text(label, 13f, OrbitaColors.MUTED, lineSp = 19f).apply { labelFor = input.id })
        addView(input)
        layoutParams = params(top = 16)
    }

    /** Dialog body holding fields, padded like Orbita's dialog. */
    fun fields(vararg views: View): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(24), 0, dp(24), dp(8))
        views.forEach(::addView)
    }

    fun dialogTitle(value: CharSequence?): TextView = text(value ?: "", 22f, face = medium, lineSp = 28f).apply {
        isAccessibilityHeading = true
        setPadding(dp(24), dp(24), dp(24), dp(10))
    }

    /** The mint chest lens of Orbita's top bar: a lit dot with a soft green glow. Decorative. */
    fun chestLens(): View = View(context).apply {
        val glow = GradientDrawable().apply {
            shape = GradientDrawable.OVAL; gradientType = GradientDrawable.RADIAL_GRADIENT
            colors = intArrayOf(0xB077FFB7.toInt(), 0x7535E77B, 0x0035E77B); gradientRadius = dp(18).toFloat()
        }
        val lens = GradientDrawable().apply {
            shape = GradientDrawable.OVAL; gradientType = GradientDrawable.RADIAL_GRADIENT
            colors = intArrayOf(0xFFEAFFF6.toInt(), OrbitaColors.MINT, 0xFF1F7A62.toInt()); gradientRadius = dp(8).toFloat()
            setStroke(max(1, dp(1)), 0xFF0A1416.toInt())
        }
        background = LayerDrawable(arrayOf(glow, lens)).apply { val inset = dp(10); setLayerInset(1, inset, inset, inset, inset) }
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        layoutParams = LinearLayout.LayoutParams(dp(36), dp(36)).apply { marginEnd = dp(6) }
    }

    /** Orbita dialog surface: #101b1d, 24dp radius, line border; mint (or danger) positive button. */
    fun styleDialog(dialog: AlertDialog, danger: Boolean = false) {
        dialog.window?.setBackgroundDrawable(InsetDrawable(rounded(OrbitaColors.PANEL, 24, OrbitaColors.LINE), dp(16)))
        dialog.findViewById<TextView>(android.R.id.message)?.apply {
            setTextColor(OrbitaColors.MUTED); setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f); lineHeight = sp(21f)
        }
        for ((which, ink) in listOf(AlertDialog.BUTTON_POSITIVE to if (danger) OrbitaColors.DANGER_TEXT else OrbitaColors.MINT,
            AlertDialog.BUTTON_NEGATIVE to OrbitaColors.TEXT, AlertDialog.BUTTON_NEUTRAL to OrbitaColors.TEXT)) {
            dialog.getButton(which)?.apply {
                isAllCaps = false; typeface = medium; setTextColor(colors(ink))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f); minHeight = dp(48); minimumHeight = dp(48)
                ellipsize = TextUtils.TruncateAt.END
            }
        }
    }
}

/** An AlertDialog builder whose dialogs carry Orbita's surface, title and buttons. */
internal class OrbitaDialogBuilder(context: Context, private val kit: OrbitaKit, private val danger: Boolean = false) :
    AlertDialog.Builder(context, android.R.style.Theme_Material_Dialog_Alert) {
    override fun setTitle(title: CharSequence?): AlertDialog.Builder = setCustomTitle(kit.dialogTitle(title))
    override fun create(): AlertDialog = super.create().also { dialog ->
        dialog.window?.setBackgroundDrawable(InsetDrawable(kit.rounded(OrbitaColors.PANEL, 24, OrbitaColors.LINE), kit.dp(16)))
        dialog.setOnShowListener { kit.styleDialog(dialog, danger) }
    }
}

/** Dark, edge-to-edge window with light system-bar icons; the content applies the insets. */
@Suppress("DEPRECATION")
internal fun Activity.applyOrbitaWindow() {
    window.setDecorFitsSystemWindows(false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = Color.TRANSPARENT
    window.isStatusBarContrastEnforced = false
    window.isNavigationBarContrastEnforced = false
    window.setBackgroundDrawable(ColorDrawable(OrbitaColors.BG))
    window.insetsController?.setSystemBarsAppearance(0,
        WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
}
