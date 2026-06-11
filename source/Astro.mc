import Toybox.Math;
import Toybox.Lang;

//! Pure astronomy for Moonkey -- no device state (the view supplies location and
//! time). Moon position is Meeus *Astronomical Algorithms* ch.47 principal terms
//! (~0.02 deg); the sun is Schlyter low precision. Verified against the `solunar`
//! ephemeris: tilt exact, moonrise/set to ~1 min.
//!
//! Float precision is delicate here -- keep the integer-first Julian date
//! (daysSinceJ2000) and the mod-360 GMST reduction (whole revolutions dropped
//! from the integer-day term), or a raw ~2.46M JD quantizes to ~6-hour steps.
module Astro {

    //! Days since J2000 (2000-01-01 12:00 UTC) from a Unix-second count, with the
    //! epoch subtracted as integers first to preserve 32-bit-float precision.
    function daysSinceJ2000(unixSec as Number) as Float {
        return (unixSec - 946728000) / 86400.0;
    }

    //! Reduce an angle (degrees) to [0, 360).
    function rev(x as Float) as Float {
        var v = x - (x / 360.0).toNumber() * 360.0;
        if (v < 0.0) { v += 360.0; }
        return v;
    }

    //! Reduce an angle (degrees) to (-180, 180].
    function normDeg180(x as Float) as Float {
        var d = x;
        while (d > 180.0) { d -= 360.0; }
        while (d < -180.0) { d += 360.0; }
        return d;
    }

    //! Meeus eccentricity factor E^|m| for the sun-anomaly (M) multiplier.
    function moonE(e as Float, m as Number) as Float {
        if (m == 0) {
            return 1.0;
        }
        return (m == 1 || m == -1) ? e : e * e;
    }

    //! Geocentric equatorial moon coordinates [RA, Dec] in radians, Meeus ch.47
    //! principal terms. ecl = obliquity (radians).
    function moonRaDec(dd as Float, ecl as Float) as Lang.Array {
        var rad = Math.PI / 180.0;
        var t = dd / 36525.0; // Julian centuries since J2000
        var lp = rev(218.3164477 + 481267.88123421 * t - 0.0015786 * t * t);
        var d = rev(297.8501921 + 445267.1114034 * t - 0.0018819 * t * t);
        var m = rev(357.5291092 + 35999.0502909 * t - 0.0001536 * t * t);
        var mp = rev(134.9633964 + 477198.8675055 * t + 0.0087414 * t * t);
        var f = rev(93.2720950 + 483202.0175233 * t - 0.0036539 * t * t);
        var e = 1.0 - 0.002516 * t - 0.0000074 * t * t;
        // [coef (1e-6 deg), D, M, M', F] -- longitude (47.A) then latitude (47.B).
        var lt = [
            [6288774, 0, 0, 1, 0], [1274027, 2, 0, -1, 0], [658314, 2, 0, 0, 0], [213618, 0, 0, 2, 0],
            [-185116, 0, 1, 0, 0], [-114332, 0, 0, 0, 2], [58793, 2, 0, -2, 0], [57066, 2, -1, -1, 0],
            [53322, 2, 0, 1, 0], [45758, 2, -1, 0, 0], [-40923, 0, 1, -1, 0], [-34720, 1, 0, 0, 0],
            [-30383, 0, 1, 1, 0], [15327, 2, 0, 0, -2], [-12528, 0, 0, 1, 2], [10980, 0, 0, 1, -2],
            [10675, 4, 0, -1, 0], [10034, 0, 0, 3, 0], [8548, 4, 0, -2, 0], [-7888, 2, 1, -1, 0],
            [-6766, 2, 1, 0, 0], [-5163, 1, 0, -1, 0], [4987, 1, 1, 0, 0], [4036, 2, -1, 1, 0]];
        var bt = [
            [5128122, 0, 0, 0, 1], [280602, 0, 0, 1, 1], [277693, 0, 0, 1, -1], [173237, 2, 0, 0, -1],
            [55413, 2, 0, -1, 1], [46271, 2, 0, -1, -1], [32573, 2, 0, 0, 1], [17198, 0, 0, 2, 1],
            [9266, 2, 0, 1, -1], [8822, 0, 0, 2, -1], [8216, 2, -1, 0, -1], [4324, 2, 0, -2, -1],
            [4200, 2, 0, 1, 1], [-3359, 2, 1, 0, -1], [2463, 2, -1, -1, 1], [2211, 2, -1, 0, 1],
            [2065, 2, -1, -1, -1], [-1870, 0, 1, -1, -1], [1828, 4, 0, -1, -1], [-1794, 0, 1, 0, 1]];
        var sl = 0.0;
        for (var i = 0; i < lt.size(); i++) {
            var term = lt[i] as Lang.Array;
            var arg = (term[1] as Number) * d + (term[2] as Number) * m
                + (term[3] as Number) * mp + (term[4] as Number) * f;
            sl += (term[0] as Number) * moonE(e, term[2] as Number) * Math.sin(arg * rad);
        }
        var sb = 0.0;
        for (var i = 0; i < bt.size(); i++) {
            var term = bt[i] as Lang.Array;
            var arg = (term[1] as Number) * d + (term[2] as Number) * m
                + (term[3] as Number) * mp + (term[4] as Number) * f;
            sb += (term[0] as Number) * moonE(e, term[2] as Number) * Math.sin(arg * rad);
        }
        var lon = (lp + sl / 1000000.0) * rad;
        var lat = (sb / 1000000.0) * rad;
        var ce = Math.cos(ecl);
        var se = Math.sin(ecl);
        var slon = Math.sin(lon);
        var ra = Math.atan2(slon * ce - Math.tan(lat) * se, Math.cos(lon));
        var dec = Math.asin(Math.sin(lat) * ce + Math.cos(lat) * se * slon);
        return [ra, dec];
    }

    //! Geocentric equatorial sun coordinates [RA, Dec] in radians, Schlyter low
    //! precision. ecl = obliquity (radians).
    function sunRaDec(dd as Float, ecl as Float) as Lang.Array {
        var rad = Math.PI / 180.0;
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
        return [raSun, decSun];
    }

    //! Sky inclination of the moon (radians) = bright-limb position angle minus
    //! the parallactic angle, for an observer at latitude `latR` (rad) and
    //! longitude `lonDeg` (deg). dd = days since J2000, ecl = obliquity (rad).
    function brightLimbTilt(dd as Float, ecl as Float, latR as Float, lonDeg as Float) as Float {
        var rad = Math.PI / 180.0;
        var sr = sunRaDec(dd, ecl);
        var decSun = sr[1];
        var rd = moonRaDec(dd, ecl);
        var raMoon = rd[0];
        var decMoon = rd[1];
        // Bright-limb position angle (from celestial north).
        var dA = sr[0] - raMoon;
        var chi = Math.atan2(Math.cos(decSun) * Math.sin(dA),
            Math.sin(decSun) * Math.cos(decMoon) - Math.cos(decSun) * Math.sin(decMoon) * Math.cos(dA));
        // Parallactic angle (rotate to the local vertical).
        var ddi = dd.toNumber();
        var gmst = rev(280.46061837 + 0.98564736629 * ddi + 360.98564736629 * (dd - ddi));
        var ha = (gmst + lonDeg) * rad - raMoon;
        var q = Math.atan2(Math.sin(ha),
            Math.tan(latR) * Math.cos(decMoon) - Math.sin(decMoon) * Math.cos(ha));
        return chi - q;
    }

    //! Moon equatorial position at `ddv` (days since J2000): [RA deg, Dec rad, GMST deg].
    function moonEqAt(ddv as Float, rad as Float) as Lang.Array {
        var ecl = (23.4393 - 3.563e-7 * ddv) * rad;
        var rd = moonRaDec(ddv, ecl);
        var ddi = ddv.toNumber();
        var gmst = rev(280.46061837 + 0.98564736629 * ddi + 360.98564736629 * (ddv - ddi));
        return [rd[0] / rad, rd[1], gmst];
    }

    //! Refine a horizon crossing from transit `tt` (days since J2000), direction
    //! sign (-1 rise, +1 set); null if it stops crossing under iteration.
    function horizonCross(tt as Float, sign as Number, latR as Float,
            h0 as Float, rate as Float, rad as Float) as Float or Null {
        var u = tt;
        for (var k = 0; k < 2; k++) {
            var pk = moonEqAt(u, rad);
            var c = (Math.sin(h0) - Math.sin(latR) * Math.sin(pk[1])) / (Math.cos(latR) * Math.cos(pk[1]));
            if (c > 1.0 || c < -1.0) {
                return null;
            }
            u = tt + sign * (Math.acos(c) / rad / rate) / 24.0; // days
        }
        return u;
    }

    //! Days since J2000 -> local clock hour [0,24). UTC hour-of-day = frac(ddv+0.5);
    //! tzoSec is the device-clock UTC offset.
    function localHourFromDd(ddv as Float, tzoSec as Number) as Float {
        var f = ddv + 0.5;
        f -= f.toNumber(); // fractional UTC day [0,1)
        if (f < 0.0) {
            f += 1.0;
        }
        var h = f * 24.0 + tzoSec / 3600.0;
        h -= 24.0 * (h / 24.0).toNumber();
        if (h < 0.0) {
            h += 24.0;
        }
        return h;
    }

    //! Moonrise/moonset as local clock hours: [rise, set, state]. Iterated
    //! (RA/Dec re-evaluated at the transit and each crossing, ~few min). state:
    //! 0 normal, 1 up-all-day, 2 down-all-day. latR rad, lonDeg deg, ddNow days
    //! since J2000, tzoSec the device-clock UTC offset. (No-location is the
    //! caller's concern.)
    function moonRiseSet(ddNow as Float, latR as Float, lonDeg as Float, tzoSec as Number) as Lang.Array {
        var rad = Math.PI / 180.0;
        var rate = 14.492; // mean lunar diurnal rate, deg/hr
        var h0 = 0.125 * rad; // moon standard altitude (refraction + ~parallax)
        var p0 = moonEqAt(ddNow, rad);
        var cosH0 = (Math.sin(h0) - Math.sin(latR) * Math.sin(p0[1])) / (Math.cos(latR) * Math.cos(p0[1]));
        if (cosH0 > 1.0) {
            return [0.0, 0.0, 2]; // never rises
        }
        if (cosH0 < -1.0) {
            return [0.0, 0.0, 1]; // circumpolar, never sets
        }
        // Transit: Newton on the hour angle, re-evaluating the moving position.
        var tt = ddNow;
        for (var k = 0; k < 2; k++) {
            var pk = moonEqAt(tt, rad);
            var ha = normDeg180((pk[2] + lonDeg) - pk[0]); // deg
            tt -= (ha / rate) / 24.0; // days
        }
        var riseDd = horizonCross(tt, -1, latR, h0, rate, rad);
        var setDd = horizonCross(tt, 1, latR, h0, rate, rad);
        if (riseDd == null || setDd == null) {
            return [0.0, 0.0, 1]; // grazing under iteration -> treat as up
        }
        return [localHourFromDd(riseDd as Float, tzoSec), localHourFromDd(setDd as Float, tzoSec), 0];
    }
}
