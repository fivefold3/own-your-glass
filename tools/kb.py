#!/usr/bin/env python3
"""kb.py - the service knowledge base (kb/*.toml): check it, compare it with
the toolkit, and write the docs generated from it.

    tools/kb.py check      schema and safety rules (CI)
    tools/kb.py gen        write toolkit/etc/options.sh and owners.txt
    tools/kb.py docs       write docs/COMPATIBILITY.md (uses kb/presence.json)
    tools/kb.py drift      fail if the generated files are out of date (CI)
    tools/kb.py parity     (historical) the KB vs the module-era toolkit (1.4.0-1.4.3)

kb/presence.json comes from tools/spec-check.py --kb, run locally against
extracted firmware; LG firmware itself never enters this repository.
"""
import fnmatch, json, os, re, sys, tomllib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KB = os.path.join(REPO, "kb")
PRESETS = ("recommended", "strict", "lockdown")
FLAG_RE = re.compile(r"^(u|m|j=[A-Za-z0-9._-]+|L=(dynamic|static|unified|jailed))$")
RIC = ("aic", "eic", "kic", "cic", "ruc")   # kb/hosts.toml [codes]


def load():
    d = {}
    for f in ("categories", "options", "presets", "services", "sdx", "hosts", "settings", "apps"):
        with open(os.path.join(KB, f + ".toml"), "rb") as fh:
            d[f] = tomllib.load(fh)
    return d


def spec_line(s, released=False):
    """The spec line lib/svc.sh takes for a service record."""
    f = [s["id"], s.get("unit", ""), s.get("binary", ""), s.get("comm", ""), s.get("argmatch", "")]
    if released:
        return "|".join(f)
    return "|".join(f + [s.get("ls2", ""), ",".join(s.get("flags", []))])


def expand(name, cc=None):
    """Host templates: {ric}. -> aic./eic./kic. and the bare name; {cc}. -> country."""
    if name.startswith("{ric}."):
        base = name[6:]
        return [base] + [f"{r}.{base}" for r in RIC]
    if name.startswith("{cc}."):
        return [f"{cc}.{name[5:]}"] if cc else []
    return [name]


def lockdown_only(opt):
    return bool(opt.get("presets")) and set(opt["presets"]) <= {"lockdown"}


# ------------------------------------------------------------------ check --
def check(d):
    errs = []
    err = errs.append
    cats = {c["id"] for c in d["categories"]["category"]}
    opts = {}
    for o in d["options"]["option"]:
        if o["id"] in opts:
            err(f"option {o['id']}: duplicate id")
        opts[o["id"]] = o
        for k in ("category", "name", "what", "breaks", "presets", "since"):
            if k not in o:
                err(f"option {o['id']}: missing {k}")
        if o.get("category") not in cats:
            err(f"option {o['id']}: unknown category {o.get('category')}")
        for p in o.get("presets", []):
            if p not in PRESETS:
                err(f"option {o['id']}: unknown preset {p}")
    for p in d["presets"]["preset"]:
        if p["id"] not in PRESETS:
            err(f"preset {p['id']}: unknown")
    # the catalogue the app reads is |-separated, one record per line
    for kind, recs, fields in (("category", d["categories"]["category"], ("title", "blurb")),
                               ("option", d["options"]["option"], ("name", "what", "breaks", "warning", "detail")),
                               ("preset", d["presets"]["preset"], ("name", "summary", "warning"))):
        for r in recs:
            for f in fields:
                if any(c in str(r.get(f, "")) for c in "|\n"):
                    err(f"{kind} {r['id']}: {f} contains '|' or a line break")
    never = d["services"]["never"]
    hard, soft = never["paths"], never.get("soft_paths", [])
    never_ls2, ls2_allow = never["ls2"], never.get("ls2_allow", [])

    def denied(path, pats):
        return any(fnmatch.fnmatch(path, p) for p in pats)

    ids, ls2s = set(), {}
    for s in d["services"]["service"]:
        sid = s["id"]
        if sid in ids:
            err(f"service {sid}: duplicate id")
        ids.add(sid)
        o = opts.get(s.get("option"))
        if not o:
            err(f"service {sid}: unknown option {s.get('option')}")
            continue
        act = s.get("action", "block")
        if act not in ("block", "release"):
            err(f"service {sid}: unknown action {act}")
        if "since" not in s:
            err(f"service {sid}: missing since")
        b, comm = s.get("binary", ""), s.get("comm", "")
        if b == "?" and not comm:
            err(f"service {sid}: binary '?' needs a comm to find it by")
        if comm and comm[:15] == "com.webos.servi":
            err(f"service {sid}: comm {comm} is shared by many LG daemons; match by executable")
        if comm and b.startswith("/") and not b.endswith(".js") and os.path.basename(b)[:15] != comm[:15]:
            err(f"service {sid}: comm {comm} is not the first 15 characters of {os.path.basename(b)}")
        for fl in s.get("flags", []):
            if not FLAG_RE.match(fl):
                err(f"service {sid}: bad flag {fl}")
        if act == "block":
            if b.startswith("/") and denied(b, hard):
                err(f"service {sid}: {b} is on the hard never list")
            if b.startswith("/") and denied(b, soft) and not lockdown_only(o):
                err(f"service {sid}: {b} is soft never-touch; only a Lockdown-only option may block it")
            l = s.get("ls2", "")
            if l:
                if l in ls2s:
                    err(f"service {sid}: ls2 {l} also on {ls2s[l]}")
                ls2s[l] = sid
                if l not in ls2_allow and denied(l, never_ls2) and not lockdown_only(o):
                    err(f"service {sid}: ls2 {l} is on the never list")
    names = set()
    for n in d["sdx"]["name"]:
        nm = n["name"]
        if nm in names:
            err(f"sdx {nm}: duplicate")
        names.add(nm)
        act = n.get("action")
        if act not in ("block", "keep", "never"):
            err(f"sdx {nm}: unknown action {act}")
        if act == "block" and n.get("option") not in opts:
            err(f"sdx {nm}: block needs a known option")
        if act == "never" and "option" in n:
            err(f"sdx {nm}: a never name cannot belong to an option")
    hn = d["hosts"]["never"]
    codes = d["hosts"].get("codes", {})
    if tuple(codes.get("regions", [])) != RIC:
        err(f"hosts codes.regions must be {list(RIC)}")
    for c in codes.get("countries", []):
        if not re.fullmatch(r"[a-z]{2}", c):
            err(f"hosts codes.countries: {c} is not a two-letter code")
    seen = {}
    for h in d["hosts"]["host"]:
        if h.get("option") not in opts:
            err(f"hosts {h.get('names')}: unknown option")
        for name in h["names"]:
            for x in expand(name, "xx"):
                if x in seen and seen[x] != h["option"]:
                    err(f"host {x}: in two options ({seen[x]} and {h['option']})")
                seen[x] = h["option"]
                bad = x in hn["names"] or any(x.endswith(s) for s in hn["suffixes"])
                for p in hn["prefixed"]:
                    if x == p or (x.endswith("." + p) and x[: -len(p) - 1].count(".") == 0):
                        bad = True
                if bad:
                    err(f"host {x}: on the never list")
    # a literal region host (kr.x) of one option is what another option's
    # {cc}.x becomes on a TV in that country (kb.py cannot expand {cc})
    tmpl = {n[5:]: h["option"] for h in d["hosts"]["host"] if shipped(h) for n in h["names"] if n.startswith("{cc}.")}
    for h in d["hosts"]["host"]:
        if not shipped(h):
            continue
        for name in h["names"]:
            m = re.match(r"^[a-z]{2}\.(.+)$", name)
            if m and m.group(1) in tmpl and tmpl[m.group(1)] != h["option"]:
                err(f"host {name}: is {{cc}}.{m.group(1)} of option {tmpl[m.group(1)]} on a TV in that country")
    keys = set()
    for s in d["settings"]["setting"]:
        k = (s["category"], s["key"])
        if k in keys:
            err(f"setting {k}: duplicate")
        keys.add(k)
        if s.get("option") not in opts:
            err(f"setting {k}: unknown option")
        try:
            json.loads(s["value"])
        except Exception:
            err(f"setting {k}: value is not JSON: {s['value']}")
    apps = set()
    for a in d["apps"]["app"]:
        if a.get("option") not in opts:
            err(f"apps {a['ids'][:1]}: unknown option")
        for i in a["ids"]:
            if i in apps:
                err(f"app {i}: listed twice")
            apps.add(i)
    return errs


# ----------------------------------------------------------------- parity --
def _module_text(name):
    with open(os.path.join(REPO, "toolkit", "modules", name + ".sh")) as fh:
        return fh.read()


def _block(text, var):
    m = re.search(r"^" + var + r"='\n(.*?)^'", text, re.S | re.M)
    return [l for l in (m.group(1).splitlines() if m else []) if l.strip() and not l.startswith("#")]


def _dq(text, var):
    m = re.search(r"^" + var + r'="(.*?)"', text, re.S | re.M)
    return (m.group(1).split() if m else [])


def parity(d):
    diffs = []

    def cmp(what, kb, tk):
        kb, tk = set(kb), set(tk)
        for x in sorted(kb - tk):
            diffs.append(f"{what}: only in the KB: {x}")
        for x in sorted(tk - kb):
            diffs.append(f"{what}: only in the toolkit: {x}")

    svcs = d["services"]["service"]
    for mod in sorted({s["legacy"] for s in svcs if "legacy" in s}):
        text = _module_text(mod)
        up = mod.upper()
        cmp(f"{mod} spec", [spec_line(s) for s in svcs if s.get("legacy") == mod and s.get("action", "block") == "block"], _block(text, f"{up}_SPEC"))
        cmp(f"{mod} released", [spec_line(s, True) for s in svcs if s.get("legacy") == mod and s.get("action") == "release"], _block(text, f"{up}_RELEASED"))
    sdx = _module_text("sdx")
    cmp("sdx block", [n["name"] for n in d["sdx"]["name"] if n.get("legacy") == "sdx"], _dq(sdx, "SDX_BLOCK"))
    apps = _module_text("apps")
    cmp("apps", [i for a in d["apps"]["app"] if a.get("legacy") == "apps" for i in a["ids"]], _dq(apps, "APPS_IDS") or re.search(r"APPS_IDS='(.*?)'", apps, re.S).group(1).split())
    consent = _module_text("consent")
    tk = []
    for line in _block(consent, "CONSENT_SETTINGS"):
        cat, js = line.split("|", 1)
        for k, v in json.loads(js).items():
            tk.append(f"{cat}.{k}={json.dumps(v, sort_keys=True)}")
    cmp("consent settings", [f"{s['category']}.{s['key']}={json.dumps(json.loads(s['value']), sort_keys=True)}" for s in d["settings"]["setting"] if s.get("legacy") == "consent"], tk)
    e = d["settings"]["eula"]
    cmp("consent ids", e["ids"], _dq(consent, "CONSENT_IDS"))
    with open(os.path.join(REPO, "toolkit", "lib", "eula.sh")) as fh:
        cmp("consent flags", e["flags"], _dq(fh.read(), "EULA_TRACKING_FLAGS"))
    with open(os.path.join(REPO, "toolkit", "etc", "blocklist.txt")) as fh:
        tkh = [l.split("#")[0].split()[0] for l in fh if l.split("#")[0].strip()]
    cmp("hosts", [n for h in d["hosts"]["host"] if h.get("legacy") == "network" for n in h["names"]], tkh)
    with open(os.path.join(REPO, "toolkit", "lib", "common.sh")) as fh:
        cs = fh.read()
    m = re.search(r"bind_denied\(\) \{\n\s+case \$1 in\n\s+(.*?)\) return 0", cs, re.S)
    ms = re.search(r"# soft never.*?case \$1 in\n\s+(.*?)\) \[", cs, re.S)
    nv = d["services"]["never"]
    cmp("never paths", nv["paths"], m.group(1).split("|"))
    cmp("soft never paths", nv.get("soft_paths", []), ms.group(1).split("|"))
    with open(os.path.join(REPO, "toolkit", "lib", "blocklist.sh")) as fh:
        bl = fh.read()
    m = re.search(r"ls2_denied\(\) \{\n\s+case \$1 in\n(.*?)\n\s+esac", bl, re.S)
    body = m.group(1)
    allow = re.findall(r"^\s+([^\s|)]+)\) return 1", body, re.M)
    deny = re.search(r"^\s+(org\.webosbrew[^)]*)\) return 0", body, re.M).group(1).split("|")
    cmp("never ls2", nv["ls2"], deny)
    cmp("ls2 allow", nv.get("ls2_allow", []), allow)
    return diffs


# -------------------------------------------------------------------- gen --
def shipped(x):
    return x.get("since") != "planned" and not x.get("retire")


def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def var(oid):
    return oid.replace("-", "_")


def gen(d):
    """toolkit/etc/options.sh: the option catalogue and contents for the engine
    (lib/options.sh); toolkit/etc/owners.txt: which option owns a path, unit,
    LS2 name or setting (migration of module-era state)."""
    opts = [o for o in d["options"]["option"] if shipped(o)]
    ids = [o["id"] for o in opts]
    out = ["# options.sh - generated by tools/kb.py gen from kb/*.toml. Do not edit:",
           "# change the knowledge base and run tools/kb.py gen.", ""]
    pres = {}
    pj = os.path.join(KB, "presence.json")
    if os.path.exists(pj):
        with open(pj) as fh:
            pres = json.load(fh)
    out.append(f"OYG_KB_GENS={q(' '.join(pres.get('generations', [])))}")
    out.append(f"OYG_KB_RUN={q(' '.join(d['services'].get('run_on', {}).get('generations', [])))}")
    out.append(f"OYG_OPTIONS={q(' '.join(ids))}")
    cats = [c for c in d["categories"]["category"] if any(o["category"] == c["id"] for o in opts)]
    out.append(f"OYG_CATEGORIES={q(' '.join(c['id'] for c in cats))}")
    for c in cats:
        out.append(f"CAT_{var(c['id'])}_title={q(c['title'])}; CAT_{var(c['id'])}_blurb={q(c['blurb'])}")
    out.append("")
    for p in d["presets"]["preset"]:
        members = [o["id"] for o in opts if p["id"] in o.get("presets", []) and not o.get("needs_test")]
        if p["id"] == "lockdown" and not any(o["id"] for o in opts if o.get("presets") == ["lockdown"]):
            continue   # Lockdown ships with its own options
        out.append(f"PRESET_{p['id']}={q(' '.join(members))}")
        out.append(f"PRESET_{p['id']}_name={q(p['name'])}; PRESET_{p['id']}_summary={q(p['summary'])}; PRESET_{p['id']}_warning={q(p.get('warning', ''))}")
    out.append(f"OYG_PRESETS={q(' '.join(p['id'] for p in d['presets']['preset'] if 'PRESET_' + p['id'] + '=' in chr(10).join(out)))}")
    out.append("")
    svcs = d["services"]["service"]
    owners = []
    for o in opts:
        v = var(o["id"])
        out.append(f"# --- {o['id']}")
        for k in ("category", "name", "what", "breaks", "hook", "warning"):
            out.append(f"OPT_{v}_{k}={q(o.get(k, ''))}")
        out.append(f"OPT_{v}_presets={q(' '.join(o.get('presets', [])))}; OPT_{v}_untested={1 if o.get('needs_test') else 0}")
        mine = [s for s in svcs if s.get("option") == o["id"] and shipped(s)]
        for sfx, pick in (("spec", lambda s: not s.get("needs_test")), ("spec_t", lambda s: s.get("needs_test"))):
            lines = [spec_line(s) for s in mine if s.get("action", "block") == "block" and pick(s)]
            out.append(f"OPT_{v}_{sfx}={q(chr(10).join([''] + lines + ['']) if lines else '')}")
        rel = [spec_line(s, True) for s in d["services"]["service"] if s.get("option") == o["id"] and s.get("action") == "release" and s.get("since") != "planned"]
        out.append(f"OPT_{v}_released={q(chr(10).join([''] + rel + ['']) if rel else '')}")
        names = [n["name"] for n in d["sdx"]["name"] if n.get("option") == o["id"] and n["action"] == "block" and shipped(n)]
        out.append(f"OPT_{v}_sdx={q(' '.join(names))}")
        for sfx, pick in (("hosts", lambda h: not h.get("needs_test")), ("hosts_t", lambda h: h.get("needs_test"))):
            hs = [n for h in d["hosts"]["host"] if h.get("option") == o["id"] and shipped(h) and pick(h) for n in h["names"]]
            out.append(f"OPT_{v}_{sfx}={q(' '.join(hs))}")
        for sfx, pick in (("settings", lambda s: not s.get("needs_test")), ("settings_t", lambda s: s.get("needs_test"))):
            st = [f"{s['category']}|{s['key']}|{s['value']}" for s in d["settings"]["setting"] if s.get("option") == o["id"] and shipped(s) and pick(s)]
            out.append(f"OPT_{v}_{sfx}={q(chr(10).join([''] + st + ['']) if st else '')}")
        for sfx, pick in (("apps", lambda a: not a.get("needs_test")), ("apps_t", lambda a: a.get("needs_test"))):
            ap = [i for a in d["apps"]["app"] if a.get("option") == o["id"] and shipped(a) and pick(a) for i in a["ids"]]
            out.append(f"OPT_{v}_{sfx}={q(' '.join(ap))}")
        out.append("")
        for s in mine:
            if s.get("action", "block") != "block":
                continue
            b = s.get("binary", "")
            if b.startswith("/"):
                owners.append(f"bin|{b}|{o['id']}")
            if s.get("comm"):
                owners.append(f"comm|{s['comm']}|{o['id']}")
            if s.get("unit"):
                owners.append(f"unit|{s['unit']}|{o['id']}")
            if s.get("ls2"):
                owners.append(f"ls2|{s['ls2']}|{o['id']}")
            owners.append(f"id|{s['id']}|{o['id']}")
        for s in d["settings"]["setting"]:
            if s.get("option") == o["id"] and shipped(s):
                owners.append(f"set|{s['category']}.{s['key']}|{o['id']}")
    e = d["settings"]["eula"]
    out.append(f"EULA_IDS={q(' '.join(e['ids']))}")
    out.append(f"EULA_FLAGS={q(' '.join(e['flags']))}")
    hn = d["hosts"]["never"]
    out.append(f"NEVER_HOSTS={q(' '.join(hn['names']))}")
    out.append(f"NEVER_HOST_SUFFIXES={q(' '.join(hn['suffixes']))}")
    out.append(f"NEVER_HOST_PREFIXED={q(' '.join(hn['prefixed']))}")
    codes = d["hosts"]["codes"]
    out.append(f"OYG_RICS={q(' '.join(codes['regions']))}")
    out.append(f"OYG_COUNTRIES={q(' '.join(codes['countries']))}")
    files = {}
    files[os.path.join(REPO, "toolkit", "etc", "options.sh")] = "\n".join(out) + "\n"
    files[os.path.join(REPO, "toolkit", "etc", "owners.txt")] = "# owners.txt - generated by tools/kb.py gen: kind|key|option\n" + "\n".join(owners) + "\n"
    return files


def write_gen(d):
    for path, text in gen(d).items():
        with open(path, "w") as fh:
            fh.write(text)
        print("wrote", path)


def gen_drift(d):
    """paths whose committed content differs from what gen would write"""
    bad = []
    for path, text in gen(d).items():
        try:
            with open(path) as fh:
                if fh.read() != text:
                    bad.append(path)
        except FileNotFoundError:
            bad.append(path)
    return bad


# ------------------------------------------------------------------- docs --
def docs(d):
    pres = {}
    pj = os.path.join(KB, "presence.json")
    if os.path.exists(pj):
        with open(pj) as fh:
            pres = json.load(fh)
    gens = pres.get("generations", [])
    opts = {o["id"]: o for o in d["options"]["option"]}
    cats = d["categories"]["category"]
    out = ["# Compatibility", "",
           "Generated by `tools/kb.py docs` from `kb/*.toml` and `kb/presence.json` (which `tools/spec-check.py --kb` "
           "writes from extracted LG firmware). Do not edit by hand.", "",
           "The webOS release decides the service set far more than the model: one image per chip platform and "
           "version is shipped to every region. Presence is per webOS generation across the surveyed images "
           f"({', '.join(gens) or 'no survey data'}): ● on every image of that generation, ◐ on some, · on none.", ""]
    for c in cats:
        copts = [o for o in d["options"]["option"] if o["category"] == c["id"]]
        if not copts:
            continue
        out += [f"## {c['title']}", ""]
        for o in copts:
            pre = ", ".join(p.capitalize() for p in o.get("presets", [])) or "Custom only"
            state = "planned" if o["since"] == "planned" else f"since {o['since']}"
            out += [f"### {o['name']} (`{o['id']}`)", "",
                    f"{o['what']}" + (f" **Breaks:** {o['breaks']}." if o["breaks"] else "") + (f" {o['detail']}" if o.get("detail") else ""), "",
                    f"Presets: {pre}. {state.capitalize()}." + (" Not yet verified on a TV." if o.get("needs_test") else ""), ""]
            svcs = [s for s in d["services"]["service"] if s.get("option") == o["id"] and s.get("action", "block") == "block"]
            if svcs:
                out.append("| service | " + " | ".join(gens) + " | what |")
                out.append("|---|" + "---|" * len(gens) + "---|")
                for s in svcs:
                    row = pres.get("services", {}).get(s["id"], {})
                    cells = [{"all": "●", "some": "◐", "none": "·"}.get(row.get(g, ""), "?") for g in gens]
                    tag = " (planned)" if s.get("since") == "planned" else ""
                    out.append(f"| `{s['id']}`{tag} | " + " | ".join(cells) + f" | {s.get('what', '')} |")
                out.append("")
            names = [n["name"] for n in d["sdx"]["name"] if n.get("option") == o["id"]]
            if names:
                out += ["Gateway names routed nowhere: " + ", ".join(f"`{n}`" for n in names) + ".", ""]
    out += ["## Never touched", "", "These stay whatever the preset:", ""]
    out += [f"- {r}" for r in d["services"]["never"]["reasons"] + d["hosts"]["never"]["reasons"]]
    out += ["", "Gateway names: " + ", ".join(f"`{n['name']}`" for n in d["sdx"]["name"] if n["action"] == "never") + ".", ""]
    path = os.path.join(REPO, "docs", "COMPATIBILITY.md")
    with open(path, "w") as fh:
        fh.write("\n".join(out))
    # README: the options table between its markers
    rows = ["| option | Recommended | Strict | Lockdown | breaks | notes |", "|---|:-:|:-:|:-:|---|---|"]
    for c in cats:
        copts = [o for o in d["options"]["option"] if o["category"] == c["id"] and shipped(o)]
        if not copts:
            continue
        rows.append(f"| **{c['title']}** | | | | | |")
        for o in copts:
            mark = lambda p: ("●" if p in o.get("presets", []) and not o.get("needs_test") else ("○" if p in o.get("presets", []) else ""))
            note = " (not yet verified)" if o.get("needs_test") else ""
            rows.append(f"| {o['name']}{note} | {mark('recommended')} | {mark('strict')} | {mark('lockdown')} | {o['breaks'] or '–'} | {o.get('detail', '')} |")
    rows.append("")
    rows.append("● on in that preset, ○ joins it once verified on a TV.")
    rp = os.path.join(REPO, "README.md")
    with open(rp) as fh:
        rt = fh.read()
    rt = re.sub(r"(<!-- options:begin -->\n).*?(<!-- options:end -->)", lambda m: m.group(1) + "\n".join(rows) + "\n" + m.group(2), rt, flags=re.S)
    with open(rp, "w") as fh:
        fh.write(rt)
    return path


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    d = load()
    if cmd == "check":
        errs = check(d)
        for e in errs:
            print("kb:", e)
        print(f"kb check: {len(errs)} problem(s)")
        sys.exit(1 if errs else 0)
    if cmd == "parity":
        diffs = parity(d)
        for x in diffs:
            print("parity:", x)
        print(f"kb parity: {len(diffs)} difference(s) with toolkit/")
        sys.exit(1 if diffs else 0)
    if cmd == "gen":
        write_gen(d)
        return
    if cmd == "drift":
        bad = gen_drift(d)
        for b in bad:
            print("kb: generated file out of date (run tools/kb.py gen):", b)
        sys.exit(1 if bad else 0)
    if cmd == "docs":
        print("wrote", docs(d))
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
