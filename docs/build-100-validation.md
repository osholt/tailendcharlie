# Build 100 regression validation

Candidate date: 21 September 2026. Release tracked by #818. The user explicitly
requested fixing these regressions and pushing to testers. These checks establish
implementation behaviour; field-dependent tickets remain ready for validation.

| Issue | Change | Regression evidence |
| --- | --- | --- |
| #793 | Remove supplemental business-name pills, place fetches and added business layers; migrate cached presentation styles offline | Day/night cached-style tests with networking disabled; removing the layer cleanup makes the test fail |
| #776 | Restore provider road width expressions and the earlier road-class palette | Cached widened styles restore original widths; linear-width mutation fails; rendered Bristol review confirms subdued minor roads and no business pills |
| #306 | Restore the flat Settings menu during active free-roam navigation | Portrait and landscape tests open Settings with route progress still present; ignoring host menu actions fails |
| #819 | Bounded 32 MB RAM tile cache, shared disk reads, asynchronous ambient writes and background validation | Warm-tile/disk-removal, eviction, concurrency and delayed-write tests; bypassing RAM hits fails; offline readiness still requires durable files |
| #820 | Keep circular-route errors visible; offer Cancel, Edit route and Try another loop | Failure/recovery and successful preview widget tests; restoring automatic setup reopening fails; two live Bristol provider requests return usable loops |
| #777 | Pointed rider markers; derive missing travel course from GPS displacement and retain direction while stopped | Geometry and direction tests, real map-widget missing-course test; removing heading output fails; marker render inspected at three headings |
| #821 | Keep rider at the landscape right third, outside measured panels at every text size | Actual widget rectangle assertions in both orientations and all three sizes, existing overlay stress tests; ignoring occlusions fails |
| #822 | Persist travelled distance and planned progress through off-route stops; combine connector distance/time with the remaining plan | Coffee-stop/rejoin, bad-fix, checkpoint restore and actual map recreation tests; disabling restore and omitting the remaining plan both fail |

## Scope of evidence

The rendered road-style review uses the app's transformed style with real public
map tiles in MapLibre in a browser. It is not a physical iPhone performance or
sunlight test. Marker rendering was checked separately with Flutter. Cold tile
network speed remains dependent on the provider; downloaded resources avoid
repeat disk work after their first read. RAM residency never marks an offline
pack as durably downloaded.

The live circular-route checks returned a 73.854 km northern loop from an 80 km
request and a 107.901 km north-west loop from an 80 mile flowing-roads request
avoiding motorways. The planner uses length tolerances. This verifies live
provider success and the UI recovery path, not every possible origin or failure.

Off-route progress does not reset. Until a usable road rejoin exists, the panel
labels the original plan's remaining distance and withholds ETA. It does not
present straight-line distance as road distance. Explicitly selecting a different
route starts a separate journey. Long GPS gaps are not invented as travelled
mileage. CarPlay/Android Auto retain their existing snapshot contract; no physical
vehicle validation is claimed.

A bounded external review attempt timed out without its required completion
sentinel and is not counted as completed review evidence. Local diff review and
the regression/mutation checks provide the implementation evidence.

## Local checks

- Complete mobile suite: **2,264 passed, 24 existing skips**.
- Flutter static analysis: no issues; Dart formatting: 540 files unchanged.
- Projected-navigation compliance: zero structural/traceability failures for
  the incremental tester gate. Existing physical-platform gaps remain ticketed.
- Diff whitespace check clean.

## Release gate

Require format and static analysis, the complete mobile suite, and all seven
protected-main checks before merge. Deploy the relay at the merged app commit,
then dispatch build 100 to iOS TestFlight and Android alpha. Verify store state,
not only upload success. Actual run links and availability belong on #818.
