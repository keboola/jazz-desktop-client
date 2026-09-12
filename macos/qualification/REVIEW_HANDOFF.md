# September8 authenticated review handoff — no bypass

1. Owner restores the normal authenticated session at
   `https://process-miner-74014979.hub.europe-west3.gcp.keboola.com`.
   Do not share the password, extract cookies, change browser security settings or use an Admin/device
   token as a substitute. Stop if the password form or any authorization error remains.
2. Unlock the desktop normally and keep the review tab visible. A decoded image in a hidden tab
   or a locked console does not prove visible playback; the observer refuses hidden tabs.
   Open `/#/area/process-mining/process/__unassigned__/governance` on that origin. Select capture
   `cap-01a0801f-21f6-7072-974c-4066a1e50a98` from archive
   `ar-01a0801f-21f6-7688-a476-fd3302a2c242`. Do not press Assign, Confirm, Resubmit or analysis actions.
3. Review `september8_review.js` and run it as a normal DevTools Sources Snippet in that tab.
   This handoff does not automate pasting/security warnings or enable JavaScript-from-Apple-Events.
   The script refuses a wrong origin, scope, password form or selection before making requests.
4. Run:

   ```js
   const mediaReceipt = await jazzSeptember8Qualification.retrieve();
   mediaReceipt
   ```

   This makes at most three scoped GETs (review JSON, one exact JPEG, one exact MP4), with no redirects,
   no retry and no-store. Bodies have fixed byte/time ceilings. It checks archive/content identity,
   counts/gaps and actual media SHA256/length, not just metadata. Any failure stops the attempt.
5. Save each **verified** body separately using the normal browser download UI (choose new files;
   handle any browser download prompt manually, do not bypass it):

   ```js
   jazzSeptember8Qualification.save(0); // september8-verified.jpeg
   jazzSeptember8Qualification.save(1); // september8-verified.m4a
   ```

   Independently check the two newly downloaded files:

   ```bash
   shasum -a 256 /path/to/new/september8-verified.jpeg /path/to/new/september8-verified.m4a
   stat -f '%z' /path/to/new/september8-verified.jpeg /path/to/new/september8-verified.m4a
   ```

   JPEG:175342bytes, `ae9c2d9b8e5315b32a8ce47a4c088c4a3d393cf374e91cfe6c38eb49f77bbefc`.
   MP4:6901483bytes, `b4e8753654e3387a6049d89d7cacbf2c61a719cee2ecab0d3e2c2bebf3cc69e3`.
   Never substitute the local archive's blobs or synthetic files for these downloads.
6. In the existing review player, expose the verified screenshot at the returned
   `mediaReceipt.media[0].alignedStartMillis`, within valid audio coverage. Start this20-second
   observation, then use the **actual UI** Play timeline button and drag its evidence-time slider
   by more than one second within audio coverage:

   ```js
   const playbackReceipt = await jazzSeptember8Qualification.observePlayback();
   playbackReceipt
   ```

   The snippet does not play or seek for you. It records visible loaded imagery, an advancing
   unmuted audio clock and a trusted slider event followed by seeking, while retaining exact source
   and capture scope. Use the UI to pause afterward. Confirm audible output personally; an advancing
   HTML media clock cannot prove speaker output. The playing UI's button is labelled `Pause`, not
   `Pause timeline`; do not leave a failed pause attempt unattended. Keep all five gaps visible and uninterpreted.
7. Preserve the two non-secret receipt objects plus that explicit audible-output/visual confirmation
   for publication. These prepared commands and their offline tests are **not** S6 qualification.
   If a selector, media MIME, scope or capability differs, stop and report it; do not broaden guards.

Offline checks: `node --test macos/qualification/test_review.cjs` from repository root. No request to
private media is made by those tests. S4 deployment remains held; none of these steps starts capture.
