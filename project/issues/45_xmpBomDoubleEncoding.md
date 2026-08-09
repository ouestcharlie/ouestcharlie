# OEC-45: Fix double-encoded UTF-8 BOM in XMP sidecars

#status:done

## Context

Woof-generated XMP sidecars carry a corrupted byte-order mark: the bytes
`C3AF C2BB C2BF` (the `ï»¿` mojibake) appear at the start of the `<?xpacket?>`
processing instruction instead of the correct 3-byte UTF-8 BOM `EF BB BF`.

The bug lives in the py-toolkit library that Woof calls into. In
`ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py` the xpacket header
hardcodes the BOM as **three separate Unicode code points**:

```python
_XPACKET_HEADER = "<?xpacket begin='\xef\xbb\xbf' id='W5M0MpCehiHzreSzNTczkc9d'?>\n"
```

In a Python `str`, `\xef\xbb\xbf` is U+00EF (ï), U+00BB (»), U+00BF (¿) — three
characters, not raw bytes. `serialize_xmp` returns a `str`, and the write path
encodes it with `xml.encode("utf-8")`. Each of those code points then
UTF-8-encodes to two bytes — U+00EF→`C3AF`, U+00BB→`C2BB`, U+00BF→`C2BF` —
producing the 6-byte garbage on disk. This precisely matches the signature of a
UTF-8 BOM decoded as Latin-1 and re-encoded as UTF-8, but here it happens in a
single step from the mistaken `\xNN` literal.

The corruption is original to the XMP implementation (present since the feature
was written on 2026-02-21), not a recent regression. It sits inside the
`<?xpacket?>` line, which the reader strips before parsing, so internal parsing
is unaffected — but any external tooling reading these sidecars sees a broken BOM.

Intended outcome: sidecars carry a single correct UTF-8 BOM, and existing
corrupted files parse cleanly and self-heal on their next write. No migration
script — remediation happens organically as files are rewritten.

---

## Changes

### 1. Fix the writer — one line

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`

Replace the three code points in `_XPACKET_HEADER` with the single BOM code point
`﻿` (U+FEFF), which UTF-8-encodes to exactly `EF BB BF`:

```python
_XPACKET_HEADER = "<?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>\n"
```

No change is needed to the `.encode("utf-8")` write calls or to `serialize_xmp`.

### 2. Read tolerance — self-heal existing files

**File:** `ouestcharlie-py-toolkit/src/ouestcharlie_toolkit/xmp.py`

The read path decodes with `data.decode("utf-8")`. Decode defensively with
`utf-8-sig` so a leading real BOM is dropped if present:

```python
sidecar = parse_xmp(data.decode("utf-8-sig"))
```

`utf-8-sig` strips a leading `EF BB BF` and is otherwise identical to `utf-8`.
Combined with the writer fix, any corrupted sidecar self-heals the next time
`write`/`create` re-serializes it.

### 3. Update tests and fixtures

**Files:** `ouestcharlie-py-toolkit/tests/test_xmp.py`,
`ouestcharlie-py-toolkit/tests/sample-images/*.ref.xmp`

- The expected-output literals in `test_xmp.py` embed
  `<?xpacket begin='\xef\xbb\xbf' ...?>`; change these to `﻿` to match the
  corrected serializer.
- Regenerate `001.ref.xmp` / `002.ref.xmp` if any test compares against them
  byte-for-byte (they contain the corrupted BOM on disk).
- Add a focused assertion: `serialize_xmp(...).encode("utf-8")` begins with
  `b"<?xpacket begin='" + codecs.BOM_UTF8`, guarding against regression to the
  double-encoded form.

---

## Verification

1. From `ouestcharlie-py-toolkit/`: `.venv/bin/pytest tests/test_xmp.py -v`
2. Byte check on a freshly written sidecar — `head -c 20 <file>.xmp | xxd` should
   show `ef bb bf`, never `c3 af c2 bb c2 bf`.
3. Round-trip an existing corrupted sidecar through `XmpStore.read` then `write`
   and confirm the on-disk BOM is now correct (self-heal).
4. Confirm the "Aug 2 files are correct" observation: verify those files came
   through the same code path, or that they predate the feature / a different tool
   wrote them — that explains why only Woof output is corrupted.
