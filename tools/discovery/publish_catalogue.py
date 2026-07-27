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
"""

import json
import os
import pathlib

import evidence_index

OUT = os.environ.get('DISCOVERY_WORK_DIR', '/private/tmp/discovery-out')
REPO = os.environ.get('DISCOVERY_REPO', str(pathlib.Path(__file__).resolve().parents[2]))

# An anonymous candidate has to earn its place on geometry alone.
MIN_ANON_LENGTH_KM = 3.0
MIN_ANON_BENDS = 90.0


CLASS_WORDS = {
    'primary': 'A-road',
    'secondary': 'B-road',
    'tertiary': 'Minor road',
    'unclassified': 'Unclassified road',
    'residential': 'Residential road',
}


def road_name(derived, used):
    """Name a road candidate so that no two are indistinguishable in a list.

    A road number alone is not enough: the B6012 appears as five separate
    candidates, and five identical rows in a planner are useless. Localities
    disambiguate; a counter is the last resort.
    """
    locality = (derived.get('locality') or {}).get('name')

    if derived['roadRefs']:
        base = '/'.join(derived['roadRefs'][:2])
    elif derived['roadNames']:
        base = derived['roadNames'][0]
    else:
        classes = derived['roadClasses']
        word = CLASS_WORDS.get(classes[0] if classes else '', 'Road')
        base = f'{word} near {locality}' if locality else f'{word} (unnamed)'

    candidate = base
    if candidate in used and locality and f'near {locality}' not in candidate:
        candidate = f'{base} near {locality}'
    if candidate in used:
        used[candidate] += 1
        return f'{candidate} ({used[candidate]})'
    used[candidate] = 1
    return candidate


def summit_name(name, used):
    """Disambiguate a pass summit from the road of the same name."""
    if name not in used:
        used[name] = 1
        return name
    summit = f'{name} (summit)'
    if summit not in used:
        used[summit] = 1
        return summit
    used[summit] += 1
    return f'{name} (summit {used[summit]})'


def describe_pass(props, derived):
    """Compose a factual note for a pass whose research is still outstanding."""
    parts = [props['name']]
    locality = (derived.get('locality') or {}).get('name')
    if locality:
        parts[0] += f', near {locality}'
    elevation = props.get('sourceElevation')
    sentence = parts[0]
    if elevation:
        sentence += f', mapped at {elevation} m'
    sentence += '.'
    peak = derived.get('nearestPeak') or {}
    if peak.get('name'):
        sentence += f' Nearest summit is {peak["name"]}'
        if peak.get('elevation'):
            sentence += f' at {peak["elevation"]} m'
        sentence += '.'
    sentence += ' Not yet cross-checked against motorcycle route sources.'
    return sentence


def describe(props, derived, evidence):
    """One or two sentences, built only from facts we hold."""
    components = props.get('scoreComponents') or {}
    refs = derived['roadRefs']
    names = derived['roadNames']
    locality = (derived.get('locality') or {}).get('name')
    length = components.get('lengthKm')
    bends = components.get('bendDegreesPerKm')

    if refs:
        subject = '/'.join(refs[:2])
    elif names:
        subject = names[0]
    else:
        subject = 'An unclassified road'

    opening = subject
    if locality:
        opening += f' near {locality}'
    parts = []
    if length:
        parts.append(f'{length:.1f} km')
    if bends:
        parts.append(f'{bends:.0f}° of bend per km')
    if parts:
        opening += ', ' + ' with '.join(parts)
    sentence = opening + '.'

    tail = []
    limit = derived['speedLimit']
    if limit['value']:
        qualifier = '' if limit['provenance'] == 'tagged' else ' (implied by a national limit tag)'
        if limit.get('mixed'):
            low, high = limit['range']
            tail.append(f'Limit varies from {low} to {high}')
        else:
            tail.append(f'Limit {limit["value"]}{qualifier}')
    else:
        tail.append('No speed limit is mapped')

    if derived['averageSpeedCheck'].get('present'):
        tail.append('an average speed check covers part of it')
    elif derived['fixedSpeedCameras']:
        count = derived['fixedSpeedCameras']
        tail.append(f'{count} fixed speed camera{"s" if count > 1 else ""} nearby')

    if evidence:
        routes = '; '.join(evidence['routes'][:2])
        tail.append(f'listed as a motorcycle road ({routes})')

    if tail:
        sentence += ' ' + tail[0]
        if len(tail) > 1:
            sentence += ', ' + ', '.join(tail[1:])
        sentence += '.'
    return sentence


def main():
    index = evidence_index.build()
    catalogue = json.load(open(f'{OUT}/discovery-catalogue.geojson'))
    derived_all = json.load(open(f'{OUT}/enrichment-deterministic.json'))
    overlay = json.load(open(f'{OUT}/editorial-overlay.json'))['entries']

    # A pass summit node and the road that crosses it often share an OSM name, so
    # register the road names first. The pass then resolves to "<name> (summit)"
    # rather than presenting a planner with two identical rows.
    used_names = {}
    for feature in catalogue['features']:
        props = feature['properties']
        if props['category'] == 'mountain_pass':
            continue
        names = derived_all[props['id']]['roadNames']
        if names:
            used_names.setdefault(names[0], 1)

    kept, tally = [], {
        'researched': 0,
        'pending': 0,
        'discarded-anonymous': 0,
        'pass-researched': 0,
        'pass-pending': 0,
        'pass-rejected': 0,
        'pass-reclassified': 0,
    }

    for feature in catalogue['features']:
        props = feature['properties']
        derived = derived_all[props['id']]
        is_pass = props['category'] == 'mountain_pass'

        if is_pass:
            editorial = overlay[props['id']]
            status = editorial['researchStatus']
            if status == 'classification-rejected':
                if editorial['verdict'] == 'reject':
                    tally['pass-rejected'] += 1
                    continue
                # Reclassified: it is a road, not a pass. Keep it in the road layer.
                # The name has to come from the overlay: these candidates are pass
                # *nodes*, so they carry no way refs of their own to fall back on,
                # and falling back would keep the placeholder name verbatim.
                props['category'] = 'good_biking_road'
                props['name'] = editorial['name']
                props['riderNote'] = editorial['riderNote']
                props['researchStatus'] = 'researched'
                props['reclassifiedFrom'] = 'mountain_pass'
                props['reclassificationReason'] = editorial['reason']
                tally['pass-reclassified'] += 1
            elif status == 'researched':
                props['name'] = summit_name(editorial['name'], used_names)
                props['riderNote'] = editorial['riderNote']
                props['busyPeriods'] = editorial.get('busyPeriods')
                if editorial.get('enforcementNote'):
                    props['enforcementNote'] = editorial['enforcementNote']
                props['evidenceSources'] = editorial['sources']
                props['researchStatus'] = 'researched'
                tally['pass-researched'] += 1
            else:
                props['researchStatus'] = 'pending'
                props['riderNote'] = describe_pass(props, derived)
                props['name'] = summit_name(props['name'], used_names)
                tally['pass-pending'] += 1
        else:
            evidence = next(
                (index[r] for r in derived['roadRefs'] if r in index), None
            )
            has_identity = bool(derived['roadRefs'] or derived['roadNames'])

            if not evidence and not has_identity:
                components = props.get('scoreComponents') or {}
                length = components.get('lengthKm') or 0
                bends = components.get('bendDegreesPerKm') or 0
                if length < MIN_ANON_LENGTH_KM or bends < MIN_ANON_BENDS:
                    tally['discarded-anonymous'] += 1
                    continue

            if evidence:
                props['researchStatus'] = 'researched'
                props['evidenceSources'] = [evidence['source']]
                props['listedRoutes'] = evidence['routes']
                tally['researched'] += 1
            else:
                props['researchStatus'] = 'pending'
                tally['pending'] += 1

            props['name'] = road_name(derived, used_names)

            props['riderNote'] = describe(props, derived, evidence)

        # Rider-facing derived facts, on every surviving candidate.
        props['speedLimit'] = derived['speedLimit']
        props['averageSpeedCheck'] = derived['averageSpeedCheck']
        props['fixedSpeedCameras'] = derived['fixedSpeedCameras']
        if derived.get('locality'):
            props['locality'] = derived['locality']
        if derived['roadRefs']:
            props['roadRefs'] = derived['roadRefs']
        kept.append(feature)

    counts = {}
    for feature in kept:
        counts[feature['properties']['category']] = (
            counts.get(feature['properties']['category'], 0) + 1
        )

    properties = dict(catalogue['properties'])
    properties.update(
        {
            'counts': counts,
            'publicationStatus': 'published',
            'enrichedAt': '2026-07-27',
            'evidenceSource': evidence_index.SOURCE,
            'enforcementNote': (
                'Average speed check and camera fields report what OpenStreetMap '
                'records. Absence means not recorded, not absence of enforcement.'
            ),
            'speedLimitNote': (
                'Speed limits carry provenance: tagged, inferred-from-maxspeed-type, '
                'or unknown. An unknown limit is not an unrestricted road.'
            ),
        }
    )

    published = {'type': 'FeatureCollection', 'properties': properties, 'features': kept}

    for path in (
        f'{REPO}/apps/mobile/assets/discovery_catalogue.geojson',
        f'{REPO}/apps/website/data/discovery-catalogue.geojson',
    ):
        with open(path, 'w') as handle:
            json.dump(published, handle, separators=(',', ':'))
        print(f'wrote {path}')

    print(f'\npublished {len(kept)} of {len(catalogue["features"])} candidates')
    for key in sorted(tally):
        print(f'  {key:24s} {tally[key]}')
    print(f'\nby category: {counts}')


if __name__ == '__main__':
    main()
