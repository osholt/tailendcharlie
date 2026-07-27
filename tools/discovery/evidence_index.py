"""Motorcycle-use evidence index, compiled from bestbikingroads.com regional listings.

Retrieved 27 July 2026 from the 19 UK regional index pages. Each entry is a road
number that the directory lists as a motorcycle road, with the route the directory
names.

What a match does and does not prove: it proves the *road number* is recognised as a
riding road, and it quotes the stretch the directory names. It does not prove a
given candidate section is that stretch — the A5 runs from London to Holyhead and only
part of it is the celebrated bit. So the composed description quotes the listed route
and lets the planner judge, rather than asserting that this section is the good one.
"""

SOURCE = 'https://www.bestbikingroads.com/motorcycle-roads/country/united-kingdom'

# (refs, listed route, region)
LISTINGS = [
    # North West England
    ('A537', 'Buxton - Macclesfield (The Cat & Fiddle)', 'north-west-england'),
    ('A686', 'Hartside Pass: Haydon Bridge - Penrith', 'north-west-england'),
    ('A57', 'Glossop - Sheffield', 'north-west-england'),
    ('A592', 'Kirkstone Pass: Windermere - Penrith', 'north-west-england'),
    ('A5004', 'Buxton - Whaley Bridge', 'north-west-england'),
    ('B5023', 'Wirksworth - Duffield', 'north-west-england'),
    ('A6', 'Kendal - Penrith', 'north-west-england'),
    ('A54', 'Congleton - Buxton', 'north-west-england'),
    ('A49', 'Warrington - Shrewsbury', 'north-west-england'),
    ('A6024 B6105', 'Woodhead Road: Holmfirth - Glossop', 'north-west-england'),
    ('A684', 'Kendal - Bedale', 'north-west-england'),
    ('B5289', 'Keswick - Cockermouth (Newlands/Honister)', 'north-west-england'),
    ('A5074', 'Gilpin Bridge - Bowness on Windermere', 'north-west-england'),
    ('A683', 'Devils Bridge - Brough', 'north-west-england'),
    ('A595', 'Calder Bridge - Dalton in Furness', 'north-west-england'),
    ('A682', 'Barrowford - Long Preston', 'north-west-england'),
    ('A5012', 'Pikehall - Cromford', 'north-west-england'),
    ('B6014', 'Tansley - Stretton', 'north-west-england'),
    # Yorkshire
    ('B1257', 'Stokesley - Helmsley (North Yorks TT)', 'yorkshire'),
    ('A169', 'Whitby - Pickering', 'yorkshire'),
    ('A161', 'Goole - Gainsborough', 'yorkshire'),
    ('B6160', 'Bolton Bridge - Thoralby', 'yorkshire'),
    ('B6479', 'Settle - Chapel le Dale', 'yorkshire'),
    ('B6255', 'Ingleton - Hawes', 'yorkshire'),
    ('B6270', 'Marske - Grinton - Thwaite - Nateby', 'yorkshire'),
    ('A61', 'Ripley - Ripon', 'yorkshire'),
    ('B1222', 'York - Sherburn Elmet', 'yorkshire'),
    ('B6451', 'Summer Bridge - Otley', 'yorkshire'),
    ('B1246', 'Pocklington - Kirkburn', 'yorkshire'),
    ('A171', 'Scarborough - Whitby', 'yorkshire'),
    # Highland Scotland
    ('A971', 'A971 to Sandness', 'highland-scotland'),
    ('A828', 'Glenachulish - North Connell', 'highland-scotland'),
    ('B9176', 'Ardross', 'highland-scotland'),
    ('A87', 'Invergarry - Kyle of Lochalsh; Kyleakin - Totscore (Skye)', 'highland-scotland'),
    ('A896', 'Lochcarron - Applecross (Bealach na Ba)', 'highland-scotland'),
    ('B863', 'North Ballachulish - Kinlochleven', 'highland-scotland'),
    ('A835', 'Tore - Ullapool - Ledmore', 'highland-scotland'),
    ('A82', 'Inverness - Fort William', 'highland-scotland'),
    ('A889 A86', 'Dalwhinnie - Roybridge', 'highland-scotland'),
    ('A838', 'Collaboll - Durness - Tongue', 'highland-scotland'),
    ('A894', 'Inchnadamph - Scourie - Laxford Bridge', 'highland-scotland'),
    ('A830', 'Lochailort - Mallaig (Road to the Isles)', 'highland-scotland'),
    ('A832 A835', 'Kinlochewe - Ullapool', 'highland-scotland'),
    ('A890', 'Auchtertyre - Achnasheen', 'highland-scotland'),
    ('A9 A99', 'Inverness - John o’Groats', 'highland-scotland'),
    # North Wales
    ('A4212', 'Bala - Trawsfynydd', 'north-wales'),
    ('A5', 'Bangor - Betws-y-Coed; Shrewsbury - Holyhead', 'north-wales'),
    ('A4086', 'Capel Curig - Llanrug - Caernarfon', 'north-wales'),
    ('B4391', 'Ffestiniog - Arenig; Llanfyllin - Bala', 'north-wales'),
    ('A470', 'Trawsfynydd - Betws-y-Coed; Conway - Blaenau Ffestiniog', 'north-wales'),
    ('A458 A470', 'Shrewsbury - Dolgellau', 'north-wales'),
    ('A542', 'Horseshoe Pass: Llangollen - Llandegla', 'north-wales'),
    ('A543', 'Denbigh - Pentre-Foelas (Denbigh Moors)', 'north-wales'),
    ('A548', 'Abergele - Llanrwst', 'north-wales'),
    ('B5105', 'Ruthin - Llanfihangel', 'north-wales'),
    ('A4085', 'Beddgelert - Garreg', 'north-wales'),
    ('A5104 A494', 'Penyffordd - Dolgellau', 'north-wales'),
    ('A498', 'Betws-y-Coed - Beddgelert (Scenic Snowdonia)', 'north-wales'),
    ('B4501', 'Denbigh - Cerrigydrudion', 'north-wales'),
    ('B4405', 'Bryncrug - Tal y Llyn', 'north-wales'),
    # Mid Wales
    ('A40', 'Abergavenny - Llandovery', 'mid-wales'),
    ('A4069', 'Brynamman - Llangadog (Black Mountain)', 'mid-wales'),
    ('A483', 'Llandovery - Beulah - Builth Wells; Llandrindod Wells - Newtown', 'mid-wales'),
    ('A488', 'Bishops Castle - Knighton', 'mid-wales'),
    ('A44', 'Aberystwyth - Llangurig; Evesham - Moreton-in-Marsh (Fish Hill)', 'mid-wales'),
    ('A482', 'Lampeter - Llanwrda', 'mid-wales'),
    ('A487', 'Aberystwyth - St Davids; Dolgellau - Machynlleth', 'mid-wales'),
    ('A493', 'Dolgellau - Machynlleth', 'mid-wales'),
    ('A484', 'Cardigan - Carmarthen', 'mid-wales'),
    ('B4329', 'Eglwyswrw - Haverfordwest', 'mid-wales'),
    ('B4355', 'Dolfor - Knighton', 'mid-wales'),
    ('B4519', 'Upper Chapel - Garth', 'mid-wales'),
    # South East Wales
    ('A466', 'Chepstow - Monmouth (Tintern Abbey)', 'south-east-wales'),
    ('B4235', 'Chepstow - Usk', 'south-east-wales'),
    ('B4521', 'Abergavenny - Skenfrith', 'south-east-wales'),
    ('B4423', 'Llanfihangel Crucorney - Hay on Wye (Gospel Pass)', 'south-east-wales'),
    ('B4560', 'Beaufort - Llangynidr', 'south-east-wales'),
    ('A469', 'Llechryd - Cardiff', 'south-east-wales'),
    ('A479', 'Talgarth - Tretower', 'south-east-wales'),
    ('B4358', 'Newbridge-on-Wye - Treflys', 'south-east-wales'),
    ('A4059', 'Beacons Reservoir - Rhigos (Dead Sheep Mountain)', 'south-east-wales'),
    # North East England
    ('B6277', 'Middleton-in-Teesdale - Alston', 'north-east-england'),
    ('B6276', 'Middleton-in-Teesdale - Brough', 'north-east-england'),
    ('A68', 'Crook - Jedburgh - Dalkeith', 'north-east-england'),
    ('A696', 'Ponteland - Otterburn', 'north-east-england'),
    ('A6108', 'Scotch Corner - Leyburn - Ripon', 'north-east-england'),
    ('B6271', 'Scorton - Northallerton', 'north-east-england'),
    ('A170', 'Thirsk - Helmsley', 'north-east-england'),
    ('A689', 'Wolsingham - Brampton', 'north-east-england'),
    ('B7068 B6357', 'Kielder - Lockerbie', 'north-east-england'),
    ('B6318', 'Greenhead - Langholm (Military Road)', 'north-east-england'),
    ('B6268', 'Barnard Castle - Carterway Heads', 'north-east-england'),
    ('B1248', 'Malton - Wetwang', 'north-east-england'),
    ('B6279', 'Darlington - Eggleston', 'north-east-england'),
    # South Scotland
    ('B742', 'Prestwick - Hillhead', 'south-scotland'),
    ('A712', 'Crocketford - Newton Stewart (Galloway Magic)', 'south-scotland'),
    ('B6357', 'Canonbie - Bonchester Bridge', 'south-scotland'),
    ('A72', 'Galashiels - Peebles', 'south-scotland'),
    ('A699', 'Kelso - Selkirk', 'south-scotland'),
    ('A713', 'Ayr - Castle Douglas', 'south-scotland'),
    ('B7076', 'Kirkpatrick Fleming - Eaglesfield', 'south-scotland'),
    ('A708', 'Selkirk - Moffat', 'south-scotland'),
    ('A75', 'The Queen’s Way: Stranraer - New Galloway', 'south-scotland'),
    ('B743', 'Strathaven - Muirkirk', 'south-scotland'),
    ('A714', 'Newton Stewart - Girvan', 'south-scotland'),
    ('A70 A721', 'Lang Whang: Balerno - Carluke', 'south-scotland'),
    ('B7086', 'Strathaven - Kirkmuirhill', 'south-scotland'),
    ('B724', 'Annan - Dumfries', 'south-scotland'),
    # South West England
    ('A39', 'Bridgwater - Lynmouth', 'south-west-england'),
    ('B3306', 'St Ives - Land’s End', 'south-west-england'),
    ('B3157', 'Bridport - Weymouth', 'south-west-england'),
    ('B3081', 'Shaftesbury - Ringwood (Zig Zag Hill)', 'south-west-england'),
    ('B3227', 'South Molton - Taunton', 'south-west-england'),
    ('A352', 'Sherborne - Dorchester', 'south-west-england'),
    ('B3212', 'Yelverton - Exeter (Dartmoor)', 'south-west-england'),
    ('B3301', 'Portreath - Hayle', 'south-west-england'),
    ('A350', 'Warminster - Poole', 'south-west-england'),
    ('A3072', 'Crediton - Bickleigh', 'south-west-england'),
    ('B3135', 'Chewton Mendip - Cheddar (Cheddar Gorge)', 'south-west-england'),
    ('A361', 'Lechlade - Burford; Daventry - Banbury', 'south-west-england'),
    ('B3347', 'Ringwood - Sopley', 'south-west-england'),
    ('A3083', 'Helston - Lizard', 'south-west-england'),
    ('A36', 'Southampton - Bristol', 'south-west-england'),
    ('A338', 'Hungerford - Tidworth', 'south-west-england'),
    ('A4', 'Newbury - Bath', 'south-west-england'),
    ('B4425', 'Burford - Cirencester', 'south-west-england'),
    ('A3030 A357', 'Sherborne - Shaftesbury', 'south-west-england'),
    # West Midlands
    ('B5013', 'Rugeley - Uttoxeter', 'west-midlands'),
    ('A423', 'Southam - Banbury', 'west-midlands'),
    ('A515', 'Lichfield - Ashbourne', 'west-midlands'),
    ('A519', 'Newport - Eccleshall', 'west-midlands'),
    ('A465', 'Hereford - Abergavenny', 'west-midlands'),
    ('A442', 'Telford - Hodnet', 'west-midlands'),
    ('B4555', 'Kinlet - Bridgnorth', 'west-midlands'),
    ('B4204', 'Worcester - Tenbury Wells', 'west-midlands'),
    ('A444', 'Nuneaton - Overseal', 'west-midlands'),
    ('B4363', 'Cleobury Mortimer - Bridgnorth', 'west-midlands'),
    ('A529', 'Nantwich - Audlem', 'west-midlands'),
    ('A454 B4364', 'Dudley - Ludlow', 'west-midlands'),
    ('A422', 'Alcester - Worcester', 'west-midlands'),
    # East Midlands
    ('B6047', 'Market Harborough - Melton Mowbray', 'east-midlands'),
    ('B5324 A6006', 'Ashby-de-la-Zouch - Melton Mowbray', 'east-midlands'),
    ('A631', 'Gainsborough - Louth', 'east-midlands'),
    ('B664', 'Uppingham - Market Harborough', 'east-midlands'),
    ('B1225', 'Horncastle - Caistor (Lincolnshire Wolds)', 'east-midlands'),
    ('A6003', 'Corby - Oakham', 'east-midlands'),
    ('A1133', 'Newark - Gainsborough', 'east-midlands'),
    ('B676', 'Colsterworth - Melton Mowbray', 'east-midlands'),
    ('A151', 'Bourne - Colsterworth', 'east-midlands'),
    ('A508', 'Northampton - Market Harborough', 'east-midlands'),
    ('A46', 'Lincoln - Market Rasen', 'east-midlands'),
    ('A158', 'Lincoln - Skegness', 'east-midlands'),
    ('A606', 'Edwalton - Stamford', 'east-midlands'),
    ('B1203', 'Market Rasen - Binbrook (Tealby bends)', 'east-midlands'),
    # South East England
    ('A272', 'Winchester - Petersfield - Haywards Heath', 'south-east-england'),
    ('A32', 'Fareham - Chawton', 'south-east-england'),
    ('A507', 'Baldock - Buntingford', 'south-east-england'),
    ('A413', 'Aylesbury - Towcester', 'south-east-england'),
    ('A339', 'Alton - Basingstoke', 'south-east-england'),
    ('A1060', 'Harlow - Chelmsford', 'south-east-england'),
    ('A262', 'Lamberhurst - Biddenden', 'south-east-england'),
    ('A3055', 'Freshwater - Niton (Military Road, Isle of Wight)', 'south-east-england'),
    ('B655', 'Barton-le-Clay - Hitchin', 'south-east-england'),
    ('B1012 B1010', 'South Woodham Ferrers - Burnham on Crouch', 'south-east-england'),
    ('B2146 B2141', 'Petersfield - Chichester', 'south-east-england'),
    ('B4494', 'Wantage - Newbury', 'south-east-england'),
    ('B3349', 'Riseley - Alton', 'south-east-england'),
    ('B660', 'Glatton - Winwick - Bedford', 'south-east-england'),
    ('B4011', 'Thame - Bicester', 'south-east-england'),
    # North East Scotland
    ('A93', 'Blairgowrie - Ballater (Glenshee and Royal Deeside)', 'north-east-scotland'),
    ('A939', 'Ballater - Dava (The Lecht)', 'north-east-scotland'),
    ('A85', 'Tyndrum - Oban; Lochearnhead - Crianlarich', 'north-east-scotland'),
    ('A84', 'Doune - Lochearnhead', 'north-east-scotland'),
    ('A86', 'Newtonmore - Spean Bridge (Loch Laggan)', 'north-east-scotland'),
    ('A95', 'Keith - Speybridge (Speyside Whisky Run)', 'north-east-scotland'),
    ('B9008', 'Bridge of Avon - Tomintoul', 'north-east-scotland'),
    ('A944', 'Aberdeen - Westhill - Alford - Lumsden', 'north-east-scotland'),
    ('B974', 'Montrose - Banchory - Braemar (Cairn o’ Mount)', 'north-east-scotland'),
    ('B8019', 'Tummel Bridge - Pitlochry', 'north-east-scotland'),
    # Argyll and Bute
    ('A83', 'Lochgilphead - Inveraray; Tarbert - Campbeltown', 'argyll-bute-scotland'),
    ('A816', 'Oban - Lochgilphead', 'argyll-bute-scotland'),
    ('A821', 'The Duke’s Pass: Callander - Aberfoyle', 'argyll-bute-scotland'),
    ('A861', 'Ardgour - Strontian', 'argyll-bute-scotland'),
    ('A815', 'Gourock - Strachur', 'argyll-bute-scotland'),
    ('A817', 'Arden (Loch Lomond) - Garelochhead', 'argyll-bute-scotland'),
    ('A819', 'Dalmally - Inveraray', 'argyll-bute-scotland'),
    ('B836 A886', 'Dunoon - Inveraray', 'argyll-bute-scotland'),
    ('B8001 B842', 'Kennacraig - Campbeltown via Carradale', 'argyll-bute-scotland'),
    # Central Scotland and Arran
    ('A701', 'Howgate - Moffat', 'central-scotland-arran'),
    ('B769', 'Stewarton - Thornliebank', 'central-scotland-arran'),
    ('A702', 'Loanhead - Abington', 'central-scotland-arran'),
    ('A7', 'Gorebridge - Langholm', 'central-scotland-arran'),
    ('A760', 'Largs - Johnstone', 'central-scotland-arran'),
    ('B709', 'Dewar - Langholm', 'central-scotland-arran'),
    ('A809', 'Bearsden - Drymen', 'central-scotland-arran'),
    # East Anglia
    ('B1057', 'Finchingfield - Haverhill', 'east-anglia'),
    ('B645', 'Chelveston - St Neots (Kimbolton Road)', 'east-anglia'),
    ('B1022', 'Colchester - Maldon', 'east-anglia'),
    ('B184', 'Chipping Ongar - Saffron Walden', 'east-anglia'),
    ('B1053', 'Finchingfield - Saffron Walden', 'east-anglia'),
    ('B1145', 'Mundesley - Kings Lynn', 'east-anglia'),
    ('B1508', 'Colchester - Sudbury', 'east-anglia'),
    ('A1141', 'Lavenham - Hadleigh', 'east-anglia'),
    ('B1352', 'Harwich - Mistley', 'east-anglia'),
    ('A1120', 'Stowmarket - Yoxford', 'east-anglia'),
    ('B656', 'Hitchin - Welwyn', 'east-anglia'),
    ('A1065', 'Fakenham - Mildenhall', 'east-anglia'),
    ('B1368', 'Hauxton - Puckeridge', 'east-anglia'),
    ('B1051', 'Thaxted - Elsenham', 'east-anglia'),
    ('B1101', 'March - Elm (Twenty Foot Road)', 'east-anglia'),
    # Ulster
    ('A2', 'Larne - Portrush (Antrim Coast Road)', 'ulster-northern-ireland'),
    ('A20', 'Newtownards - Portaferry (Portaferry Road)', 'ulster-northern-ireland'),
]


def build():
    """Return {ref: {'routes': [...], 'regions': {...}, 'source': url}}."""
    index = {}
    for refs, route, region in LISTINGS:
        for ref in refs.split():
            entry = index.setdefault(
                ref,
                {
                    'routes': [],
                    'regions': set(),
                    'source': f'https://www.bestbikingroads.com/motorcycle-roads/united-kingdom/rides/{region}',
                },
            )
            if route not in entry['routes']:
                entry['routes'].append(route)
            entry['regions'].add(region)
    for entry in index.values():
        entry['regions'] = sorted(entry['regions'])
    return index


if __name__ == '__main__':
    index = build()
    print(f'{len(index)} distinct road numbers with motorcycle-use evidence')
    print(f'from {len(LISTINGS)} directory listings')
