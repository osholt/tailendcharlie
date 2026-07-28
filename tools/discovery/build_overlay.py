"""Build the hand-researched editorial overlay for discovery candidates.

Why this is a separate file rather than more columns in the generated catalogue:
`generate_catalogue.py` is reproducible from a checksummed OSM extract, and rerunning
it must be safe. Researched prose cannot be re-derived from the extract, so if it
lived in the generated file the next regeneration would silently destroy it. The
overlay is merged in at generation time instead.

Entries are keyed by candidate id *and* carry their sourceFeatureId, because
candidate ids are content hashes: a new OSM extract can change them, and the
sourceFeatureId is what lets an orphaned entry be re-matched rather than lost.

Nothing in here is inferred. Every claim is traceable to a URL in `sources`, and a
candidate nobody has checked says `pending` rather than carrying invented prose. A
ride-planning dataset that guesses is worse than one that admits a gap.

How the research was verified
-----------------------------
Every pass node, and the way that carries the road across it, was re-queried from the
Overpass API on 28 July 2026. The road number, road name, mapped speed limit, surface
and lane count in each entry are therefore checked facts.

Editorial claims are graded, because the grade changes how much weight a rider should
give them:

  `sourceVerification: "fetched"`      the cited page was retrieved and the claim
                                       read off it
  `sourceVerification: "listing-only"` the page exists at this URL and the claim is
                                       limited to what the listing itself
                                       establishes - that a directory lists the road,
                                       not what its reviewers said about it

Two claims were dropped during verification rather than published:

  - a widely-repeated line calling the Slaidburn-Bentham fell road "a cyclist and
    motorcyclist's dream ride" appears on no page that could be retrieved, so Bowland
    Knotts and Cross o' Greet record no motorcycle evidence;
  - the A923 enforcement note was going to describe a fixed 60 mph camera. Police
    Scotland's own page says the route is a *mobile* camera route at national speed
    limit. Tullybaccart says that instead.

`motorcycleEvidence` vocabulary:

  `established`               a motorcycle-specific source names this road or pass
  `driving-roads-directory`   an enthusiast driving-roads source lists it, but no
                              motorcycle-specific source was found
  `none-found`                searched on 27-28 July 2026 and nothing was found. A
                              recorded outcome, not a gap to be filled with
                              plausible prose later.
"""

import json
import os

OUT = os.environ.get("DISCOVERY_WORK_DIR", "/private/tmp/discovery-out")

RESEARCHED_ON = "2026-07-28"

OSM_NODE = "https://www.openstreetmap.org/node"
OSM_WAY = "https://www.openstreetmap.org/way"

# `crossingRoad.speedLimit` is what the way carried when it was read, with the way URL
# to re-check it. It deliberately does *not* restate OpenStreetMap's tag provenance
# (`tagged` versus `inferred-from-maxspeed-type`): the derived `speedLimit` field owns
# that, computed from the same extract, and duplicating it by hand had already drifted
# on 17 of 31 entries - a maxspeed=60 mph way written up as merely implied. One owner
# per fact.
OBSERVED_ON = "2026-07-28"

MYROUTEAPP_LAKES = (
    "https://www.myrouteapp.com/en/motore-e-auto-rotte/gb/North-West/1546798/"
    "The-Lake-District-Passes-Clockwise"
)
BOWLAND_HILLCLIMBS = "https://www.discoverbowland.uk/itinerary/classic-bowland-hillclimbs/"
LAKES_BUSY = (
    "https://www.timesandstar.co.uk/news/26291603.lake-district-braces-busiest-weekend-four-years/"
)
BOWLAND_SINGLE_TRACK = (
    "Discover Bowland describes both eastern Bowland fell roads as effectively "
    "single track for much of their length across quiet moorland."
)
LAKES_SUMMER = "Lake District leisure traffic peaks on summer weekends and school holidays."

# Keyed by the OSM name in the generated catalogue. `crossingRoad` is the way the
# summit node is a vertex of, read from Overpass on 28 July 2026; its `sourceUrl` is
# that way, so a reader can re-check the limit rather than trust this file.
RESEARCHED = {
    # --- researched 27 July 2026; left as the maintainer approved them --------
    "Cairnwell Pass": {
        "name": "Cairnwell Pass (A93)",
        "riderNote": (
            "At 670 m the highest main road in the UK, carrying the A93 Old Military "
            "Road between Spittal of Glenshee and Braemar past the Glenshee Ski "
            "Centre at the summit. The Devil's Elbow double hairpin sits about a "
            "mile south of the top."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Ski-centre traffic in winter and snowgate closures; tourist coaches on "
            "the Snow Roads route in summer."
        ),
        "sources": [
            "https://en.wikipedia.org/wiki/Cairnwell_Pass",
            "https://www.ordnancesurvey.co.uk/news/highest-and-lowest-roads",
            "https://www.epikdrives.com/best-drives/snow-roads-old-military-road-scotland",
        ],
        "sourceVerification": "listing-only",
    },
    "Gospel Pass": {
        "name": "Gospel Pass",
        "riderNote": (
            "The highest road pass in Wales at 550 m, crossing the Black Mountains "
            "between Hay-on-Wye and Llanthony. Largely single-track with grass down "
            "the middle in places and open sheep grazing."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Heavily used on summer weekends and bank holidays; the single-track "
            "sections back up badly with oncoming cars."
        ),
        "sources": [
            "https://www.visitwales.com/things-do/adventure-and-activities/five-must-ride-motorbike-routes-wales",
            "https://roadskin.co.uk/blogs/news/wales-on-two-wheels-top-motorcycle-routes-biker-friendly-hangouts",
        ],
        "sourceVerification": "listing-only",
    },
    "Bwlch y Groes": {
        "name": "Bwlch y Groes (Hellfire Pass)",
        "riderNote": (
            "The second highest paved pass in Wales at 546 m, running from "
            "Llanymawddwy to Llanuwchllyn. Known as Hellfire Pass for the sustained "
            "steep climb; it forms part of the Welsh Super 10 route."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": "Quiet by Welsh-pass standards; busiest on fine summer weekends.",
        "sources": [
            "https://en.wikipedia.org/wiki/Bwlch_y_Groes",
            "https://roadskin.co.uk/blogs/news/wales-on-two-wheels-top-motorcycle-routes-biker-friendly-hangouts",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/138142001",
        },
    },
    "Snake Pass": {
        "name": "Snake Pass (A57)",
        "riderNote": (
            "The A57 over the Pennines between Glossop and Ladybower, carrying around "
            "30,000 vehicles a week between Manchester and Sheffield. Repeated "
            "landslips at Doctor's Gate, Alport, Gillot Hey and Wood Cottage have "
            "closed it for extended periods, so check it is open before committing."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Commuter-heavy on weekdays and busy with leisure traffic on weekends. "
            "Closures and weight limits recur - verify before setting off."
        ),
        "enforcementNote": (
            "The Peak District authority has considered average speed cameras here, "
            "and £7.6m of Safer Roads Fund work included motorcyclist-friendly "
            "barriers. OSM does not yet record an enforcement relation."
        ),
        "sources": [
            "https://www.derbyshire.gov.uk/transport-roads/roads-traffic/landslips/snake-pass/a57-snake-pass.aspx",
            "https://democracy.peakdistrict.gov.uk/documents/s63558/Appendix%201%20A57%20Snake%20Pass%20Average%20Speed%20Camera%20Proposals.pdf",
            "https://www.derbyshiretimes.co.uk/news/transport/a57-snake-pass-busy-derbyshire-a-road-closes-today-for-three-weeks-amid-series-of-landslips-along-challenging-route-8729202",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "ref": "A57",
            "speedLimit": "50 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/4340120",
        },
    },
    "Hardknott Pass": {
        "name": "Hardknott Pass",
        "riderNote": (
            "Shares the title of steepest road in Britain at 1 in 3, with 33% "
            "gradients on several hairpins and an undulating surface. Barely one car "
            "wide in places, connecting Eskdale with the Duddon Valley."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Avoid summer weekends - much of it is single track and it jams with "
            "cars and cyclists. A weekday is a different road."
        ),
        "sources": [
            "https://www.adventurebikerider.com/abrs-weekend-ride-the-challenging-hardknott-pass/",
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/wrynose-pass-hardknott-pass-eskdale-green-little-langdale",
            MYROUTEAPP_LAKES,
        ],
        "sourceVerification": "fetched",
    },
    "Wrynose Pass": {
        "name": "Wrynose Pass",
        "riderNote": (
            "Three miles of narrow, steep pass linking Little Langdale towards the "
            "Duddon Valley, almost always ridden as a pair with Hardknott. Sharp "
            "hairpins with 1 in 3 and 1 in 4 sections."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": "Same as Hardknott - congested on spring and summer weekends.",
        "sources": [
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/wrynose-pass-hardknott-pass-eskdale-green-little-langdale",
            MYROUTEAPP_LAKES,
        ],
        "sourceVerification": "fetched",
    },
    "Kirkstone Pass": {
        "name": "Kirkstone Pass (A592)",
        "riderNote": (
            "At 454 m the highest Lake District pass with a road over it, carrying "
            "the A592 from Ambleside to Patterdale and Ullswater. The Ambleside "
            "climb is known locally as The Struggle and approaches 1 in 4."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": "Busy with Lake District tourist traffic through the summer.",
        "sources": [
            "https://en.wikipedia.org/wiki/Kirkstone_Pass",
            "https://www.visitcumbria.com/amb/kirkstone-pass/",
            MYROUTEAPP_LAKES,
        ],
        "sourceVerification": "fetched",
    },
    "Horseshoe Pass": {
        "name": "Horseshoe Pass (A542)",
        "riderNote": (
            "The A542 between Llangollen and Llandegla, topping out at 417 m. The "
            "Ponderosa café at the summit is one of the best-known biker meeting "
            "points in north Wales."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Very busy with bikes on fine weekends, which is the appeal and also the "
            "risk - expect oncoming riders using the whole road."
        ),
        "sources": [
            "https://en.wikipedia.org/wiki/Horseshoe_Pass",
            "https://www.devittinsurance.com/guides/biker-cafes/wales/ponderosa-cafe/",
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-wales/ride/a542-horseshoe-pass-llangollen-llandegla",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "ref": "A542",
            "speedLimit": "40 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/103415950",
        },
    },
    "Buttertubs Pass": {
        "name": "Buttertubs Pass",
        "riderNote": (
            "Roughly 5.3 miles of open moorland road between Hawes and Thwaite in "
            "the Yorkshire Dales, named for the limestone potholes near the summit "
            "that resemble butter churns."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": "Popular on summer weekends; unfenced with livestock on the road.",
        "sources": [
            "https://www.bennetts.co.uk/bikesocial/news-and-views/features/travel/what-are-the-best-motorcycle-routes-in-the-uk",
            "https://www.adventurebikerider.com/article/the-best-of-the-yorkshire-dales/",
        ],
        "sourceVerification": "listing-only",
    },
    "Mam Ratagan": {
        "name": "Mam Ratagan",
        "riderNote": (
            "Climbs to around 335 m on the single-track road from Shiel Bridge to "
            "Glenelg, with a series of hairpins and a long drop down Glen More to sea "
            "level. Often ridden with the Glenelg-Skye ferry and Bealach Udal."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Ferry traffic in season; the ferry runs summer only, so plan the link "
            "to Skye around it."
        ),
        "sources": [
            "https://www.madornomad.com/the-best-motorcycle-routes-in-scotland/",
            "https://www.undiscoveredscotland.co.uk/glenelg/glenelg/index.html",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/48715690",
        },
    },
    "Bealach Udal": {
        "name": "Bealach Udal",
        "riderNote": (
            "The steep pass on the Kylerhea road on Skye, reached from the Glenelg "
            "ferry. Ranked the fifth hardest climb in Scotland by Simon Warren, it is "
            "narrow with passing places rather than a two-lane pass."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": "Tied to the seasonal Glenelg ferry; otherwise lightly used.",
        "sources": [
            "https://pjammcycling.com/climb/5527.Bealach-Udal",
            "https://www.madornomad.com/the-best-motorcycle-routes-in-scotland/",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/294908496",
        },
    },
    # --- researched for issue #158, 27-28 July 2026 --------------------------
    "Honister Pass": {
        "name": "Honister Pass (B5289)",
        "riderNote": (
            "The B5289 over Honister at 356 m, joining Seatoller in Borrowdale to "
            "Gatesgarth at the foot of Buttermere, with gradients reaching 1 in 4. "
            "One of the six passes on MyRoute-app's Lake District motorcycle loop."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Peak holiday season is heavy between the Honister slate mine and "
            "Seatoller, and Cumberland Council has imposed emergency speed and "
            f"weight restrictions here after culvert damage. {LAKES_SUMMER}"
        ),
        "sources": [
            "https://en.wikipedia.org/wiki/Honister_Pass",
            MYROUTEAPP_LAKES,
            "https://keswickreminder.co.uk/2024/08/02/emergency-traffic-restrictions-on-honister-pass/",
            LAKES_BUSY,
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "B5289",
            "name": "Honister Pass",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/149710348",
        },
    },
    "Newlands Pass": {
        "name": "Newlands Pass (Newlands Hause)",
        "riderNote": (
            "Mapped at 333 m on the unclassified road between Buttermere and "
            "Braithwaite, also known as Newlands Hause. OpenStreetMap records it as "
            "roughly a lane and a half wide, and the Buttermere side carries the "
            "steepest ramps of the northern Lakes passes."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": f"{LAKES_SUMMER} A lane-and-a-half road does not absorb it.",
        "sources": [
            "https://en.wikipedia.org/wiki/Newlands_Pass",
            MYROUTEAPP_LAKES,
            "https://stillbiking.com/rides/north-lake-district/",
            LAKES_BUSY,
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Newlands Pass",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1.5",
            "sourceUrl": f"{OSM_WAY}/585193029",
        },
    },
    "Whinlatter Pass": {
        "name": "Whinlatter Pass (B5292)",
        "riderNote": (
            "The B5292 between Braithwaite and Lorton, the northernmost of the Lake "
            "District passes and the only one with a forest visitor centre on it. "
            "Two lanes throughout, which makes it the gentlest of the group."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Whinlatter Forest's visitor centre sits on the pass, so it carries "
            "family and visitor traffic through the day in season."
        ),
        "sources": [
            "https://en.wikipedia.org/wiki/Whinlatter_Pass",
            MYROUTEAPP_LAKES,
            "https://stillbiking.com/rides/north-lake-district/",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "B5292",
            "name": "Whinlatter Pass",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/36858155",
        },
    },
    "Cairn O' Mount Pass": {
        "name": "Cairn o' Mount (B974)",
        "riderNote": (
            "The B974 Old Military Road over Cairn o' Mount at 454 m, between "
            "Fettercairn and Banchory. Simon Weir ranks the Banchory-to-Fettercairn "
            "run eighth among Scotland's ten best biking roads, describing mile "
            "after quiet mile across the hills."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Snow gates shut this road early and reopen it late - Undiscovered "
            "Scotland describes it as often the first road closed by snow and the "
            "last to reopen, and Traffic Scotland posts the gate status. Check "
            "before committing in winter."
        ),
        "sources": [
            "https://www.simonweir.co.uk/post/the-ten-best-biking-roads-in-scotland",
            "https://en.wikipedia.org/wiki/Cairn_o%27_Mount",
            "https://www.undiscoveredscotland.co.uk/fettercairn/cairnomount/index.html",
            "https://www.pressandjournal.co.uk/fp/news/transport/2779309/snow-gates-closed-on-b974-as-adverse-weather-hits/",
            "https://www.aberdeenshire.gov.uk/roads-and-travel/roads/winter-maintenance/snow-clearing",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "B974",
            "name": "Old Military Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/360775717",
        },
    },
    "Clay Bank Top": {
        "name": "Clay Bank Top (B1257)",
        "riderNote": (
            "The 268 m summit of the B1257 Stokesley-to-Helmsley road, known to "
            "riders as the Yorkshire TT, dropping off the moor edge down Clay Bank "
            "past Chop Gate. BestBikingRoads rates the road 4.1 out of 5 overall and "
            "4.6 for corners."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "Busier at weekends. BestBikingRoads reviewers report a consistent "
            "police presence and frequent crashes on sunny summer weekends, and "
            "recommend riding it midweek."
        ),
        "enforcementNote": (
            "BestBikingRoads reviewers describe a regular police presence on summer "
            "weekends. OpenStreetMap records no camera or enforcement relation here, "
            "which is a gap in the map rather than an absence of enforcement."
        ),
        "sources": [
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/yorkshire/ride/b1257-stokesley-helmsley-north-yorks-tt",
            "https://www.mslmagazine.co.uk/top-roads-north-york-moors/",
            "https://www.sabre-roads.org.uk/wiki/B1257",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "B1257",
            "name": "Clay Bank",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/569948220",
        },
    },
    "Clee Hill Pass": {
        "name": "Clee Hill (A4117)",
        "riderNote": (
            "The A4117 crossing Clee Hill at 381 m between Ludlow and Cleobury "
            "Mortimer - a long drag up and over, with views across Shropshire from "
            "the top. BestBikingRoads rates it 3 out of 5 overall, 4 for both "
            "corners and scenery."
        ),
        "motorcycleEvidence": "established",
        "enforcementNote": (
            "BestBikingRoads reviewers score police presence 3 out of 5 on this "
            "road. OpenStreetMap records no camera or enforcement relation here."
        ),
        "sources": [
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/west-midlands/ride/a4117-clee-hill-cleobury-mortimer",
            "https://en.wikipedia.org/wiki/A4117_road",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "A4117",
            "name": "Ludlow Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/1332050139",
        },
    },
    "Pen-y-Pass": {
        "name": "Pen-y-Pass (A4086)",
        "riderNote": (
            "The 359 m summit of the Llanberis Pass, where the A4086 runs between "
            "the Glyderau and the Snowdon massif from Capel Curig to Llanberis. Two "
            "lanes at the national limit, and the busiest mountain road in Eryri."
        ),
        "motorcycleEvidence": "established",
        "busyPeriods": (
            "The Pen-y-Pass car park is often full before 8am on weekends and busy "
            "summer days, and busy weekends are booked out weeks ahead - expect "
            "queueing and drivers hunting for parking on the pass itself from early "
            "morning through the season."
        ),
        "sources": [
            "https://en.wikipedia.org/wiki/Llanberis_Pass",
            "https://snowdonexperts.uk/snowdon-parking-at-pen-y-pass/",
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-wales/ride/a4086-capel-curig-llanrug-caernarfon",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "A4086",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/305470121",
        },
    },
    "Trough of Bowland": {
        "name": "Trough of Bowland (Trough Road)",
        "riderNote": (
            "The single-track Trough Road through the Trough of Bowland, the classic "
            "crossing between Dunsop Bridge and the headwaters of the Wyre, with a "
            "short steep pull through Sykes. BestBikingRoads carries a 68 km route "
            "through it rated 4 out of 5."
        ),
        "motorcycleEvidence": "established",
        "sources": [
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/north-west-england/ride/prestwich-trough-of-bowland-lancaster",
            BOWLAND_HILLCLIMBS,
            "https://en.wikipedia.org/wiki/Trough_of_Bowland",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Trough Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1",
            "sourceUrl": f"{OSM_WAY}/22966699",
        },
    },
    "Kidstones Pass": {
        "name": "Kidstones Pass (B6160)",
        "riderNote": (
            "The B6160 over Kidstones Bank at 425 m, between Bishopdale and Cray at "
            "the head of Wharfedale. OpenStreetMap records the south-western climb as "
            "2.9 km and 185 m of ascent, 10% at the start and up to 20% higher up. "
            "BestBikingRoads lists the B6160 as a motorcycle road."
        ),
        "motorcycleEvidence": "established",
        "sources": [
            "https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/yorkshire/ride/b6160-bolton-bridge-thoralby",
            f"{OSM_NODE}/2980402128",
            "https://www.yorkshire-dales.com/kidstones-pass.html",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "ref": "B6160",
            "name": "Kidstones Bank",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/4453089",
        },
    },
    "Bwlch-y-maen": {
        "name": "Bwlch-y-maen (B4410)",
        "riderNote": (
            "A saddle on the B4410 above Llanfrothen in Eryri, on the Garreg-to-"
            "Maentwrog road. Rush Magazine's north Wales driving-roads guide lists "
            "the B4410 as a rollercoaster B-road that pinches to single track around "
            "Rhyd. No motorcycle-specific source names it."
        ),
        "motorcycleEvidence": "driving-roads-directory",
        "sources": [
            "https://www.rushmagazine.co.uk/post/the-best-driving-roads-in-north-wales-part-ii",
            "https://en.wikipedia.org/wiki/Rhyd,_Gwynedd",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "ref": "B4410",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/306991380",
        },
    },
    "Killhope Cross": {
        "name": "Killhope Cross (A689)",
        "riderNote": (
            "At 627 m the highest point on any A road in England, where the A689 "
            "crosses the Durham/Cumbria watershed between Cowshill and Nenthead. "
            "Ordnance Survey names it Britain's highest-elevation major road. No "
            "motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://www.ordnancesurvey.co.uk/news/highest-and-lowest-roads",
            "https://en.wikipedia.org/wiki/Killhope_Cross",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "ref": "A689",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/604384116",
        },
    },
    "Harthope Head": {
        "name": "Harthope Head (Harthope Moss)",
        "riderNote": (
            "At about 627 m the highest public road summit in England, on Harthope "
            "Road between St John's Chapel in Weardale and Langdon Beck in Teesdale; "
            "Ordnance Survey puts the summit at 630 m. A cattle grid sits on the "
            "summit itself. No motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://www.ordnancesurvey.co.uk/news/highest-and-lowest-roads",
            "https://en.wikipedia.org/wiki/Harthope_Moss",
            f"{OSM_NODE}/981662272",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Harthope Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/158725084",
        },
    },
    "Swinhope Head": {
        "name": "Swinhope Head",
        "riderNote": (
            "The summit of the single-track moor crossing between Westgate in "
            "Weardale and Newbiggin in Teesdale. OpenStreetMap records no elevation "
            "on the node and maps the way as one lane. No motorcycle-route source "
            "was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://www.geograph.org.uk/photo/2691145",
            f"{OSM_NODE}/8092142261",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1",
            "sourceUrl": f"{OSM_WAY}/36779193",
        },
    },
    "Top o'Dent": {
        "name": "Top o' Dent",
        "riderNote": (
            "A 421 m saddle on a single-track unclassified lane above Dent, "
            "Westmorland and Furness. Verified against OpenStreetMap on 28 July "
            "2026; no motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [f"{OSM_NODE}/771987101", f"{OSM_WAY}/70802978"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1",
            "sourceUrl": f"{OSM_WAY}/70802978",
        },
    },
    "Scarth Nick": {
        "name": "Scarth Nick",
        "riderNote": (
            "A 232 m notch through the western edge of the North York Moors on the "
            "old drovers' road between Osmotherley and Swainby, mapped three metres "
            "wide, with the Sheepwash ford and picnic area immediately below it. No "
            "motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "busyPeriods": (
            "The Sheepwash picnic area below the nick is a well-used stopping point, "
            "so expect parked cars and pedestrians on a three-metre road."
        ),
        "sources": [
            "https://www.coasttocoast.uk/vale-of-mowbray/danby-wiske-swainby/sheep-wash/",
            f"{OSM_WAY}/37064871",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Scarth Nick",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "widthMetres": "3",
            "sourceUrl": f"{OSM_WAY}/37064871",
        },
    },
    "Cross O'Greet (Tatham Fell)": {
        "name": "Cross o' Greet (Lythe Fell Road)",
        "riderNote": (
            "The higher of the two fell roads over the eastern Forest of Bowland at "
            "426 m, on the single-track Lythe Fell Road between Slaidburn and High "
            "Bentham. Discover Bowland describes a climb up a steep-sided clough and "
            "a long, sinuous moorland descent towards Bentham."
        ),
        "motorcycleEvidence": "none-found",
        "busyPeriods": BOWLAND_SINGLE_TRACK,
        "sources": [BOWLAND_HILLCLIMBS, f"{OSM_WAY}/219700927"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Lythe Fell Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/219700927",
        },
    },
    "Bowland Knotts": {
        "name": "Bowland Knotts (Keasden Road)",
        "riderNote": (
            "The second of the two eastern Bowland fell roads, crossing at 422 m on "
            "Keasden Road between Slaidburn and Clapham. Discover Bowland calls the "
            "climb steady and graded, with a steep and sometimes technical descent "
            "through Gisburn Forest. OpenStreetMap maps no speed limit on this way."
        ),
        "motorcycleEvidence": "none-found",
        "busyPeriods": BOWLAND_SINGLE_TRACK,
        "sources": [
            BOWLAND_HILLCLIMBS,
            "https://www.walkingenglishman.com/lancashire02.html",
            f"{OSM_WAY}/77197900",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Keasden Road",
            "speedLimit": None,
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/77197900",
        },
    },
    "Waddington Fell": {
        "name": "Waddington Fell (B6478)",
        "riderNote": (
            "The B6478 Slaidburn Road over Waddington Fell at 355 m, the main "
            "Clitheroe-to-Slaidburn route and the least remote of the Bowland "
            "crossings. Verified against OpenStreetMap on 28 July 2026; no "
            "motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [f"{OSM_NODE}/767200156", f"{OSM_WAY}/61321849"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "B6478",
            "name": "Slaidburn Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/61321849",
        },
    },
    "Nick O'Pendle": {
        "name": "Nick o' Pendle",
        "riderNote": (
            "The 295 m col carrying the Clitheroe-to-Sabden road over the shoulder of "
            "Pendle Hill. Climbfinder measures the Sabden side at 1.3 km averaging "
            "10.9%. Discover Bowland's hill-climb route finishes with a sustained "
            "climb here and a fast descent to Clitheroe; the sources found are "
            "cycling ones, not motorcycle ones."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://climbfinder.com/en/climbs/nick-of-pendle-sabden",
            BOWLAND_HILLCLIMBS,
            f"{OSM_WAY}/5064225",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Clitheroe Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/5064225",
        },
    },
    "Grindleton Fell": {
        "name": "Grindleton Fell (Smalden Lane)",
        "riderNote": (
            "A 269 m crossing on Smalden Lane above Grindleton, on the Ribble Valley "
            "side of the Forest of Bowland. Discover Bowland's hill-climb route "
            "swings back over Grindleton Fell into the Ribble Valley. OpenStreetMap "
            "maps no speed limit on this lane."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [BOWLAND_HILLCLIMBS, f"{OSM_WAY}/61321848"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Smalden Lane",
            "speedLimit": None,
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/61321848",
        },
    },
    "Merrybent Hill": {
        "name": "Merrybent Hill",
        "riderNote": (
            "A 321 m saddle on an unnamed single-carriageway lane in Bowland Forest "
            "High, Ribble Valley. Verified against OpenStreetMap on 28 July 2026; no "
            "motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [f"{OSM_NODE}/1574085914", f"{OSM_WAY}/618634969"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/618634969",
        },
    },
    "Tullybaccart": {
        "name": "Tullybaccart (A923)",
        "riderNote": (
            "A 213 m crossing of the Sidlaw Hills on the A923 between Coupar Angus "
            "and Muirhead, north-west of Dundee. Two lanes, good surface, national "
            "speed limit. No motorcycle-route source was found that names it."
        ),
        "motorcycleEvidence": "none-found",
        "enforcementNote": (
            "Police Scotland lists the A923 Coupar Angus to Muirhead as a mobile "
            "safety camera route at national speed limit, with sites including Leys "
            "and Kettins Junction. OpenStreetMap records no camera or enforcement "
            "relation here, so this candidate's derived camera count is zero - a gap "
            "in the map, not an absence of enforcement."
        ),
        "sources": [
            "https://www.safetycameras.gov.scot/cameras/safety-camera-locations/north/perth-and-kinross/a923-coupar-angus-to-muirhead-at-leys/",
            "https://www.safetycameras.gov.scot/cameras/safety-camera-locations/north/perth-and-kinross/a923-coupar-angus-to-muirhead-at-kettins-junction/",
            "https://www.sabre-roads.org.uk/wiki/index.php?title=A923",
        ],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "A923",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/676101875",
        },
    },
    "Witchie Knowe": {
        "name": "Witchie Knowe",
        "riderNote": (
            "A saddle on a single-track unclassified road in Yarrow, Scottish "
            "Borders, on the crossing between the Ettrick and Yarrow valleys. "
            "OpenStreetMap maps no elevation. No motorcycle-route source was found "
            "that names it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [f"{OSM_NODE}/8983659412", f"{OSM_WAY}/194250648"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1",
            "sourceUrl": f"{OSM_WAY}/194250648",
        },
    },
    "The Gap": {
        "name": "The Gap (Mull of Kintyre road)",
        "riderNote": (
            "A saddle on the single-track unclassified road at the south end of "
            "Kintyre, about a kilometre east of the Mull of Kintyre lighthouse. "
            "Frommer's describes the narrow road from Southend reaching the gap, "
            "beyond which the 2.5 km down to the lighthouse is a walk rather than a "
            "ride."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://www.frommers.com/destinations/kintyre-peninsula/regions-in-brief/",
            f"{OSM_WAY}/30770026",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Unclassified road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "1",
            "sourceUrl": f"{OSM_WAY}/30770026",
        },
    },
    "Barnes Gap": {
        "name": "Barnes Gap (C612)",
        "riderNote": (
            "A glacial breach carrying the C612 Gorticashel Road through the Sperrins "
            "between Gortin and Plumbridge, with the C611 branching at the gap "
            "itself. A Northern Ireland motorbike itinerary that names it could not "
            "be retrieved, so no motorcycle evidence is recorded."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [f"{OSM_NODE}/4324845956", f"{OSM_WAY}/111768192"],
        "sourceVerification": "fetched",
        "crossingRoad": {
            "ref": "C612",
            "name": "Gorticashel Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "sourceUrl": f"{OSM_WAY}/111768192",
        },
    },
    "Windy Gap": {
        "name": "Windy Gap (Slievenaboley Road)",
        "riderNote": (
            "A viewpoint saddle on the Slievenaboley Road in the Dromara Hills, "
            "within the Mourne and Slieve Croob National Landscape, south-west of "
            "Dromara. Not the Mourne Windy Gap between Eagle Mountain and "
            "Slievemoughanmore, which has no road over it."
        ),
        "motorcycleEvidence": "none-found",
        "sources": [
            "https://walkni.com/mourne-mountains/windy-gap-pad/",
            f"{OSM_WAY}/70259637",
        ],
        "sourceVerification": "listing-only",
        "crossingRoad": {
            "name": "Slievenaboley Road",
            "speedLimit": "60 mph",
            "observedOn": OBSERVED_ON,
            "lanes": "2",
            "sourceUrl": f"{OSM_WAY}/70259637",
        },
    },
}

# The unnamed mountain_pass=yes nodes, resolved against the roads that actually cross
# them - re-verified via Overpass on 28 July 2026. None is a mountain pass in any
# sense a rider would accept; the generator inherited OpenStreetMap's habit of tagging
# any local hill saddle. Renaming them would dress up a classification error, so each
# carries a verdict and the OSM URLs that support it.
#
# `generate_catalogue.py` now rejects unnamed `mountain_pass=yes` nodes outright, so
# none of these reaches the catalogue. This table remains the audit trail for why they
# are absent, and a belt to that braces: `publish_catalogue.py` drops any candidate
# whose sourceFeatureId appears here, so an extract that reinstates one cannot quietly
# republish it.
#
# The four previously reclassified into `good_biking_road` are no longer emitted as
# features. They were pass *nodes*, so they were Point geometry in a line layer, and
# the web planner partitions its map sources by geometry type: every Point lands in
# the mountain-pass source and is drawn in the mountain-pass colour. Reclassifying
# them therefore put four ordinary roads on the map as mountain passes. Where the road
# deserves to be offered it belongs in the road layer on its own way geometry, and
# `roadLayerCoverage` records whether it is already there.
CLASSIFICATION_REJECTIONS = {
    "node/732132339": {
        "verdict": "reject",
        "reason": (
            "Glasnakille Road, a dead-end single-track lane on Skye at 100 m. Not a "
            "pass, and it leads nowhere a group ride would route through."
        ),
        "sources": [f"{OSM_NODE}/732132339", f"{OSM_WAY}/59063444"],
    },
    "node/2308216337": {
        "verdict": "reject-as-pass",
        "reason": (
            "An unnamed saddle at 242 m on the A4113 near the Shropshire/"
            "Herefordshire border. A good A-road hill crossing, but not a mountain "
            "pass, and the A4113 is already a road-layer candidate on its own way "
            "geometry."
        ),
        "roadLayerCoverage": "A4113 is already published in the road layer.",
        "sources": [f"{OSM_NODE}/2308216337", f"{OSM_WAY}/498608792"],
    },
    "node/2308216342": {
        "verdict": "reject",
        "reason": (
            "An unnamed unclassified lane near Shelderton at 278 m, with only tracks "
            "and footways around it. Too minor to offer as a destination road."
        ),
        "sources": [f"{OSM_NODE}/2308216342", f"{OSM_WAY}/142467348"],
    },
    "node/280187024": {
        "verdict": "reject-as-pass",
        "reason": (
            "An unnamed saddle at 261 m on the A928 in Angus, north of Dundee. A "
            "reasonable moorland-edge road, not a pass. No road-layer candidate "
            "covers the A928, so this crossing is not offered at all - a road-layer "
            "scoring question, not a reason to publish it as a pass."
        ),
        "roadLayerCoverage": "No A928 candidate in the road layer.",
        "sources": [f"{OSM_NODE}/280187024", f"{OSM_WAY}/25699801"],
    },
    "node/271799539": {
        "verdict": "reject-as-pass",
        "reason": (
            "An unnamed node on the A859, the spine road of Harris, where the B897 "
            "branches off. The road is well worth riding and is already a road-layer "
            "candidate; this point is not a named pass."
        ),
        "roadLayerCoverage": "A859 is already published in the road layer.",
        "sources": [f"{OSM_NODE}/271799539", f"{OSM_WAY}/36197614"],
    },
    "node/8500938038": {
        "verdict": "reject-as-pass",
        "reason": (
            "An unnamed node on the B9120 over the Hill of Garvock, Aberdeenshire, "
            "an asphalt secondary road at the national limit. A pleasant secondary "
            "road, already a road-layer candidate; the summit is not a pass."
        ),
        "roadLayerCoverage": "B9120 is already published in the road layer.",
        "sources": [f"{OSM_NODE}/8500938038", f"{OSM_WAY}/34872676"],
    },
    "node/33624619": {
        "verdict": "reject",
        "reason": (
            "An unnamed node at 152 m on the A3055 Bonchurch Road on the Isle of "
            "Wight. Offering this as a mountain pass would discredit the whole layer."
        ),
        "sources": [f"{OSM_NODE}/33624619", f"{OSM_WAY}/38318557"],
    },
    "node/3906229915": {
        "verdict": "reject",
        "reason": (
            "An unnamed node at 147 m on the B954 near Hatton, Angus. An ordinary "
            "rural junction area with no pass character."
        ),
        "sources": [f"{OSM_NODE}/3906229915", f"{OSM_WAY}/284507865"],
    },
}


def main():
    catalogue = json.load(open(f"{OUT}/discovery-catalogue.geojson"))
    passes = [f for f in catalogue["features"] if f["properties"]["category"] == "mountain_pass"]

    entries = {}
    counts = {"researched": 0, "pending": 0}
    evidence_counts = {}
    verification_counts = {}

    for feature in passes:
        props = feature["properties"]
        entry = {"sourceFeatureId": props["sourceFeatureId"], "category": props["category"]}

        research = RESEARCHED.get(props["name"])
        if research:
            entry.update(research)
            entry["researchStatus"] = "researched"
            entry["researchedOn"] = RESEARCHED_ON
            counts["researched"] += 1
            evidence = research["motorcycleEvidence"]
            evidence_counts[evidence] = evidence_counts.get(evidence, 0) + 1
            verification = research["sourceVerification"]
            verification_counts[verification] = verification_counts.get(verification, 0) + 1
        else:
            entry["researchStatus"] = "pending"
            entry["name"] = props["name"]
            counts["pending"] += 1

        entries[props["id"]] = entry

    overlay = {
        "schemaVersion": 2,
        "catalogueVersion": catalogue["properties"]["catalogueVersion"],
        "note": (
            "Hand-researched editorial content. Merged into the generated catalogue "
            "at build time; never written by the generator. Entries are re-matched by "
            "sourceFeatureId if candidate ids change. Every claim is traceable to a "
            "URL in `sources`; `sourceVerification` records whether the cited page "
            "was retrieved or only listed. `motorcycleEvidence: none-found` is a "
            "recorded research outcome, not a placeholder."
        ),
        "researchedOn": RESEARCHED_ON,
        "entries": entries,
        "classificationRejections": CLASSIFICATION_REJECTIONS,
    }
    json.dump(overlay, open(f"{OUT}/editorial-overlay.json", "w"), indent=1)

    print(f"overlay entries: {len(entries)}")
    for key, value in counts.items():
        print(f"  {key:14s} {value}")
    print(f"  rejections     {len(CLASSIFICATION_REJECTIONS)}")
    print("motorcycle evidence:")
    for key in sorted(evidence_counts):
        print(f"  {key:26s} {evidence_counts[key]}")
    print("source verification:")
    for key in sorted(verification_counts):
        print(f"  {key:26s} {verification_counts[key]}")

    missing = set(RESEARCHED) - {f["properties"]["name"] for f in passes}
    if missing:
        print(f"\nWARNING research written for names not in catalogue: {sorted(missing)}")


if __name__ == "__main__":
    main()
