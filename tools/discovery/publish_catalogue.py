"""Merge derived facts, researched evidence and composed descriptions; publish.

Tiering
-------
`researched`  the road number appears in a motorcycle-road directory, so there is
              external corroboration that riders use it.
`pending`     nobody has corroborated it, but it carries a name or a road number, so
              somebody recognises it as a road. Ships, marked unverified.
`discarded`   anonymous (no name, no number, unclassified) with no corroboration, and
              nothing in its geometry to argue for it. Dropped.

The score cannot drive this. The generator already creamed off the top 1,100 per
category, so scores run 81-100 with 1,376 candidates tied at 100 — saturated and
useless as a discriminator. `scoreComponents` carries the real signal, so the
anonymous tier is judged on length and bend density instead.

Descriptions
------------
Composed from verified facts only — road number, locality, length, bend density,
speed limit, enforcement. That is factual composition, not research: it states what
the extract says and nothing more. Subjective claims about how a road rides appear
only for `researched` entries, quoted from the directory that made them.

Overlay merge
-------------
An overlay entry is looked up by candidate id first, then by `sourceFeatureId`. The
second lookup is what makes researched prose survive a regeneration: candidate ids
are content hashes, so a new extract churns them, and without the fallback every
researched pass would silently revert to a generated `pending` note. A candidate with
no overlay entry at all is `pending`, never a crash — a fresh extract introducing a
new pass must not break publication.
"""

import json
import os
import pathlib

import evidence_index
import road_ratings

OUT = os.environ.get("DISCOVERY_WORK_DIR", "/private/tmp/discovery-out")
REPO = os.environ.get("DISCOVERY_REPO", str(pathlib.Path(__file__).resolve().parents[2]))

# An anonymous candidate has to earn its place on geometry alone.
MIN_ANON_LENGTH_KM = 3.0
MIN_ANON_BENDS = 90.0


CLASS_WORDS = {
    "primary": "A-road",
    "secondary": "B-road",
    "tertiary": "Minor road",
    "unclassified": "Unclassified road",
    "residential": "Residential road",
}


BUSY_PERIODS_NOT_RESEARCHED = (
    "Not researched. No claim is made either way about when this road is busy."
)


def index_overlay(entries):
    """Index overlay entries by sourceFeatureId so orphans can be re-matched.

    A sourceFeatureId shared by two entries is a genuine ambiguity, so neither is
    offered for re-matching: attaching the wrong prose to a pass is worse than
    falling back to a generated note.
    """
    by_source = {}
    for candidate_id, entry in entries.items():
        source_id = entry.get("sourceFeatureId")
        if source_id:
            by_source.setdefault(source_id, []).append(candidate_id)
    return {
        source_id: entries[matches[0]]
        for source_id, matches in by_source.items()
        if len(matches) == 1
    }


def overlay_entry_for(props, entries, by_source):
    """Return (entry, how) for a candidate. `how` records which key matched."""
    entry = entries.get(props["id"])
    if entry is not None:
        return entry, "candidate-id"
    entry = by_source.get(props.get("sourceFeatureId"))
    if entry is not None:
        return entry, "source-feature-id"
    return None, "none"


def busy_periods_field(entry):
    """Busy periods, always with provenance.

    A bare missing field reads as "not busy" to anyone consuming the catalogue, which
    is a claim nobody researched. `researched` carries the finding and its date;
    `not-researched` says so out loud.
    """
    value = (entry or {}).get("busyPeriods")
    if value:
        return {
            "value": value,
            "provenance": "researched",
            "researchedOn": (entry or {}).get("researchedOn"),
        }
    return {"value": None, "provenance": "not-researched", "note": BUSY_PERIODS_NOT_RESEARCHED}


def road_name(derived, used):
    """Name a road candidate so that no two are indistinguishable in a list.

    A road number alone is not enough: the B6012 appears as five separate
    candidates, and five identical rows in a planner are useless. Localities
    disambiguate; a counter is the last resort.
    """
    locality = (derived.get("locality") or {}).get("name")

    if derived["roadRefs"]:
        base = "/".join(derived["roadRefs"][:2])
    elif derived["roadNames"]:
        base = derived["roadNames"][0]
    else:
        classes = derived["roadClasses"]
        word = CLASS_WORDS.get(classes[0] if classes else "", "Road")
        base = f"{word} near {locality}" if locality else f"{word} (unnamed)"

    candidate = base
    if candidate in used and locality and f"near {locality}" not in candidate:
        candidate = f"{base} near {locality}"
    if candidate in used:
        used[candidate] += 1
        return f"{candidate} ({used[candidate]})"
    used[candidate] = 1
    return candidate


def summit_name(name, used):
    """Disambiguate a pass summit from the road of the same name."""
    if name not in used:
        used[name] = 1
        return name
    summit = f"{name} (summit)"
    if summit not in used:
        used[summit] = 1
        return summit
    used[summit] += 1
    return f"{name} (summit {used[summit]})"


def describe_pass(props, derived):
    """Compose a factual note for a pass whose research is still outstanding."""
    parts = [props["name"]]
    locality = (derived.get("locality") or {}).get("name")
    if locality:
        parts[0] += f", near {locality}"
    elevation = props.get("sourceElevation")
    sentence = parts[0]
    if elevation:
        sentence += f", mapped at {elevation} m"
    sentence += "."
    peak = derived.get("nearestPeak") or {}
    if peak.get("name"):
        sentence += f" Nearest summit is {peak['name']}"
        if peak.get("elevation"):
            sentence += f" at {peak['elevation']} m"
        sentence += "."
    sentence += " Not yet cross-checked against motorcycle route sources."
    return sentence


def describe(props, derived, evidence):
    """One or two sentences, built only from facts we hold."""
    components = props.get("scoreComponents") or {}
    refs = derived["roadRefs"]
    names = derived["roadNames"]
    locality = (derived.get("locality") or {}).get("name")
    length = components.get("lengthKm")
    bends = components.get("bendDegreesPerKm")

    if refs:
        subject = "/".join(refs[:2])
    elif names:
        subject = names[0]
    else:
        subject = "An unclassified road"

    opening = subject
    if locality:
        opening += f" near {locality}"
    parts = []
    if length:
        parts.append(f"{length:.1f} km")
    if bends:
        parts.append(f"{bends:.0f}° of bend per km")
    if parts:
        opening += ", " + " with ".join(parts)
    sentence = opening + "."

    tail = []
    limit = derived["speedLimit"]
    if limit["value"]:
        qualifier = "" if limit["provenance"] == "tagged" else " (implied by a national limit tag)"
        if limit.get("mixed"):
            low, high = limit["range"]
            tail.append(f"Limit varies from {low} to {high}")
        else:
            tail.append(f"Limit {limit['value']}{qualifier}")
    else:
        tail.append("No speed limit is mapped")

    if derived["averageSpeedCheck"].get("present"):
        tail.append("an average speed check covers part of it")
    elif derived["fixedSpeedCameras"]["count"]:
        count = derived["fixedSpeedCameras"]["count"]
        tail.append(f"{count} fixed speed camera{'s' if count > 1 else ''} mapped nearby")

    if evidence:
        routes = "; ".join(evidence["routes"][:2])
        tail.append(f"listed as a motorcycle road ({routes})")

    if tail:
        sentence += " " + tail[0]
        if len(tail) > 1:
            sentence += ", " + ", ".join(tail[1:])
        sentence += "."
    return sentence


def main():
    index = evidence_index.build()
    catalogue = json.load(open(f"{OUT}/discovery-catalogue.geojson"))
    derived_all = json.load(open(f"{OUT}/enrichment-deterministic.json"))
    overlay_document = json.load(open(f"{OUT}/editorial-overlay.json"))
    overlay = overlay_document["entries"]
    overlay_by_source = index_overlay(overlay)
    rejections = overlay_document.get("classificationRejections", {})
    # Rider verdicts collected by the relay since the last publication, if an
    # export has been fetched. Absent is normal and behaves as it did before.
    ratings = road_ratings.load(catalogue["properties"]["catalogueVersion"])

    # A pass summit node and the road that crosses it often share an OSM name, so
    # register the road names first. The pass then resolves to "<name> (summit)"
    # rather than presenting a planner with two identical rows.
    used_names = {}
    for feature in catalogue["features"]:
        props = feature["properties"]
        if props["category"] == "mountain_pass":
            continue
        names = derived_all[props["id"]]["roadNames"]
        if names:
            used_names.setdefault(names[0], 1)

    kept, tally = (
        [],
        {
            "researched": 0,
            "pending": 0,
            "discarded-anonymous": 0,
            "pass-researched": 0,
            "pass-pending": 0,
            "pass-rejected": 0,
            "pass-reclassified": 0,
            "pass-classification-rejected": 0,
            "overlay-rematched-by-source-id": 0,
            "overlay-missing": 0,
            "rider-verified": 0,
            "rider-flagged-for-removal": 0,
        },
    )
    # Candidates riders have voted against, for a human to look at. Never acted on
    # here: a road leaves the catalogue through the editorial overlay, by a
    # reviewer's decision.
    removal_review = []

    for feature in catalogue["features"]:
        props = feature["properties"]
        derived = derived_all[props["id"]]
        is_pass = props["category"] == "mountain_pass"

        # A candidate a reviewer has rejected on classification grounds never ships,
        # whatever layer it claims to be in. The generator now drops unnamed pass
        # nodes itself, so this is the belt to that braces: an extract that reinstates
        # one, or a named candidate a reviewer later rejects, is still caught here.
        if props.get("sourceFeatureId") in rejections:
            tally["pass-classification-rejected"] += 1
            continue

        editorial, matched_by = overlay_entry_for(props, overlay, overlay_by_source)
        if matched_by == "source-feature-id":
            tally["overlay-rematched-by-source-id"] += 1
            props["overlayMatch"] = "re-matched-by-source-feature-id"
        elif is_pass and editorial is None:
            tally["overlay-missing"] += 1

        if is_pass:
            if editorial and editorial["researchStatus"] == "researched":
                props["name"] = summit_name(editorial["name"], used_names)
                props["riderNote"] = editorial["riderNote"]
                props["motorcycleEvidence"] = editorial["motorcycleEvidence"]
                # Ships on the feature, not just in the overlay: a rider reading the
                # catalogue has to be able to tell a claim read off a retrieved page
                # from one that only rests on a directory listing.
                props["sourceVerification"] = editorial["sourceVerification"]
                if editorial.get("enforcementNote"):
                    props["enforcementNote"] = editorial["enforcementNote"]
                if editorial.get("crossingRoad"):
                    props["crossingRoad"] = editorial["crossingRoad"]
                props["evidenceSources"] = editorial["sources"]
                props["researchStatus"] = "researched"
                props["researchedOn"] = editorial["researchedOn"]
                tally["pass-researched"] += 1
            else:
                props["researchStatus"] = "pending"
                props["riderNote"] = describe_pass(props, derived)
                props["name"] = summit_name(props["name"], used_names)
                tally["pass-pending"] += 1
            props["busyPeriods"] = busy_periods_field(editorial)
        else:
            evidence = next((index[r] for r in derived["roadRefs"] if r in index), None)
            has_identity = bool(derived["roadRefs"] or derived["roadNames"])

            if not evidence and not has_identity:
                components = props.get("scoreComponents") or {}
                length = components.get("lengthKm") or 0
                bends = components.get("bendDegreesPerKm") or 0
                if length < MIN_ANON_LENGTH_KM or bends < MIN_ANON_BENDS:
                    tally["discarded-anonymous"] += 1
                    continue

            if evidence:
                props["researchStatus"] = "researched"
                props["evidenceSources"] = [evidence["source"]]
                props["listedRoutes"] = evidence["routes"]
                tally["researched"] += 1
            else:
                props["researchStatus"] = "pending"
                tally["pending"] += 1

            props["name"] = road_name(derived, used_names)

            props["riderNote"] = describe(props, derived, evidence)
            # No road candidate has had its busy periods researched, and saying so is
            # the point: an omitted field would be read as "not busy".
            props["busyPeriods"] = busy_periods_field(editorial)

        # Riders who have actually ridden a road are the only source of truth
        # about whether it belongs here, so their verdict outranks a directory
        # ref match - but only in the direction that adds a road. A negative
        # verdict is recorded and reported, never applied.
        if rating := road_ratings.lookup(ratings, props):
            props["riderRatings"] = {
                "worthIncluding": rating["worthIncluding"],
                "notWorthIncluding": rating["notWorthIncluding"],
                "recommendation": rating["recommendation"],
                "lastRatedOn": rating["lastRatedOn"],
            }
            if rating["recommendation"] == "promote":
                if props["researchStatus"] == "pending":
                    tally["rider-verified"] += 1
                props["researchStatus"] = "researched"
                props["evidenceSources"] = sorted(
                    {*props.get("evidenceSources", []), "tail-end-charlie-riders"}
                )
            elif rating["recommendation"] == "review-for-removal":
                tally["rider-flagged-for-removal"] += 1
                removal_review.append(
                    {
                        "id": props["id"],
                        "sourceFeatureId": props.get("sourceFeatureId"),
                        "name": props["name"],
                        "category": props["category"],
                        **props["riderRatings"],
                    }
                )

        # Rider-facing derived facts, on every surviving candidate.
        props["speedLimit"] = derived["speedLimit"]
        props["averageSpeedCheck"] = derived["averageSpeedCheck"]
        props["fixedSpeedCameras"] = derived["fixedSpeedCameras"]
        if derived.get("locality"):
            props["locality"] = derived["locality"]
        if derived["roadRefs"]:
            props["roadRefs"] = derived["roadRefs"]
        kept.append(feature)

    counts = {}
    for feature in kept:
        counts[feature["properties"]["category"]] = (
            counts.get(feature["properties"]["category"], 0) + 1
        )

    properties = dict(catalogue["properties"])
    properties.update(
        {
            "counts": counts,
            "publicationStatus": "published",
            "enrichedAt": "2026-07-27",
            "evidenceSource": evidence_index.SOURCE,
            "enforcementNote": (
                "Average speed check and camera fields report what OpenStreetMap "
                "records, and each carries a provenance and a note. Absence means "
                "not recorded, not absence of enforcement: OpenStreetMap holds one "
                "average-speed relation for the whole United Kingdom extract, while "
                "the A57 Snake Pass has published average speed camera proposals it "
                "does not record."
            ),
            "speedLimitNote": (
                "Speed limits carry provenance: tagged, inferred-from-maxspeed-type, "
                "or unknown. An unknown limit is not an unrestricted road."
            ),
            "busyPeriodsNote": (
                "busyPeriods carries a provenance of researched or not-researched. "
                "not-researched means nobody has checked, not that the road is quiet."
            ),
            "sourceVerificationNote": (
                "On a researched candidate, sourceVerification is `fetched` when the "
                "cited page was retrieved and the claim read off it, or "
                "`listing-only` when the URL resolves and the claim is limited to "
                "what the listing establishes. motorcycleEvidence `none-found` "
                "records that a search was done and found nothing."
            ),
            "editorialOverlay": {
                "schemaVersion": overlay_document["schemaVersion"],
                "note": (
                    "Researched names, rider notes, motorcycle evidence and busy "
                    "periods come from editorial-overlay.json and are merged here. "
                    "They are re-matched by sourceFeatureId when candidate ids "
                    "change, so a regeneration cannot destroy them."
                ),
                "rematchedBySourceFeatureId": tally["overlay-rematched-by-source-id"],
                "classificationRejections": len(rejections),
            },
        }
    )

    published = {"type": "FeatureCollection", "properties": properties, "features": kept}

    for path in (
        f"{REPO}/apps/mobile/assets/discovery_catalogue.geojson",
        f"{REPO}/apps/website/data/discovery-catalogue.geojson",
    ):
        with open(path, "w") as handle:
            json.dump(published, handle, separators=(",", ":"))
        print(f"wrote {path}")

    if removal_review:
        path = f"{OUT}/rider-removal-review.json"
        with open(path, "w") as handle:
            json.dump({"candidates": removal_review}, handle, indent=1, sort_keys=True)
        print(f"wrote {path}")

    print(f"\npublished {len(kept)} of {len(catalogue['features'])} candidates")
    for key in sorted(tally):
        print(f"  {key:26s} {tally[key]}")
    print(f"\nby category: {counts}")
    if removal_review:
        print(
            f"\n{len(removal_review)} candidate(s) flagged by riders for removal "
            "review; none removed. See rider-removal-review.json."
        )


if __name__ == "__main__":
    main()
