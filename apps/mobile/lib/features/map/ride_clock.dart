import 'dart:async';

import 'package:flutter/material.dart';

/// The time of day, drawn by the app (#452).
///
/// > Show the time on the map in landscape mode and on CarPlay but don't use
/// > Apple's built in widgets to do it.
///
/// A helmet and gloves make a wrist watch useless and the phone is already in
/// front of the rider, so the clock belongs on the map. Apple's own widgets are
/// ruled out explicitly: they carry their own styling and placement and would not
/// sit with the rest of the chrome.
///
/// ## Ticking on the minute, not every second
///
/// A clock showing hours and minutes only needs to redraw when the minute
/// changes. A one-second timer would rebuild this sixty times for every visible
/// change, on a phone that is also drawing a moving map and running navigation.
///
/// So it sleeps until the next minute boundary, redraws, and sleeps again. See
/// [millisecondsUntilNextMinute].
class RideClock extends StatefulWidget {
  const RideClock({super.key, this.clock, this.style, this.darkMap = true});

  /// Overridden in tests. Production reads the device clock.
  final DateTime Function()? clock;

  final TextStyle? style;

  /// The palette of the map under the label, independent of the app theme.
  final bool darkMap;

  @override
  State<RideClock> createState() => _RideClockState();
}

class _RideClockState extends State<RideClock> {
  Timer? _tick;
  late DateTime _now = _read();

  DateTime _read() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _tick?.cancel();
    _tick = Timer(
      Duration(milliseconds: millisecondsUntilNextMinute(_read())),
      () {
        if (!mounted) return;
        setState(() => _now = _read());
        // Rescheduled from the new time rather than repeating a fixed minute:
        // a timer that drifts by a few milliseconds each hour eventually fires
        // just *before* the boundary and shows the previous minute.
        _schedule();
      },
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The platform's own formatting, so a rider who keeps their phone on a
    // 24-hour clock sees one here too. Formatting it by hand is how an app ends
    // up showing 13:00 to somebody who has never used a 24-hour clock.
    final label = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(_now));
    return Text(
      label,
      key: const Key('ride-clock'),
      style:
          widget.style ??
          TextStyle(
            color: widget.darkMap ? Colors.white : Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1,
            shadows: [
              Shadow(
                color: widget.darkMap ? Colors.black87 : Colors.white,
                blurRadius: 4,
              ),
            ],
          ),
    );
  }
}

/// Milliseconds from [now] to the start of the next minute.
///
/// Never zero: a timer scheduled for zero milliseconds fires immediately and, if
/// the clock has not yet crossed the boundary, reschedules for zero again — a
/// spin that would run flat out for a whole second. One second is the floor,
/// which is also the longest a clock can be wrong by without a rider noticing.
int millisecondsUntilNextMinute(DateTime now) {
  final elapsed = now.second * 1000 + now.millisecond;
  final remaining = Duration.millisecondsPerMinute - elapsed;
  return remaining < 1000 ? 1000 : remaining;
}
