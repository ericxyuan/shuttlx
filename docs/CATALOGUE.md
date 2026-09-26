# Equipment catalogue boundary

`Resources/catalogue-development.json` is intentionally a small, clearly marked development dataset. It contains no bundled product photography and does not claim complete coverage of badminton products or regional colorways. Each product and variant points to a manufacturer HTTPS source and carries the verification date.

`CatalogService` validates schema version, stable IDs, HTTPS provenance, manufacturer ownership and image permission before merging an imported JSON catalogue. A user can import verified records from a security-scoped JSON file in Profile. The import is persisted under Application Support and is merged by stable ID, so a later official correction replaces the old record instead of creating duplicates.

The data model separates brand, product, variant, colorway and image. `UserEquipment` stores a readable snapshot plus start/retirement dates, allowing a future comparison between equipment setups without implying causation. Missing imagery is represented by a neutral placeholder; the app never fabricates a product photograph.
