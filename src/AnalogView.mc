import Toybox.Activity;
import Toybox.ActivityMonitor;
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
//!   up = heart rate (in a heart)   down = steps
//!   left = weather + temperature   right = time + date
//!   NE = intensity min  SE = floors  SW = UTC  NW = sunrise/sunset
//!
//! In always-on (low-power) mode the OS dims the panel and pixel-shifts for
//! burn-in, so we keep full colours. We only drop the elements that add lit
//! pixels with no benefit at a glance: the filled heart and the second hand.
class AnalogView extends WatchUi.WatchFace {

    private const DAYLIGHT_COLOR = 0xFFAA00; // amber for the day/night arc
    private const ACCENT_COLOR = DAYLIGHT_COLOR; // accent matches the day arc
    private const RING_R_FRAC = 0.25;      // day/night ring radius (and hand inner clip) as a fraction of dial radius
    private const MOON_TILT_OFFSET = -1.5707963; // -90 deg: align baked moon orientation with the sky

    private var _isSleeping as Boolean = false;
    private var _vectorFont as Graphics.VectorFont or Null = null;
    private var _vectorFontTried as Boolean = false;
    private var _moon as WatchUi.BitmapResource or Null = null;
    private var _moonBuf as Graphics.BufferedBitmapReference or Null = null;
    private var _moonBucket as Number = -1;   // hour bucket the buffer was baked for

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

        // Clear background.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        ensureVectorFont(dc);
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

        // Hour hand.
        drawHand(dc, cx, cy, hourAngle, innerR, radius * 0.50, 9, ACCENT_COLOR);

        // Minute hand.
        drawHand(dc, cx, cy, minuteAngle, innerR, radius * 0.80, 7, ACCENT_COLOR);

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
        var dx = Math.sin(angle);
        var dy = -Math.cos(angle);
        var px = Math.cos(angle);
        var py = Math.sin(angle);
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
        dc.setColor(ACCENT_COLOR, Graphics.COLOR_TRANSPARENT);
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
            _vectorFont = Graphics.getVectorFont({
                :face => ["RobotoCondensedBold", "RobotoCondensedRegular", "Swiss721Regular"],
                :size => (dc.getFontHeight(Graphics.FONT_XTINY) * 1.15).toNumber()
            });
        }
    }

    //! Draw the four diagonal data fields as text curved along the dial edge.
    private function drawRadialFields(dc as Graphics.Dc, cx as Number, cy as Number, radius as Numeric) as Void {
        if (!(dc has :drawRadialText) || _vectorFont == null) {
            return;
        }
        // Angle is degrees counter-clockwise from 3 o'clock. Top text uses CW
        // (renders outside the baseline), bottom uses CCW (renders inside it),
        // so push the bottom radius out to keep all four the same distance.
        var rTop = radius * 0.82;
        var rBot = rTop + dc.getFontHeight(Graphics.FONT_XTINY) * 0.75;
        var cw = Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE;
        var ccw = Graphics.RADIAL_TEXT_DIRECTION_COUNTER_CLOCKWISE;
        drawRadial(dc, cx, cy, rTop, 45, "IM " + intensityMinutesText(), cw);   // NE
        drawRadial(dc, cx, cy, rTop, 135, sunText(), cw);                      // NW (R/S label)
        drawRadial(dc, cx, cy, rBot, 225, "UTC " + utcText(), ccw);            // SW
        drawRadial(dc, cx, cy, rBot, 315, "FL " + floorsText(), ccw);          // SE

        // Thin gradient arc (black -> light gray -> black) outside each field
        // (interactive only).
        if (!_isSleeping) {
            var rArc = (radius * 0.97).toNumber();
            drawGradientArc(dc, cx, cy, rArc, 45, 30, 0.8);
            drawGradientArc(dc, cx, cy, rArc, 135, 30, 1.0);
            drawGradientArc(dc, cx, cy, rArc, 225, 30, 0.6);
            drawGradientArc(dc, cx, cy, rArc, 315, 30, 0.6);
        }
    }

    //! Draw a thin arc centred at centerDeg (+/- spanDeg) whose grey level
    //! fades black -> light gray -> black, by stepping through short sub-arcs.
    private function drawGradientArc(dc as Graphics.Dc, cx as Number, cy as Number,
            r as Number, centerDeg as Number, spanDeg as Number, intensity as Float) as Void {
        var segs = 12;
        dc.setPenWidth(2);
        for (var k = 0; k < segs; k++) {
            var t0 = k / (segs * 1.0);
            var t1 = (k + 1) / (segs * 1.0);
            var lvl = intensity * Math.sin(Math.PI * (t0 + t1) / 2.0); // 0 at ends, 1 at center
            var g = (lvl * 170).toNumber();                // 0..0xAA
            dc.setColor((g << 16) | (g << 8) | g, Graphics.COLOR_TRANSPARENT);
            var a0 = centerDeg - spanDeg + 2.0 * spanDeg * t0;
            var a1 = centerDeg - spanDeg + 2.0 * spanDeg * t1;
            dc.drawArc(cx, cy, r, Graphics.ARC_COUNTER_CLOCKWISE, a0.toNumber(), a1.toNumber());
        }
    }

    private function drawRadial(dc as Graphics.Dc, cx as Number, cy as Number, r as Float,
            angle as Number, text as String, direction as Graphics.RadialTextDirection) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawRadialText(cx, cy, _vectorFont, text, Graphics.TEXT_JUSTIFY_CENTER, angle, r, direction);
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

    private function utcText() as String {
        var info = Gregorian.utcInfo(Time.now(), Time.FORMAT_SHORT);
        return Lang.format("$1$:$2$", [info.hour.format("%02d"), info.min.format("%02d")]);
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
            for (var i = 0; i < 24; i++) {
                var ta = i * Math.PI / 12.0;
                var ts = Math.sin(ta);
                var tc = Math.cos(ta);
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
            dc.setColor(DAYLIGHT_COLOR, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE,
                hourToArcDegrees(localHour(sr)), hourToArcDegrees(localHour(ss)));
        }

        // Current-time pointer, coloured to match the side it sits on:
        // daylight (amber) during the day, night (dark gray) otherwise.
        var pointerColor = Graphics.COLOR_DK_GRAY;
        if (sr != null && ss != null) {
            var nowSec = now.value();
            if (nowSec > sr.value() && nowSec < ss.value()) {
                pointerColor = DAYLIGHT_COLOR;
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
        var segs = 20;
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

        // Up: heart rate (small heart icon above the value).
        drawHeartRate(dc, cx, cy - off);

        // Down: steps (nudged down toward the 6 o'clock edge).
        drawValue(dc, cx, cy + off + radius * 0.07, stepsText());

        // Left: weather icon above the temperature (nudged a little further left).
        var leftX = cx - off - radius * 0.08;
        drawWeatherIcon(dc, leftX, cy - 16, 16);
        drawValue(dc, leftX, cy + 22, temperatureText());

        // Right: date above the time. The time sits at the same y as the
        // temperature on the left so the two bottom values line up.
        var rightX = cx + off + radius * 0.07;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightX, cy - 16, Graphics.FONT_XTINY, dateText(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        drawValue(dc, rightX, cy + 22, timeOfDayText());
    }

    //! Draw a single value centered at (x, y).
    private function drawValue(dc as Graphics.Dc, x as Numeric, y as Numeric, value as String) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, value,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Draw the heart-rate value. The filled heart is drawn only in high power
    //! (it is the largest bright area, so it is dropped entirely in always-on);
    //! the value itself is always shown.
    private function drawHeartRate(dc as Graphics.Dc, x as Numeric, y as Numeric) as Void {
        var iconH = dc.getFontHeight(Graphics.FONT_XTINY) * 0.65;
        var textH = dc.getFontHeight(Graphics.FONT_TINY);
        // Small heart icon above the value (skipped in always-on).
        if (!_isSleeping) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            drawHeart(dc, x, y - textH * 1.0, iconH / 0.6875);
        }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y - textH * 0.05, Graphics.FONT_TINY, heartRateText(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Fill a heart of the given width centered at (cx, cy) using the classic
    //! parametric heart curve as one filled polygon. Points must be integers
    //! for fillPolygon to fill (floats render as edges only).
    private function drawHeart(dc as Graphics.Dc, cx as Numeric, cy as Numeric, w as Float) as Void {
        var scale = w / 32.0;
        var steps = 40;
        var pts = new [steps];
        for (var i = 0; i < steps; i++) {
            var t = i * (Math.PI * 2.0 / steps);
            var st = Math.sin(t);
            var hx = 16.0 * st * st * st;
            var hy = 13.0 * Math.cos(t) - 5.0 * Math.cos(2.0 * t) - 2.0 * Math.cos(3.0 * t) - Math.cos(4.0 * t);
            // +6 recenters the curve's bbox on cy.
            pts[i] = [(cx + scale * hx).toNumber(), (cy - scale * (hy + 6.0)).toNumber()];
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
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
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

        // Cloud body shared by cloud / rain / snow.
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var cloudY = (category.equals("cloud")) ? y : y - r * 0.4;
        dc.fillCircle(x - r * 0.55, cloudY, r * 0.45);
        dc.fillCircle(x + r * 0.5, cloudY, r * 0.42);
        dc.fillCircle(x, cloudY - r * 0.35, r * 0.5);
        dc.fillRectangle(x - r * 0.95, cloudY, r * 1.9, r * 0.5);

        if (category.equals("rain")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            for (var i = -1; i <= 1; i++) {
                var dx = x + i * r * 0.5;
                dc.drawLine(dx, cloudY + r * 0.6, dx - r * 0.15, cloudY + r * 1.1);
            }
        } else if (category.equals("snow")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            for (var i = -1; i <= 1; i++) {
                dc.fillCircle(x + i * r * 0.5, cloudY + r * 0.85, 2);
            }
        }
    }

    //! Bucket a Weather condition code into clear / rain / snow / cloud.
    private function weatherCategory(condition as Number) as String {
        if (condition == Weather.CONDITION_CLEAR
                || condition == Weather.CONDITION_PARTLY_CLOUDY
                || condition == Weather.CONDITION_MOSTLY_CLEAR) {
            return "clear";
        }
        if (condition == Weather.CONDITION_RAIN
                || condition == Weather.CONDITION_LIGHT_RAIN
                || condition == Weather.CONDITION_HEAVY_RAIN
                || condition == Weather.CONDITION_SCATTERED_SHOWERS) {
            return "rain";
        }
        if (condition == Weather.CONDITION_SNOW
                || condition == Weather.CONDITION_LIGHT_SNOW
                || condition == Weather.CONDITION_HEAVY_SNOW) {
            return "snow";
        }
        return "cloud";
    }

    //! Second hand: a thin white hand with the outer (tip) segment in the
    //! accent colour, a short tail, and a black outline.
    private function drawSecondHand(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, innerR as Float, length as Float) as Void {
        var sin = Math.sin(angle);
        var cos = Math.cos(angle);
        var split = length * 0.87;
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
        dc.setColor(ACCENT_COLOR, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(xs, ys, x1, y1);
        // Thin black cut at the white->accent transition.
        drawHandCut(dc, cx, cy, angle, split, 3.0);
    }

    //! Draw a single hand (with a thin black outline) from the center outward
    //! at the given angle (radians, clockwise from 12 o'clock).
    private function drawHand(dc as Graphics.Dc, cx as Number, cy as Number,
            angle as Float, innerR as Float, length as Float, penWidth as Number, color as Number) as Void {
        var dx = Math.sin(angle);          // along the hand (outward)
        var dy = -Math.cos(angle);
        var px = Math.cos(angle);          // perpendicular
        var py = Math.sin(angle);
        var hw = penWidth / 2.0;
        var ox = cx + length * dx;         // outer tip (kept rounded)
        var oy = cy + length * dy;
        // Outline: flat-ended rectangle body + round outer cap.
        dc.setColor(0x808080, Graphics.COLOR_TRANSPARENT);
        handRect(dc, cx, cy, dx, dy, px, py, innerR - 1.0, length, hw + 1.0);
        dc.fillCircle(ox, oy, hw + 1.0);
        // Fill.
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        handRect(dc, cx, cy, dx, dy, px, py, innerR, length, hw);
        dc.fillCircle(ox, oy, hw);
    }

    //! Fill a rectangle along a hand: from radius r0 to r1, half-width hw.
    //! Points are integers so fillPolygon fills (floats render edges only).
    private function handRect(dc as Graphics.Dc, cx as Number, cy as Number,
            dx as Float, dy as Float, px as Float, py as Float,
            r0 as Float, r1 as Float, hw as Float) as Void {
        var ax = cx + r0 * dx;
        var ay = cy + r0 * dy;
        var bx = cx + r1 * dx;
        var by = cy + r1 * dy;
        dc.fillPolygon([
            [(ax + px * hw).toNumber(), (ay + py * hw).toNumber()],
            [(bx + px * hw).toNumber(), (by + py * hw).toNumber()],
            [(bx - px * hw).toNumber(), (by - py * hw).toNumber()],
            [(ax - px * hw).toNumber(), (ay - py * hw).toNumber()]
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
