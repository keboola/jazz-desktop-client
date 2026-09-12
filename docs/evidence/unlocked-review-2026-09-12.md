# Unlocked September8 trial — real rendering and trusted seek, playback defect

[Exact receipt](unlocked-review-2026-09-12.json). No private media, credentials or cookies are published.

- Fresh authenticated full-body checks at2026-09-12T18:07:33.586Z again match the expected JPEG
  (175342bytes, SHA256 `ae9c2d9b8e5315b32a8ce47a4c088c4a3d393cf374e91cfe6c38eb49f77bbefc`) and MP4
  (6901483bytes, SHA256 `b4e8753654e3387a6049d89d7cacbf2c61a719cee2ecab0d3e2c2bebf3cc69e3`).
- The exact1920×1080 screenshot rendered at18:09:47.786Z with document visibility=visible, focus=true,
  positive CSS visibility, fully inside the viewport and two animation frames observed. This is not
  the previous hidden-tab-only observation. The exact capture remained selected in the owner profile.
- Native mouse input, admitted by the OS event-posting preflight, produced an **isTrusted=true** slider
  input at18:21:31.005Z. Capture presentation moved to59990ms; audio moved from8.5582s to50.641s, with
  trusted seeking/seeked events and readyState4 afterward. The bounded observer independently reports
  trustedSliderSeekObserved=true. An earlier click at almost the current thumb position did not seek;
  it is not counted as a successful scrub. Failed AX target lookups were likewise not counted.

## Actual playback did not pass

A native Play click started the player; it became unpaused/unmuted at volume1 and decoded audio.
However, the native `played` ranges cover only **0.092925seconds across123 tiny intervals**, while
media position spans7.907210seconds. Position/decoding alone would falsely suggest continuous playback.
The UI ultimately reported “The browser refused playback of this exact evidence segment” and retained
its stop guard. The exact rejection subtype was not captured; it is not labelled an authentication
failure or a proven AbortError. Final audio is paused. **Sustained/audio-output qualification remains
false**, despite genuine successful byte, visible-image and trusted-seek checks.

The checked-in player seeks unconditionally inside both audio/video `canplay` readiness callbacks.
Seeking can cause another canplay event; a moving presentation clock turns this into feedback. The
processor PR removes only those redundant assignments, retaining initial metadata alignment, the
existing tolerance-checked sync, scope/mount/duration checks, gap boundaries and stop guards. No live
page patch or deployment was used to manufacture a pass.

Two tests execute the actual JSX callbacks: before the repair,100 readiness events write currentTime
100times; after, neither track re-seeks and stale mounts remain blocked. A separate isolated headless
Chromium test uses synthetic four-second PCM audio, a moving capture clock and one deliberate seek:
old callback20225 seeks/0.000719 played seconds, repaired callback2 seeks/1.569614 played seconds.
This is a causal synthetic reproduction, **not repaired playback of the private September8 audio**.
Initial standalone harness wiring errors were corrected before accepting those final results.

## S5 remains blocked; no native launch

Fresh read-only whole-spool and targeted checks retain the same tree digest, queue record and immutable
package hashes. The reconnectRequired delivery still has attempt2/resume creatingIntent and bound
scope/route; its invalid review references a predecessor belonging to another archive. Installed
startup/reconnect can persist retry changes before network success. No repair/retry was performed.

Stored TCC values are not effective installed-process grants. No competing installed process was
observed, but diagnostic-bearing lsof results do not establish an exclusive BSD-flock lease. No lock
was acquired or removed. These conditions do not prove that launch cannot release/alter backlog, so
**no Start/sample/Stop or other capture action occurred**. All five evidence gaps and existing data
remain intact. No S4 deployment or rollback mutation occurred.

Receipts and synthetic diagnostic logs: `/tmp/jazz-continuous-eaa688eb/unlocked-s6-s5/`.
The next S6 step is reviewed deployment of the player repair with a fresh rollback baseline, then a
new actual-media playback trial—not another login, unlock bypass or relaxation of the player guard.
