# OEC-63: Sidecar interoperability with darktable (shared NAME.EXT.xmp)

#status:done

Status flow: draft (write spec) -> open (review spec) -> todo (spec validated) -> ongoing (implementation started) -> done (merged)

## Context

Since OEC-25, OuEstCharlie names sidecars `NAME.EXT.xmp`, which is darktable's
own convention. darktable and OuEstCharlie therefore read and write **the same
file**.

darktable, at import, reads the sidecar: tags (`lr:hierarchicalSubject`,
`dc:subject`), rating, color labels, GPS, and its metadata fields such as
`dc:description`. From then on its database takes precedence, and at every sync
it rewrites the sidecar from that database. Observed on a JPG whose sidecar was
written by OuEstCharlie:

| Field | Written by OuEstCharlie | After a darktable sync |
|---|---|---|
| `ouestcharlie:*` (content hash, versions) | present | **kept** |
| `exif:*`/`tiff:*` copies | present | kept |
| `exif:DateTimeOriginal` | `2025-08-24T06:03:45.314000+02:00` | `2025:08:24 06:03:45.314` (EXIF style, no offset) |
| `dc:description`, `dc:subject` | the user's caption and tags | replaced by darktable's database values (empty caption; its automatic tags `darktable`, `format`, `jpg`, and `darktable|format|jpg` in `lr:hierarchicalSubject`) when darktable did not import them |
| `xmp:Rating` | absent | `1` (darktable's default initial rating) |
| `darktable:history` and other darktable data | — | added |

OuEstCharlie keeps darktable's data when it rewrites a sidecar: unknown
attributes and child elements round-trip through `XmpSidecar._extra`. But when
reading a darktable-written sidecar, it gets several fields wrong:

1. **Date lost.** `_parse_iso_datetime` (`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`)
   only accepts ISO 8601. darktable's `2025:08:24 06:03:45.314` parses as
   `None`, so a full reindex drops the photo's date: it disappears from date
   filters and sorts.
2. **Wrong XMP namespace for `xmp:Rating`.** `_NS_XMP` is
   `http://ns.adobe.com/xmp/1.0/`, but the XMP Basic namespace is
   `http://ns.adobe.com/xap/1.0/`. As a result:
   - OuEstCharlie's ratings are invisible to darktable, Lightroom, digiKam and
     any other XMP reader;
   - ratings set in those tools (`xmp:Rating` in the real namespace) are
     ignored by OuEstCharlie;
   - a file holding both namespaces under the same `xmp` prefix makes
     serialization fall back to a generated prefix for one of them.
3. **GPS written as attributes is ignored.** The reader only looks for
   `exif:GPSLatitude`/`GPSLongitude` as child elements. XMP allows simple
   properties as attributes, which is how darktable (Exiv2) writes them.

Tags (`lr:hierarchicalSubject`, darktable's internal `darktable|…` tags, and
writing tags that darktable can read) are handled in OEC-33.

Intended outcome: a sidecar written or rewritten by darktable is read
correctly: date with its offset, rating and GPS. The rating written by
OuEstCharlie is visible in other tools. No migration script: fixes apply when
sidecars are next read or written.

---

## Changes

### 1. Accept EXIF-style dates in sidecars

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` (`_parse_iso_datetime`)

Accept, in addition to ISO 8601:

- `YYYY:MM:DD HH:MM:SS` with optional `.fraction` (EXIF style, darktable);
- XMP partial dates (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`), as
  allowed by the XMP spec, rounded to the start of the period.

These carry no offset, so the result is naive.

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`
(`XmpStore.read_or_create_from_picture`)

When an existing sidecar's `date_taken` is naive and the media file is a photo,
recover the offset from the photo's own EXIF (`OffsetTimeOriginal`/
`OffsetTime`, as `photo.py` already does for extraction). Use it only if the
EXIF local date-time equals the sidecar's, compared to the second (EXIF
`DateTimeOriginal` has no fraction; darktable's `.314` comes from
`SubSecTimeOriginal`). Otherwise keep the naive value: the
sidecar is the source of truth for a date the user may have corrected. This
reads only the EXIF header, and only for sidecars with a naive date.

Do not write the recovered offset back: it is recovered again at each index,
and darktable would strip it again anyway.

### 2. Use the real XMP Basic namespace for `xmp:Rating`

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`

- Set `_NS_XMP = "http://ns.adobe.com/xap/1.0/"`, and fix `_WELL_KNOWN_NS`.
- **Read:** take `Rating` from the real namespace first, then from the legacy
  `http://ns.adobe.com/xmp/1.0/` one, so existing OuEstCharlie sidecars keep
  their rating.
- **Write:** write `Rating` in the real namespace only, and drop the legacy
  attribute (add it to `_KNOWN_ATTRS` so it is not carried in `_extra`).
- Existing sidecars switch namespace the next time OuEstCharlie writes them. No
  bulk rewrite.

### 3. Read GPS written as attributes

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` (reader)

For `exif:GPSLatitude`/`GPSLongitude`, accept both the child-element form and
the attribute form on `rdf:Description`. The value format (`DD,MM.mmmN`) is the
same, so `_parse_xmp_gps` is unchanged. Apply the same to any other simple
property the reader only takes from child elements.

### 4. Tests

**File:** `ouestcharlie-py-toolkit/tests/test_xmp.py`

Use a fixture sidecar in darktable's format,
`tests/sample-images/001.darktable.ref.xmp` paired with `001.jpg` (written by Exiv2, with
`darktable:history`, `xmp:Rating`, EXIF-style date, attribute GPS, and
`darktable|format|jpg` tags). OEC-33 reuses the same fixture for its tag tests.

- `test_parse_exif_style_date`: `2025:08:24 06:03:45.314` → naive
  `2025-08-24 06:03:45.314`; partial XMP dates parse.
- `test_naive_sidecar_date_recovers_offset_from_photo_exif`: a photo with
  `OffsetTimeOriginal=+02:00` and a naive sidecar date → aware date with
  `+02:00`; a sidecar date different from the EXIF one stays naive.
- `test_rating_read_from_xap_namespace`, `test_rating_read_from_legacy_namespace`,
  `test_rating_written_in_xap_namespace_only`.
- `test_gps_read_from_attributes`.
- `test_round_trip_preserves_darktable_history`: read and write a darktable
  sidecar; `darktable:history` and `darktable:masks_history` are unchanged.

### 5. Documentation

- `ouestcharlie-py-toolkit/py_toolkit_LLD.md` (XMP section): sharing
  `NAME.EXT.xmp` with darktable; accepted date formats and offset recovery;
  XMP Basic namespace.

### 6. Blog post: using darktable and Woof together

**File:** `ouestcharlie.github.io/docs/_posts/YYYY-MM-DD-darktable-and-woof.md`
(new post, dated on publication; same front matter and style as the existing
posts)

Written once §1–§3 are released and checked against a real darktable library
(Verification 2–4). Audience: darktable users who want to search and browse
their library through Claude without leaving darktable. Content:

- **Why they fit together.** darktable stays the editor and its database stays
  in place. Woof reads the same `NAME.EXT.xmp` sidecars and the photo files,
  never darktable's database, and only writes the sidecars.
- **Search and browse a darktable library.** Register the darktable library
  folder with Woof and index it. Show which darktable data Woof sees: date
  (with offset recovered from the photo's EXIF), rating, GPS, description and
  tags (tags per OEC-33). Example searches and gallery views mixing these
  fields, e.g. by place, date range and rating.
- **Maintain the library with the skills.** Use
  `sort-enrich-photos-interactive-clusters` and `sort-enrich-photos-strava` on
  an import folder before importing it into darktable, so darktable picks up
  descriptions and tags at import. Moving files: darktable tracks images by
  path, so sort before import, or move files within darktable, not with the
  skills, once imported.
- **Recommended darktable setup**, so changes flow both ways. darktable reads a
  sidecar only at import. After that its database wins, and any change made in
  darktable rewrites the whole sidecar from the database. In darktable's
  preferences → storage → XMP sidecar files
  ([darktable manual](https://docs.darktable.org/usermanual/stable/en/preferences-settings/storage/)):
    - **write sidecar file for each image: on import** (darktable → XMP):
      darktable writes the sidecar at import and after every change (rating,
      tags, metadata, edit), so OuEstCharlie sees darktable's changes at its
      next index. With "after edit", images never edited in darktable get no
      update; with "never", darktable's changes never reach the sidecar.
    - **look for updated XMP files on startup: on** (XMP → darktable): at
      startup, darktable lists the images whose sidecar is newer than its
      database entry and asks, per image or for all, whether to reload the
      sidecar into the database or overwrite it from the database. Choose to
      reload the sidecar for files changed by OuEstCharlie. Reloading also
      reloads `darktable:history`, which OuEstCharlie keeps unchanged.
- **Limits.** The check runs only at startup. Changes made by Woof while
  darktable is open are not seen, and the next darktable change to that image
  overwrites them. Workflow: close darktable before enriching photos with Woof,
  then restart darktable and reload the updated sidecars. To force darktable →
  XMP for some images: lighttable → history stack → "write sidecar files" on
  the selection (to check in darktable before publishing).

---

## Verification

1. From `ouestcharlie-py-toolkit/`: `uv run pytest tests/test_xmp.py -v`.
2. Import a photo with an OuEstCharlie sidecar into darktable, let darktable
   sync, then run a full reindex of that folder. The row keeps its date (with
   offset), and the rating is darktable's.
3. With darktable closed, change `xmp:Rating` in the sidecar with an external
   tool (text editor, ExifTool, or Claude editing the file; rating edit in Woof
   is only on the roadmap), then start darktable (with "look for updated XMP
   files" on) and reload the sidecar: darktable shows the new rating. Then run
   a full reindex in Woof: Woof shows the same rating.
4. Run the tag skill (`tag_files.py`) on a photo imported in darktable, then
   open its sidecar: `darktable:history` is unchanged. The skills are the
   writers users run on existing sidecars today; `XmpStore`'s round trip
   (used once rating edit in Woof lands) is covered by
   `test_round_trip_preserves_darktable_history`.

---

## Decisions

- **Both sidecar forms present** (`NAME.EXT.xmp` from darktable next to an
  older `NAME.xmp` written by OuEstCharlie or Lightroom): no merge.
  OuEstCharlie reads only `NAME.EXT.xmp`, and the metadata in `NAME.xmp` is
  shadowed. Accepted: `NAME.xmp` is legacy and `NAME.EXT.xmp` is the current
  default.
- **Concurrent edits:** darktable syncs from its database without reading the
  file first. This cannot be fixed on OuEstCharlie's side; it is covered by the
  recommended darktable setup and workflow in the blog post (§6).
- **Default rating 1** (§2): darktable writes `xmp:Rating="1"` by default on
  import. OuEstCharlie treats it as a real rating, with no special case: it is
  what the user sees in darktable, and darktable's default initial rating is
  configurable.
