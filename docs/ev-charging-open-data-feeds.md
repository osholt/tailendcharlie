# UK public charging open-data feed register

Research date: **11 October 2026**, Europe/London. Refs #970; parent #969.
Companion to [the charging-data decision](fuel-and-charging-data-decision.md#chargers).

This register records **65 network, platform and legacy-name entries**, including
all the names in the issue, with aliases combined where appropriate. It identifies
seven anonymously working locations samples. It is a verified record of the
observations below, **not a verified census of every current legal CPO**, nor a
certification that any feed meets every statutory requirement.

## Method and source selection

1. Start with the issue's operator names, the
   [OSM UK charging-data page](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom)
   and [Zapmap's public network list](https://www.zapmap.com/ev-guides/public-charging-point-networks)
   for **names only**. No Zapmap locations, prices, counts or other dataset was
   copied. Search operator websites for open data, OCPI and PCPR publications;
   follow their documented providers and add smaller, regional and host-operated
   networks. OSM is a lead, not proof of current access; its reviewed revision was
   dated 30 August 2025.
2. Review the latest available
   [DfT infrastructure statistics, 1 July 2026](https://www.gov.uk/government/statistics/electric-vehicle-charging-infrastructure-statistics-1-july-2026/public-electric-vehicle-charging-infrastructure-statistics-1-july-2026).
   Its EVSE/device statistics are not a complete named-CPO or physical-site
   census. No device counts were converted into sites. Site estimates below come
   only from first-party statements or the sampled feed's Location count.
3. Prefer the operator's own publication; distinguish provider documentation,
   third-party access reports and a live HTTP observation. For entries without a
   feed, the linked site and targeted searches are the evidence boundary.
   `not-published` means **no statutory endpoint located in the reviewed sources**,
   not that the operator has no data or is breaching the law.
4. Use the bounded standard-library probe below, with no credentials: at most two
   feed requests per entry, a 20-second socket timeout, a read deadline, and
   `User-Agent: TailEndCharlie-feed-register/1.0 (+https://tailendcharlie.app)`.
   A published versions URL would be checked first, then one locations page with
   `limit=1` (Monta uses `per_page=1`). No reviewed source supplied a versions URL,
   so none was guessed and no protocol version was negotiated. Documented OCPI
   versions and API-path versions are labelled separately.
5. Read at most **64 KiB per response**, below the requested 2 MB ceiling. Skip
   bodies whose Content-Length exceeds that cap and compressed bodies. Never
   follow pagination, fetch individual EVSEs, download a bulk archive,
   retry, or automatically follow redirects. The six Eco-Movement entries each
   used two requests: the documented path returned 307, then the separately
   documented trailing-slash path returned 401. Six open entries also received one separately documented tariff-page request
   with `limit=1`; all other sampled entries used one request.
   **29 feed requests across 17 entries**, still at most two per entry; other entries have no
   live feed observation. Website/document retrieval is separate from these feed
   requests. No saved responses, station records or personal addresses are included.
6. Record sanitized metadata only: HTTP codes, offered versions, module names,
   field-presence evidence, total-count and pagination-presence flags. No account
   registration, form submission, agreement, email, key acquisition or authenticated
   request was made. Request drafts below are unsent.

[Regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
requires reference and availability data to be open, with changes to availability
reflected within 30 seconds. Its no-terms requirement concerns **use of the data**.
The [government guidance](https://www.gov.uk/government/publications/the-public-charge-point-regulations-2023-guidance/public-charge-point-regulations-2023-guidance)
allows access-management terms such as API authentication and rate limits, while
restricting terms on reuse. Consequently, a key or access agreement alone is not
classified here as non-compliance. The guidance also describes OCPI 2.2.1 data
requirements and the reference-only exception for equipment incapable of reporting
availability. This review records terms for follow-up, not a legal determination.
The [National Chargepoint Registry was withdrawn on 28 November 2024](https://www.gov.uk/guidance/find-and-use-data-on-public-electric-vehicle-chargepoints).

## Outcomes

These counts are mutually exclusive **register-entry counts**, not sums of legal
operators or independent datasets. Seven entries describe platforms/host networks,
and one is a legacy name; the other 57 are network entries. Networks can overlap.

| Outcome | Entries | Interpretation |
| --- | ---: | --- |
| `open-and-working` | 7 | Anonymous HTTP 200 with exactly one recognizable Location; no completeness claim |
| `needs-key` | 18 | Key, login, or access-request route; actual credential type can remain unknown |
| `basic-auth` | 1 | Osprey: Basic access reported by OSM; not independently authenticated |
| `published-but-failing` | 1 | MFG: request timed out on this check |
| `not-published` | 34 | No verified statutory feed URL found within reviewed sources |
| `published-not-sampled` | 4 | Publication exists, but the bounded check cannot establish a usable sample |
| **Total** | **65** | |

The sixth category prevents bulk-only publications, skipped oversized responses
and unresolved publication links from being misleadingly called failed APIs.

- **Working samples:** Arnold Clark Charge, char.gy, ChargePlace Scotland, Evolt
  Network, Monta, PoGo Charge and Urban Fox.
- **Key/access requests:** Allego, Believ, Blink, BP Pulse, ChargePoint CMS, EVYVE,
  Fastned, GRIDSERVE, InstaVolt, IONITY, Lidl, RAW Charging, EVPoint,
  Sainsbury's Smart Charge, Shell Recharge /
  ubitricity, Source EV, Weev and Zest. Osprey is separately Basic. Wenea also gets
  a draft asking for a paginated API; its publicly linked ZIP was not downloaded.
- **Published but not sampled:** Clenergy EV and EV Dot returned HTTP 200 with
  Content-Length above 64 KiB; their bodies were skipped, so this does **not** prove
  they ignore pagination. GeniePoint publishes JSON links, but exact target paths
  could not be extracted from the directly blocked page. Wenea exposes a bulk ZIP.

## Register

The table is generated from [feeds.toml](../tools/charging/feeds.toml); an offline
unit test checks every cell and the row order. `unknown` means unverified,
`documented` means asserted in source documentation, `observed` means present in
one sampled Location or separately labelled Tariff, and `not-observed` means
absent from that one sample only.
`references-only` means connector tariff IDs, **not a verified per-kWh price**.
Five separate tariff samples expose numeric ENERGY prices; these have not been
joined to the sampled Locations or converted to rider-facing pence/kWh. Modules
are documented publications, not a discovered OCPI module list. An empty EVSE
array can produce a working Location sample with no status observation.

A blank endpoint means none verified. A portal root or ZIP URL is labelled in the
notes; it is not automatically a probe target. `auth=unknown` does not imply
anonymous access. Counts from `X-Total-Count` are Location-object estimates,
not deduplicated physical sites; Be.EV's 600 is its published lower bound.

<!-- register:start -->
| Operator | Open-data page | Feed base URL | Format / OCPI | Modules (documented) | EVSE status | kWh tariffs | Auth | Terms | Sites approx | Checked / result | Sources |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [3ti / Papilio](https://3ti.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://3ti.co.uk/) |
| [Allego](https://www.allego.eu/) | [Page](https://www.allego.eu/charge-point-data/) | — | unknown / unknown | unknown | unknown | unknown | unknown | Request form and UK GDPR notice | unknown | 2026-10-11: needs-key; Charge-point data request form; credential mechanism unknown | [1](https://www.allego.eu/charge-point-data/) |
| [APCOA Charging](https://www.apcoa.co.uk/ev-charging/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.apcoa.co.uk/ev-charging/) |
| [Applegreen Electric](https://www.applegreenfastcharge.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.applegreenfastcharge.com/) |
| [Arnold Clark Charge](https://www.arnoldclark.com/charge) | [Page](https://www.arnoldclark.com/charge) | [https://api.fuuse.io/opendata/e6397b95-1624-49cd-824d-ab2f9dfe7294/](https://api.fuuse.io/opendata/e6397b95-1624-49cd-824d-ab2f9dfe7294/) | OCPI-shaped JSON / unknown | locations, tariffs | observed | not-observed | none | No feed-specific acceptance shown on publication page | 126 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 126; Link present | [1](https://www.arnoldclark.com/charge) |
| [Be.EV](https://be-ev.co.uk/) | [Page](https://be-ev.co.uk/public-charge-point-regulations/) | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | 600 | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://be-ev.co.uk/) [2](https://be-ev.co.uk/public-charge-point-regulations/) |
| [Believ (Liberty Charge)](https://www.believ.com/) | [Page](https://www.believ.com/open-data/) | [https://api.believ.com/](https://api.believ.com/) | unknown / unknown | unknown | unknown | unknown | unknown | Developer portal registration/login; larger-data request form | unknown | 2026-10-11: needs-key; Access gated; no credentials requested or used | [1](https://www.believ.com/open-data/) [2](https://api.believ.com/) [3](https://www.believ.com/press-releases/liberty-charge-rebrands-to-believ/) [4](https://api.believ.com/register) |
| [Blink (EB Charging / Electric Blue)](https://blinkcharging.com/en-gb) | [Page](https://blinkcharging.com/en-gb/getintouch/blink-open-data-request) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Request form; sharing personal data with Eco-Movement disclosed | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://blinkcharging.com/en-gb/getintouch/blink-open-data-request) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) [4](https://ir.blinkcharging.com/sec-filings/all-sec-filings/content/0001493152-22-011169/0001493152-22-011169.pdf) |
| [BP Pulse](https://www.bppulse.co.uk/) | [Page](https://www.bppulse.co.uk/help-centre/charging/faq/public-charge-point-regulations) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Not found | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://www.bppulse.co.uk/help-centre/charging/faq/public-charge-point-regulations) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) [4](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) [5](https://www.bppulse.com/en-gb/help-and-support/contact) |
| [char.gy](https://char.gy/) | [Page](https://help.char.gy/support/solutions/articles/77000576948-public-charge-point-regulations-2023) | [https://char.gy/open-ocpi/](https://char.gy/open-ocpi/) | OCPI-shaped JSON / unknown | locations, tariffs | not-observed | observed | none | No feed-specific acceptance shown on publication page | 5962 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 5962; Link present | [1](https://help.char.gy/support/solutions/articles/77000576948-public-charge-point-regulations-2023) |
| [ChargeMyStreet](https://chargemystreet.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://chargemystreet.co.uk/) |
| [ChargePlace Scotland](https://chargeplacescotland.org/) | [Page](https://chargeplacescotland.org/network-performance-2/) | [https://info.smartcharging.uk/public_feed/locations/2463](https://info.smartcharging.uk/public_feed/locations/2463) | OCPI-shaped JSON / unknown | locations, tariffs | observed | observed | none | No feed-specific acceptance shown on publication page | 1479 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 1479 | [1](https://chargeplacescotland.org/network-performance-2/) |
| [ChargePoint CMS (platform networks)](https://www.chargepoint.com/en-gb) | [Page](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: needs-key; Partner request route offered; token and endpoint not disclosed | [1](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) [2](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform) |
| [CityEV / EVopencard (platform networks)](https://cityev.net/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://cityev.net/faqs/) [2](https://cityev.net/evopencard-app/) |
| [Clenergy EV](https://www.clenergy-ev.com/) | [Page](https://www.clenergy-ev.com/open-data/) | [https://api.clenergy.online/development/pcpr/](https://api.clenergy.online/development/pcpr/) | OCPI-shaped JSON / unknown | locations, tariffs | unknown | unknown | none | No feed-specific acceptance shown on publication page | unknown | 2026-10-11: published-not-sampled; HTTP 200; oversize-body-skipped | [1](https://www.clenergy-ev.com/open-data/) |
| [Connected Kerb](https://connectedkerb.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://connectedkerb.com/) [2](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) |
| [Dragon Charging](https://dragoncharging.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://dragoncharging.co.uk/) |
| [E.ON Drive](https://www.eonenergy.com/electric-vehicle-charging.html) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.eonenergy.com/electric-vehicle-charging.html) |
| [ESB Energy / ESB ecars (UK and NI)](https://www.esbenergy.co.uk/ev) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.esbenergy.co.uk/ev) [2](https://data.gov.ie/en_GB/dataset/esb-ev-public-charging-network) |
| [EV Dot (BMM Networks)](https://www.bmmnetworks.co.uk/) | [Page](https://www.bmmnetworks.co.uk/open-data/) | [https://api.evdot.clenergy.online/development/pcpr/](https://api.evdot.clenergy.online/development/pcpr/) | OCPI-shaped JSON / unknown | locations, tariffs | unknown | unknown | none | No feed-specific acceptance shown on publication page | unknown | 2026-10-11: published-not-sampled; HTTP 200; oversize-body-skipped | [1](https://www.bmmnetworks.co.uk/open-data/) |
| [EVC](https://www.evc.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.evc.co.uk/) |
| [Evology](https://evology.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://evology.co.uk/) |
| [Evolt Network (SWARCO E.Connect)](https://evoltnetwork.co.uk/) | [Page](https://evoltnetwork.co.uk/faqs/) | [https://info.smartcharging.uk/public_feed/locations/3666](https://info.smartcharging.uk/public_feed/locations/3666) | OCPI-shaped JSON / unknown | locations, tariffs | observed | observed | none | No feed-specific acceptance shown on publication page | 710 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 710 | [1](https://evoltnetwork.co.uk/faqs/) |
| [EVPoint / EG on the move](https://www.eg-otm.com/ev-charging/) | [Page](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) | — | unknown / unknown | unknown | unknown | unknown | unknown | Request form; access and reuse conditions not verified | unknown | 2026-10-11: needs-key; ChargePoint request form explicitly lists this network; endpoint and credentials pending | [1](https://www.eg-otm.com/ev-charging/) [2](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) [3](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform) |
| [EVYVE](https://evyve.co.uk/) | [Page](https://evyve.co.uk/) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Request form; data-use conditions not stated on homepage | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://evyve.co.uk/) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) |
| [EZO (EasyGo)](https://ezo.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://ezo.co.uk/news/ezo-begins-rollout-in-scotland/) [2](https://scotlandchargers.ezo.co.uk/infrastructure-faqs) [3](https://ezo.co.uk/support/) |
| [Fastned](https://www.fastnedcharging.com/en-gb) | [Page](https://www.fastnedcharging.com/en-gb/uk-open-data) | — | unknown / unknown | locations, tariffs | documented | documented | emailed-key | Fair-use policy: attribution, adapted-data notice, revocable licence, indemnity; access implies agreement | unknown | 2026-10-11: needs-key; Access gated; no credentials requested or used | [1](https://www.fastnedcharging.com/en-gb/uk-open-data) [2](https://form.typeform.com/to/y9Adcjqe) |
| [FOR EV](https://forev.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://forev.co.uk/) |
| [Fuuse (platform networks)](https://fuuse.io/) | [Page](https://fuuse.io/blog/public-charge-point-regulations) | — | OCPI-shaped JSON (tenant dependent) / unknown | locations, tariffs | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://fuuse.io/blog/public-charge-point-regulations) [2](https://content.fuuse.io/hubfs/User%20Guides%20and%20Onboarding%20Support/Customer%20Journeys%20-%20F-MK-0066-V2.pdf) |
| [GeniePoint (Equans)](https://www.equans.co.uk/drivers-geniepoint) | [Page](https://www.equans.co.uk/drivers-geniepoint/open-data) | [https://opendata.geniepoint.co.uk/](https://opendata.geniepoint.co.uk/) | OCPI-shaped JSON / unknown | locations, tariffs | unknown | unknown | none | No feed-specific acceptance shown on publication page | unknown | 2026-10-11: published-not-sampled; Published links; exact paths not verified; no feed request | [1](https://www.equans.co.uk/drivers-geniepoint/open-data) [2](https://drivers.geniepoint.co.uk/open-data) |
| [Go Zero](https://www.gozerocharge.com/) | [Page](https://gozerocharge.com/public-charge-point-open-data/) | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.gozerocharge.com/) [2](https://gozerocharge.com/public-charge-point-open-data/) [3](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) |
| [GRIDSERVE (Electric Highway)](https://www.gridserve.com/) | [Page](https://www.gridserve.com/open-data/) | [https://api.gridserve.com/ocpi/v1/](https://api.gridserve.com/ocpi/v1/) | OCPI-shaped JSON / unknown | locations, tariffs | documented | documented | emailed-key | API/fair-use acceptance required; terms assert data IP/confidentiality and restrictions; clarify statutory reuse rights | unknown | 2026-10-11: needs-key; HTTP 401; http-error | [1](https://www.gridserve.com/open-data/) [2](https://www.gridserve.com/wp-content/uploads/2024/11/GRIDSERVE-PCPR-API-Developer-Documentation.pdf) [3](https://www.gridserve.com/wp-content/uploads/2024/11/GRIDSERVE-PCPR-Open-Data-Onboarding-Information.pdf) [4](https://www.gridserve.com/ecotricity-completes-electric-highway-sale-to-gridserve/) [5](https://www.gridserve.com/legal-area/open-data-api-terms-and-conditions/) |
| [InstaVolt](https://instavolt.co.uk/) | [Page](https://instavolt.co.uk/public-charge-point-regulation-data/) | — | OCPI (documented) / unknown | locations | unknown | unknown | emailed-key | Page requires a signed Open Data Agreement before credentials | unknown | 2026-10-11: needs-key; Access gated; no credentials requested or used | [1](https://instavolt.co.uk/public-charge-point-regulation-data/) |
| [IONITY](https://www.ionity.eu/) | [Page](https://www.ionity.eu/open-data-request) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Request form and personal-data processing notice | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://www.ionity.eu/open-data-request) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) |
| [Joju Charging](https://www.jojusolar.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.jojusolar.co.uk/a-10-million-kwh-milestone-joju-and-mer-ev-charging/) [2](https://play.google.com/store/apps/details?id=com.jojucharging) |
| [JOLT](https://joltcharge.com/uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://joltcharge.com/uk/) |
| [Lidl](https://www.lidl.co.uk/c/electric-vehicle-charging/s10022527) | [Page](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) | — | unknown / unknown | unknown | unknown | unknown | unknown | Request form; access and reuse conditions not verified | unknown | 2026-10-11: needs-key; ChargePoint request form explicitly lists this network; endpoint and credentials pending | [1](https://www.lidl.co.uk/c/electric-vehicle-charging/s10022527) [2](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) [3](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform) |
| [Mer](https://uk.mer.eco/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://uk.mer.eco/) |
| [MFG EV Power](https://www.motorfuelgroup.com/) | [Page](https://www.motorfuelgroup.com/ev-power/) | [https://opendata.motorfuelgroup.net/](https://opendata.motorfuelgroup.net/) | OCPI-shaped JSON / unknown | locations, tariffs | unknown | unknown | none | No feed-specific acceptance shown on publication page | unknown | 2026-10-11: published-but-failing; HTTP no response; timeout | [1](https://www.motorfuelgroup.com/ev-power/) |
| [Monta (platform networks)](https://monta.com/uk/) | [Page](https://docs.public-api.monta.com/reference/get-open-data-locations) | [https://public-api.monta.com/api/v1/open-data/](https://public-api.monta.com/api/v1/open-data/) | OCPI JSON / 2.2.1 (documented) | locations | observed | references-only | none | Bearer UI shown in API docs, but one location returned anonymously; feed-specific terms unverified | unknown | 2026-10-11: open-and-working; HTTP 200; one-location-observed | [1](https://docs.public-api.monta.com/reference/get-open-data-locations) |
| [Osprey](https://www.ospreycharging.co.uk/) | [Page](https://www.ospreycharging.co.uk/post/consumer-charge-point-regulations) | — | OCPI (documented) / unknown | unknown | unknown | unknown | basic | Not found | unknown | 2026-10-11: basic-auth; Access gated; no credentials requested or used | [1](https://www.ospreycharging.co.uk/post/consumer-charge-point-regulations) [2](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) |
| [Park & Recharge](https://parkrecharge.com/) | [Page](https://parkrecharge.com/public-charging/) | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://parkrecharge.com/public-charging/) |
| [Plug-N-Go](https://plug-n-go.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://plug-n-go.com/) |
| [Pod (Pod Point)](https://podenergy.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://podenergy.com/) |
| [PoGo Charge](https://pogocharge.com/) | [Page](https://pogocharge.com/faqs/) | [https://info.smartcharging.uk/public_feed/locations/4009](https://info.smartcharging.uk/public_feed/locations/4009) | OCPI-shaped JSON / unknown | locations, tariffs | observed | observed | none | No feed-specific acceptance shown on publication page | 161 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 161 | [1](https://pogocharge.com/faqs/) |
| [Project EV (platform networks)](https://www.projectev.co.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.projectev.co.uk/) |
| [Qwello](https://qwello.uk/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://qwello.uk/) |
| [RAW Charging](https://rawcharging.com/) | [Page](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) | — | unknown / unknown | unknown | unknown | unknown | unknown | Request form; access and reuse conditions not verified | unknown | 2026-10-11: needs-key; ChargePoint request form explicitly lists this network; endpoint and credentials pending | [1](https://rawcharging.com/) [2](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators) [3](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform) |
| [Revive (West of England)](https://travelwest.info/electric-vehicles/charging-points/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://travelwest.info/electric-vehicles/charging-points/) |
| [ROAM Charging](https://www.roamcharging.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.roamcharging.com/) |
| [Sainsbury's Smart Charge](https://smartcharge.co.uk/) | [Page](https://smartcharge.co.uk/faq) | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: needs-key; Endpoint supplied on request; authentication mechanism unknown | [1](https://smartcharge.co.uk/faq) |
| [ScottishPower Recharge](https://www.scottishpower.co.uk/electric-vehicle-charging) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.scottishpower.co.uk/electric-vehicle-charging) |
| [Shell Recharge / ubitricity](https://www.shell.co.uk/electric-vehicle-charging.html) | [Page](https://www.shell.co.uk/electric-vehicle-charging/shell-recharge-open-data-request.html) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Contact-details form; data-use terms not displayed in readable page | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://www.shell.co.uk/electric-vehicle-charging/shell-recharge-open-data-request.html) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) [4](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) |
| [Source EV](https://source-ev.com/) | [Page](https://source-ev.com/legal/request-compliance-data) | [https://open-chargepoints.com/api/ocpi/cpo/2.2.1/](https://open-chargepoints.com/api/ocpi/cpo/2.2.1/) | OCPI JSON / 2.2.1 (URL; guide calls it 2.2) | locations, tariffs, statuses | unknown | unknown | emailed-key | Form asks for signed agreement and acceptance; OGL-equivalent reuse with attribution | unknown | 2026-10-11: needs-key; HTTP 307/401; http-error | [1](https://source-ev.com/legal/request-compliance-data) [2](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) [3](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) |
| [SureCharge (FM Conway)](https://www.fmconway.co.uk/our-services/surecharge) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.fmconway.co.uk/our-services/surecharge) |
| [Tesla Supercharger](https://www.tesla.com/en_gb/supercharger) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.tesla.com/en_gb/support/charging/supercharging-other-evs) [2](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom) |
| [TotalEnergies Charging Services (Source London)](https://chargingservices.totalenergies.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://totalenergies.co.uk/contact-us) [2](https://chargingservices.totalenergies.com/en/assistance/faq?category=2&country=united-kingdom) |
| [Trojan Energy](https://trojan.energy/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://trojan.energy/) |
| [Urban Fox](https://urbanfox.network/) | [Page](https://urbanfox.network/public-charge-point-regulations-data-access/) | [https://api.urbanfox.network/api/opendata/](https://api.urbanfox.network/api/opendata/) | OCPI-shaped JSON / unknown | locations, tariffs | not-observed | observed | none | No feed-specific acceptance shown on publication page | 139 | 2026-10-11: open-and-working; HTTP 200; one-location-observed; X-Total-Count 139; Link present | [1](https://urbanfox.network/public-charge-point-regulations-data-access/) [2](https://api.urbanfox.network/api-docs/opendata/v1/api.yaml) |
| [VendElectric (Rolec platform)](https://www.rolecserv.com/vendelectric) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.rolecserv.com/vendelectric) |
| [Wattif EV](https://www.wattifev.com/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://www.wattifev.com/) |
| [Weev](https://weev.ie/) | [Page](https://weev.ie/open-data) | — | unknown / unknown | unknown | unknown | unknown | emailed-key | API-key request form; detailed terms not verified | unknown | 2026-10-11: needs-key; Access gated; no credentials requested or used | [1](https://weev.ie/open-data) |
| [Wenea](https://wenea.com/uk/) | [Page](https://wenea.com/uk/open-data/) | [https://wenea.com/apilocation/data.zip](https://wenea.com/apilocation/data.zip) | ZIP (contents not downloaded) / unknown | locations, tariffs | documented | documented | none | Open-data policy: attribution, no misrepresentation, access controls; request form | unknown | 2026-10-11: published-not-sampled; Bulk ZIP on linked confirmation page; deliberately not downloaded | [1](https://wenea.com/uk/open-data/) [2](https://wenea.com/uk/thanks-page-open-data/) |
| [ZeroNet (Zero Carbon World)](https://zerocarbonworld.org/zero-net/) | — | — | unknown / unknown | unknown | unknown | unknown | unknown | Not found | unknown | 2026-10-11: not-published; No statutory feed URL found in reviewed sources; no feed request | [1](https://zerocarbonworld.org/zero-net/) |
| [Zest](https://www.zest.uk.com/) | [Page](https://www.zest.uk.com/charge-point-open-data) | — | unknown / unknown | unknown | unknown | unknown | unknown | CC BY 4.0 stated; form accepts privacy policy | unknown | 2026-10-11: needs-key; Data request form; credential mechanism unknown | [1](https://www.zest.uk.com/charge-point-open-data) |
<!-- register:end -->

## Evidence, scope and operational notes

The machine-readable row includes its detailed notes and exact reviewed request
URLs. Additional fields preserve `http_statuses` (0 means no HTTP response),
`versions_offered`, `modules_observed`, `x_total_count` (-1 means unknown), and
`link_pagination`. Empty observed lists mean unverified, not unsupported. Only the
presence of a Link header is retained; its URL and any response body are discarded.
`checked_on` is the research date for unprobed rows, not a claim of live access.

| Feed or group | Update and access observations |
| --- | --- |
| Eco-Movement: BP Pulse, Shell, Blink, EVYVE, IONITY, Source | [Guide](https://developers.eco-movement.com/docs/eco-movement-pcpr-api-user-guide) describes locations, tariffs and statuses. [Locations reference](https://developers.eco-movement.com/reference/get-all-locations-pcpr-api) states 30 requests/hour. The URL says 2.2.1 while guide text calls it 2.2. Raw Authorization API key is documented. The common gateway's 401 does not establish any operator's tenant coverage. |
| GRIDSERVE | [Onboarding guide](https://www.gridserve.com/wp-content/uploads/2024/11/GRIDSERVE-PCPR-Open-Data-Onboarding-Information.pdf) states changes within 30 seconds. [API terms](https://www.gridserve.com/legal-area/open-data-api-terms-and-conditions/) default to one request per 30 seconds per key; API path v1 is not an OCPI version. Terms asserting data IP/confidentiality merit clarification about statutory reuse. |
| Wenea | [Policy](https://wenea.com/uk/open-data/) states availability changes within 30 seconds and possible throttling without a numeric rate. A publicly reachable confirmation page links a bulk ZIP; no form was submitted to reach it. |
| Fastned | [Policy](https://www.fastnedcharging.com/en-gb/uk-open-data) mentions API keys, attribution/adaptation notices and possible throttling, but gives neither a numeric limit nor a verified endpoint. |
| Monta | One Location returned anonymously despite the Bearer credential UI. Documented cursor pagination uses per_page, after and before. Its platform scope can overlap named CPOs and roaming-enabled records; a UK-only public census was not established. |
| char.gy and Urban Fox | One Location each returned, but an EVSE status value was not observed in either sample. char.gy had tariff references; Urban Fox did not. This says nothing about unsampled locations. |
| All other entries | Unless a row explicitly says otherwise, refresh frequency and rate limits were not stated in the reviewed sources. The statutory 30-second obligation must not be substituted for measured or promised feed behavior. |

Aliases are deliberately consolidated: Electric Highway with GRIDSERVE; Liberty
Charge with Believ; SWARCO E.Connect with Evolt; EB Charging / Electric Blue with
Blink; Equans with GeniePoint; Pod Point with Pod; EasyGo with EZO. Shell's common
request route needs confirmation for Shell Recharge, ubitricity and Community by
Shell Recharge. Source EV is separate from TotalEnergies' former Source London.
ESB Energy/ecars is separate from EB Charging. CPS, PoGo and Evolt use different
published tenant URLs on the same provider. Some Joju installations run on Mer.

EZO's [operator FAQ](https://scotlandchargers.ezo.co.uk/infrastructure-faqs) reports
completed migration from CPS in four northern Scottish council areas; the CPS
feed must not be treated as all of Scotland. Fuuse, Clenergy, Monta, ChargePoint
CMS, CityEV, VendElectric and Project EV are marked `platform-network`, rather
than counted as extra legal CPOs. ZeroNet is marked `legacy-network`: its former
operator domain served unrelated content and its current publisher remains
unverified. ESB's separately published quarterly island-of-Ireland reference CSV
is not established as a statutory live UK feed. No bulk CSV was downloaded.

## Tariff endpoint follow-up — 11 October 2026

The six documented tariff endpoints each returned HTTP 200 with one JSON object
using `limit=1`. No whole dataset was downloaded or response saved. Location
outcome counts above are unchanged; this check establishes a separate module.

| Network | Numeric ENERGY price | X-Total-Count (tariffs, not sites) | Link pagination |
| --- | --- | ---: | --- |
| Arnold Clark Charge | Not observed in first tariff | 2 | Yes |
| char.gy | Observed | 3 | Yes |
| ChargePlace Scotland | Observed | 323 | Yes |
| Evolt Network | Observed | 289 | Yes |
| PoGo Charge | Observed | 13 | Yes |
| Urban Fox | Observed | 22 | Yes |

Targets are stored as `tariffs_url` beside their operator publication sources.
Monta has no reviewed tariff URL, so none was guessed. The probe requires a
single tariff object, currency field and a finite, nonnegative numeric ENERGY
component. It does not output the price, IDs or other record contents.
[OCPI 2.2.1](https://github.com/ocpi/ocpi/blob/2.2.1/mod_tariffs.asciidoc)
defines ENERGY as per-kWh pricing. A usable rider price still requires matching
connector tariff IDs, currency and VAT handling, time/restriction evaluation and
other fee components. One arbitrary tariff must not be attached to an arbitrary
Location, and an absent ENERGY component can be a legitimate non-energy tariff.

## Access-route follow-up — 11 October 2026

A browser review of the operator-linked request forms found three additional
network scopes in the [ChargePoint request form](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform): **Raw Charging**,
**ev-point**, and **Lidl Great Britain Limited**. These rows now have an access
route, but no endpoint, credentials or authenticated sample. The separate
**ChargePoint platform CPOs** option must not be assumed to include every scope.
Confirm coverage and avoid counting shared records twice.

[Believ registration](https://api.believ.com/register) provides a simpler API
onboarding route than its separate larger-data questionnaire. Fastned's policy
page offers a [Request API Access form](https://form.typeform.com/to/y9Adcjqe).
BP's old PCPR page redirected to its homepage; use the
[current contact form](https://www.bppulse.com/en-gb/help-and-support/contact)
to confirm the statutory access route. These are publication observations, not
additional feed requests. Forms were prepared for the app operator, with final
submission, passwords, CAPTCHA and agreement decisions left to them. No request
was submitted by this research task. Receipt of credentials remains unverified.

## Unsent access-request drafts

All drafts below are **from testing@tailendcharlie.app**, for the app operator to
send. No email was sent and no contact form was submitted. Where no verified
mailbox exists, the recipient is the published contact route; obtain the correct
open-data mailbox before sending. Do not guess addresses. Ask for credentials
privately and keep them out of the public repository.

### Raw Charging — ChargePoint request scope

To: [ChargePoint open-data request form](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform); select **Raw Charging**\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
(https://tailendcharlie.app). Please include the OCPI version, endpoint URLs,
pagination, rate limits and update frequency. Please confirm the **Raw Charging**
network scope, any overlap with ChargePoint platform CPOs and how credentials
should be supplied privately.

Thank you,\
Tail End Charlie

### ev-point — ChargePoint request scope

To: [ChargePoint open-data request form](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform); select **ev-point**\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
(https://tailendcharlie.app). Please include the OCPI version, endpoint URLs,
pagination, rate limits and update frequency. Please confirm the **ev-point**
network scope, any overlap with ChargePoint platform CPOs and how credentials
should be supplied privately.

Thank you,\
Tail End Charlie

### Lidl Great Britain Limited — ChargePoint request scope

To: [ChargePoint open-data request form](https://docs.google.com/forms/d/e/1FAIpQLSeJ9Z3dyMdsBjaQ3pj9F3aOAXE4jstoHFBxwVq3wxs5lU5JLg/viewform); select **Lidl Great Britain Limited**\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
(https://tailendcharlie.app). Please include the OCPI version, endpoint URLs,
pagination, rate limits and update frequency. Please confirm the **Lidl Great Britain Limited**
network scope, any overlap with ChargePoint platform CPOs and how credentials
should be supplied privately.

Thank you,\
Tail End Charlie

### Allego

To: Charge-point data request page; dedicated mailbox not published ([published route](https://www.allego.eu/charge-point-data/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Allego open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please identify the read-only feed URL and access process behind your charge-point-data request page.

Thank you,\
Tail End Charlie

### Believ (Liberty Charge)

To: hello@believ.com ([published route](https://www.believ.com/open-data/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Believ (Liberty Charge) open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please provide the documentation and read-only onboarding route for your API portal, including former Liberty Charge coverage.

Thank you,\
Tail End Charlie

### Blink (EB Charging / Electric Blue)

To: pcpr@eco-movement.com ([published route](https://blinkcharging.com/en-gb/getintouch/blink-open-data-request))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Blink (EB Charging / Electric Blue) open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please scope access to the UK Blink network, including former EB Charging and Electric Blue.

Thank you,\
Tail End Charlie

### BP Pulse

To: pcpr@eco-movement.com ([published route](https://www.bppulse.co.uk/help-centre/charging/faq/public-charge-point-regulations))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello BP Pulse open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please confirm the current BP Pulse UK access route and that this Eco-Movement contact handles its statutory feed.

Thank you,\
Tail End Charlie

### ChargePoint CMS (platform networks)

To: External request link on operator page; select ChargePoint CMS ([published route](https://www.chargepoint.com/en-gb/blog/navigating-uk-public-charging-regulations-guide-charge-point-operators))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello ChargePoint CMS (platform networks) open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please identify the UK public CPO scopes available through ChargePoint CMS and how to avoid duplicate host/operator records.

Thank you,\
Tail End Charlie

### EVYVE

To: pcpr@eco-movement.com ([published route](https://evyve.co.uk/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello EVYVE open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please scope access to the EVYVE UK public network.

Thank you,\
Tail End Charlie

### Fastned

To: Request API Access form on the [UK open-data page](https://www.fastnedcharging.com/en-gb/uk-open-data) ([direct form](https://form.typeform.com/to/y9Adcjqe))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Fastned open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please provide the API URL and confirm which fair-use clauses govern access versus statutory data reuse.

Thank you,\
Tail End Charlie

### GRIDSERVE (Electric Highway)

To: support@gridserve.com ([published route](https://www.gridserve.com/open-data/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello GRIDSERVE (Electric Highway) open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please supply the ec-subscription-key onboarding route, including Electric Highway, and clarify how the data IP/confidentiality terms apply to statutory reuse.

Thank you,\
Tail End Charlie

### InstaVolt

To: opendata@instavolt.com ([published route](https://instavolt.co.uk/public-charge-point-regulation-data/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello InstaVolt open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please share the Open Data Agreement for review and identify the feed URLs, supported version and tariff module.

Thank you,\
Tail End Charlie

### IONITY

To: pcpr@eco-movement.com ([published route](https://www.ionity.eu/open-data-request))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello IONITY open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please scope access to IONITY public UK locations.

Thank you,\
Tail End Charlie

### Osprey

To: support@ospreycharging.co.uk (OSM-reported support route) ([published route](https://www.ospreycharging.co.uk/post/consumer-charge-point-regulations))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Osprey open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please confirm the reported HTTP Basic access route and privately supply read-only credentials and endpoint URLs.

Thank you,\
Tail End Charlie

### Sainsbury's Smart Charge

To: Customer support 0800 014 2141; request an open-data email contact ([published route](https://smartcharge.co.uk/faq))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Sainsbury's Smart Charge open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Your FAQ directs data users to telephone support. Please route this request to the open-data team and provide its read-only endpoint.

Thank you,\
Tail End Charlie

### Shell Recharge / ubitricity

To: pcpr@eco-movement.com ([published route](https://www.shell.co.uk/electric-vehicle-charging/shell-recharge-open-data-request.html))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Shell Recharge / ubitricity open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please cover Shell Recharge, ubitricity and Community by Shell Recharge and confirm whether separate credentials or scopes are needed.

Thank you,\
Tail End Charlie

### Source EV

To: pcpr@eco-movement.com ([published route](https://source-ev.com/legal/request-compliance-data))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Source EV open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please scope access to Source EV, distinguish it from former Source London, and provide the proposed agreement for review.

Thank you,\
Tail End Charlie

### Weev

To: Open-data form / support +44 (0)28 9031 3031 ([published route](https://weev.ie/open-data))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Weev open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please identify the Northern Ireland/UK public subset separately from Republic of Ireland coverage.

Thank you,\
Tail End Charlie

### Wenea

To: info@wenea.com ([published route](https://wenea.com/uk/open-data/))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Wenea open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Your publication links a bulk ZIP. Please provide a paginated read-only API and any required key so we can request one Location without downloading the archive.

Thank you,\
Tail End Charlie

### Zest

To: Charge point open-data enquiry form; email recipient not published ([published route](https://www.zest.uk.com/charge-point-open-data))\
From: testing@tailendcharlie.app\
Subject: PCPR regulation 10 — read-only UK open-data access

Hello Zest open-data team,

Please provide free read-only access under Public Charge Point Regulations 2023
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made)
to your public UK locations, connectors, payment methods, EVSE status and tariffs
(including price per kWh) for Tail End Charlie, a free motorcycle group-riding app
([tailendcharlie.app](https://tailendcharlie.app)). Please include the OCPI version,
endpoint URLs, pagination, rate limits and update frequency. Please confirm that access includes live availability and tariffs as well as reference data, and identify the read-only endpoint.

Thank you,\
Tail End Charlie

## Probe usage and schema

Python 3.12; standard library only. Run from the repository root:

```bash
# One chosen feed, with at most two requests. This is a new live check.
python3 tools/charging/check_feeds.py --id arnold-clark
# Optional separate check: one documented tariff page, no Location join.
python3 tools/charging/check_feeds.py --id char-gy --tariffs-only
# No network: render the committed metadata as the documentation table.
python3 tools/charging/check_feeds.py --markdown
# Offline, mocked HTTP checks, including exact docs/register agreement.
python3 -m unittest discover -s tools/charging/tests
ruff format --check tools/charging
ruff check tools/charging
```

Without `--id` the tool checks all configured entries once, sequentially. It is a
manual spot-check tool, not a polling service; respect recorded limits before
rerunning it. A supplied versions endpoint would be called before locations,
without following its returned discovery URLs. `--tariffs-only` replaces both
requests with one tariff-page request, never a third request. Its outcome describes
only that tariff sample and must not overwrite the Location outcome. Budget
requests across runs; the tool does not persist a cross-run request counter.
A 401, 403 or 429 stops that entry.
Unpublished endpoints and deliberate bulk/link skips make no HTTP request.
The timeout bounds socket operations and a deadline stops further body reads;
it is not a hard process-wide deadline for DNS resolution.

The summary reports HTTP codes, offered versions, status/tariff evidence,
X-Total-Count, Link presence, observed modules and outcome. It never prints response
bodies, error text, returned URLs or credential headers. A process failure should
be investigated locally without enabling HTTP debug logging. Mock tests cover
request count/order, pagination, size/deadline bounds, redirects, HTTP failures,
malformed data, price-vs-reference distinctions and credential redaction. CI adds
these unittest tests and the directory to the existing discovery-tool lint steps.

Each `[[feed]]` has the requested common fields. `has_status` and `has_tariffs`
are evidence strings rather than misleading booleans; `sites_approx = -1` means
unknown. `modules` and `ocpi_version` are documented claims; their observed
counterparts are separate. `rate_limit`, `update_frequency`, `terms`, `notes`,
`contact` and `sources` preserve the qualifiers needed to interpret a row.
`record_kind` distinguishes network, platform-network and legacy-network.

`versions_url`, `locations_url` and optional `tariffs_url` contain reviewed HTTPS targets;
`base_url` is descriptive and is never guessed into a request. The optional
`page_size_parameter` selects the documented pagination field. `probe_skip`
prevents bulk downloads or unresolved links from being probed. Shared provider
URLs are intentional; they do not establish a provider-wide dataset or tenant
access. This tool does not update the register automatically. Update reviewed
metadata, regenerate the marked table with `--markdown`, and rerun the tests.

Credentials are read **only** from the environment variable named by
`credential_env`; the TOML contains names, never values. For Basic auth that
variable holds `username:password`; for a documented API-key scheme it holds
only the key. `auth_header` and `auth_scheme` describe a reviewed header format.
If the format is unknown, the tool will not guess how to send a credential.
A reserved environment-variable name on an unknown row is not evidence that
access requires a key. Keep credentials in a local secret manager/environment;
do not put them on a command line, in the register, in a PR or in test output.

## Limitations and next evidence

- Coverage is broad, not exhaustive. The market changes, small site owners can be
  legal CPOs, some sites are private, and rebrands/platform tenants overlap. No
  source reviewed establishes a complete current denominator. Unverified legal
  operator identities and the legacy entry are explicit; do not market this as
  all UK chargers or sum its site estimates into a national total.
- Most rows are publication research, not authenticated live verification. A
  blocked website, missing URL or one timeout is not evidence of a statutory
  breach. Osprey's authentication report and BP Pulse's access route rely partly
  on OSM. Operators without located feeds need direct follow-up.
- One Location cannot establish network coverage, connector completeness,
  payment-method coverage, current prices, tariff currency/VAT interpretation,
  public accessibility, or whether an operator reports every working/broken EVSE.
  Separate tariff samples establish field presence only. Further verification must
  join tariff IDs and validate pence/kWh, currency and VAT; `references-only`
  must not be used as a price.
- No repeated status observation was made; **30-second freshness was not tested**.
  Documented refresh commitments and rate limits are not measured service levels.
  Versions/modules were not negotiated. Content-Length skips and pagination
  header presence alone do not establish whether pagination is implemented.
- No credentials were requested, accounts created, terms accepted, forms sent,
  emails sent, driver APIs reverse-engineered, or whole datasets downloaded.
  Resolve the access drafts and publication gaps before implementing ingestion.
  Integration, freshness validation and field tests belong to subsequent work in
  #969; this PR changes documentation, a manual probe and its offline CI only.
