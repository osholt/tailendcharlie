import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { BIKE_AND_BREW_CHECKED_AT } from "../bike-and-brew-places.mjs";
import { BIKER_PLACES } from "../biker-places.mjs";

const OUTPUT_URL = new URL("../../mobile/assets/biker_places.json", import.meta.url);
const SOURCE_URL = "https://ukbikercafes.co.uk/bike-and-brew-list/";

await writeFile(
  OUTPUT_URL,
  `${JSON.stringify(
    {
      checkedAt: BIKE_AND_BREW_CHECKED_AT,
      sourceUrl: SOURCE_URL,
      places: BIKER_PLACES,
    },
    null,
    2,
  )}\n`,
);

console.log(
  `Wrote ${BIKER_PLACES.length} biker places to ${fileURLToPath(OUTPUT_URL)}.`,
);
