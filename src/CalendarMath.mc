import Toybox.Lang;

//! Pure Gregorian-calendar + DST math -- no timezone database. Used by the SW
//! timezone field. All functions are deterministic from their arguments.
module Cal {

    //! Hours to add for DST given the zone's rule group and the zone's local
    //! fractional day-of-year (`nowFrac`). Transitions are taken at ~02:00 local
    //! (the `h` threshold) so the changeover doesn't jump at midnight.
    //! group: 1 EU (last Sun Mar -> last Sun Oct), 2 US (2nd Sun Mar -> 1st Sun
    //! Nov), 3 AU/Sydney (1st Sun Oct -> 1st Sun Apr), 4 NZ (last Sun Sep -> 1st
    //! Sun Apr). 3 and 4 are southern-hemisphere and wrap the year.
    function dstHours(group as Number, year as Number, nowFrac as Float) as Float {
        var h = 2.0 / 24.0; // transition near 02:00 local standard time
        if (group == 1) {
            var s = doy(year, 3, lastSunday(year, 3)) + h;
            var e = doy(year, 10, lastSunday(year, 10)) + h;
            return (nowFrac >= s && nowFrac < e) ? 1.0 : 0.0;
        }
        if (group == 2) {
            var s = doy(year, 3, nthSunday(year, 3, 2)) + h;
            var e = doy(year, 11, nthSunday(year, 11, 1)) + h;
            return (nowFrac >= s && nowFrac < e) ? 1.0 : 0.0;
        }
        if (group == 3) {
            var s = doy(year, 10, nthSunday(year, 10, 1)) + h;
            var e = doy(year, 4, nthSunday(year, 4, 1)) + h;
            return (nowFrac >= s || nowFrac < e) ? 1.0 : 0.0;
        }
        if (group == 4) { // NZ: last Sun Sep -> 1st Sun Apr (southern, wraps)
            var s = doy(year, 9, lastSunday(year, 9)) + h;
            var e = doy(year, 4, nthSunday(year, 4, 1)) + h;
            return (nowFrac >= s || nowFrac < e) ? 1.0 : 0.0;
        }
        return 0.0;
    }

    //! Day of week (0 = Sunday) for a Gregorian date, via Sakamoto.
    function weekday(y as Number, m as Number, d as Number) as Number {
        var t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
        var yy = (m < 3) ? y - 1 : y;
        return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7;
    }

    //! Day-of-month of the nth (1-based) Sunday of a month.
    function nthSunday(y as Number, m as Number, n as Number) as Number {
        var first = 1 + ((7 - weekday(y, m, 1)) % 7);
        return first + 7 * (n - 1);
    }

    //! Day-of-month of the last Sunday of a month.
    function lastSunday(y as Number, m as Number) as Number {
        var ld = daysInMonth(y, m);
        return ld - weekday(y, m, ld);
    }

    function leapYear(y as Number) as Boolean {
        return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
    }

    function daysInMonth(y as Number, m as Number) as Number {
        if (m == 2) {
            return leapYear(y) ? 29 : 28;
        }
        return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
    }

    //! Day of year (1..366).
    function doy(y as Number, m as Number, d as Number) as Number {
        var dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        var n = d;
        for (var k = 1; k < m; k++) {
            n += dim[k - 1];
        }
        if (m > 2 && leapYear(y)) {
            n += 1;
        }
        return n;
    }
}
