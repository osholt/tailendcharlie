# Arrival estimates and the France comparison

Build 99 follow-up, #797. This is implementation and automated evidence, not
physical navigation validation.

## Comparison of the supplied recordings

The two privately supplied France GPXs were analysed locally. No GPX, coordinates,
exact timestamps or screenshots are committed. Recording A is `ride-574443`;
recording B is `ride-018414`.

| Measurement | A | B |
| --- | ---: | ---: |
| Timestamp span | 6 h 30 min | 9 h 32 min |
| Observed stationary dwell excluded | 19 min | 24 min |
| Probable long breaks in nearby-endpoint GPS gaps | 108 min | 103 min |
| Travel estimate after those exclusions | 4 h 23 min | 7 h 25 min |
| Uncertain gaps **included** in that travel estimate | 19 min | 48 min |
| Distance observed across continuous fixes | 254.6 km | 389.6 km |
| Reconstructed current OSRM car duration | 5 h 39 min | 8 h 20 min |
| Reconstructed OSRM distance | 291.7 km | 423.0 km |

A break is at least five minutes within 60 m of an anchored position. A gap of at
least five minutes whose endpoints are within 250 m is labelled a **probable**
break. Short traffic delays remain in travel time. Gaps over two minutes that
cannot support a break inference remain uncertain. The distance column omits
unobserved jumps and implausible GPS jumps; it is not an exact odometer distance.

The original on-screen route estimates were not captured. The reconstruction
uses the existing diagnostic OSRM requests against simplified track sections:
22 blocks for A, 28 for B, with one overlapping input edge between neighbouring
blocks. It is a current car-route reconstruction, not a replay of the original
motorcycle provider estimate. Its distance is about 15%/9% above continuously
observed distance. Detours from reconstruction and request overlap therefore
contribute to its apparent time excess (about 29%/12%). These ratios must **not**
be installed as a personal speed correction. Both recordings exceed the new
five-percent uncertain-time threshold and are excluded from automatic training.

A confirmed code defect also affected estimates: reusing a saved route dropped
its structured provider duration. #796 retains it (except on reversal, when
fresh directions and duration are required). The provider baseline remains
stored even after personalised estimates are displayed.

## Personal learning

Learning is local and can be disabled or reset in Settings. Eligible records
must be completed, active, timed, at least ten kilometres and ten minutes,
within 10% of the plan's distance, finish near the planned endpoints, and have
at least 90% of sampled fixes within 100 m of the planned corridor. Unknown time
must be no more than 5%. Incomplete checkpoints and major deviations are excluded.

The newest 30 qualifying rides per broad provider-average-speed band are used
(under 40, 40–75, over 75 km/h). Three are required before personal adjustment.
The median travel/provider ratio is shrunk towards the provider or population
baseline with weight `n / (n + 8)`. The final multiplier is bounded to 0.8–1.2.
Instantaneous GPS speed never sets a route-wide ETA. These are broad road-mix
bands, not per-road traffic modelling or a claim of Waze-equivalent predictions.

## Optional motorcycle population model

Contribution is a **separate switch, off by default**. Only three optional ratios,
rounded to 0.05 and bounded to 0.8–1.2, leave the phone. No raw trace, ride ID,
trip date, duration, distance, speed, account ID or heatmap credential is sent.
A separate random secure-storage credential permits replacement and deletion;
the relay stores only its hash, the coarse profile and a 90-day expiry date.
Normal network infrastructure still sees requests; this is not network anonymity.

Each credential has equal weight irrespective of ride count. At least 20 distinct
contributor profiles are required per band. Median factors are shrunk towards 1,
rounded to 0.05, capped to 0.85–1.15, and published without precise counts. A
credential is not proof of a unique human: rate limits and caps limit abuse, but
this early model is not resistant to determined creation of multiple identities.
No population advantage is claimed until a sufficient cohort exists.

Opt-out is saved before networking. Deletion retries after a connection failure
or restart, retains its deletion credential until acknowledged, and runs after
any in-flight upload. Reset replaces the shared profile with an empty one if
contribution is enabled. Expired profiles are excluded from reads and purged by
the normal cleanup job. Public factors cache for up to seven days on the phone;
a removal can therefore take that long to disappear from another offline
phone's cached estimates, although new relay reads exclude it immediately.

Relay migration 0012 must deploy before the client. Old relays returning an
error leave local/provider estimates working. Baseline duration is never
rewritten, preventing learning from feeding back into its own training target.
