import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Position;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Weather;

//! A simple analog watchface: quarter-hour ticks, hour/minute/second hands, a
//! center hub, four cardinal data fields and four diagonal radial fields.
//!   up = body/movement (complication)   down = body/movement (complication)
//!   left = weather + temperature   right = time + date
//!   NE = energy (compl)  SE = height (compl)  SW = timezone  NW = time/pos (compl)
//!
//! In always-on (low-power) mode the OS dims the panel and pixel-shifts for
//! burn-in, so we keep full colours. We only drop the elements that add lit
//! pixels with no benefit at a glance: the filled heart and the second hand.
class AnalogView extends WatchUi.WatchFace {

    private const DAYLIGHT_COLOR = 0xFFAA00; // default amber accent
    // Accent colour: drives the hands, the day/night daylight arc, and the
    // current-time pointer. Defaults to amber; user-selectable via the native
    // watch-face editor (fenix 8+, API 5.1.0); falls back to amber elsewhere.
    private var _accentColor as Number = DAYLIGHT_COLOR;
    private var _configTried as Boolean = false;

    // SW radial timezone, selected by repurposing the watch-face-config "style"
    // selector. _tzStyle indexes these tables (id N in watchface-config.xml ->
    // index N here). Fixed UTC offsets in hours -- NO DST (CIQ has no tz database).
    private var _tzStyle as Number = 0;
    private const TZ_OFFSET = [0.0, 0.0, 1.0, 3.5, 4.0, 5.5, 9.0, 10.0, -5.0, -8.0];
    private const TZ_LABEL = ["UTC", "LON", "STO", "TEH", "DXB", "IND", "TYO", "SYD", "NYC", "LAX"];

    // Configurable complication slots. The watch-face-config schema requires
    // integer <complication id>s, so these name the slot indices (id N in
    // watchface-config.xml == SLOT_* here). _compVal caches each raw value string
    // (refreshed by the change callback); "" -> built-in fallback.
    private const SLOT_SE = 0; // height
    private const SLOT_NE = 1; // energy
    private const SLOT_N = 2;  // body/movement (up)
    private const SLOT_S = 3;  // body/movement (down)
    private const SLOT_NW = 4; // time/position
    private const SLOT_COUNT = 5;
    private var _compId as Lang.Array = new [SLOT_COUNT];
    private var _compVal as Lang.Array = ["", "", "", "", ""];
    private var _compCbRegistered as Boolean = false;
    // Last-frame geometry, cached so the editor's tap hit-test can locate fields.
    private var _cx as Number = 0;
    private var _cy as Number = 0;
    private var _radius as Number = 0;

    // Data colour for the cardinal (N/E/S/W) field readouts and weather glyphs.
    // Defaults to light gray; user-selectable via the editor's data-colour picker.
    private var _dataColor as Number = 0xAAAAAA; // = light gray (COLOR_LT_GRAY)
    private const RING_R_FRAC = 0.25;      // day/night ring radius (and hand inner clip) as a fraction of dial radius
    private const MOON_TILT_OFFSET = 0.0; // 0 deg (was -90): align baked moon orientation with the sky

    private var _isSleeping as Boolean = false;
    private var _vectorFont as Graphics.VectorFont or Null = null;
    private var _labelFont as Graphics.VectorFont or Null = null; // tiny N/S field labels
    private var _vectorFontTried as Boolean = false;
    private var _moon as WatchUi.BitmapResource or Null = null;
    private var _moonBuf as Graphics.BufferedBitmapReference or Null = null;
    private var _moonBucket as Number = -1;   // hour bucket the buffer was baked for

    // Precomputed constant geometry (built once, reused every frame).
    private var _heartHx as Lang.Array or Null = null; // parametric heart curve x
    private var _heartHy as Lang.Array or Null = null; // ...and y (recentre baked in)
    private var _tickSin as Lang.Array or Null = null;  // 24-hour ring tick sin/cos
    private var _tickCos as Lang.Array or Null = null;
    private var _gradArcs as Lang.Array or Null = null; // cached gradient-arc colour steps
    private var _gradCx as Number = 0;                  // centre/radius the steps were built for
    private var _gradCy as Number = 0;
    private var _gradR as Number = 0;
    // Cached radial labels: rendered once into a graphics-pool buffer (NOT the
    // 128 KB heap) and re-rendered only when the field text changes, so the
    // expensive per-glyph drawRadialText runs ~once/min instead of every frame.
    private var _radBuf as Graphics.BufferedBitmapReference or Null = null;
    private var _radKey as String or Null = null;

    function initialize() {
        WatchFace.initialize();
    }

    //! Redraw the whole face. Called once per second when awake and once per
    //! minute in low-power (sleep) mode.
    function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var cx = width / 2;
        var cy = height / 2;
        var radius = (width < height ? width : height) / 2;
        _cx = cx;
        _cy = cy;
        _radius = radius;

        // Clear background.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        ensureVectorFont(dc);
        ensureConfig();
        // Moon first: its bitmap's black corners would otherwise clip the
        // day/night arc, so the arc is drawn on top.
        if (!_isSleeping) {
            drawMoon(dc, cx, cy, (radius * 0.18).toNumber(), moonPhase());
        }
        drawDayNightArc(dc, cx, cy, radius);
        drawDataFields(dc, cx, cy, radius);
        drawRadialFields(dc, cx, cy, radius);

        var clock = System.getClockTime();
        var hour = clock.hour % 12;
        var minute = clock.min;
        var second = clock.sec;

        var twoPi = Math.PI * 2.0;
        // Include the finer units so both hands creep smoothly rather than snap.
        var hourAngle = (hour + minute / 60.0 + second / 3600.0) / 12.0 * twoPi;
        var minuteAngle = (minute + second / 60.0) / 60.0 * twoPi;

        // Hands are clipped a fixed gap outside the day/night ring, so they
        // track the ring radius (no inner part/tail).
        var innerR = radius * (RING_R_FRAC + 0.06);

        // Hour hand: tapered amber baton ending in an open ring (skeleton) tip.
        drawHourHand(dc, cx, cy, hourAngle, innerR, radius * 0.50, 9, _accentColor);

        // Minute hand: tapered amber lance converging to a sharp point.
        drawMinuteHand(dc, cx, cy, minuteAngle, innerR, radius * 0.80, 7, _accentColor);

        // Second hand: white with an accent-coloured tip (skipped in low power).
        if (!_isSleeping) {
            drawSecondHand(dc, cx, cy, second / 60.0 * twoPi, innerR, radius * 0.96);
        }

        // Thin black cut where the hour/minute hands cross the outer ring.
        if (!_isSleeping) {
            var rc = radius * 0.38;
            drawHandCut(dc, cx, cy, hourAngle, rc, 6.0);
            drawHandCut(dc, cx, cy, minuteAngle, rc, 5.0);
            // drawHandCut(dc, cx, cy, second / 60.0 * twoPi, rc, 5.0);
        }
    }

    //! Draw a thin black mark across a hand at radius rc (cuts the hand at the
    //! outer ring). halfWidth spans the hand's full width.
    private function drawHandCut(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, rc as Float, halfWidth as Float) as Void {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        var dx = sin;
        var dy = -cos;
        var px = cos;
        var py = sin;
        var mx = cx + rc * dx;
        var my = cy + rc * dy;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawLine(mx - halfWidth * px, my - halfWidth * py, mx + halfWidth * px, my + halfWidth * py);
    }

    //! Fraction through the synodic month: 0 = new, 0.5 = full, ~1 = new again.
    private function moonPhase() as Float {
        var newMoon = 947182440;  // 2000-01-06 18:14 UTC, seconds since epoch
        var synodic = 2551443;    // 29.53059 days in seconds
        var into = (Time.now().value() - newMoon) % synodic;
        if (into < 0) {
            into += synodic;
        }
        return into.toFloat() / synodic.toFloat();
    }

    //! Draw the moon. The phase shading AND the sky-inclination rotation are
    //! baked into a buffer once per hour; every frame is just a plain blit (no
    //! per-frame ephemeris or rotation -- keeps the 1 Hz redraw cheap).
    private function drawMoon(dc as Graphics.Dc, cx as Number, cy as Number, r as Number, phase as Float) as Void {
        var bucket = (Time.now().value() / 3600).toNumber(); // re-bake hourly
        var buf = (_moonBuf != null) ? _moonBuf.get() : null;
        if (buf == null || bucket != _moonBucket) {
            _moonBucket = bucket;
            buf = bakeMoon(r, phase);
        }
        if (buf == null) {
            return;
        }
        dc.drawBitmap(cx - r, cy - r, buf); // rotation already baked in
    }

    //! Render the upright phase-shaded moon into a scratch buffer, then bake the
    //! sky-inclination rotation into the persistent display buffer. Runs hourly.
    private function bakeMoon(r as Number, phase as Float) as Graphics.BufferedBitmap or Null {
        if (_moon == null) {
            _moon = WatchUi.loadResource(Rez.Drawables.Moon) as WatchUi.BitmapResource;
        }
        var d = 2 * r;

        // 1. Upright phase-shaded moon in a scratch alpha buffer (alpha is needed
        //    for the soft-terminator overlay; this buffer is freed after baking).
        var tmpRef = Graphics.createBufferedBitmap({
            :width => d,
            :height => d,
            :alphaBlending => Graphics.ALPHA_BLENDING_FULL
        });
        var tmp = (tmpRef != null) ? tmpRef.get() : null;
        if (tmp == null) {
            return null;
        }
        var tdc = tmp.getDc();
        tdc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        tdc.clear();
        tdc.drawScaledBitmap(0, 0, d, d, _moon);

        var waxing = phase < 0.5;
        var cosp = Math.cos(2.0 * Math.PI * phase);
        var shadowSign = waxing ? -1.0 : 1.0;
        var maxA = 175;
        var band = r * 0.16;
        var steps = 6;
        var rampColors = new [steps];
        for (var j = 0; j < steps; j++) {
            rampColors[j] = Graphics.createColor((maxA * (j + 0.5) / steps).toNumber(), 0, 0, 0);
        }
        var deepColor = Graphics.createColor(maxA, 0, 0, 0);
        tdc.setPenWidth(1);
        for (var y = -r; y <= r; y++) {
            var hw = Math.sqrt((r * r - y * y).toFloat());
            if (hw < 1.0) {
                continue;
            }
            var termX = (waxing ? 1.0 : -1.0) * hw * cosp;
            var uRim = hw * (1.0 + cosp);
            if (uRim <= 0.0) {
                continue;
            }
            for (var j = 0; j < steps; j++) {
                var u0 = -band + 2.0 * band * j / steps;
                var u1 = -band + 2.0 * band * (j + 1) / steps;
                if (u1 > uRim) {
                    u1 = uRim;
                }
                if (u1 > u0) {
                    moonShadowLine(tdc, r, r + y, termX, shadowSign, u0, u1, hw, rampColors[j]);
                }
            }
            if (uRim > band) {
                moonShadowLine(tdc, r, r + y, termX, shadowSign, band, uRim, hw, deepColor);
            }
        }

        // 2. Bake the rotation into the persistent display buffer (opaque) so
        //    each frame only needs a plain drawBitmap.
        var disp = (_moonBuf != null) ? _moonBuf.get() : null;
        if (disp == null) {
            _moonBuf = Graphics.createBufferedBitmap({ :width => d, :height => d });
            disp = (_moonBuf != null) ? _moonBuf.get() : null;
        }
        if (disp == null) {
            return null;
        }
        var ddc = disp.getDc();
        ddc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        ddc.clear();
        var tilt = moonTilt() + MOON_TILT_OFFSET;
        var xform = new Graphics.AffineTransform();
        xform.translate(r.toFloat(), r.toFloat());
        xform.rotate(tilt);
        xform.translate(-r.toFloat(), -r.toFloat());
        ddc.drawBitmap2(0, 0, tmp, {
            :transform => xform,
            :filterMode => Graphics.FILTER_MODE_POINT
        });
        return disp;
    }

    //! Sky inclination of the moon (radians): bright-limb position angle minus
    //! the parallactic angle, so the terminator tilts as seen from the wearer's
    //! location. Reasonable (~few-degree) precision. 0 when no location.
    private function moonTilt() as Float {
        // Observer location for the parallactic angle: prefer the GPS fix (the
        // sim's position control and the device's real position), fall back to
        // the weather observation point.
        var loc = null;
        if (Toybox has :Position) {
            var pinfo = Position.getInfo();
            if (pinfo != null && pinfo.position != null) {
                loc = pinfo.position;
            }
        }
        if (loc == null) {
            loc = sunLocation();
        }
        if (loc == null) {
            return 0.0;
        }
        var ll = loc.toRadians(); // [lat, lon] radians
        var latR = ll[0];
        var rad = Math.PI / 180.0;
        var jd = Time.now().value() / 86400.0 + 2440587.5;
        var dd = jd - 2451545.0;
        var lonDeg = ll[1] / rad;
        var ecl = (23.4393 - 3.563e-7 * dd) * rad;

        // Sun (Schlyter low precision).
        var ws = 282.9404 + 4.70935e-5 * dd;
        var ms = 356.0470 + 0.9856002585 * dd;
        var es = 0.016709 - 1.151e-9 * dd;
        var msR = ms * rad;
        var eS = msR + es * Math.sin(msR) * (1.0 + es * Math.cos(msR));
        var xv = Math.cos(eS) - es;
        var yv = Math.sqrt(1.0 - es * es) * Math.sin(eS);
        var lonsun = Math.atan2(yv, xv) + ws * rad;
        var rs = Math.sqrt(xv * xv + yv * yv);
        var xs = rs * Math.cos(lonsun);
        var ys = rs * Math.sin(lonsun);
        var raSun = Math.atan2(ys * Math.cos(ecl), xs);
        var decSun = Math.atan2(ys * Math.sin(ecl), Math.sqrt(xs * xs + (ys * Math.cos(ecl)) * (ys * Math.cos(ecl))));
        var lsun = ms + ws;

        // Moon (Schlyter, main perturbations).
        var nm = 125.1228 - 0.0529538083 * dd;
        var wm = 318.0634 + 0.1643573223 * dd;
        var mm = 115.3654 + 13.0649929509 * dd;
        var em = 0.054900;
        var am = 60.2666;
        var mmR = mm * rad;
        var eM = mmR + em * Math.sin(mmR) * (1.0 + em * Math.cos(mmR));
        eM = eM - (eM - em * Math.sin(eM) - mmR) / (1.0 - em * Math.cos(eM));
        var xm = am * (Math.cos(eM) - em);
        var ym = am * Math.sqrt(1.0 - em * em) * Math.sin(eM);
        var rm = Math.sqrt(xm * xm + ym * ym);
        var vw = Math.atan2(ym, xm) + wm * rad;
        var nmR = nm * rad;
        var imR = 5.1454 * rad;
        var xe1 = rm * (Math.cos(nmR) * Math.cos(vw) - Math.sin(nmR) * Math.sin(vw) * Math.cos(imR));
        var ye1 = rm * (Math.sin(nmR) * Math.cos(vw) + Math.cos(nmR) * Math.sin(vw) * Math.cos(imR));
        var ze1 = rm * Math.sin(vw) * Math.sin(imR);
        var lonM = Math.atan2(ye1, xe1);
        var latM = Math.atan2(ze1, Math.sqrt(xe1 * xe1 + ye1 * ye1));
        var lm = nm + wm + mm;
        var dEl = (lm - lsun) * rad;
        var fAr = (lm - nm) * rad;
        lonM = lonM
            - 1.274 * rad * Math.sin(mmR - 2.0 * dEl)
            + 0.658 * rad * Math.sin(2.0 * dEl)
            - 0.186 * rad * Math.sin(msR)
            - 0.059 * rad * Math.sin(2.0 * mmR - 2.0 * dEl)
            + 0.053 * rad * Math.sin(mmR + 2.0 * dEl);
        latM = latM - 0.173 * rad * Math.sin(fAr - 2.0 * dEl);
        var clat = Math.cos(latM);
        var xg = clat * Math.cos(lonM);
        var yg = clat * Math.sin(lonM);
        var zg = Math.sin(latM);
        var yeq = yg * Math.cos(ecl) - zg * Math.sin(ecl);
        var zeq = yg * Math.sin(ecl) + zg * Math.cos(ecl);
        var raMoon = Math.atan2(yeq, xg);
        var decMoon = Math.atan2(zeq, Math.sqrt(xg * xg + yeq * yeq));

        // Bright-limb position angle (from celestial north).
        var dA = raSun - raMoon;
        var chi = Math.atan2(Math.cos(decSun) * Math.sin(dA),
            Math.sin(decSun) * Math.cos(decMoon) - Math.cos(decSun) * Math.sin(decMoon) * Math.cos(dA));

        // Parallactic angle (rotate to the local vertical).
        var gmst = 280.46061837 + 360.98564736629 * dd;
        var ha = (gmst + lonDeg) * rad - raMoon;
        var q = Math.atan2(Math.sin(ha),
            Math.tan(latR) * Math.cos(decMoon) - Math.sin(decMoon) * Math.cos(ha));

        return chi - q;
    }

    //! Draw one horizontal shadow segment ([u0,u1] mapped to x, clamped to the
    //! disc +/-1px) with the given (alpha) stroke colour.
    private function moonShadowLine(dc as Graphics.Dc, cx as Number, ry as Number,
            termX as Float, shadowSign as Float, u0 as Float, u1 as Float, hw as Float, color as Number) as Void {
        var xa = termX + shadowSign * u0;
        var xb = termX + shadowSign * u1;
        var lo = (xa < xb) ? xa : xb;
        var hi = (xa < xb) ? xb : xa;
        if (lo < -hw - 1.0) {
            lo = -hw - 1.0;
        }
        if (hi > hw + 1.0) {
            hi = hw + 1.0;
        }
        if (hi <= lo) {
            return;
        }
        dc.setStroke(color);
        dc.drawLine(cx + lo, ry, cx + hi, ry);
    }

    //! Draw the quarter-hour markers only (12, 3, 6, 9).
    private function drawTicks(dc as Graphics.Dc, cx as Number, cy as Number, radius as Number) as Void {
        dc.setColor(_accentColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        var outer = radius - 2;
        var inner = radius - 16;
        for (var i = 0; i < 12; i += 3) {
            var angle = i / 12.0 * Math.PI * 2.0;
            var sin = Math.sin(angle);
            var cos = Math.cos(angle);
            dc.drawLine(
                cx + outer * sin, cy - outer * cos,
                cx + inner * sin, cy - inner * cos);
        }
    }

    //! Lazily create a scalable vector font for radial text (needed by
    //! drawRadialText). Returns null on devices without a matching face.
    private function ensureVectorFont(dc as Graphics.Dc) as Void {
        if (_vectorFontTried) {
            return;
        }
        _vectorFontTried = true;
        if (Graphics has :getVectorFont) {
            // Per-device face availability varies: MARQ2/fenix/FR965/epix ship
            // RobotoCondensed*; venu3 only has Roboto-Regular. List several so a
            // match is found on each target (null → radial fields are skipped).
            var faces = ["RobotoCondensedBold", "RobotoCondensedRegular", "RobotoCondensed",
                "Swiss721Bold", "Swiss721Regular", "RobotoRegular"];
            _vectorFont = Graphics.getVectorFont({
                :face => faces,
                :size => (dc.getFontHeight(Graphics.FONT_XTINY) * 1.15).toNumber()
            });
            // Much smaller scalable font for the N/S type labels.
            _labelFont = Graphics.getVectorFont({
                :face => faces,
                :size => (dc.getFontHeight(Graphics.FONT_XTINY) * 0.6).toNumber()
            });
        }
    }

    //! Read accent colour and timezone style from the native watch-face editor
    //! (devices with the watch-face configuration API, API 5.1.0). getSettings is
    //! null on devices without the editor (e.g. MARQ 2) -> keep the defaults.
    private function ensureConfig() as Void {
        if (_configTried) {
            return;
        }
        _configTried = true;
        // Defaults preserve the old fields: SE floors, NE intensity, N HR, S steps.
        if (Toybox has :Complications) {
            _compId[SLOT_SE] = new Complications.Id(Complications.COMPLICATION_TYPE_FLOORS_CLIMBED);
            _compId[SLOT_NE] = new Complications.Id(Complications.COMPLICATION_TYPE_INTENSITY_MINUTES);
            _compId[SLOT_N] = new Complications.Id(Complications.COMPLICATION_TYPE_HEART_RATE);
            _compId[SLOT_S] = new Complications.Id(Complications.COMPLICATION_TYPE_STEPS);
            _compId[SLOT_NW] = new Complications.Id(Complications.COMPLICATION_TYPE_SUNSET);
        }
        if (Application has :WatchFaceConfig) {
            var settings = Application.WatchFaceConfig.getSettings(null);
            if (settings != null) {
                var ac = settings.accentColor;
                if (ac != null && ac.color != null) {
                    _accentColor = ac.color as Number;
                }
                if (settings.styleId != null) {
                    _tzStyle = settings.styleId as Number;
                }
                var dcol = settings.complicationColor;
                if (dcol != null && dcol.color != null) {
                    _dataColor = dcol.color as Number;
                }
                var cs = settings.complicationSettings;
                if (cs != null) {
                    for (var i = 0; i < cs.size(); i++) {
                        var cid = cs[i].complicationId;
                        var uid = cs[i].uniqueIdentifier;
                        if (cid != null && uid != null && uid >= 0 && uid < SLOT_COUNT) {
                            _compId[uid] = cid;
                        }
                    }
                }
            }
        }
        subscribeComps();
    }

    //! Subscribe to all configured complications and seed their values. The
    //! change callback keeps them fresh; the registration is done once.
    private function subscribeComps() as Void {
        if (!(Toybox has :Complications)) {
            return;
        }
        if (!_compCbRegistered) {
            Complications.registerComplicationChangeCallback(method(:onComplicationChange));
            _compCbRegistered = true;
        }
        for (var i = 0; i < SLOT_COUNT; i++) {
            if (_compId[i] != null) {
                Complications.subscribeToUpdates(_compId[i]);
                _compVal[i] = compValue(_compId[i]);
            }
        }
    }

    //! A complication's current value as a bare string ("" if unavailable).
    private function compValue(id as Complications.Id or Null) as String {
        if (!(Toybox has :Complications) || id == null) {
            return "";
        }
        try {
            var c = Complications.getComplication(id);
            if (c != null && c.value != null) {
                var v = c.value;
                var vs = (v instanceof Lang.Float || v instanceof Lang.Double) ? v.format("%d") : v.toString();
                var t = id.getType();
                var pct = t == Complications.COMPLICATION_TYPE_BATTERY
                    || t == Complications.COMPLICATION_TYPE_BODY_BATTERY
                    || t == Complications.COMPLICATION_TYPE_PULSE_OX;
                if (pct && vs.find("%") == null) {
                    vs += "%";
                }
                return vs;
            }
        } catch (ex) {
        }
        return "";
    }

    //! Display value for a slot: the complication value, or a built-in fallback
    //! for the well-known types (HR/steps/intensity/floors), else "--".
    private function slotValue(slot as Number) as String {
        var v = _compVal[slot] as String;
        if (v.length() > 0) {
            return v;
        }
        var id = _compId[slot];
        var t = (id != null) ? id.getType() : null;
        if (t == Complications.COMPLICATION_TYPE_HEART_RATE) { return heartRateText(); }
        if (t == Complications.COMPLICATION_TYPE_STEPS) { return stepsText(); }
        if (t == Complications.COMPLICATION_TYPE_INTENSITY_MINUTES) { return intensityMinutesText(); }
        if (t == Complications.COMPLICATION_TYPE_FLOORS_CLIMBED) { return floorsText(); }
        return "--";
    }

    //! Short field label for a configurable complication type.
    private function compLabel(type as Complications.Type) as String {
        if (type == Complications.COMPLICATION_TYPE_HEART_RATE) { return "HR"; }
        if (type == Complications.COMPLICATION_TYPE_STEPS) { return "STP"; }
        if (type == Complications.COMPLICATION_TYPE_CALORIES) { return "CAL"; }
        if (type == Complications.COMPLICATION_TYPE_BODY_BATTERY) { return "BB"; }
        if (type == Complications.COMPLICATION_TYPE_STRESS) { return "STR"; }
        if (type == Complications.COMPLICATION_TYPE_PULSE_OX) { return "OX"; }
        if (type == Complications.COMPLICATION_TYPE_RESPIRATION_RATE) { return "RSP"; }
        if (type == Complications.COMPLICATION_TYPE_INTENSITY_MINUTES) { return "IM"; }
        if (type == Complications.COMPLICATION_TYPE_FLOORS_CLIMBED) { return "FL"; }
        if (type == Complications.COMPLICATION_TYPE_WEEKLY_RUN_DISTANCE) { return "RUN"; }
        if (type == Complications.COMPLICATION_TYPE_WEEKLY_BIKE_DISTANCE) { return "BIK"; }
        if (type == Complications.COMPLICATION_TYPE_ALTITUDE) { return "ALT"; }
        if (type == Complications.COMPLICATION_TYPE_SEA_LEVEL_PRESSURE) { return "BAR"; }
        if (type == Complications.COMPLICATION_TYPE_SUNRISE) { return "R"; }
        if (type == Complications.COMPLICATION_TYPE_SUNSET) { return "S"; }
        if (type == Complications.COMPLICATION_TYPE_DATE) { return ""; }
        if (type == Complications.COMPLICATION_TYPE_WEEKDAY_MONTHDAY) { return ""; }
        if (type == Complications.COMPLICATION_TYPE_CALENDAR_EVENTS) { return "EVT"; }
        if (type == Complications.COMPLICATION_TYPE_BATTERY) { return "BAT"; }
        return "?";
    }

    //! Lowercase label for the small N/S field adornment (body/movement types).
    private function cardinalLabel(type as Complications.Type) as String {
        if (type == Complications.COMPLICATION_TYPE_STEPS) { return "steps"; }
        if (type == Complications.COMPLICATION_TYPE_CALORIES) { return "cal"; }
        if (type == Complications.COMPLICATION_TYPE_BODY_BATTERY) { return "body"; }
        if (type == Complications.COMPLICATION_TYPE_STRESS) { return "stress"; }
        if (type == Complications.COMPLICATION_TYPE_PULSE_OX) { return "spo2"; }
        if (type == Complications.COMPLICATION_TYPE_RESPIRATION_RATE) { return "resp"; }
        if (type == Complications.COMPLICATION_TYPE_INTENSITY_MINUTES) { return "int"; }
        if (type == Complications.COMPLICATION_TYPE_FLOORS_CLIMBED) { return "floors"; }
        if (type == Complications.COMPLICATION_TYPE_WEEKLY_RUN_DISTANCE) { return "run"; }
        if (type == Complications.COMPLICATION_TYPE_WEEKLY_BIKE_DISTANCE) { return "bike"; }
        return "";
    }

    //! Inline "LABEL value" text for a diagonal radial field (label omitted if "").
    private function compInline(slot as Number, fallback as String) as String {
        var id = _compId[slot];
        if (id == null) {
            return fallback;
        }
        var lbl = compLabel(id.getType());
        var val = slotValue(slot);
        return (lbl.length() > 0) ? (lbl + " " + val) : val;
    }

    //! NW field text. Sun types keep the nice dynamic "next event" display
    //! (sunText); other time/position types show the complication value.
    private function nwFieldText() as String {
        var id = _compId[SLOT_NW];
        if (id == null) {
            return sunText();
        }
        var t = id.getType();
        if (t == Complications.COMPLICATION_TYPE_SUNRISE || t == Complications.COMPLICATION_TYPE_SUNSET) {
            return sunText();
        }
        return compInline(SLOT_NW, sunText());
    }

    //! Complication-changed callback (system push) -> refresh + redraw.
    function onComplicationChange(id as Complications.Id) as Void {
        var hit = false;
        for (var i = 0; i < SLOT_COUNT; i++) {
            if (_compId[i] != null && id.equals(_compId[i])) {
                _compVal[i] = compValue(_compId[i]);
                hit = true;
            }
        }
        if (hit) {
            WatchUi.requestUpdate();
        }
    }

    //! Set the accent colour and redraw. Called by the watch-face delegate when
    //! the user edits the accent in the native editor (live preview).
    function setAccentColor(color as Number) as Void {
        _accentColor = color;
        WatchUi.requestUpdate();
    }

    //! Set the SW-field timezone style and redraw (live editor preview).
    function setTzStyle(style as Number) as Void {
        _tzStyle = style;
        WatchUi.requestUpdate();
    }

    //! Set the cardinal-field data colour and redraw (live editor preview).
    function setDataColor(color as Number) as Void {
        _dataColor = color;
        WatchUi.requestUpdate();
    }

    //! Hit-test an editor tap against the four complication fields; returns the
    //! slot's id (== uniqueIdentifier) for setSelectedComplication, or null.
    function getTappedComplication(x as Number, y as Number) as Number or Null {
        var r = _radius;
        if (r <= 0) {
            return null;
        }
        // [slot, centreX, centreY] for N, S, NE, SE.
        var fields = [
            [SLOT_N, _cx, _cy - r * 0.58],
            [SLOT_S, _cx, _cy + r * 0.60],
            [SLOT_NE, _cx + r * 0.58, _cy - r * 0.58],
            [SLOT_SE, _cx + r * 0.58, _cy + r * 0.58],
            [SLOT_NW, _cx - r * 0.58, _cy - r * 0.58]
        ];
        var best = null;
        var bestD = r * 0.22; // tap tolerance
        for (var i = 0; i < fields.size(); i++) {
            var f = fields[i] as Lang.Array;
            var dx = x - (f[1] as Number);
            var dy = y - (f[2] as Number);
            var d = Math.sqrt(dx * dx + dy * dy);
            if (d < bestD) {
                bestD = d;
                best = f[0] as Number;
            }
        }
        return best;
    }

    //! Set a complication slot (0 SE, 1 NE, 2 N, 3 S) from a live editor edit:
    //! re-subscribe + redraw.
    function setComplication(slot as Number, id as Complications.Id) as Void {
        if (slot >= 0 && slot < SLOT_COUNT) {
            _compId[slot] = id;
            subscribeComps();
            WatchUi.requestUpdate();
        }
    }

    //! Draw the four diagonal data fields (curved radial text), blitting a cached
    //! pool buffer that is only re-rendered when the field text changes.
    private function drawRadialFields(dc as Graphics.Dc, cx as Number, cy as Number, radius as Numeric) as Void {
        if (!(dc has :drawRadialText) || _vectorFont == null) {
            return;
        }
        // NE energy (slot 1) and SE height (slot 0) complications, inline.
        var imText = compInline(SLOT_NE, "IM " + intensityMinutesText());
        var sun = nwFieldText();
        var utc = swFieldText();
        var fl = compInline(SLOT_SE, "FL " + floorsText());
        // Sleep state is part of the key: the gradient arcs are baked in only when
        // awake, so an enter/exit-sleep transition forces a rebuild.
        var key = imText + "|" + sun + "|" + utc + "|" + fl + (_isSleeping ? "|s" : "|w");

        var buf = (_radBuf != null) ? _radBuf.get() : null;
        if (buf == null || !key.equals(_radKey)) {
            // Pool buffer was purged, a label changed, or sleep flipped -> re-render
            // (the only place the costly drawRadialText / drawArc run).
            buf = renderRadialCache(dc, cx, cy, radius, imText, sun, utc, fl);
            _radKey = key;
        }
        if (buf != null) {
            dc.drawBitmap(0, 0, buf);
        }
    }

    //! (Re)render the four radial labels -- plus the gradient arcs when awake --
    //! into the cached transparent pool buffer and return it. Allocates the
    //! buffer from the graphics pool on first use.
    private function renderRadialCache(dc as Graphics.Dc, cx as Number, cy as Number, radius as Numeric,
            imText as String, sun as String, utc as String, fl as String) as Graphics.BufferedBitmap or Null {
        var buf = (_radBuf != null) ? _radBuf.get() : null;
        if (buf == null) {
            _radBuf = Graphics.createBufferedBitmap({
                :width => dc.getWidth(),
                :height => dc.getHeight(),
                :alphaBlending => Graphics.ALPHA_BLENDING_FULL
            });
            buf = (_radBuf != null) ? _radBuf.get() : null;
        }
        if (buf == null) {
            return null;
        }
        var bdc = buf.getDc();
        bdc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_TRANSPARENT);
        bdc.clear();
        // Angle is degrees counter-clockwise from 3 o'clock. Top text uses CW
        // (renders outside the baseline), bottom uses CCW (renders inside it),
        // so push the bottom radius out to keep all four the same distance.
        var rTop = radius * 0.82;
        var rBot = rTop + dc.getFontHeight(Graphics.FONT_XTINY) * 0.75;
        var cw = Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE;
        var ccw = Graphics.RADIAL_TEXT_DIRECTION_COUNTER_CLOCKWISE;
        bdc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        bdc.drawRadialText(cx, cy, _vectorFont, imText, Graphics.TEXT_JUSTIFY_CENTER, 45, rTop, cw);  // NE
        bdc.drawRadialText(cx, cy, _vectorFont, sun, Graphics.TEXT_JUSTIFY_CENTER, 135, rTop, cw);    // NW
        bdc.drawRadialText(cx, cy, _vectorFont, utc, Graphics.TEXT_JUSTIFY_CENTER, 225, rBot, ccw);   // SW
        bdc.drawRadialText(cx, cy, _vectorFont, fl, Graphics.TEXT_JUSTIFY_CENTER, 315, rBot, ccw);    // SE

        // Thin gradient arcs ride in the same buffer (interactive only). They are
        // fully static, so this runs once and only re-bakes on a sleep transition.
        if (!_isSleeping) {
            if (_gradArcs == null) {
                buildGradientArcs(cx, cy, (radius * 0.97).toNumber());
            }
            drawGradientArcs(bdc);
        }
        return buf;
    }

    //! Build the four gradient arcs once. Each is a thin arc centred at centerDeg
    //! (+/- spanDeg) whose grey level fades black -> light gray -> black, stepped
    //! through short real sub-arcs. Only the per-step angles and colours are
    //! constant per device, so they are precomputed here; the per-frame draw is
    //! just setColor + drawArc (a true arc, so the curve stays smooth).
    private function buildGradientArcs(cx as Number, cy as Number, r as Number) as Void {
        _gradCx = cx;
        _gradCy = cy;
        _gradR = r;
        var specs = [[45, 0.8], [135, 1.0], [225, 0.6], [315, 0.6]];
        var spanDeg = 30;
        var segs = 12;
        var arcs = new [specs.size()];
        for (var n = 0; n < specs.size(); n++) {
            var centerDeg = specs[n][0];
            var intensity = specs[n][1];
            // Each step is [startDeg, endDeg, color]; sub-arcs overlap by 1 deg so
            // the joins between colour steps leave no gap.
            var steps = new [segs];
            for (var k = 0; k < segs; k++) {
                var t0 = k / (segs * 1.0);
                var t1 = (k + 1) / (segs * 1.0);
                var a0 = centerDeg - spanDeg + 2.0 * spanDeg * t0;
                var a1 = centerDeg - spanDeg + 2.0 * spanDeg * t1;
                var lvl = intensity * Math.sin(Math.PI * (t0 + t1) / 2.0); // 0 at ends, 1 at center
                var g = (lvl * 170).toNumber();                            // 0..0xAA
                steps[k] = [
                    (a0 - 1.0).toNumber(), (a1 + 1.0).toNumber(),
                    (g << 16) | (g << 8) | g
                ];
            }
            arcs[n] = steps;
        }
        _gradArcs = arcs;
    }

    //! Draw the precomputed gradient arcs as real arcs.
    private function drawGradientArcs(dc as Graphics.Dc) as Void {
        dc.setPenWidth(2);
        for (var n = 0; n < _gradArcs.size(); n++) {
            var steps = _gradArcs[n] as Lang.Array;
            for (var k = 0; k < steps.size(); k++) {
                var s = steps[k] as Lang.Array;
                dc.setColor(s[2], Graphics.COLOR_TRANSPARENT);
                dc.drawArc(_gradCx, _gradCy, _gradR, Graphics.ARC_COUNTER_CLOCKWISE, s[0], s[1]);
            }
        }
    }


    private function intensityMinutesText() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :activeMinutesWeek) && info.activeMinutesWeek != null) {
            return info.activeMinutesWeek.total.toString();
        }
        return "--";
    }

    private function floorsText() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && (info has :floorsClimbed) && info.floorsClimbed != null) {
            return info.floorsClimbed.toString();
        }
        return "--";
    }

    //! SW field: a short timezone label + the time at that zone's fixed UTC
    //! offset (selected via the watch-face-config style; UTC default; no DST).
    private function swFieldText() as String {
        var i = _tzStyle;
        if (i < 0 || i >= TZ_OFFSET.size()) {
            i = 0;
        }
        var secs = Time.now().value() + (TZ_OFFSET[i] * 3600).toNumber();
        var info = Gregorian.utcInfo(new Time.Moment(secs), Time.FORMAT_SHORT);
        return TZ_LABEL[i] + " " + Lang.format("$1$:$2$",
            [info.hour.format("%02d"), info.min.format("%02d")]);
    }

    //! Location for sun calculations: prefer the cached weather observation
    //! position, fall back to the last known GPS fix (Positioning permission).
    private function sunLocation() as Position.Location or Null {
        if (Toybox has :Weather) {
            var conditions = Weather.getCurrentConditions();
            if (conditions != null && conditions.observationLocationPosition != null) {
                return conditions.observationLocationPosition;
            }
        }
        if (Toybox has :Position) {
            var info = Position.getInfo();
            if (info != null && info.position != null) {
                return info.position;
            }
        }
        return null;
    }

    //! Show the next sun event: sunset during the day, otherwise sunrise.
    //! Prefixed with R (rise) / S (set).
    private function sunText() as String {
        if (!(Toybox has :Weather)) {
            return "--";
        }
        var location = sunLocation();
        if (location == null) {
            return "--";
        }
        var now = Time.now();
        var sunrise = Weather.getSunrise(location, now);
        var sunset = Weather.getSunset(location, now);
        if (sunrise == null || sunset == null) {
            return "--";
        }
        var nowSec = now.value();
        var moment = sunrise;
        var prefix = "R ";
        if (nowSec > sunrise.value() && nowSec < sunset.value()) {
            moment = sunset;
            prefix = "S ";
        }
        var t = Gregorian.info(moment, Time.FORMAT_SHORT);
        return prefix + Lang.format("$1$:$2$", [t.hour.format("%d"), t.min.format("%02d")]);
    }

    //! Inner 24-hour day/night ring: a dark full-circle track, an amber arc
    //! over daylight (sunrise..sunset) and a pointer at the current time.
    //! Midnight is at the top, noon at the bottom.
    private function drawDayNightArc(dc as Graphics.Dc, cx as Number, cy as Number, radius as Number) as Void {
        var r = (radius * RING_R_FRAC).toNumber();

        // Sunrise/sunset (used for the sun-ring peak, the daylight arc, the pointer).
        var now = Time.now();
        var sr = null;
        var ss = null;
        if (Toybox has :Weather) {
            var loc = sunLocation();
            if (loc != null) {
                sr = Weather.getSunrise(loc, now);
                ss = Weather.getSunset(loc, now);
            }
        }

        // Full 24h track.
        dc.setPenWidth(2);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 0, 360);

        // 24 hour ticks + the gradient outer ring -- detail dropped in always-on.
        if (!_isSleeping) {
            var tIn = radius * 0.31;
            var tOut = radius * 0.35;
            if (_tickSin == null) {
                var ts24 = new [24];
                var tc24 = new [24];
                for (var i = 0; i < 24; i++) {
                    var ta = i * Math.PI / 12.0;
                    ts24[i] = Math.sin(ta);
                    tc24[i] = Math.cos(ta);
                }
                _tickSin = ts24;
                _tickCos = tc24;
            }
            for (var i = 0; i < 24; i++) {
                var ts = _tickSin[i];
                var tc = _tickCos[i];
                if (i % 6 == 0) {
                    dc.setPenWidth(2);
                } else {
                    dc.setPenWidth(1);
                }
                dc.drawLine(cx + tIn * ts, cy - tIn * tc, cx + tOut * ts, cy - tOut * tc);
            }
            // Thin outer circle as a gradient ring, brightest at max sun = the
            // clockwise midpoint of the daylight arc (matches the amber arc centre).
            var peakDeg = hourToArcDegrees(12.0); // ~bottom when no sun data
            if (sr != null && ss != null) {
                var dsr = hourToArcDegrees(localHour(sr));
                var dss = hourToArcDegrees(localHour(ss));
                var span = dsr - dss;
                while (span < 0) {
                    span += 360;
                }
                peakDeg = dsr - span / 2;
            }
            drawSunRing(dc, cx, cy, (radius * 0.38).toNumber(), peakDeg);
        }

        // Daylight arc (skipped if no sun data is available).
        if (sr != null && ss != null) {
            // In always-on, match the night-track width to keep lit pixels low.
            dc.setPenWidth(_isSleeping ? 2 : 3);
            dc.setColor(_accentColor, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE,
                hourToArcDegrees(localHour(sr)), hourToArcDegrees(localHour(ss)));
        }

        // Current-time pointer, coloured to match the side it sits on:
        // daylight (amber) during the day, night (dark gray) otherwise.
        var pointerColor = Graphics.COLOR_DK_GRAY;
        if (sr != null && ss != null) {
            var nowSec = now.value();
            if (nowSec > sr.value() && nowSec < ss.value()) {
                pointerColor = _accentColor;
            }
        }
        var clock = System.getClockTime();
        var h = clock.hour + clock.min / 60.0;
        var a = h * Math.PI / 12.0; // radians clockwise from the top (midnight at top)
        var px = cx + r * Math.sin(a);
        var py = cy - r * Math.cos(a);
        dc.setColor(pointerColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, 5);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(px, py, 2);
    }

    //! Draw a full thin circle whose grey level peaks (light gray) at peakDeg
    //! and fades to black at the opposite side -- a soft highlight at max sun.
    private function drawSunRing(dc as Graphics.Dc, cx as Number, cy as Number, r as Number, peakDeg as Number) as Void {
        var segs = 8;
        dc.setPenWidth(1);
        for (var k = 0; k < segs; k++) {
            var a0 = k * 360.0 / segs;
            var a1 = (k + 1) * 360.0 / segs;
            var mid = (a0 + a1) / 2.0;
            var level = (1.0 + Math.cos((mid - peakDeg) * Math.PI / 180.0)) / 2.0;
            var g = (85 + level * 85).toNumber(); // dark gray (0x55) .. light gray (0xAA)
            dc.setColor((g << 16) | (g << 8) | g, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_COUNTER_CLOCKWISE, a0.toNumber(), a1.toNumber());
        }
    }

    //! Local hour-of-day (0..24, fractional) for a moment.
    private function localHour(moment as Time.Moment) as Float {
        var i = Gregorian.info(moment, Time.FORMAT_SHORT);
        return i.hour + i.min / 60.0;
    }

    //! Map hour-of-day to drawArc degrees (0=3 o'clock, CCW positive) with
    //! midnight at the top and noon at the bottom.
    private function hourToArcDegrees(h as Float) as Number {
        var d = 90.0 - 15.0 * h;
        if (d < 0.0) {
            d += 360.0;
        }
        return d.toNumber();
    }

    //! Draw the four cardinal data fields at the up/down/left/right positions.
    private function drawDataFields(dc as Graphics.Dc, cx as Number, cy as Number, radius as Number) as Void {
        var off = radius * 0.58;

        // Up (N, slot 2): body/movement complication, adornment above.
        drawCardinalComp(dc, cx, cy - off, SLOT_N, true);

        // Down (S, slot 3): body/movement complication, adornment below.
        drawCardinalComp(dc, cx, cy + off + radius * 0.02, SLOT_S, false);

        // Left: weather icon (top), a precip-chance bar, then the temperature.
        var leftX = cx - off - radius * 0.05;
        var cond = currentConditions();
        drawWeatherIcon(dc, leftX, cy - 16, 16);
        // Thin precip-chance bar between the glyph and the temperature, only when
        // it's high enough to be worth showing (interactive only).
        if (!_isSleeping && cond != null && cond.precipitationChance != null
                && cond.precipitationChance >= 20) {
            drawPrecipBar(dc, leftX, cy + 3, radius * 0.18, cond.precipitationChance);
        }
        drawValue(dc, leftX, cy + 22, temperatureText());

        // Further left: wind barb (interactive only; skip light/calm wind < 4 m/s).
        if (!_isSleeping && cond != null && cond.windSpeed != null && cond.windBearing != null
                && cond.windSpeed >= 4.0) {
            drawWindBarb(dc, leftX - radius * 0.22, cy - radius * 0.02, radius * 0.11,
                cond.windSpeed, cond.windBearing);
        }

        // Right: date above the time. The time sits at the same y as the
        // temperature on the left so the two bottom values line up.
        var rightX = cx + off + radius * 0.07;
        dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightX, cy - 16, Graphics.FONT_XTINY, dateText(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        drawValue(dc, rightX, cy + 22, timeOfDayText());
    }

    //! Draw a single value centered at (x, y).
    private function drawValue(dc as Graphics.Dc, x as Numeric, y as Numeric, value as String) as Void {
        dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Thin horizontal precip-chance bar (amber fill over a dark track) centred
    //! at (x, y), total width w. chance is 0..100.
    private function drawPrecipBar(dc as Graphics.Dc, x as Numeric, y as Numeric,
            w as Float, chance as Number) as Void {
        var x0 = x - w / 2.0;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x0, y, w, 2);
        var fw = (w * chance / 100.0).toNumber();
        if (fw > 0) {
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x0, y, fw, 2);
        }
    }

    //! Draw a cardinal (N/S) complication: the value in data colour, with a small
    //! adornment above (N) or below (S) -- the heart icon for heart rate (dropped
    //! in always-on, like before), otherwise a tiny-font type label.
    private function drawCardinalComp(dc as Graphics.Dc, x as Numeric, y as Numeric,
            slot as Number, isNorth as Boolean) as Void {
        var textH = dc.getFontHeight(Graphics.FONT_TINY);
        var id = _compId[slot];
        var t = (id != null) ? id.getType() : null;

        dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, slotValue(slot),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (t == Complications.COMPLICATION_TYPE_HEART_RATE) {
            if (!_isSleeping) {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                var iconH = dc.getFontHeight(Graphics.FONT_XTINY) * 0.65;
                drawHeart(dc, x, isNorth ? (y - textH) : (y + textH), iconH / 0.6875);
            }
        } else if (t != null) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            var ly = isNorth ? (y - textH * 0.7) : (y + textH * 0.7);
            var just = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
            if (_labelFont != null) {
                dc.drawText(x, ly, _labelFont, cardinalLabel(t), just);
            } else {
                dc.drawText(x, ly, Graphics.FONT_XTINY, cardinalLabel(t), just);
            }
        }
    }

    //! Fill a heart of the given width centered at (cx, cy) using the classic
    //! parametric heart curve as one filled polygon. Points must be integers
    //! for fillPolygon to fill (floats render as edges only).
    private function drawHeart(dc as Graphics.Dc, cx as Numeric, cy as Numeric, w as Float) as Void {
        // The curve shape is constant; only scale/position change. Build the
        // unit-curve points once (+6 recenter baked into hy), then per frame it
        // is just a scale+offset -- no per-frame trig.
        if (_heartHx == null) {
            var n = 40;
            var hxs = new [n];
            var hys = new [n];
            for (var i = 0; i < n; i++) {
                var t = i * (Math.PI * 2.0 / n);
                var st = Math.sin(t);
                hxs[i] = 16.0 * st * st * st;
                hys[i] = 13.0 * Math.cos(t) - 5.0 * Math.cos(2.0 * t)
                    - 2.0 * Math.cos(3.0 * t) - Math.cos(4.0 * t) + 6.0;
            }
            _heartHx = hxs;
            _heartHy = hys;
        }
        var scale = w / 32.0;
        var hx = _heartHx;
        var hy = _heartHy;
        var steps = hx.size();
        var pts = new [steps];
        for (var i = 0; i < steps; i++) {
            pts[i] = [(cx + scale * hx[i]).toNumber(), (cy - scale * hy[i]).toNumber()];
        }
        dc.fillPolygon(pts);
    }

    private function heartRateText() as String {
        // On-device, the live HR for a watchface comes from Activity.Info.
        var act = Activity.getActivityInfo();
        if (act != null && act.currentHeartRate != null) {
            return act.currentHeartRate.toString();
        }
        // Fallback: latest logged sample (this is what the simulator feeds via
        // Health Monitoring; Activity.Info HR is not simulated for watchfaces).
        if (ActivityMonitor has :getHeartRateHistory) {
            var sample = ActivityMonitor.getHeartRateHistory(1, true).next();
            if (sample != null && sample.heartRate != null
                    && sample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) {
                return sample.heartRate.toString();
            }
        }
        return "--";
    }

    private function stepsText() as String {
        var info = ActivityMonitor.getInfo();
        if (info != null && info.steps != null) {
            return info.steps.toString();
        }
        return "--";
    }

    private function temperatureText() as String {
        var conditions = currentConditions();
        if (conditions != null && conditions.temperature != null) {
            var celsius = conditions.temperature;
            var value = celsius;
            if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
                value = (celsius * 9 / 5) + 32;
            }
            return value.format("%d") + "°";
        }
        return "--";
    }

    private function timeOfDayText() as String {
        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        return Lang.format("$1$:$2$", [hour.format("%d"), clock.min.format("%02d")]);
    }

    private function dateText() as String {
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        return Lang.format("$1$ $2$", [info.day.format("%02d"), info.month]);
    }

    //! Look up the cached current weather conditions, guarding devices without
    //! the Weather API.
    private function currentConditions() as Weather.CurrentConditions or Null {
        if (Toybox has :Weather) {
            return Weather.getCurrentConditions();
        }
        return null;
    }

    //! Draw a small weather glyph (sun / cloud / rain / snow) centered at (x, y).
    private function drawWeatherIcon(dc as Graphics.Dc, x as Numeric, y as Numeric, r as Numeric) as Void {
        var conditions = currentConditions();
        var category = "cloud";
        if (conditions != null && conditions.condition != null) {
            category = weatherCategory(conditions.condition);
        }

        if (category.equals("clear")) {
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y, r * 0.6);
            dc.setPenWidth(2);
            for (var i = 0; i < 8; i++) {
                var a = i / 8.0 * Math.PI * 2.0;
                var s = Math.sin(a);
                var c = Math.cos(a);
                dc.drawLine(x + r * 0.8 * s, y - r * 0.8 * c, x + r * 1.15 * s, y - r * 1.15 * c);
            }
            return;
        }

        if (category.equals("fog")) {
            // Stacked horizontal lines with staggered ends (drifting fog/haze).
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            for (var i = 0; i < 4; i++) {
                var ly = y - r * 0.55 + i * r * 0.36;
                var inset = (i % 2 == 0) ? r * 0.22 : 0.0;
                dc.drawLine(x - r * 0.85 + inset, ly, x + r * 0.85 - inset, ly);
            }
            return;
        }

        // Cloud body shared by cloud / rain / snow / storm.
        dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
        var cloudY = (category.equals("cloud")) ? y : y - r * 0.4;
        dc.fillCircle(x - r * 0.55, cloudY, r * 0.45);
        dc.fillCircle(x + r * 0.5, cloudY, r * 0.42);
        dc.fillCircle(x, cloudY - r * 0.35, r * 0.5);
        dc.fillRectangle(x - r * 0.95, cloudY, r * 1.9, r * 0.5);

        if (category.equals("rain")) {
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            for (var i = -1; i <= 1; i++) {
                var dx = x + i * r * 0.5;
                dc.drawLine(dx, cloudY + r * 0.6, dx - r * 0.15, cloudY + r * 1.1);
            }
        } else if (category.equals("snow")) {
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            for (var i = -1; i <= 1; i++) {
                dc.fillCircle(x + i * r * 0.5, cloudY + r * 0.85, 2);
            }
        } else if (category.equals("storm")) {
            // Lightning bolt below the cloud.
            dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(3);
            dc.drawLine(x + r * 0.13, cloudY + r * 0.40, x - r * 0.13, cloudY + r * 0.92);
            dc.drawLine(x - r * 0.13, cloudY + r * 0.92, x + r * 0.07, cloudY + r * 0.92);
            dc.drawLine(x + r * 0.07, cloudY + r * 0.92, x - r * 0.13, cloudY + r * 1.40);
        }
    }

    //! Wind barb (meteorological): a staff pointing into the wind with feathers
    //! encoding speed in knots -- half feather = 5 kt, full = 10 kt, pennant =
    //! 50 kt. Capped at 60 kt (one pennant + one full). bearingDeg is the compass
    //! direction the wind blows FROM (0 = N, clockwise). len is the staff length.
    private function drawWindBarb(dc as Graphics.Dc, x as Numeric, y as Numeric,
            len as Float, speedMps as Float, bearingDeg as Number) as Void {
        var kt = speedMps * 1.94384;
        var units = ((kt + 2.5) / 5.0).toNumber(); // count of 5-kt units (nearest 5)
        if (units > 12) {
            units = 12;                             // cap at 60 kt
        }
        dc.setColor(_dataColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        if (units <= 0) {
            dc.drawCircle(x, y, 3);                 // calm
            return;
        }
        var rad = Math.PI / 180.0;
        var b = bearingDeg * rad;
        var dx = Math.sin(b);                       // along the staff, toward the wind source
        var dy = -Math.cos(b);
        var hx = (len / 2.0) * dx;
        var hy = (len / 2.0) * dy;
        var fx = x + hx;                            // upwind end (feathers attach here)
        var fy = y + hy;
        dc.drawLine(x - hx, y - hy, fx, fy);

        var full = len * 0.36;
        var half = len * 0.20;
        var step = len * 0.18;
        var fAng = Math.atan2(dy, dx) + 105.0 * rad; // feathers slant back to one side
        var fdx = Math.cos(fAng);
        var fdy = Math.sin(fAng);

        var pos = 0.0;                              // distance from the upwind end inward
        if (units >= 10) {                          // one pennant (50 kt)
            var px = fx - step * dx;
            var py = fy - step * dy;
            dc.fillPolygon([
                [fx.toNumber(), fy.toNumber()],
                [(fx + full * fdx).toNumber(), (fy + full * fdy).toNumber()],
                [px.toNumber(), py.toNumber()]
            ]);
            pos = step * 1.6;
            units -= 10;
        }
        for (var i = 0; i < units / 2; i++) {       // full feathers (10 kt)
            var ax = fx - pos * dx;
            var ay = fy - pos * dy;
            dc.drawLine(ax, ay, ax + full * fdx, ay + full * fdy);
            pos += step;
        }
        if (units % 2 > 0) {                         // a single half feather (5 kt)
            if (pos == 0.0) {                       // sit it in from the tip if alone
                pos = step;
            }
            var ax = fx - pos * dx;
            var ay = fy - pos * dy;
            dc.drawLine(ax, ay, ax + half * fdx, ay + half * fdy);
        }
    }

    //! Bucket a Weather condition code into clear / rain / snow / storm / fog /
    //! cloud. The "chance of" codes deliberately fall through to cloud -- the
    //! precip bar carries the probability, so the glyph stays a plain cloud
    //! rather than over-stating it as steady rain/snow.
    private function weatherCategory(condition as Number) as String {
        if (condition == Weather.CONDITION_CLEAR
                || condition == Weather.CONDITION_MOSTLY_CLEAR
                || condition == Weather.CONDITION_PARTLY_CLEAR
                || condition == Weather.CONDITION_FAIR
                || condition == Weather.CONDITION_PARTLY_CLOUDY) {
            return "clear";
        }
        if (condition == Weather.CONDITION_RAIN
                || condition == Weather.CONDITION_LIGHT_RAIN
                || condition == Weather.CONDITION_HEAVY_RAIN
                || condition == Weather.CONDITION_SCATTERED_SHOWERS
                || condition == Weather.CONDITION_SHOWERS
                || condition == Weather.CONDITION_LIGHT_SHOWERS
                || condition == Weather.CONDITION_HEAVY_SHOWERS
                || condition == Weather.CONDITION_DRIZZLE
                || condition == Weather.CONDITION_FREEZING_RAIN
                || condition == Weather.CONDITION_UNKNOWN_PRECIPITATION) {
            return "rain";
        }
        if (condition == Weather.CONDITION_SNOW
                || condition == Weather.CONDITION_LIGHT_SNOW
                || condition == Weather.CONDITION_HEAVY_SNOW
                || condition == Weather.CONDITION_FLURRIES
                || condition == Weather.CONDITION_SLEET
                || condition == Weather.CONDITION_ICE
                || condition == Weather.CONDITION_ICE_SNOW
                || condition == Weather.CONDITION_WINTRY_MIX
                || condition == Weather.CONDITION_RAIN_SNOW
                || condition == Weather.CONDITION_LIGHT_RAIN_SNOW
                || condition == Weather.CONDITION_HEAVY_RAIN_SNOW) {
            return "snow";
        }
        if (condition == Weather.CONDITION_THUNDERSTORMS
                || condition == Weather.CONDITION_SCATTERED_THUNDERSTORMS
                || condition == Weather.CONDITION_CHANCE_OF_THUNDERSTORMS
                || condition == Weather.CONDITION_HAIL
                || condition == Weather.CONDITION_SQUALL
                || condition == Weather.CONDITION_TORNADO
                || condition == Weather.CONDITION_HURRICANE
                || condition == Weather.CONDITION_TROPICAL_STORM) {
            return "storm";
        }
        if (condition == Weather.CONDITION_FOG
                || condition == Weather.CONDITION_MIST
                || condition == Weather.CONDITION_HAZE
                || condition == Weather.CONDITION_HAZY
                || condition == Weather.CONDITION_SMOKE
                || condition == Weather.CONDITION_DUST
                || condition == Weather.CONDITION_SAND
                || condition == Weather.CONDITION_SANDSTORM
                || condition == Weather.CONDITION_VOLCANIC_ASH) {
            return "fog";
        }
        return "cloud";
    }

    //! Second hand: a thin white hand with the outer (tip) segment in the
    //! accent colour, a short tail, and a black outline.
    private function drawSecondHand(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, innerR as Float, length as Float) as Void {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        var split = length * 0.80; // accent tip = outer ~20% of the hand
        var x0 = cx + innerR * sin;
        var y0 = cy - innerR * cos;
        var xs = cx + split * sin;
        var ys = cy - split * cos;
        var x1 = cx + length * sin;
        var y1 = cy - length * cos;
        // Outline.
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(5);
        dc.drawLine(x0, y0, x1, y1);
        // White body, accent tip.
        dc.setPenWidth(3);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x0, y0, xs, ys);
        dc.setColor(_accentColor, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(xs, ys, x1, y1);
        // Thin black cut at the white->accent transition.
        drawHandCut(dc, cx, cy, angle, split, 3.0);
    }

    //! Hour hand: a tapered amber baton ending in an open ring ("skeleton" /
    //! pomme) tip, so the longer minute hand sweeps visibly through it. The grey
    //! under-pass (wider body, thicker ring) reads as a polished bevel.
    //! Angle is radians, clockwise from 12 o'clock.
    private function drawHourHand(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, innerR as Float, length as Float, penWidth as Number, color as Number) as Void {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        var dx = sin;                      // along the hand (outward)
        var dy = -cos;
        var px = cos;                      // perpendicular
        var py = sin;
        var hw = penWidth / 2.0;
        var ringR = hw + 2.0;
        var ringCtr = length - ringR;      // ring centre along the hand
        var bodyEnd = length - 2.0 * ringR; // body meets the ring's inner edge
        var rcx = cx + ringCtr * dx;
        var rcy = cy + ringCtr * dy;
        // Outline (grey bevel): tapered body + ring, one pixel proud.
        dc.setColor(0x808080, Graphics.COLOR_TRANSPARENT);
        handRect(dc, cx, cy, dx, dy, px, py, innerR - 1.0, bodyEnd, hw + 1.0, 3.5);
        dc.setPenWidth(5);
        dc.drawCircle(rcx, rcy, ringR);
        // Fill: body tapers from full width down to the ring's stroke weight.
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        handRect(dc, cx, cy, dx, dy, px, py, innerR, bodyEnd, hw, 2.5);
        dc.setPenWidth(3);
        dc.drawCircle(rcx, rcy, ringR);
    }

    //! Minute hand: a tapered amber lance that narrows to a sharp point, giving a
    //! silhouette distinct from the hour hand's open ring. Grey under-pass bevel.
    private function drawMinuteHand(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, innerR as Float, length as Float, penWidth as Number, color as Number) as Void {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        var dx = sin;
        var dy = -cos;
        var px = cos;
        var py = sin;
        var hw = penWidth / 2.0;
        var shoulder = length * 0.90;      // parallel body up to here, then a short blunt point
        dc.setColor(0x808080, Graphics.COLOR_TRANSPARENT);
        lancePoly(dc, cx, cy, dx, dy, px, py, innerR - 1.0, shoulder, length + 1.5, hw + 1.0);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        lancePoly(dc, cx, cy, dx, dy, px, py, innerR, shoulder, length, hw);
    }

    //! Fill a tapered quad along a hand: radius r0..r1 with half-width hw0 at the
    //! inner end and hw1 at the outer end. Integer points so fillPolygon fills.
    private function handRect(dc as Graphics.Dc, cx as Number, cy as Number,
            dx as Float, dy as Float, px as Float, py as Float,
            r0 as Float, r1 as Float, hw0 as Float, hw1 as Float) as Void {
        var ax = cx + r0 * dx;
        var ay = cy + r0 * dy;
        var bx = cx + r1 * dx;
        var by = cy + r1 * dy;
        dc.fillPolygon([
            [(ax + px * hw0).toNumber(), (ay + py * hw0).toNumber()],
            [(bx + px * hw1).toNumber(), (by + py * hw1).toNumber()],
            [(bx - px * hw1).toNumber(), (by - py * hw1).toNumber()],
            [(ax - px * hw0).toNumber(), (ay - py * hw0).toNumber()]
        ]);
    }

    //! Fill a 5-point lance: flat base (half-width hw) from r0 to the shoulder rs,
    //! then converging to a point at the tip rt. Integer points for fillPolygon.
    private function lancePoly(dc as Graphics.Dc, cx as Number, cy as Number,
            dx as Float, dy as Float, px as Float, py as Float,
            r0 as Float, rs as Float, rt as Float, hw as Float) as Void {
        var a0x = cx + r0 * dx;
        var a0y = cy + r0 * dy;
        var sx = cx + rs * dx;
        var sy = cy + rs * dy;
        var tx = cx + rt * dx;
        var ty = cy + rt * dy;
        dc.fillPolygon([
            [(a0x + px * hw).toNumber(), (a0y + py * hw).toNumber()],
            [(sx + px * hw).toNumber(), (sy + py * hw).toNumber()],
            [tx.toNumber(), ty.toNumber()],
            [(sx - px * hw).toNumber(), (sy - py * hw).toNumber()],
            [(a0x - px * hw).toNumber(), (a0y - py * hw).toNumber()]
        ]);
    }

    function onEnterSleep() as Void {
        _isSleeping = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _isSleeping = false;
        WatchUi.requestUpdate();
    }
}
