/* Own Your Glass — TV app.
 *
 * Three screens: main (status + "Own the glass"), settings (module toggles,
 * boot persistence, undo, uninstall, log) and log. Root comes from Homebrew
 * Channel's service (luna://org.webosbrew.hbchannel.service/exec); every
 * action is `oyg <command>` from the toolkit bundled with the app, run
 * detached with its output in a log file the app tails. Status is
 * `oyg status`, cheap enough to poll.
 */
(function () {
  "use strict";
  var APPID = "org.ownyourglass.app";
  var SVC = "luna://org.webosbrew.hbchannel.service";
  var LOG = "/tmp/own-your-glass-app.log";
  var TK = null;
  var $ = function (id) { return document.getElementById(id); };
  function esc(x) { return String(x).replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
  function sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

  /* ---------- luna ---------- */
  var bridges = [];
  function ls2(uri, method, params, cb) {
    if (window.webOS && webOS.service && webOS.service.request) {
      webOS.service.request(uri, { method: method, parameters: params || {},
        onSuccess: function (r) { cb(null, r || {}); },
        onFailure: function (e) { cb((e && e.errorText) || "luna failure", null); } });
      return;
    }
    if (!window.PalmServiceBridge) { cb("no luna bridge", null); return; }
    var b = new PalmServiceBridge(); bridges.push(b);
    b.onservicecallback = function (msg) {
      var i = bridges.indexOf(b); if (i >= 0) bridges.splice(i, 1);
      var o; try { o = JSON.parse(msg); } catch (e) { o = { errorText: String(msg) }; }
      if (o && o.returnValue === false) cb(o.errorText || "luna error", null); else cb(null, o || {});
    };
    try { b.call(uri + "/" + method, JSON.stringify(params || {})); } catch (e) { cb(String(e), null); }
  }
  var chain = Promise.resolve();
  function sh(cmd, cb) {
    chain = chain.then(function () {
      return new Promise(function (res) {
        ls2(SVC, "exec", { command: cmd }, function (e, r) { cb(e, r ? (r.stdoutString || "") : ""); res(); });
      });
    });
  }

  /* ---------- state ---------- */
  var SEED = [
    ["nag", "Stop the terms & conditions prompt and marketing re-consent toast"],
    ["acr", "ACR content recognition, ad overlays, ad-ID manager"], ["telemetry", "Log uploaders, remote diagnostics, promotional nudges"],
    ["remote", "Remote support daemon, telnet root shell, world-writable root service"], ["voice", "Remote and far-field mic pipelines, wake words, Alexa, ThinQ AI"],
    ["mic", "All audio capture devices (built-in and far-field mics)"], ["capture", "Screen-capture file readable by every app, video-plane grabber"],
    ["consent", "Decline every tracking consent, disable ad and data settings"],
    ["apps", "Hide ad, ACR, remote-support and demo apps from the launcher"],
    ["cloud", "ThinQ cloud link, push, rule engine, Google Home, casting, phone helpers", "Breaks the ThinQ app, Home Hub and Matter, Google Home, AirPlay and Chromecast discovery, phone casting, Always Ready"],
    ["network", "Sinkhole ad, ACR and telemetry hostnames via /etc/hosts", "Can break LG time sync (NTP) and some LG services"]];
  var NAMES = { nag: "Terms prompt", acr: "ACR and ads", telemetry: "Telemetry", remote: "Remote access", voice: "Voice", mic: "Microphones",
    capture: "Screen capture", consent: "Consents", apps: "Hidden apps", cloud: "Cloud and casting", network: "Hostname sinkhole" };
  var mods = SEED.map(function (x) { return { id: x[0], desc: x[1], breaks: x[2] || "", on: false, applied: false, lines: [], pending: true }; });
  var meta = {}, running = false, statusKnown = false, retries = 0, lastLog = "";
  var screen = "main", focus = { main: 0, settings: 0 }, modal = { open: false, i: 0 }, prevScreen = "main";
  var desired = {};
  try { desired = JSON.parse(localStorage.getItem("oyg.desired") || "{}"); } catch (e) { desired = {}; }
  function saveDesired() { try { localStorage.setItem("oyg.desired", JSON.stringify(desired)); } catch (e) {} }
  function wantOn(m) { return (m.id in desired) ? desired[m.id] : m.on; }
  function isPending(m) { return (m.id in desired) && desired[m.id] !== m.on; }
  function pendingList() { return mods.filter(isPending); }

  function parseStatus(t) {
    var list = [], cur = null; meta = {};
    t.split("\n").forEach(function (l) {
      var p = l.split("|");
      if (p[0] === "META") { meta[p[1]] = p.slice(2).join("|"); return; }
      if (p[0] === "MOD") { cur = { id: p[1], on: p[2] === "on", applied: p[3] === "1", desc: p[4] || "", breaks: p[5] || "", lines: [] }; list.push(cur); return; }
      if (p.length >= 3 && cur && p[0] === cur.id.toUpperCase()) cur.lines.push({ level: p[1], text: p.slice(2).join("|") });
    });
    if (list.length) { mods = list; statusKnown = true; }
  }
  function levelOf(m) {
    if (m.pending) return "pending";
    if (isPending(m)) return "pendingchange";
    if (!m.on) return "off";
    if (!m.applied) return "notapplied";
    if (m.lines.some(function (x) { return x.level === "FAIL"; })) return "fail";
    if (m.lines.some(function (x) { return x.level === "WARN"; })) return "warn";
    return "ok";
  }
  function stateText(m) {
    var lv = levelOf(m);
    if (lv === "pending") return "checking";
    if (lv === "pendingchange") return desired[m.id] ? "on after apply" : "off after apply";
    if (lv === "off") return "off";
    if (lv === "notapplied") return "not applied";
    var bad = m.lines.filter(function (x) { return x.level === "FAIL" || x.level === "WARN"; });
    if (bad.length) return bad.length + " to fix";
    return m.lines.every(function (x) { return x.level === "NA"; }) ? "nothing here" : "blocked";
  }
  // "owned by you" = every module that is on is applied and clean (pending
  // toggles do not change what is in place right now)
  function liveLevel(m) {
    if (!m.applied) return "notapplied";
    if (m.lines.some(function (x) { return x.level === "FAIL"; })) return "fail";
    if (m.lines.some(function (x) { return x.level === "WARN"; })) return "warn";
    return "ok";
  }
  function ownership() {
    if (!statusKnown) return "checking";
    var on = mods.filter(function (m) { return m.on; });
    if (!on.length || !on.some(function (m) { return m.applied; })) return "lg";
    return on.every(function (m) { return liveLevel(m) === "ok"; }) ? "you" : "partial";
  }

  /* ---------- render: main ---------- */
  function renderMain() {
    var own = ownership(), pend = pendingList().length, g = $("glass"), o = $("owner"), d = $("detail");
    g.className = "glass" + (own === "you" ? " owned" : own === "checking" ? " checking" : "");
    var onCount = mods.filter(function (m) { return m.on; }).length;
    if (own === "checking") { o.className = "owner busy"; o.innerHTML = 'Checking&hellip;'; d.textContent = ""; }
    else if (own === "you") { o.className = "owner you"; o.textContent = "Owned by you"; d.textContent = onCount + " protections in place"; }
    else if (own === "partial") { o.className = "owner busy"; o.textContent = "Partly yours"; d.textContent = "some protections need re-applying"; }
    else { o.className = "owner lg"; o.textContent = "Owned by LG"; d.textContent = "nothing applied yet"; }
    if (pend) d.textContent = pend + (pend === 1 ? " change" : " changes") + " waiting to be applied";
    var btns = $("main-actions").querySelectorAll("button"), ownBtn = btns[0];
    ownBtn.textContent = pend ? "Apply changes" : own === "you" ? "Give the glass back" : own === "partial" ? "Re-own the glass" : "Own the glass";
    ownBtn.disabled = own === "checking";
    if (ownBtn.disabled && focus.main === 0) { focus.main = 1; focus.autoMoved = true; }
    else if (!ownBtn.disabled && focus.autoMoved) { focus.main = 0; focus.autoMoved = false; }
    for (var i = 0; i < btns.length; i++) btns[i].className = "pill" + (i === 0 ? " primary" : "") + (screen === "main" && focus.main === i ? " focus" : "");
    $("device").textContent = (meta.model || "") + (meta.webos ? "  webOS " + meta.webos : "") + (meta.version ? "  v" + meta.version : "");
  }

  /* ---------- render: settings ---------- */
  function settingsItems() {
    var items = [{ section: "Protections" }];
    mods.forEach(function (m) { items.push({ kind: "module", m: m }); });
    items.push({ section: "Actions" });
    var pend = pendingList().length;
    items.push({ kind: "apply", name: pend ? "Apply " + pend + (pend === 1 ? " change" : " changes") : "Re-apply everything that is on", desc: "commit the toggles above" });
    items.push({ kind: "check", name: "Check again", desc: "re-read the status" });
    items.push({ kind: "purge", name: "Clear collected data", desc: "delete cached ads, ad logs, queued crash and log uploads, voice transcripts; reset the advertising ID" });
    items.push({ kind: "log", name: "Log", desc: "what the last job did" });
    items.push({ kind: "restore", name: "Give the glass back", desc: "undo every change, keep the app" });
    items.push({ kind: "uninstall", name: "Restore and uninstall", desc: "undo everything and remove this app", danger: true });
    return items;
  }
  var focusables = [];
  function renderSettings() {
    var list = $("settings-list"); list.innerHTML = ""; focusables = [];
    settingsItems().forEach(function (it) {
      if (it.section) { var h = document.createElement("div"); h.className = "section"; h.textContent = it.section; list.appendChild(h); return; }
      var d = document.createElement("div"), idx = focusables.length; focusables.push(it);
      var cls = "item", right = "", name = it.name, desc = it.desc, state = "";
      if (it.kind === "module") {
        var m = it.m, lv = levelOf(m); cls += " " + lv; name = NAMES[m.id] || m.id; desc = m.desc; state = stateText(m);
        right = '<div class="toggle' + (wantOn(m) ? " on" : "") + (isPending(m) ? " pending" : "") + '"></div>';
      } else { right = '<span class="chev">&#8250;</span>'; if (it.danger) cls += " danger"; }
      if (screen === "settings" && focus.settings === idx) cls += " focus";
      d.className = cls;
      var breaks = it.kind === "module" && it.m.breaks ? '<div class="breaks">' + esc(it.m.breaks) + '</div>' : "";
      d.innerHTML = '<div class="text"><div class="name">' + esc(name) + '</div><div class="desc">' + esc(desc) + '</div>' + breaks + '</div>' +
        (state ? '<div class="state">' + esc(state) + '</div>' : "") + right;
      d.onclick = function () { focus.settings = idx; renderSettings(); activateSettings(); };
      list.appendChild(d);
    });
    var pend = pendingList().length;
    $("settings-hint").textContent = pend ? pend + " pending" : (ownership() === "you" ? "all protections in place" : "");
    var f = list.querySelector(".focus"); if (f && f.scrollIntoView) f.scrollIntoView({ block: "center" });
  }
  function render() { renderMain(); if (screen === "settings") renderSettings(); }

  /* ---------- screens ---------- */
  function show(name) {
    prevScreen = screen; screen = name;
    if (name === "main") { focus.main = 0; focus.autoMoved = false; }   // the primary action is the default
    ["main", "settings", "log"].forEach(function (s) { $("screen-" + s).hidden = s !== name; });
    if (name === "settings") { var el = $("screen-settings"); el.style.animation = "none"; void el.offsetWidth; el.style.animation = ""; }
    render();
  }

  /* ---------- log + jobs ---------- */
  function showLog(t) {
    if (t === lastLog) return; lastLog = t;
    var el = $("log"); el.innerHTML = "";
    var lines = t.split("\n").filter(Boolean), last = "";
    lines.forEach(function (l) {
      var cls = /^== /.test(l) ? "head" : /^\s*ok /.test(l) ? "ok" : /^\s*FAIL|fatal/.test(l) ? "fail" : /^\s*warn/.test(l) ? "warn" : "";
      var s = document.createElement("div"); s.className = cls; s.textContent = l.replace(/^==\s*/, ""); el.appendChild(s); last = l;
    });
    el.scrollTop = el.scrollHeight;
    $("job-line").textContent = last.replace(/^==\s*/, "").replace(/^\s*(ok|warn|FAIL)\s+/, "");
  }
  function refresh(cb) {
    if (!TK) { cb && cb(); return; }
    sh("sh " + TK + "/oyg status 2>&1", function (e, out) {
      if (e || !/^META\|version/m.test(out || "")) {
        if (retries++ < 6) { setTimeout(function () { refresh(cb); }, 2500); return; }
        showLog("status failed: " + (e || out));
      } else { retries = 0; parseStatus(out); }
      render(); cb && cb();
    });
  }
  function job(title, cmd) {
    if (running || !TK) return;
    running = true; $("job").hidden = false; $("job-title").textContent = title; $("job-line").textContent = ""; $("logtitle").textContent = title; $("busy").textContent = "running";
    var full = "OYG_MASK_UNITS=0 sh " + TK + "/oyg " + cmd;
    sh(": > " + LOG + "; chmod 600 " + LOG + "; nohup sh -c " + sq(full + " >> " + LOG + " 2>&1; echo @@EXIT:$? >> " + LOG) + " >/dev/null 2>&1 </dev/null &",
      function () { poll(Date.now()); });
  }
  function poll(t0) {
    sh("tail -c 30000 " + LOG + " 2>/dev/null", function (e, out) {
      var m = /@@EXIT:(\d+)/.exec(out);
      showLog(out.replace(/@@EXIT:\d+\s*$/, ""));
      if (m || Date.now() - t0 > 600000) {
        running = false; $("job").hidden = true;
        $("busy").textContent = m ? (m[1] === "0" ? "done" : "finished with warnings") : "timed out";
        if (/app removal requested/.test(out)) { $("busy").textContent = "app removed"; show("log"); return; }
        statusKnown = false; mods.forEach(function (x) { x.pending = true; }); show("main"); refresh(); return;
      }
      setTimeout(function () { poll(t0); }, 800);
    });
  }
  function applyJob() {
    var args = pendingList().map(function (m) { return m.id + "=" + (desired[m.id] ? "on" : "off"); });
    desired = {}; saveDesired();
    job(args.length ? "Applying changes" : "Owning the glass", (args.length ? "sync " + args.join(" ") + " && sh " + TK + "/oyg " : "") + "apply");
  }

  /* ---------- actions ---------- */
  function activateMain() {
    if (focus.main === 0) {
      if ($("main-actions").querySelectorAll("button")[0].disabled) return;
      if (!pendingList().length && ownership() === "you") job("Giving the glass back", "restore"); else applyJob();
    } else { focus.settings = 0; show("settings"); }
  }
  function activateSettings() {
    var it = focusables[focus.settings]; if (!it) return;
    if (it.kind === "module") {
      var m = it.m; if (m.pending) return;
      var next = !wantOn(m);
      if (next === m.on) delete desired[m.id]; else desired[m.id] = next;
      saveDesired(); render(); return;
    }
    if (it.kind === "apply") applyJob();
    else if (it.kind === "check") { statusKnown = false; mods.forEach(function (m) { m.pending = true; }); render(); refresh(); }
    else if (it.kind === "purge") job("Clearing collected data", "purge");
    else if (it.kind === "log") show("log");
    else if (it.kind === "restore") job("Giving the glass back", "restore");
    else if (it.kind === "uninstall") job("Restoring the TV and removing the app", "uninstall --remove-app");
  }
  function exitApp() { if (window.webOS && webOS.platformBack) webOS.platformBack(); else window.close(); }
  // Exit confirm: the system alert (same one Homebrew Channel uses), whose
  // Exit button closes the app through the application manager. The in-app
  // dialog is only the fallback if the alert cannot be raised.
  function confirmExit() {
    var alert = { message: "Exit Own Your Glass?<br/>Everything applied stays in place while the app is closed.",
      buttons: [{ label: "Stay" }, { label: "Exit", onclick: "luna://com.webos.applicationManager/closeByAppId", params: { id: APPID } }] };
    sh("luna-send -a com.webos.service.secondscreen.gateway -n 1 -f luna://com.webos.notification/createAlert " + sq(JSON.stringify(alert)) + " </dev/null",
      function (e, out) { if (e || !/"returnValue"\s*:\s*true/.test(out || "")) showModal(true); });
  }
  function showModal(open) { modal.open = open; modal.i = 0; $("modal").hidden = !open; renderModal(); }
  function renderModal() {
    var b = document.querySelectorAll("#modal button");
    for (var i = 0; i < b.length; i++) b[i].className = "pill" + (modal.i === i ? " focus" : "");
  }
  document.querySelectorAll("#modal button").forEach(function (b) {
    b.onclick = function () { if (b.getAttribute("data-m") === "exit") exitApp(); else showModal(false); };
  });
  $("main-actions").querySelectorAll("button").forEach(function (b, i) { b.onclick = function () { focus.main = i; renderMain(); activateMain(); }; });

  document.addEventListener("keydown", function (ev) {
    var k = ev.keyCode;
    if (modal.open) {
      if (k === 461 || k === 27) showModal(false);
      else if (k === 37 || k === 39) { modal.i = modal.i ? 0 : 1; renderModal(); }
      else if (k === 13) { if (modal.i === 1) exitApp(); else showModal(false); }
      ev.preventDefault(); return;
    }
    if (running && k !== 461 && k !== 27) { ev.preventDefault(); return; }   // a job is running: only Back (to peek at the log)
    if (k === 461 || k === 27) {
      ev.preventDefault();
      if (screen === "log") { show(running ? "main" : "settings"); return; }
      if (screen === "settings") { show("main"); return; }
      if (running) { show("log"); return; }
      confirmExit(); return;
    }
    if (k === 13) { ev.preventDefault(); if (screen === "main") activateMain(); else if (screen === "settings") activateSettings(); return; }
    if (screen === "main") {
      var n = $("main-actions").querySelectorAll("button").length, first = $("main-actions").querySelectorAll("button")[0].disabled ? 1 : 0;
      if (k === 37 || k === 38) focus.main = Math.max(first, focus.main - 1);
      else if (k === 39 || k === 40) focus.main = Math.min(n - 1, focus.main + 1);
      else return;
    } else if (screen === "settings") {
      if (k === 38) focus.settings = Math.max(0, focus.settings - 1);
      else if (k === 40) focus.settings = Math.min(focusables.length - 1, focus.settings + 1);
      else return;
    } else if (screen === "log") {
      var el = $("log");
      if (k === 38) el.scrollTop -= 200; else if (k === 40) el.scrollTop += 200; else return;
    }
    ev.preventDefault(); render();
  });

  /* ---------- boot ---------- */
  function start() {
    render();
    var cands = ["/media/developer/apps/usr/palm/applications/" + APPID, "/media/cryptofs/apps/usr/palm/applications/" + APPID, "/usr/palm/applications/" + APPID];
    sh("for d in " + cands.join(" ") + "; do [ -x $d/toolkit/oyg ] && { echo $d/toolkit; break; }; done", function (e, out) {
      TK = (out || "").trim() || null;
      if (!TK) { $("owner").textContent = "root service missing"; $("detail").textContent = e ? String(e) : "toolkit directory not found"; return; }
      sh("tail -c 30000 " + LOG + " 2>/dev/null; [ -d /var/lib/own-your-glass/lock ] && echo @@LOCKED", function (e2, out) {
        out = out || "";
        if (/@@LOCKED/.test(out) && !/@@EXIT:/.test(out)) {
          running = true; $("job").hidden = false; $("job-title").textContent = "Still working"; $("logtitle").textContent = "Still working"; $("busy").textContent = "running";
          showLog(out.replace(/@@LOCKED\s*$/, "")); poll(Date.now()); return;
        }
        out = out.replace(/@@EXIT:\d+\s*$/, "").replace(/@@LOCKED\s*$/, "");
        if (out.trim()) showLog(out);
        else sh("sh " + TK + "/oyg log 2>/dev/null", function (e3, o3) { if (o3) { $("logtitle").textContent = "Toolkit log"; showLog(o3.replace(/^\S+ \S+ /mg, "")); } });
        refresh();
      });
      setInterval(function () { if (!running) refresh(); }, 30000);
    });
  }
  // brought back to the front (Home key, another app, or the launcher icon):
  // the TV may have changed meanwhile, so re-read the status
  document.addEventListener("visibilitychange", function () { if (!document.hidden && TK && !running) refresh(); });
  window.addEventListener("load", start);
})();
