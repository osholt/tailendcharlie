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
asset is Great Britain-only. A route outside the index receives neutral copy;
it never falls back to a network reverse geocoder.

Run the generator unit test from the repository root with:

```bash
python3 -m unittest tools/places/test_generate_route_places.py
```
