# France feedback validation — build 98

The 20 September feedback is tracked by [#781](https://github.com/osholt/tailendcharlie/issues/781).
The issue PRs feed one integration branch. The final release PR must pass the
protected main branch's combined checks before deployment and store upload.
No physical field result is claimed by these automated checks.

| Issue | Implementation | Targeted evidence | Remaining field check |
| --- | --- | --- | --- |
| #732 background crash | #791 removes the invalid optional superclass callback | Build 97 Organizer reports; native simulator test passes with fix and raises the exact unrecognised-selector exception with the old call restored | Home/app switching and lock/unlock without CarPlay on both affected phones; ride continuity |
| #772 French speed limits | #790 matches lookahead direction against the local road tangent | 48 provider/controller tests; disabling the tangent rejects the valid curved-road fixture | Revisit missing stretches; source gaps remain |
| #773 roundabouts | #787 limits bearing samples to the road between neighbouring junctions | 81 navigation/provider tests; restoring the unbounded departure window fails | Direction and exit count at the reported junctions; count discrepancy unresolved |
| #774 straight junctions | #788 preserves explicit continue guidance and detects ambiguous legal forward forks | 100 navigation/provider tests; suppressing continues and bypassing the topology detector are caught | Real ambiguous straight junctions without excessive side-road prompts |
| #775 driving text size | #784 adds Small/Medium/Large and concise enlarged direction text | 15 size/preference tests; removed persistence and disabled enlargement are caught; 320px portrait and landscape at 1.6 system text scale | Mounted-phone readability and available map area |
| #776 dark roads | #783 widens and brightens minor/major roads and their labels | Palette/width/contrast/cache tests; restoring a dim minor-road colour fails | Direct sunlight and tinted visor |
| #777 rider arrows | #785 rotates a pointed background independently of upright identity | 21 marker tests plus 142 map tests; disabled rotation and an opaque mask substituted for a distance field fail | Moving group, rotated map, both platforms, stopped/stale positions |
| #778 speech | #782 refreshes/cancels speech and formats British metric distances | 39 formatter/speech tests; raw metres, stale resolver, missing cancellation and stale neural-player setup are caught | Actual prompt timing and pronunciation while riding |
| #779 library | #789 adds map selection and place/length/rating/area filters to Imported/Recorded/Rides tabs | 15 focused Flutter tests, two French-place generator tests; disabled rating and segment-intersection filters fail; rendered 390px preview inspected | Large real libraries, overlapping routes and offline map availability |
| #780 heatmap | #786 blends kernels and allows bounded country views | 164 mobile and 14 server tests; one-pixel kernels and reinstated country rejection fail; rendered continuity preview inspected | Sparse/dense real data at riding and country zoom after relay rollout |

## Evidence boundaries

- The two provided GPX recordings were used locally to reconstruct routes with
  the app's documented routing providers. They do not contain the exact original
  spoken instructions. Full tracks and raw crash reports are not committed.
- In reconstructed OSRM routes, 13 of 117 roundabout direction classifications
  changed with bounded bearing sampling. These are diagnostic comparisons, not
  13 independently verified road errors.
- One reconstructed OSRM/Valhalla exit-count disagreement includes service-road
  branches. No reliable example establishes that an incoming split carriageway
  was counted twice. The app continues to use provider counts rather than
  subtracting exits speculatively.
- Seven sampled roads with missing posted limits also lacked OSM speed-limit
  tags. The curved-road fix addresses lookahead rejection; it cannot supply
  absent map data. See [French speed-limit findings](france-speed-limit-findings.md)
  for the official signing rules and provider boundary.
- The heatmap's minimum distinct contributors, privacy trimming, daily snapshot
  and result cap remain intact. Expanding the viewport does not create heat
  where the underlying snapshot has no publishable data.

## Release evidence

The final main commit, combined CI run, relay `serverBuildCommit`, signed build
runs and store processing/distribution state are recorded on #781. A successful
upload is not evidence of external TestFlight approval or field validation.
