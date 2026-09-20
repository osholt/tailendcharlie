# Offline route endpoint places

`generate_route_places.py` extracts only `populatedPlace` features from the
official OS Open Names CSV download and converts their British National Grid
coordinates to WGS84. The compact result labels saved routes without sending a
rider's start or finish to a geocoder.

Source: [OS Open Names](https://osdatahub.os.uk/downloads/open/OpenNames), used
under the Open Government Licence. The generated asset carries the required
attribution: “Contains OS data © Crown copyright and database right 2026”.

Regenerate after an intentional dataset update:

```bash
curl -fL 'https://api.os.uk/downloads/v1/products/OpenNames/downloads?area=GB&format=CSV&redirect' -o /tmp/os-open-names.zip
uv run --with pyproj tools/places/generate_route_places.py \
  /tmp/os-open-names.zip \
  apps/mobile/assets/route_places.json \
  --source-version 2026-07
```

The source download is about 100 MB compressed and is not committed. The app
asset covers Great Britain. A route outside the indexes receives neutral copy;
it never falls back to a network reverse geocoder.

Run the generator unit test from the repository root with:

```bash
python3 -m unittest tools/places/test_generate_route_places.py
```

French place search uses a separate `route_places_fr.json` asset generated from
the [official commune API](https://geo.api.gouv.fr/decoupage-administratif/communes).
It contains metropolitan France and Corsica, using town-hall positions rather
than the centres of large commune polygons. Population only chooses a recognisable
town over a nearby tiny settlement. The source dataset is published under
[ODbL 1.0](https://www.data.gouv.fr/datasets/contours-administratifs); the derived
asset is distributed under that licence here, separately from the OS asset.
Both source attributions appear in the library. Neither index makes runtime
location requests.

```bash
curl -fL 'https://geo.api.gouv.fr/communes?fields=nom,code,mairie,population&format=json' -o /tmp/fr-communes.json
python3 tools/places/generate_french_route_places.py /tmp/fr-communes.json \
  apps/mobile/assets/route_places_fr.json --source-version 2026-09-20
python3 -m unittest tools/places/test_generate_french_route_places.py
```
