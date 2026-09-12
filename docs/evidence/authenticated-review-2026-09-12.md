# Authenticated September8 bytes verified; visible/native trials still open

[Exact sanitized receipt](authenticated-review-2026-09-12.json). This supersedes the password-session
blocker in earlier S6 reports, not the remaining playback/native gates.

## S6 actual server data

The owner-designated Jiri browser profile successfully opened the exact unassigned September8 review.
The existing snippet fetched review JSON and **actual JPEG/MP4 response bodies** through the browser's
normal same-origin authenticated session. All three fetches required HTTP200, bounded bodies and no
redirects/retry. No cookies, passwords or tokens were extracted or logged.

At2026-09-12T16:59:56.374Z:

| Artifact | Actual bytes | SHA256 |
| --- | ---: | --- |
| JPEG `art-01a0801f-332a-75be-a137-d6cb5ec934ff` | 175342 | `ae9c2d9b8e5315b32a8ce47a4c088c4a3d393cf374e91cfe6c38eb49f77bbefc` |
| MP4 `art-01a0801f-4527-7ad4-a43f-237b11816009` | 6901483 | `b4e8753654e3387a6049d89d7cacbf2c61a719cee2ecab0d3e2c2bebf3cc69e3` |

Both complete bodies were SHA256/length checked inside the browser. The JPEG was also saved and
independently rehashed locally; **no local audio download was established**, despite the verified
complete browser body. These are not local-archive substitutes or synthetic fixtures.

The exact JPEG decoded in the scoped review at1920×1080; its CSS/layout checks were positive at the
4350ms presentation position. That alone is **not visible-review proof**: subsequent checks found
`document.visibilityState=hidden`, no document focus, and macOS `CGSSessionScreenIsLocked=true` with
`loginwindow` frontmost. No unlocking/security bypass was attempted. System Events automation was
also denied (-1743); the permission was not changed.

The review timeline was moved into audio coverage (10000ms), and Play timeline was requested.
The audio element remained paused, readyState0/currentTime0 with no decoded duration. **No advancing
audio clock, audible output or actual media seek was verified.** A temporary20-second pause timer
looked for the wrong label (`Pause timeline`, whereas the UI uses `Pause`); it did not click the
control. An explicit scoped UI Pause then succeeded, and the final state has no active playback.
No audio playback was observed during that interval. One bounded read-only Range diagnostic returned
206, `Content-Range: bytes 0-1023/6901483`, audio/mp4; its body was canceled after headers. This proves
neither decoding nor scrubbing. UI-generated requests were not counted as a total transport budget.

The blocker is now an **unlocked, visible desktop trial**, not the authenticated password session.
Audio loading still needs re-observation there; the locked state alone is not a proven diagnosis of
all media-loading behavior. The observer now refuses hidden tabs initially and throughout playback;
one regression fails before this guard and passes after it. Five Node checks pass. This avoids a
false visible-render claim without changing the installed app, server or browser security policy.

## S5 retained-data safety

Fresh read-only inspection found the same stable full-tree digest and unchanged installed pilot.
The reconnectRequired delivery and invalid review overlay belong to the **same archive**:

- Delivery has bound scope/route, attempt2, resumeState creatingIntent. Its20262439-byte immutable
  package hashes to `3ffa526f9027c9eef53cdf592c8fe758e1b93fe4f3f3725bd79b1b368877f5ea`, matching its record.
- The missing predecessor ID exists in two loose assertion files and one immutable package, but all
  matches target a **different archive**. Copying that assertion into this chain is not a valid
  same-archive repair. No assertion, package, queue record or predecessor was changed.
- Installed `a2a019f` reconnect invokes queue.retry; retry can persist a new local delivery state
  before network success. S4's best-effort deny gate does not disable legacy archive delivery.
- Two empty0600 lock files remain. Targeted lsof found no descriptors but emitted diagnostics.
  The production lease uses BSD flock; absence of observed handles is not an acquired exclusive
  lease. No lease was acquired/cleared, and no lock-freedom claim is made.
- Stored TCC auth_value2 remains observed for Microphone, Screen Capture and Accessibility, but
  effective installed-process TCC remains unknown. The app is not running; no TCC request/change.

Therefore **no safe launch proof exists** under the preservation requirement. No installed launch,
Start/sample/Stop, reenrollment, pending-delivery cancellation/retry or policy change occurred.
The real September8 package remains ready,20261404bytes, SHA256
`68563109b7e5caad816928bbd16b7c66c02209e08bc78807aee9dcdd96179010`; all five review gaps remain.

Owner authorization for a bounded S4 branch pilot is recorded. No deployment was attempted here;
exact-release/rollback reconciliation remains outstanding. Authorization is not a rollback receipt
or a safety fence for this retained native delivery.

Private local working files: `/tmp/jazz-continuous-eaa688eb/owner-s6-s5/`. Raw private media is not
published. Only the temporary download button was removed; the exact review tab remains paused.
