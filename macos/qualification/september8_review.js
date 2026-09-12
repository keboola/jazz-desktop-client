/* Run as a reviewed DevTools Snippet ONLY after normal login and exact capture selection.
 * No cookies are read, no writes are sent, no player/assignment controls are activated.
 */
(() => {
  "use strict";
  const origin = "https://process-miner-74014979.hub.europe-west3.gcp.keboola.com";
  const archive = "ar-01a0801f-21f6-7688-a476-fd3302a2c242";
  const capture = "cap-01a0801f-21f6-7072-974c-4066a1e50a98";
  const fragment = "#/area/process-mining/process/__unassigned__/governance";
  const path = `/api/process-governance/evidence-reviews/${archive}/${capture}`;
  const query = "?companyId=default&areaId=process-mining&processId=__unassigned__";
  const expected = [
    ["art-01a0801f-332a-75be-a137-d6cb5ec934ff", 175342, "ae9c2d9b8e5315b32a8ce47a4c088c4a3d393cf374e91cfe6c38eb49f77bbefc", "image/jpeg"],
    ["art-01a0801f-4527-7ad4-a43f-237b11816009", 6901483, "b4e8753654e3387a6049d89d7cacbf2c61a719cee2ecab0d3e2c2bebf3cc69e3", "audio/mp4"],
  ];
  let verified = null;
  let attempted = false;
  function page() {
    if (location.origin !== origin || location.hash !== fragment || document.querySelector('input[type="password"]'))
      throw Error("STOP: normal authenticated scoped review required");
    const selected = [...document.querySelectorAll('button[aria-pressed="true"] code')];
    if (selected.filter(e => e.textContent.trim() === capture).length !== 1)
      throw Error("STOP: select the exact September8 capture");
  }
  function mediaURL(value) {
    const u = new URL(value, origin);
    if (u.origin !== origin || !u.pathname.startsWith(path) || !/^\/media\/mrg_[a-f0-9]{32}$/.test(u.pathname.slice(path.length)) || u.username || u.password || u.hash ||
        [...u.searchParams.keys()].sort().join() !== "areaId,companyId,processId" ||
        u.searchParams.get("companyId") !== "default" || u.searchParams.get("areaId") !== "process-mining" ||
        u.searchParams.get("processId") !== "__unassigned__") throw Error("STOP: unexpected media scope");
    return u.href;
  }
  async function get(url, limit, type) {
    page();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(url, {method: "GET", credentials: "same-origin", cache: "no-store", redirect: "error", signal: controller.signal});
      if (response.status !== 200 || response.headers.get("Content-Type")?.split(";")[0] !== type || !response.body)
        throw Error("STOP: response is not authenticated expected media/JSON");
      const declared = response.headers.get("Content-Length");
      if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > limit)) throw Error("STOP: response limit");
      const reader = response.body.getReader();
      const chunks = []; let length = 0;
      try {
        for (;;) {
          const {done, value} = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > limit) throw Error("STOP: response limit");
          chunks.push(value);
        }
      } finally { await reader.cancel(); }
      const bytes = new Uint8Array(length); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      page();
      return bytes;
    } finally { clearTimeout(timer); controller.abort(); }
  }
  async function retrieve() {
    page();
    if (attempted) throw Error("STOP: this snippet permits one retrieval attempt, no automatic retry");
    attempted = true;
    const review = JSON.parse(new TextDecoder().decode(await get(origin + path + query, 1048576, "application/json")));
    if (review.archive.archiveId !== archive || review.archive.captureId !== capture ||
        review.archive.contentDigest.replace(/^sha256:/, "") !== "d0de309b79d018ef5483bf5352007533740f9ab277d3705d2a01e457aab1e8a3" ||
        review.scope.companyId !== "default" || review.scope.areaId !== "process-mining" || review.scope.processId !== "__unassigned__" ||
        review.observations.length !== 376 || review.media.length !== 236 || review.gaps.length !== 5)
      throw Error("STOP: wrong/changed review");
    const output = [];
    for (const [id, size, sha, type] of expected) {
      const matches = review.media.filter(m => m.artifactId === id);
      if (matches.length !== 1 || matches[0].byteLength !== size || matches[0].sha256 !== sha || matches[0].mediaType !== type)
        throw Error("STOP: unexpected artifact metadata");
      const url = mediaURL(matches[0].url);
      const bytes = await get(url, size, type);
      const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(b => b.toString(16).padStart(2, "0")).join("");
      if (bytes.length !== size || digest !== sha) throw Error("STOP: media byte mismatch");
      output.push({artifactId: id, byteLength: size, sha256: sha, type, url,
        alignedStartMillis: matches[0].alignedStartMillis, blob: new Blob([bytes], {type})});
    }
    verified = output;
    return {archiveId: archive, captureId: capture, gapCount: 5, observedAt: new Date().toISOString(),
      serverMediaBytesVerified: true, media: output.map(({blob, url, ...m}) => m), playbackQualified: false};
  }
  function save(index) {
    page();
    if (!verified || ![0, 1].includes(index)) throw Error("STOP: verified media required");
    const url = URL.createObjectURL(verified[index].blob);
    const link = document.createElement("a"); link.href = url;
    link.download = index === 0 ? "september8-verified.jpeg" : "september8-verified.m4a";
    link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  async function observePlayback() {
    page();
    if (!verified) throw Error("STOP: verify server bytes first");
    const audio = [...document.querySelectorAll("audio")].filter(a => a.currentSrc && mediaURL(a.currentSrc) === verified[1].url);
    const sliders = document.querySelectorAll('input[aria-label="Evidence presentation time"]');
    if (audio.length !== 1 || sliders.length !== 1) throw Error("STOP: exact scoped player required");
    const a = audio[0]; let played = false, scrubbed = false, trustedSeek = false, rendered = false;
    let last = a.currentTime, seekFrom = a.currentTime;
    const input = e => { if (e.isTrusted) { trustedSeek = true; seekFrom = a.currentTime; } };
    const seek = () => { if (trustedSeek && Math.abs(a.currentTime - seekFrom) > 1) scrubbed = true; trustedSeek = false; };
    sliders[0].addEventListener("input", input, true); a.addEventListener("seeked", seek);
    function imageVisible() {
      return [...document.querySelectorAll("img")].some(e => {
        try {
          const b = e.getBoundingClientRect();
          return e.complete && e.naturalWidth > 0 && e.checkVisibility?.({opacityProperty: true, visibilityProperty: true}) === true &&
            b.width > 0 && b.height > 0 && b.bottom > 0 && b.right > 0 && b.top < innerHeight && b.left < innerWidth &&
            mediaURL(e.currentSrc) === verified[0].url;
        } catch { return false; }
      });
    }
    try {
      rendered = imageVisible();
      for (let i = 0; i < 200; i++) {
        await new Promise(resolve => setTimeout(resolve, 100)); page();
        if (mediaURL(a.currentSrc) !== verified[1].url) throw Error("STOP: player source changed");
        if (!a.paused && !a.muted && a.volume > 0 && a.readyState >= 2 && a.currentTime > last && a.currentTime - last < 0.5 && !a.seeking) played = true;
        last = a.currentTime;
        rendered = imageVisible() || rendered;
      }
      return {archiveId: archive, captureId: capture, screenshotRendered: rendered, audioClockAdvanced: played,
        trustedSliderSeekObserved: scrubbed, audibleOutputRequiresOwnerConfirmation: true, gapCount: 5, observedAt: new Date().toISOString()};
    } finally { sliders[0].removeEventListener("input", input, true); a.removeEventListener("seeked", seek); }
  }
  page();
  if (window.jazzSeptember8Qualification) throw Error("STOP: previous probe exists; do not overwrite it");
  window.jazzSeptember8Qualification = Object.freeze({retrieve, save, observePlayback});
})();
