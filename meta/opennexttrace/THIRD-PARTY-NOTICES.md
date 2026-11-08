# Third-party notices

- **OpenTrace** — <https://github.com/Archeb/opentrace>, GPL-3.0. The desktop layout and traditional RAW column mapping informed this LuCI implementation. The C#/Eto application is not built or shipped by these packages. Local `opentrace/` is a reference checkout only.
- **NextTrace / NTrace-core** — <https://github.com/nxtrace/NTrace-core>, GPL-3.0. `open-nexttrace-core` packages the unmodified upstream Linux release binary, using the tag and SHA-256 in `open-nexttrace-core/version.mk`. Corresponding source is available at that exact tag, e.g. <https://github.com/nxtrace/NTrace-core/tree/v1.7.3>. When redistributing binaries, comply with the GPL's corresponding-source requirements and retain upstream notices.
- **Leaflet 1.9.4** — <https://leafletjs.com>, BSD-2-Clause. Unmodified JavaScript and CSS are bundled in `luci-app-open_nexttrace/htdocs/luci-static/resources/open_nexttrace/vendor/`; the upstream license is in `LEAFLET-LICENSE`. Downloaded from the versioned npm distribution at <https://unpkg.com/leaflet@1.9.4/>. The tests verify both files against the official distribution hashes. Only circle markers are used; Leaflet's optional marker/layer icon images are not needed.
- **OpenStreetMap** — map data © OpenStreetMap contributors, ODbL. Tiles are requested directly by the user's browser from `https://tile.openstreetmap.org`. Attribution is always displayed. See <https://www.openstreetmap.org/copyright> and <https://operations.osmfoundation.org/policies/tiles/>.

New plugin code is licensed under GPL-3.0-only; see `LICENSE`.
