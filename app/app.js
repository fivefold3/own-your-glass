/* Own Your Glass — TV app.
 *
 * Screens: main (status and one button: "Own the glass" / "Give the glass
 * back"; Settings in the top-right corner), settings (the protection level,
 * Customize, actions), customize (every option by category, saved as the
 * one Custom set) and log (also the TV report, with Copy to USB storage). Root comes from Homebrew Channel's service
 * (luna://org.webosbrew.hbchannel.service/exec); every action is
 * `oyg <command>` from the toolkit bundled with the app, run detached with
 * its output in a log file the app tails. The catalogue (categories,
 * presets, options) is read once with `oyg catalog`; the state is
 * `oyg status`, cheap enough to poll. The TV holds the truth: the app keeps
 * nothing but a draft while Customize is open.
 */
(function () {
  "use strict";
  var APPID = "org.ownyourglass.app";
  var SVC = "luna://org.webosbrew.hbchannel.service";
  // the job log and the TV report live in one root-only directory in /tmp
  // (shared into every app jail): made here as the toolkit makes it
  // (common.sh oyg_app_dir), a planted link removed first
  var DIR = "/tmp/.own-your-glass-app", LOG = DIR + "/job.log";
  var MKDIR = "[ -L " + DIR + " ] && rm -f " + DIR + "; [ -d " + DIR + " ] || mkdir -m 700 " + DIR + "; chmod 700 " + DIR + "; ";
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

  /* ---------- catalogue and state ---------- */
  var cats = [], presets = [], opts = [], optById = {};
  var meta = {}, state = {}, res = [], statusKnown = false, catalogKnown = false, running = false, retries = 0, lastLog = "";
  var draft = null;   // {optionId: true/false} while Customize has unsaved changes
  var restartOffered = "";   // the restart reasons already offered in a dialog
  var screen = "main", focus = { main: 0, customize: 0, settings: 0 }, modal = null;

  function parseCatalog(t) {
    cats = []; presets = []; opts = []; optById = {};
    t.split("\n").forEach(function (l) {
      var p = l.split("|");
      if (p[0] === "CAT") cats.push({ id: p[1], title: p[2], blurb: p[3] || "" });
      else if (p[0] === "PRESET") presets.push({ id: p[1], name: p[2], summary: p[3] || "", warning: p[4] || "", members: (p[5] || "").split(" ").filter(Boolean) });
      else if (p[0] === "OPT") {
        var o = { id: p[1], cat: p[2], name: p[3], what: p[4] || "", breaks: p[5] || "", presets: (p[6] || "").split(" ").filter(Boolean), warning: p[7] || "", untested: p[8] === "1" };
        opts.push(o); optById[o.id] = o;
      }
    });
    catalogKnown = opts.length > 0;
  }
  function parseStatus(t) {
    var m = {}, st = {}, rs = [], cur = null;
    t.split("\n").forEach(function (l) {
      var p = l.split("|");
      if (p[0] === "META") { m[p[1]] = p.slice(2).join("|"); return; }
      if (p[0] === "OPT") { cur = { id: p[1], on: p[2] === "1", applied: p[3] === "1", lines: [] }; st[cur.id] = cur; return; }
      if (p[0] === "RES") { cur = { id: p[1], lines: [] }; rs.push(cur); return; }
      if (p.length >= 3 && cur && p[0] === cur.id.toUpperCase()) cur.lines.push({ level: p[1], text: p.slice(2).join("|") });
    });
    if (Object.keys(st).length) { meta = m; state = st; res = rs; statusKnown = true; }
  }

  function lv(lines, level) { return lines.filter(function (x) { return x.level === level; }).length; }
  function optLevel(id) {
    var s = state[id];
    if (!s) return "pending";
    if (!s.on) return s.lines.length ? "warn" : "off";
    if (!s.applied) return "notapplied";
    if (lv(s.lines, "FAIL")) return "fail";
    if (lv(s.lines, "WARN")) return "warn";
    return "ok";
  }
  function optStateText(id) {
    var s = state[id], l = optLevel(id);
    if (l === "pending") return "checking";
    if (l === "off") return "allowed";
    if (l === "notapplied") return "not applied";
    var bad = lv(s.lines, "FAIL") + lv(s.lines, "WARN");
    if (bad) return bad + " to fix";
    if (s.lines.length && s.lines.every(function (x) { return x.level === "NA"; })) return "not on this TV";
    if (lv(s.lines, "SKIP")) return "blocked \u00b7 some left on this release";
    return lv(s.lines, "RESIDENT") ? "blocked \u00b7 restart to finish" : "blocked";
  }
  function selectedIds() { return opts.filter(function (o) { return state[o.id] && state[o.id].on; }).map(function (o) { return o.id; }); }
  // "owned by you" = every selected option is applied and clean
  function ownership() {
    if (!statusKnown) return "checking";
    var sel = selectedIds();
    if (!sel.length || !sel.some(function (id) { return state[id].applied; })) return "lg";
    var clean = sel.every(function (id) { return optLevel(id) === "ok"; }) && res.every(function (r) { return !lv(r.lines, "FAIL") && !lv(r.lines, "WARN"); });
    return clean ? "you" : "partial";
  }
  function residentCount() { return selectedIds().reduce(function (a, id) { return a + lv(state[id].lines, "RESIDENT"); }, 0); }
  function presetById(id) { for (var i = 0; i < presets.length; i++) if (presets[i].id === id) return presets[i]; return null; }
  function presetName(id) { if (id === "custom") return "Custom"; var p = presetById(id); return p ? p.name : id; }

  // re-apply at start-up is off (oyg status META|persist|0): by hand, or the
  // crash-loop breaker tripped after two unconfirmed starts (META|persist_off|breaker)
  function persistOff() { return statusKnown && meta.persist === "0"; }
  // toasts are off unless turned on (oyg status META|toasts|1)
  function toastsOn() { return statusKnown && meta.toasts === "1"; }
  // untested protections: entries not yet verified on a TV, and LG's
  // always-on services on a webOS release OYG has not run on (META|untested|1)
  function untestedOn() { return statusKnown && meta.untested === "1"; }
  var UNTESTED_TEXT = "Also applies what has not been verified on a TV: on this webOS release that includes LG's always-on logging and cloud services. Without them nothing is sent out, but they keep collecting on the TV. With them, if a screen stops responding, use Give the glass back or turn this off; if the TV does not start properly twice in a row, re-apply switches itself off and the TV comes up stock.";
  function switchRight(on) { return '<div class="toggle' + (on ? " on" : "") + '"></div>'; }
  function persistText() {
    if (!persistOff()) return "";
    return meta.persist_off === "breaker" ? "Not re-applied at start-up: two starts were not confirmed" : "Not re-applied at start-up";
  }
  // a restart finishes the job: something waits for one (oyg status
  // META|restart), or blocked services were already loaded (RESIDENT)
  function restartNeeded() { return statusKnown && (!!meta.restart || residentCount() > 0); }
  function restartText() {
    var t = [];
    if (meta.restart) t.push(meta.restart + " after the TV restarts.");
    if (residentCount()) t.push("Some blocked services stay loaded until the TV restarts.");
    return t.join(" ");
  }

  /* ---------- render: main ---------- */
  // main targets: the one action (0), Settings in the corner (1) and, while
  // a restart is needed, Restart now under the action (2)
  function mainButtons() { return [$("own-btn"), $("settings-btn"), $("restart-btn")]; }
  function renderMain() {
    var own = ownership(), g = $("glass"), o = $("owner"), d = $("detail");
    g.className = "glass" + (own === "you" ? " owned" : own === "checking" ? " checking" : "");
    var n = selectedIds().length, pn = presetName(meta.preset || "recommended");
    if (own === "checking") { o.className = "owner busy"; o.innerHTML = "Checking&hellip;"; d.textContent = ""; }
    else if (own === "you") { o.className = "owner you"; o.textContent = "Owned by you"; d.textContent = pn + " \u00b7 " + n + " protections in place"; }
    else if (own === "partial") { o.className = "owner busy"; o.textContent = "Partly yours"; d.textContent = pn + " \u00b7 some protections need re-applying"; }
    else { o.className = "owner lg"; o.textContent = "Owned by LG"; d.textContent = (meta.givenback ? "Given back · " : "") + pn + " is ready to apply"; }
    var trial = (meta.trial || "").split(" ").filter(Boolean).map(function (id) { return optById[id] ? optById[id].name : id; }).join(", ");
    var rn = restartNeeded(), notes = [meta.notice || "", trial ? "Trying: " + trial + " \u00b7 restart the TV to undo" : "", rn ? "Restart required" : "", persistText(), meta.account ? "LG Account signed in" : ""].filter(Boolean);
    var nt = $("notice"); nt.hidden = !notes.length; nt.textContent = notes.join("  \u00b7  ");
    var b = mainButtons();
    b[0].textContent = own === "you" ? "Give the glass back" : own === "partial" ? "Re-own the glass" : "Own the glass";
    b[0].disabled = own === "checking";
    if (b[0].disabled && focus.main === 0) { focus.main = 1; focus.autoMoved = true; }
    else if (!b[0].disabled && focus.autoMoved) { focus.main = 0; focus.autoMoved = false; }
    b[2].hidden = !rn;
    if (!rn && focus.main === 2) focus.main = 0;
    b[0].className = "pill primary" + (screen === "main" && focus.main === 0 ? " focus" : "");
    b[1].className = "pill corner" + (screen === "main" && focus.main === 1 ? " focus" : "");
    b[2].className = "pill" + (screen === "main" && focus.main === 2 ? " focus" : "");
    $("device").textContent = (meta.model || "") + (meta.webos ? "  webOS " + meta.webos : "") + (meta.version ? "  v" + meta.version : "");
  }

  /* ---------- lists (settings, customize) ---------- */
  var focusables = [];
  function renderList(listId, items, hintId, hint) {
    var list = $(listId); list.innerHTML = ""; focusables = [];
    items.forEach(function (it) {
      if (it.section) {
        var h = document.createElement("div"); h.className = "section"; h.textContent = it.section; list.appendChild(h);
        if (it.blurb) { var bl = document.createElement("div"); bl.className = "blurb"; bl.textContent = it.blurb; list.appendChild(bl); }
        return;
      }
      var idx = focusables.length; focusables.push(it);
      var d = document.createElement("div");
      d.className = "item" + (it.cls ? " " + it.cls : "") + (it.disabled ? " disabled" : "") + (focus[screen] === idx ? " focus" : "");
      d.innerHTML = '<div class="text"><div class="name">' + esc(it.name) + '</div>' +
        (it.desc ? '<div class="desc">' + esc(it.desc) + '</div>' : "") +
        (it.breaks ? '<div class="breaks">' + esc(it.breaks) + '</div>' : "") + '</div>' +
        (it.state ? '<div class="state">' + esc(it.state) + '</div>' : "") + (it.right || '<span class="chev">&#8250;</span>');
      d.onclick = function () { focus[screen] = idx; render(); activate(); };
      d.onmouseenter = function () { pointAt(idx); };
      list.appendChild(d);
    });
    $(hintId).textContent = hint || "";
    var f = list.querySelector(".focus"); if (f && f.scrollIntoView) f.scrollIntoView({ block: "center" });
  }
  // the Magic Remote pointer: move the highlight in place (no re-render, so
  // the row under the pointer stays the same element); keys carry on from it
  function pointAt(idx) {
    if (running || modal || focus[screen] === idx) return;
    var list = $(screen + "-list"); if (!list) return;
    var items = list.querySelectorAll(".item");
    if (items[focus[screen]]) items[focus[screen]].classList.remove("focus");
    focus[screen] = idx;
    if (items[idx]) items[idx].classList.add("focus");
  }
  // while the status is being checked the selection shown could be stale:
  // the presets show no choice and cannot be picked until it is known
  function protectionItems() {
    var checking = !statusKnown, cur = checking ? "" : (meta.preset || "recommended"), items = [{ section: "Protection level" }];
    var radio = function (on) { return '<div class="radio' + (checking ? " dim" : on ? " on" : "") + '"></div>'; };
    presets.forEach(function (p) {
      items.push({ kind: "preset", id: p.id, name: p.name, desc: p.summary,
        cls: cur === p.id ? "ok" : "", disabled: checking, right: radio(cur === p.id) });
    });
    if (meta.custom_base) {
      items.push({ kind: "preset", id: "custom", name: "Custom", desc: "Your own selection, based on " + presetName(meta.custom_base),
        cls: cur === "custom" ? "ok" : "", disabled: checking, right: radio(cur === "custom") });
    }
    items.push({ kind: "customize", name: "Customize", desc: "Choose each protection yourself", disabled: checking });
    return items;
  }
  function wantOn(id) { return draft && (id in draft) ? draft[id] : !!(state[id] && state[id].on); }
  function draftChanges() { return draft ? Object.keys(draft).filter(function (id) { return draft[id] !== !!(state[id] && state[id].on); }) : []; }
  function customizeItems() {
    var items = [], ch = draftChanges().length;
    cats.forEach(function (c) {
      var mine = opts.filter(function (o) { return o.cat === c.id; });
      if (!mine.length) return;
      items.push({ section: c.title });
      mine.forEach(function (o) {
        var on = wantOn(o.id), changed = draft && (o.id in draft) && draft[o.id] !== !!(state[o.id] && state[o.id].on);
        items.push({ kind: "option", id: o.id, name: o.name + (o.untested ? " (untested)" : ""), desc: o.what,
          breaks: o.breaks ? "Breaks: " + o.breaks : "", state: changed ? (on ? "blocked after saving" : "allowed after saving") : optStateText(o.id),
          cls: changed ? "pendingchange" : optLevel(o.id),
          right: '<div class="toggle' + (on ? " on" : "") + (changed ? " pending" : "") + '"></div>' });
      });
    });
    items.push({ section: "Save" });
    items.push({ kind: "save", name: ch ? "Save as Custom and apply (" + ch + (ch === 1 ? " change)" : " changes)") : "Save as Custom and apply", desc: "Your one saved selection", disabled: !statusKnown });
    if (ch) items.push({ kind: "discard", name: "Discard changes" });
    return items;
  }
  function settingsItems() {
    var pending = restartNeeded();
    var top = pending ? [{ section: "Restart required" }, { kind: "reboot", name: "Restart the TV now", desc: restartText(), cls: "pendingchange" }] : [];
    if (meta.account) top = top.concat([{ section: "LG Account" }, { kind: "signout", name: "Sign out of LG account",
      desc: "Stops the terms prompt and account tracking", cls: "pendingchange" }]);
    return top.concat(protectionItems()).concat([{ section: "Actions" },
      { kind: "apply", name: "Re-apply" },
      { kind: "check", name: "Check again" },
      { kind: "persist", name: "Re-apply at start-up", desc: persistOff() ? (meta.persist_off === "breaker" ? "Switched off after two starts were not confirmed. Turn it on to re-apply after every restart." : "A restart brings the stock TV back until you press Own the glass") : "Protections come back after every restart",
        state: persistOff() ? "off" : "on", disabled: !statusKnown, right: switchRight(!persistOff()) },
      { kind: "toasts", name: "Notifications", desc: toastsOn() ? "Own Your Glass shows a short message on the TV screen when it applies, restores or clears data" : "Own Your Glass shows no messages on the TV screen",
        state: toastsOn() ? "on" : "off", disabled: !statusKnown, right: switchRight(toastsOn()) },
      { kind: "untested", name: "Untested protections", desc: untestedOn() ? "Protections not yet verified on a TV are applied too, LG's always-on services on this webOS release included. Turn off if a screen stops responding." : (meta.run === "0" ? "Off: LG's always-on services stay running on this webOS release (nothing is sent out, but they keep collecting). Turn on to be the first to try them." : "Off: only protections verified on a TV are applied"),
        state: untestedOn() ? "on" : "off", disabled: !statusKnown, right: switchRight(untestedOn()) },
      { kind: "purge", name: "Clear collected data", desc: "Ad caches, logs, voice transcripts, the ad ID" },
      { kind: "survey", name: "Generate a TV report", desc: "Basic information and services. No unique or personal identifiers are recorded." },
      { kind: "log", name: "Log" }]).concat(pending ? [] : [
      { kind: "reboot", name: "Restart the TV" }]).concat([
      { section: "Undo" },
      { kind: "restore", name: "Give the glass back", desc: "Undo every change" },
      { kind: "uninstall", name: "Restore and uninstall", desc: "Undo everything and remove the app", cls: "danger" }]);
  }
  function render() {
    renderMain();
    if (screen === "customize") renderList("customize-list", customizeItems(), "customize-hint", draftChanges().length ? draftChanges().length + " unsaved" : "");
    else if (screen === "settings") renderList("settings-list", settingsItems(), "settings-hint", statusKnown ? presetName(meta.preset || "recommended") : "Checking\u2026");
    renderReport();
  }

  /* ---------- screens ---------- */
  function show(name) {
    if (name !== "log") closeReport();
    screen = name;
    if (name === "main") { focus.main = 0; focus.autoMoved = false; }
    ["main", "customize", "settings", "log"].forEach(function (s) { $("screen-" + s).hidden = s !== name; });
    if (name !== "main" && name !== "log") { var el = $("screen-" + name); el.style.animation = "none"; void el.offsetWidth; el.style.animation = ""; }
    render();
  }

  /* ---------- dialogs ---------- */
  // buttons: [{label, fn}]; the first is the safe choice (Cancel, Later) and
  // has the focus
  function dialog(title, text, buttons) {
    modal = { i: 0, btns: buttons };
    $("mtitle").textContent = title; $("mtext").textContent = text;
    var box = $("mbtns"); box.innerHTML = "";
    buttons.forEach(function (b, i) {
      var el = document.createElement("button"); el.className = "pill"; el.textContent = b.label;
      el.onclick = function () { pick(i); };
      el.onmouseenter = function () { if (modal) { modal.i = i; renderModal(); } };
      box.appendChild(el);
    });
    $("modal").hidden = false; renderModal();
  }
  function ask(title, text, yes, no, onYes) { dialog(title, text, [{ label: no }, { label: yes, fn: onYes }]); }
  function pick(i) { var b = modal && modal.btns[i]; closeModal(); if (b && b.fn) b.fn(); }
  function closeModal() { modal = null; $("modal").hidden = true; }
  function renderModal() { [].forEach.call($("mbtns").children, function (el, i) { el.className = "pill" + (modal && modal.i === i ? " focus" : ""); }); }

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
    var done = function () { render(); cb && cb(); };
    var status = function () {
      sh("sh " + TK + "/oyg status 2>&1", function (e, out) {
        if (e || !/^META\|version/m.test(out || "")) {
          if (retries++ < 6) { setTimeout(function () { refresh(cb); }, 2500); return; }
          showLog("status failed: " + (e || out));
        } else { retries = 0; parseStatus(out); }
        done();
      });
    };
    if (catalogKnown) { status(); return; }
    sh("sh " + TK + "/oyg catalog 2>&1", function (e, out) { if (!e) parseCatalog(out || ""); status(); });
  }
  // when it is done, a job returns to the screen it was started from
  // (Customize's save to Settings), unless it says otherwise
  function job(title, cmd, then) {
    if (running || !TK) return;
    var from = screen === "customize" ? "settings" : screen === "log" ? "main" : screen;
    then = then || function () { show(from); };
    running = true; $("job").hidden = false; $("job-title").textContent = title; $("job-line").textContent = ""; $("logtitle").textContent = title; $("busy").textContent = "running";
    var full = "sh " + TK + "/oyg " + cmd;
    sh(MKDIR + ": > " + LOG + "; chmod 600 " + LOG + "; nohup sh -c " + sq(full + " >> " + LOG + " 2>&1; echo @@EXIT:$? >> " + LOG) + " >/dev/null 2>&1 </dev/null &",
      function () { poll(Date.now(), then); });
  }
  function poll(t0, then) {
    then = then || function () {};
    sh("tail -c 30000 " + LOG + " 2>/dev/null", function (e, out) {
      var m = /@@EXIT:(\d+)/.exec(out);
      showLog(out.replace(/@@EXIT:\d+\s*$/, ""));
      if (m || Date.now() - t0 > 600000) {
        running = false; $("job").hidden = true;
        $("busy").textContent = m ? (m[1] === "0" ? "done" : "finished with warnings") : "timed out";
        if (/app removal requested/.test(out)) { $("busy").textContent = "app removed"; show("log"); return; }
        statusKnown = false; draft = null;
        then();
        refresh(offerRestart); return;
      }
      setTimeout(function () { poll(t0, then); }, 800);
    });
  }
  // a run the app did not start holds the lock (the boot apply, its late
  // pass, a command over SSH): it writes no exit line to the app log, so
  // wait for the lock to go instead, showing the toolkit log meanwhile
  function waitLock(t0) {
    sh("[ -d /var/lib/own-your-glass/lock ] && echo @@LOCKED; sh " + TK + "/oyg log 2>/dev/null", function (e, out) {
      out = out || "";
      var locked = /^@@LOCKED/m.test(out);
      showLog(out.replace(/^@@LOCKED\s*/, "").replace(/^\S+ \S+ /mg, ""));
      if (locked && Date.now() - t0 < 600000) { setTimeout(function () { waitLock(t0); }, 2000); return; }
      running = false; $("job").hidden = true; $("busy").textContent = locked ? "timed out" : "done";
      statusKnown = false; refresh(offerRestart);
    });
  }

  /* ---------- TV report: copy to USB storage ---------- */
  // while the report is on the log screen: Copy to USB storage, greyed out
  // until the TV has USB storage mounted (asked every few seconds). The copy
  // runs directly, not as a job, so the report stays on screen.
  // The screen shows the report file itself, the one the copy saves.
  var REPORT = DIR + "/report.txt";   // toolkit survey.sh SURVEY_FILE
  var report = null;   // {usb, note, busy, asking, timer} while the report is shown
  function openReport() {
    report = { usb: "", note: "", busy: false, asking: false, timer: setInterval(usbCheck, 3000) };
    $("logtitle").textContent = "TV report";   // the job titled it "Generating report"
    show("log");
    sh("cat " + REPORT + " 2>/dev/null", function (e, out) { if (report && out) { showLog(out); $("log").scrollTop = 0; } });
    usbCheck();
  }
  function closeReport() { if (report) { clearInterval(report.timer); report = null; } }
  function usbCheck() {
    if (!report || report.busy || report.asking || !TK) return;
    report.asking = true;
    sh("sh " + TK + "/oyg survey usb-check 2>/dev/null", function (e, out) {
      if (!report) return;
      report.asking = false;
      var usb = (/^USB\|(.+)$/m.exec(out || "") || [])[1] || "";
      if (usb !== report.usb) { report.usb = usb; report.note = ""; }
      renderReport();
    });
  }
  function usbCopy() {
    if (!report || !report.usb || report.busy) return;
    report.busy = true; report.note = ""; renderReport();
    sh("sh " + TK + "/oyg survey usb 2>&1 || :", function (e, out) {   // a non-zero exit would lose the output
      if (!report) return;
      report.busy = false;
      var m = /saved to USB storage: (\S+)/.exec(out || ""), err = (out || e || "").trim().split("\n").pop();
      report.note = m ? "Saved as " + m[1] : "Could not copy: " + (err.replace(/^\s*(fatal|FAIL|warn):?\s*/, "") || "unknown error");
      renderReport();
    });
  }
  function renderReport() {
    var bar = $("logbar"), b = $("usb-btn");
    bar.hidden = !report || screen !== "log";
    if (bar.hidden) return;
    b.disabled = !report.usb || report.busy;
    b.textContent = report.busy ? "Copying\u2026" : "Copy to USB storage";
    b.className = "pill" + (b.disabled ? "" : " focus");
    $("usb-hint").textContent = report.note || (report.usb ? "" : "No USB storage connected");
  }

  /* ---------- actions ---------- */
  function reboot() { job("Restarting the TV", "reboot"); }
  // after a job, when something now waits for a restart: ask once
  function askRestart(extra) { ask("Restart the TV now?", restartText() + (extra || ""), "Restart now", "Later", reboot); }
  function offerRestart() {
    var key = (meta.restart || "") + "|" + residentCount();
    if (!restartNeeded() || key === restartOffered || modal) return;
    restartOffered = key;
    askRestart();
  }
  // turning on "Stay signed out of LG account" while an account is signed in
  // asks first
  var SIGNOUT_TEXT = "Any LG account is removed and signing in is blocked. Turn Block LG account off when you need to sign in.";
  function signsOut(ids) { return !!meta.account && ids.indexOf("account") >= 0 && !(state.account && state.account.on); }
  function choosePreset(id) {
    if (id === (meta.preset || "recommended")) { job("Applying " + presetName(id), "apply"); return; }
    var p = presetById(id), go = function () { job("Switching to " + presetName(id), "preset " + id); };
    var members = p ? p.members : (meta.preset === "custom" ? selectedIds() : []);
    var then = go;
    if (signsOut(members)) then = function () { ask("Block your LG account?", SIGNOUT_TEXT, "Block and switch", "Cancel", go); };
    if (p && p.warning) ask("Apply " + p.name + "?", p.warning, "Apply anyway", "Cancel", then); else then();
  }
  function saveCustom() {
    var base = meta.preset === "custom" ? (meta.custom_base || "recommended") : (meta.preset || "recommended");
    var args = ["base=" + base].concat(opts.map(function (o) { return o.id + "=" + (wantOn(o.id) ? "on" : "off"); }));
    job("Saving your selection", "set " + args.join(" "));   // turning the sign-out option on already asked (its warning)
  }
  function toggleOption(o) {
    var next = !wantOn(o.id);
    var commit = function () { draft = draft || {}; draft[o.id] = next; render(); };
    if (next && o.warning) ask("Turn on " + o.name + "?", o.warning, "Turn on", "Cancel", commit); else commit();
  }
  // Re-apply at start-up and Notifications flip in place: each is a flag
  // the toolkit reads, nothing to apply or re-check. The switch shows the
  // new state at once and goes back if the call fails.
  function flipFlag(cmd, on, set, then) {
    if (!TK) return;
    var was = { persist: meta.persist, persist_off: meta.persist_off, toasts: meta.toasts, untested: meta.untested };
    set(); render();
    sh("sh " + TK + "/oyg " + cmd + " " + (on ? "on" : "off") + " 2>&1", function (e, out) {
      if (e || !/^\s*ok /m.test(out)) { meta.persist = was.persist; meta.persist_off = was.persist_off; meta.toasts = was.toasts; meta.untested = was.untested; render(); return; }
      then && then();
    });
  }
  function setPersist(on) { flipFlag("persist", on, function () { meta.persist = on ? "1" : "0"; if (on) delete meta.persist_off; else meta.persist_off = "user"; }); }
  function toggleToasts() { var on = !toastsOn(); flipFlag("toasts", on, function () { meta.toasts = on ? "1" : "0"; }); }
  // untested changes what an apply does, so the flag is followed by a
  // re-apply when something is applied (turning it off restores the extras)
  function setUntested(on) {
    flipFlag("untested", on, function () { meta.untested = on ? "1" : "0"; }, function () {
      if (ownership() !== "lg") job(on ? "Applying untested protections" : "Removing untested protections", "apply");
    });
  }
  function activateMain() {
    var b = mainButtons();
    if (focus.main === 0) {
      if (b[0].disabled) return;
      if (ownership() === "you") job("Giving the glass back", "restore"); else job("Owning the glass", "apply");
    } else if (focus.main === 2) askRestart();
    else { focus.settings = 0; show("settings"); }
  }
  function activate() {
    if (screen === "main") { activateMain(); return; }
    if (screen === "log") { usbCopy(); return; }   // the report's one button
    var it = focusables[focus[screen]]; if (!it || it.disabled) return;
    if (it.kind === "preset") choosePreset(it.id);
    else if (it.kind === "customize") { draft = null; focus.customize = 0; show("customize"); }
    else if (it.kind === "option") toggleOption(optById[it.id]);
    else if (it.kind === "save") saveCustom();
    else if (it.kind === "discard") { draft = null; render(); }
    else if (it.kind === "apply") job("Applying", "apply");
    else if (it.kind === "check") { statusKnown = false; render(); refresh(); }
    else if (it.kind === "persist") { if (persistOff()) setPersist(true); else ask("Turn re-apply at start-up off?", "A restart then brings the stock TV back until you press Own the glass again.", "Turn off", "Cancel", function () { setPersist(false); }); }
    else if (it.kind === "toasts") toggleToasts();
    else if (it.kind === "untested") { if (untestedOn()) setUntested(false); else ask("Turn on untested protections?", UNTESTED_TEXT, "Turn on", "Cancel", function () { setUntested(true); }); }
    else if (it.kind === "purge") job("Clearing collected data", "purge");
    else if (it.kind === "survey") job("Generating report", "survey", openReport);
    else if (it.kind === "log") show("log");
    else if (it.kind === "signout") dialog("Sign out of your LG account?",
      "Sign out keeps the account on this TV. Remove account deletes it; signing in again needs your password.",
      [{ label: "Cancel" }, { label: "Sign out", fn: function () { job("Signing out of your LG account", "account signout"); } },
       { label: "Remove account", fn: function () { job("Removing your LG account from this TV", "account remove"); } }]);
    else if (it.kind === "reboot") { if (restartNeeded()) askRestart(); else ask("Restart the TV now?", "The TV turns off and on again. Everything applied stays in place.", "Restart now", "Cancel", reboot); }
    else if (it.kind === "restore") job("Giving the glass back", "restore");
    else if (it.kind === "uninstall") ask("Restore and uninstall?", "Every change is undone and the app is removed.", "Uninstall", "Cancel", function () { job("Restoring the TV and removing the app", "uninstall --remove-app"); });
  }
  // Back on the main screen: the system's own "exit app?" prompt, what
  // webOS.platformBack() does (webOSTV.js calls PalmSystem.platformBack).
  // Nothing waits on the toolkit, so it works while a check or job runs; a
  // running job carries on without the app.
  function exitApp() {
    if (window.PalmSystem && window.PalmSystem.platformBack) window.PalmSystem.platformBack();
    else if (window.webOS && window.webOS.platformBack) window.webOS.platformBack();
    else window.close();
  }
  function back() {
    if (screen === "log") { show(running ? "main" : "settings"); return; }
    if (screen === "customize") {
      if (draftChanges().length) { ask("Discard your changes?", "They have not been saved.", "Discard", "Keep editing", function () { draft = null; show("settings"); }); return; }
      show("settings"); return;
    }
    if (screen !== "main") { show("main"); return; }
    exitApp();
  }
  $("usb-btn").onclick = usbCopy;
  mainButtons().forEach(function (b, i) {
    b.onclick = function () { focus.main = i; renderMain(); activateMain(); };
    b.onmouseenter = function () { if (!running && !modal && !b.disabled && !b.hidden) { focus.main = i; focus.autoMoved = false; renderMain(); } };
  });

  document.addEventListener("keydown", function (ev) {
    var k = ev.keyCode;
    if (modal) {
      if (k === 461 || k === 27) closeModal();
      else if (k === 37) { modal.i = Math.max(0, modal.i - 1); renderModal(); }
      else if (k === 39) { modal.i = Math.min(modal.btns.length - 1, modal.i + 1); renderModal(); }
      else if (k === 13) pick(modal.i);
      ev.preventDefault(); return;
    }
    if (running && k !== 461 && k !== 27) { ev.preventDefault(); return; }   // a job is running: only Back (to peek at the log)
    if (k === 461 || k === 27) { ev.preventDefault(); back(); return; }
    if (k === 13) { ev.preventDefault(); activate(); return; }
    if (screen === "main") {
      // Restart now sits under the main action; Settings is up and right
      var mb = mainButtons(), canMain = !mb[0].disabled, canRestart = !mb[2].hidden;
      if (k === 38) focus.main = focus.main === 2 && canMain ? 0 : 1;
      else if (k === 39) focus.main = 1;
      else if (k === 40) { if (focus.main === 1 && canMain) focus.main = 0; else if (canRestart) focus.main = 2; }
      else if (k === 37 && focus.main === 1) focus.main = canMain ? 0 : canRestart ? 2 : 1;
      else return;
    } else if (screen === "log") {
      var el = $("log");
      if (k === 38) el.scrollTop -= 200; else if (k === 40) el.scrollTop += 200; else return;
    } else {
      if (k === 38) focus[screen] = Math.max(0, focus[screen] - 1);
      else if (k === 40) focus[screen] = Math.min(focusables.length - 1, focus[screen] + 1);
      else return;
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
      sh("tail -c 30000 " + LOG + " 2>/dev/null; [ -d /var/lib/own-your-glass/lock ] && echo @@LOCKED", function (e2, out2) {
        out2 = out2 || "";
        if (/@@LOCKED/.test(out2) && !/@@EXIT:/.test(out2)) {
          running = true; $("job").hidden = false; $("job-title").textContent = "Still working"; $("logtitle").textContent = "Still working"; $("busy").textContent = "running";
          showLog(out2.replace(/@@LOCKED\s*$/, "")); waitLock(Date.now()); return;
        }
        out2 = out2.replace(/@@EXIT:\d+\s*$/, "").replace(/@@LOCKED\s*$/, "");
        if (out2.trim()) showLog(out2);
        else sh("sh " + TK + "/oyg log 2>/dev/null", function (e3, o3) { if (o3) { $("logtitle").textContent = "Toolkit log"; showLog(o3.replace(/^\S+ \S+ /mg, "")); } });
        refresh();
      });
      setInterval(function () { if (!running && screen !== "customize") refresh(); }, 30000);
    });
  }
  // brought back to the front (Home key, another app, or the launcher icon):
  // the TV may have changed meanwhile, so re-read the status
  document.addEventListener("visibilitychange", function () { if (!document.hidden && TK && !running) refresh(); });
  window.addEventListener("load", start);
})();
