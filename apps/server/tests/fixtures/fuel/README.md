# Fuel price fixtures (#951)

- `prix_carburants_instantane_excerpt.xml` is **recorded**: the first three
  stations of `https://donnees.roulez-eco.fr/opendata/instantane` as published
  on 10 October 2026, byte for byte, closed with `</pdv_liste>`. Licence Ouverte
  / Etalab 2.0. The third station carries no prices.
- The `fuel_finder_*.json` files are **schema-derived, not recorded**. The
  relay had no Fuel Finder credentials when they were written. They follow the
  field names in the Fuel Finder API fields guide and the response envelopes
  seen in two open-source clients (see
  `docs/fuel-and-charging-data-decision.md`), and deliberately mix the bare-list
  and wrapped shapes. Names, postcodes and positions are fictional. Replace
  them with a recorded, trimmed response once the relay is registered.
