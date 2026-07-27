"""Build the hand-researched editorial overlay for discovery candidates.

Why this is a separate file rather than more columns in the generated catalogue:
`generate_catalogue.py` is reproducible from a checksummed OSM extract, and rerunning
it must be safe. Researched prose cannot be re-derived from the extract, so if it
lived in the generated file the next regeneration would silently destroy it. The
overlay is merged in at generation time instead.

Entries are keyed by candidate id *and* carry their sourceFeatureId, because
candidate ids are content hashes: a new OSM extract can change them, and the
sourceFeatureId is what lets an orphaned entry be re-matched rather than lost.

Nothing in here is inferred. Every riderNote is drawn from the cited sources, and a
candidate that has not been checked says `pending` rather than carrying invented
prose. A ride-planning dataset that guesses is worse than one that admits a gap.
"""

import json
import os

OUT = os.environ.get('DISCOVERY_WORK_DIR', '/private/tmp/discovery-out')

# Research completed 27 July 2026. Keyed by the OSM name in the generated catalogue.
RESEARCHED = {
    'Cairnwell Pass': {
        'name': 'Cairnwell Pass (A93)',
        'riderNote': (
            'At 670 m the highest main road in the UK, carrying the A93 Old Military '
            'Road between Spittal of Glenshee and Braemar past the Glenshee Ski '
            'Centre at the summit. The Devil\'s Elbow double hairpin sits about a '
            'mile south of the top.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Ski-centre traffic in winter and snowgate closures; tourist coaches on '
            'the Snow Roads route in summer.'
        ),
        'sources': [
            'https://en.wikipedia.org/wiki/Cairnwell_Pass',
            'https://www.ordnancesurvey.co.uk/news/highest-and-lowest-roads',
            'https://www.epikdrives.com/best-drives/snow-roads-old-military-road-scotland',
        ],
    },
    'Gospel Pass': {
        'name': 'Gospel Pass',
        'riderNote': (
            'The highest road pass in Wales at 550 m, crossing the Black Mountains '
            'between Hay-on-Wye and Llanthony. Largely single-track with grass down '
            'the middle in places and open sheep grazing.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Heavily used on summer weekends and bank holidays; the single-track '
            'sections back up badly with oncoming cars.'
        ),
        'sources': [
            'https://www.visitwales.com/things-do/adventure-and-activities/five-must-ride-motorbike-routes-wales',
            'https://roadskin.co.uk/blogs/news/wales-on-two-wheels-top-motorcycle-routes-biker-friendly-hangouts',
        ],
    },
    'Bwlch y Groes': {
        'name': 'Bwlch y Groes (Hellfire Pass)',
        'riderNote': (
            'The second highest paved pass in Wales at 546 m, running from '
            'Llanymawddwy to Llanuwchllyn. Known as Hellfire Pass for the sustained '
            'steep climb; it forms part of the Welsh Super 10 route.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': 'Quiet by Welsh-pass standards; busiest on fine summer weekends.',
        'sources': [
            'https://en.wikipedia.org/wiki/Bwlch_y_Groes',
            'https://roadskin.co.uk/blogs/news/wales-on-two-wheels-top-motorcycle-routes-biker-friendly-hangouts',
        ],
    },
    'Snake Pass': {
        'name': 'Snake Pass (A57)',
        'riderNote': (
            'The A57 over the Pennines between Glossop and Ladybower, carrying around '
            '30,000 vehicles a week between Manchester and Sheffield. Repeated '
            'landslips at Doctor\'s Gate, Alport, Gillot Hey and Wood Cottage have '
            'closed it for extended periods, so check it is open before committing.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Commuter-heavy on weekdays and busy with leisure traffic on weekends. '
            'Closures and weight limits recur — verify before setting off.'
        ),
        'enforcementNote': (
            'The Peak District authority has considered average speed cameras here, '
            'and £7.6m of Safer Roads Fund work included motorcyclist-friendly '
            'barriers. OSM does not yet record an enforcement relation.'
        ),
        'sources': [
            'https://www.derbyshire.gov.uk/transport-roads/roads-traffic/landslips/snake-pass/a57-snake-pass.aspx',
            'https://democracy.peakdistrict.gov.uk/documents/s63558/Appendix%201%20A57%20Snake%20Pass%20Average%20Speed%20Camera%20Proposals.pdf',
            'https://www.derbyshiretimes.co.uk/news/transport/a57-snake-pass-busy-derbyshire-a-road-closes-today-for-three-weeks-amid-series-of-landslips-along-challenging-route-8729202',
        ],
    },
    'Hardknott Pass': {
        'name': 'Hardknott Pass',
        'riderNote': (
            'Shares the title of steepest road in Britain at 1 in 3, with 33% '
            'gradients on several hairpins and an undulating surface. Barely one car '
            'wide in places, connecting Eskdale with the Duddon Valley.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Avoid summer weekends — much of it is single track and it jams with '
            'cars and cyclists. A weekday is a different road.'
        ),
        'sources': [
            'https://www.adventurebikerider.com/abrs-weekend-ride-the-challenging-hardknott-pass/',
            'https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/wrynose-pass-hardknott-pass-eskdale-green-little-langdale',
        ],
    },
    'Wrynose Pass': {
        'name': 'Wrynose Pass',
        'riderNote': (
            'Three miles of narrow, steep pass linking Little Langdale towards the '
            'Duddon Valley, almost always ridden as a pair with Hardknott. Sharp '
            'hairpins with 1 in 3 and 1 in 4 sections.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': 'Same as Hardknott — congested on spring and summer weekends.',
        'sources': [
            'https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/wrynose-pass-hardknott-pass-eskdale-green-little-langdale',
            'https://motorcycletourer.com/most-scenic-motorcycle-roads-uk/',
        ],
    },
    'Kirkstone Pass': {
        'name': 'Kirkstone Pass (A592)',
        'riderNote': (
            'At 454 m the highest Lake District pass with a road over it, carrying '
            'the A592 from Ambleside to Patterdale and Ullswater. The Ambleside '
            'climb is known locally as The Struggle and approaches 1 in 4.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': 'Busy with Lake District tourist traffic through the summer.',
        'sources': [
            'https://en.wikipedia.org/wiki/Kirkstone_Pass',
            'https://www.visitcumbria.com/amb/kirkstone-pass/',
            'https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/a592-kirkstone-pass-windermere-penrith',
        ],
    },
    'Horseshoe Pass': {
        'name': 'Horseshoe Pass (A542)',
        'riderNote': (
            'The A542 between Llangollen and Llandegla, topping out at 417 m. The '
            'Ponderosa café at the summit is one of the best-known biker meeting '
            'points in north Wales.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Very busy with bikes on fine weekends, which is the appeal and also the '
            'risk — expect oncoming riders using the whole road.'
        ),
        'sources': [
            'https://en.wikipedia.org/wiki/Horseshoe_Pass',
            'https://www.devittinsurance.com/guides/biker-cafes/wales/ponderosa-cafe/',
            'https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-wales/ride/a542-horseshoe-pass-llangollen-llandegla',
        ],
    },
    'Buttertubs Pass': {
        'name': 'Buttertubs Pass',
        'riderNote': (
            'Roughly 5.3 miles of open moorland road between Hawes and Thwaite in '
            'the Yorkshire Dales, named for the limestone potholes near the summit '
            'that resemble butter churns.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': 'Popular on summer weekends; unfenced with livestock on the road.',
        'sources': [
            'https://motorcycletourer.com/most-scenic-motorcycle-roads-uk/',
            'https://www.bennetts.co.uk/bikesocial/news-and-views/features/travel/what-are-the-best-motorcycle-routes-in-the-uk',
        ],
    },
    'Mam Ratagan': {
        'name': 'Mam Ratagan',
        'riderNote': (
            'Climbs to around 335 m on the single-track road from Shiel Bridge to '
            'Glenelg, with a series of hairpins and a long drop down Glen More to sea '
            'level. Often ridden with the Glenelg–Skye ferry and Bealach Udal.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': (
            'Ferry traffic in season; the ferry runs summer only, so plan the link '
            'to Skye around it.'
        ),
        'sources': [
            'https://www.madornomad.com/the-best-motorcycle-routes-in-scotland/',
            'https://www.undiscoveredscotland.co.uk/glenelg/glenelg/index.html',
        ],
    },
    'Bealach Udal': {
        'name': 'Bealach Udal',
        'riderNote': (
            'The steep pass on the Kylerhea road on Skye, reached from the Glenelg '
            'ferry. Ranked the fifth hardest climb in Scotland by Simon Warren, it is '
            'narrow with passing places rather than a two-lane pass.'
        ),
        'motorcycleEvidence': 'established',
        'busyPeriods': 'Tied to the seasonal Glenelg ferry; otherwise lightly used.',
        'sources': [
            'https://pjammcycling.com/climb/5527.Bealach-Udal',
            'https://www.madornomad.com/the-best-motorcycle-routes-in-scotland/',
        ],
    },
}

# The unnamed mountain_pass=yes nodes, resolved against the roads that actually
# cross them. None of these is a mountain pass in any sense a rider would accept;
# the generator inherited OpenStreetMap's habit of tagging any local hill saddle.
# Renaming them would dress up a classification error, so each gets a verdict.
RECLASSIFY = {
    'node/732132339': {
        'verdict': 'reject',
        'reason': (
            'Glasnakille Road (U4838), a dead-end single-track lane on Skye at 100 m. '
            'Not a pass, and it leads nowhere a group ride would route through.'
        ),
    },
    'node/2308216337': {
        'verdict': 'reclassify-good-biking-road',
        'name': 'A4113 Mocktree Turnpike',
        'riderNote': (
            'A hill crossing on the A4113 between Ludlow and Knighton, at 242 m on '
            'the Shropshire/Herefordshire border. Worth riding, but not a pass.'
        ),
        'reason': (
            'A4113 Mocktree Turnpike at 242 m on the Shropshire/Herefordshire border. '
            'A genuinely good A-road hill crossing, but not a mountain pass.'
        ),
    },
    'node/2308216342': {
        'verdict': 'reject',
        'reason': (
            'Unclassified lane (LX24A) near Shelderton at 278 m, with only tracks and '
            'footways around it. Too minor to offer as a destination road.'
        ),
    },
    'node/280187024': {
        'verdict': 'reclassify-good-biking-road',
        'name': 'A928 over Finlarg Hill',
        'riderNote': (
            'A 261 m crossing of Finlarg Hill on the A928 in Angus, north of Dundee. '
            'A reasonable moorland-edge road rather than a pass.'
        ),
        'reason': (
            'A928 hill crossing in Angus at 261 m. A reasonable road, not a pass.'
        ),
    },
    'node/271799539': {
        'verdict': 'reclassify-good-biking-road',
        'name': 'A859 at Bun Abhainn Eadarra',
        'riderNote': (
            'On the A859, the spine road of Harris, at Bun Abhainn Eadarra where the '
            'B897 branches off. Genuinely worth riding for the landscape; not a '
            'named pass.'
        ),
        'reason': (
            'A859/B897 on Harris at Bun Abhainn Eadarra. The Harris spine road is '
            'well worth riding, but this point is not a named pass.'
        ),
    },
    'node/8500938038': {
        'verdict': 'reclassify-good-biking-road',
        'name': 'B9120 over the Hill of Garvock',
        'riderNote': (
            'The B9120 crossing the Hill of Garvock in Aberdeenshire, an asphalt '
            'secondary road at 60 mph. A pleasant ride; the summit is not a pass.'
        ),
        'reason': (
            'B9120 over the Hill of Garvock, Aberdeenshire. A pleasant secondary '
            'road; the summit is not a pass.'
        ),
    },
    'node/33624619': {
        'verdict': 'reject',
        'reason': (
            'Bonchurch/Cowleaze Hill on the Isle of Wight at 152 m, off the A3055. '
            'Offering this as a mountain pass would discredit the whole layer.'
        ),
    },
    'node/3906229915': {
        'verdict': 'reject',
        'reason': (
            'A927/B954 near Hatton, Angus, at 147 m. An ordinary rural junction '
            'area with no pass character.'
        ),
    },
}


def main():
    catalogue = json.load(open(f'{OUT}/discovery-catalogue.geojson'))
    passes = [
        f
        for f in catalogue['features']
        if f['properties']['category'] == 'mountain_pass'
    ]

    entries = {}
    counts = {'researched': 0, 'pending': 0, 'reject': 0, 'reclassify': 0}

    for feature in passes:
        props = feature['properties']
        source_id = props['sourceFeatureId']
        entry = {'sourceFeatureId': source_id, 'category': props['category']}

        if source_id in RECLASSIFY:
            entry.update(RECLASSIFY[source_id])
            entry['researchStatus'] = 'classification-rejected'
            counts['reject' if entry['verdict'] == 'reject' else 'reclassify'] += 1
        elif props['name'] in RESEARCHED:
            entry.update(RESEARCHED[props['name']])
            entry['researchStatus'] = 'researched'
            entry['researchedOn'] = '2026-07-27'
            counts['researched'] += 1
        else:
            entry['researchStatus'] = 'pending'
            entry['name'] = props['name']
            counts['pending'] += 1

        entries[props['id']] = entry

    overlay = {
        'schemaVersion': 1,
        'catalogueVersion': catalogue['properties']['catalogueVersion'],
        'note': (
            'Hand-researched editorial content. Merged into the generated catalogue '
            'at build time; never written by the generator. Entries are re-matched '
            'by sourceFeatureId if candidate ids change.'
        ),
        'entries': entries,
    }
    json.dump(overlay, open(f'{OUT}/editorial-overlay.json', 'w'), indent=1)

    print(f'overlay entries: {len(entries)}')
    for key, value in counts.items():
        print(f'  {key:14s} {value}')

    missing = set(RESEARCHED) - {f['properties']['name'] for f in passes}
    if missing:
        print(f'\nWARNING research written for names not in catalogue: {sorted(missing)}')


if __name__ == '__main__':
    main()
