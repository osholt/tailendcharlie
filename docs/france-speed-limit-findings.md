# France speed-limit investigation (#772)

Checked 20 September 2026 against Cerema's current consolidated collection and
[IISR part 4, articles 63, 63-1 and 68](https://equipementsdelaroute.cerema.fr/IMG/pdf/iisr_4epartie_vc_20220613_cle22c5b5.pdf).

A speed bump does not by itself justify cancelling a B14 limit. A stated extent,
a replacement restriction or an applicable end sign determines the end. Zone 30
has separate entrance/exit rules; neither a bump nor a routine intersection ends
it. Vehicle-category plates restrict who a sign applies to. The app must not
infer a universal 50 km/h limit from residential road classification.

## Observed data and client defect

Sampled recorded-road segments were matched through the configured Valhalla
service. Seven selected named streets with missing limits were also checked
against current OSM way tags: none had a speed-limit tag. Those gaps cannot be
filled accurately from the available data; neither routing speed nor a nearby
road's limit is a substitute. Full private tracks remain outside this repository.

Separately, the look-ahead cache compared each sampled point with the *end*
heading of a potentially long curved edge. A sampled D 515 edge had a valid
110 km/h limit, an approach near 192° and an end heading of 244°, exceeding the
50° acceptance tolerance. A short live two-fix lookup clipped that same edge
and correctly reported about 185°. This explains avoidable gaps in prefetch,
not every missing urban limit.

The fix requests the documented trace shape and edge shape indices and uses the
nearest segment's forward tangent for each prefetched sample. Opposite-direction
matches remain rejected. Missing/malformed geometry retains the existing
provider-heading fallback. No extra provider is contacted by the app, and no
conditional rain or truck limit is promoted into a universal motorcycle limit.

Provider contract: [Valhalla trace attributes](https://valhalla.github.io/valhalla/api/map-matching/).
