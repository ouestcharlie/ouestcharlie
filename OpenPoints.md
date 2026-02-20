# Open Points

## 1. Video support is never mentioned

The HLR says "photo management" but modern phone libraries are 30-50% video. The design never addresses whether video is in scope, out of scope, or deferred. If it's out of scope, it should say so explicitly — otherwise every design decision (AVIF containers, EXIF extraction, thumbnail tiers, size estimates) implicitly excludes video without acknowledging it.

## 4. No offline / partial-connectivity story

The architecture has local + cloud backends, but there's no design for what happens when the cloud is unreachable. Can the user still browse? Are manifests cached locally? What about writes queued for sync? This is critical for mobile use cases (mobile backup is explicitly listed as a use case).

## 7. No search or query language specification

The HLD shows filter examples like `date:2024 AND tag:travel` and `rating >= 4` but never defines the query language. Bloom filters are mentioned for pruning, but what fields are indexed? What operators are supported? This is central to how consumption agents work.


