# Complete byte inventory, not launch permission

[Exact receipt](spool-safety-2026-09-12.json). `spool_inventory.py` traversed the installed revision's
whole `~/.jazz` root twice, hashing every regular file without parsing captured content. Both passes
matched:1784 entries (1539 files),125017638bytes, tree digest
`e3bfa604f4e65257b4c9f5deef19c7bdc16c6a5947a5e2afcf55bbebabaf2da4`.
The receipt distinguishes complete/stable byte inventory from incomplete semantic/safety proof.

- Archives:1531 files/84474874bytes;11 checkpoint documents say committed. No WAL files were present.
  This is checkpoint inspection, not journal replay or a new recovery-success assertion.
- Whole-archive delivery:7 files/40542647bytes; records ready1/cancelled1/reconnectRequired1.
- No files in legacy event journal, shots, narration, artifact delivery, Capture Coach or guided
  execution spools. The remaining117-byte control file is `capture-setup.json`; no capture-intent
  document was observed. All bytes were hashed, not discarded from the inventory because unfamiliar.
- Local review: two valid confirm heads and four reject heads; no valid confirm head lacks a queue
  record. A seventh overlay has one assertion referencing a missing predecessor. Its archive-ID
  hash is pinned in the receipt. The overlay was not repaired, removed, relabeled or re-finalized.
- Two lock files exist. lsof observed no open descriptors but emitted diagnostics, so exclusive-lock
  freedom is not claimed. No writer lock was acquired or cleared.
- Installed166.a2a019f was not running and still matches its executable/signature pins. Immutable,
  read-only TCC base-store queries for `dev.jazz.capture` found stored auth_value2 for Accessibility,
  Screen Capture and Microphone. They are not effective installed-process/TCC or masking trials.
  Live WALs, unreadable TCC stores and merged/managed preferences are never guessed or modified.

## Why no controlled launch occurred

Read the **installed** source revision `a2a019f`, not the newer inactive transport:
`AppDelegate.applicationDidFinishLaunching` performs launch reconnect and token renewal;
`KeboolaConnection` can call `onEndpointStored`; `CaptureController.nudgeSender` invokes
`ArchiveUploadManager.reconnectAndRetry`. That retries retained reconnectRequired entries.
`ArchiveUploadManager.init` also starts confirmed-delivery recovery/draining. ScreenshotUploader
initialization deletes orphaned shots (none were present here). These behaviors occur outside Start.
The reconnect preference is absent in the inspected plist; installed code defaults it to true.
No credential contents were read to guess whether the reconnect would succeed.

Consequently, **zero currently automatic queue candidates is not proof of no launch-time delivery**.
The retained reconnect entry, incomplete local review chain, unknown effective authority and lack of
installed TCC/lock proof keep controlledLaunchAllowed false. No Start/sample/Stop/Pause/relaunch,
credential renewal, policy change or cleanup was performed. S5 remains open; S4 deployment stays held.

## S6 handoff / checks

[Exact post-login steps](../../macos/qualification/REVIEW_HANDOFF.md) use only scoped GETs and the
existing review player. The browser snippet never reads cookies, submits a password, changes browser
policy, assigns/processes an archive or starts capture. Authentication was not retried in this slice;
the last real attempt reached a password form. S6 stays open until real post-login byte/render/playback
receipts and audible-output confirmation exist.

Ten Python harness checks and four Node browser-probe checks pass on synthetic fixtures. They prove
negative boundaries, not installed capture behavior or authenticated playback. Local receipts:
`/tmp/jazz-continuous-eaa688eb/ready-s5-s7/`.
