#!/usr/bin/env python3
"""spec-check.py - resolve the toolkit's service specs against extracted LG firmware.

Reads the spec lines in toolkit/modules/*.sh and resolves each one the way
lib/svc.sh does on a TV (explicit path, else the comm name in the usual bin
dirs, else the unit's ExecStart), with symlinks followed inside the image
(webOS 11 is usr-merged). For each entry it finds the LS2 registration and
compares it with the spec's ls2 and L= fields. It also runs the toolkit's own
sdx parser over the factory gateway table.

    tools/spec-check.py <image-dir>...          # dirs holding fs/rootfs (or rootfs)
    tools/spec-check.py --all <images-dir> [--also <image-dir>...]
    tools/spec-check.py --kb --all <images-dir> # every KB service; writes kb/presence.json

An image dir is what the research repo's firmware pipeline writes:
<dir>/fs/{rootfs,bsp,otncabi,otycabi}, or a dir with rootfs/ directly.
Local only: LG firmware is never committed, and neither is this output.
"""
import argparse, glob, json, os, re, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_DIRS = ["/usr/sbin", "/usr/bin", "/sbin", "/bin", "/usr/libexec"]
UNIT_DIRS = ["/etc/systemd/system", "/lib/systemd/system", "/usr/lib/systemd/system"]
LS2_DIRS = ["/usr/share/luna-service2/services.d", "/usr/share/dbus-1/system-services", "/usr/share/dbus-1/services"]


def load_specs():
    """[(option, kind, fields)]: the knowledge base's shipped services."""
    return [x for x in load_kb_specs(shipped_only=True)]


def load_module_specs():
    """[(module, kind, fields)] for every *_SPEC and *_RELEASED line (module-era toolkit)."""
    out = []
    for path in sorted(glob.glob(os.path.join(REPO, "toolkit/modules/*.sh"))):
        mod = os.path.basename(path)[:-3]
        text = open(path).read()
        for name, body in re.findall(r"^(\w+)='\n(.*?)^'", text, re.S | re.M):
            kind = "spec" if name.endswith("_SPEC") else "released" if name.endswith("_RELEASED") else None
            if not kind:
                continue
            for line in body.splitlines():
                if not line.strip() or line.startswith("#"):
                    continue
                f = (line.split("|") + [""] * 7)[:7]
                out.append((mod, kind, f))
    return out


class Image:
    def __init__(self, d):
        fs = os.path.join(d, "fs") if os.path.isdir(os.path.join(d, "fs")) else d
        self.name = os.path.basename(os.path.normpath(d))
        self.root = os.path.join(fs, "rootfs")
        self.extra = [os.path.join(fs, x) for x in ("bsp",) if os.path.isdir(os.path.join(fs, x))]
        self.cabi = {x: os.path.join(fs, x) for x in ("otncabi", "otycabi") if os.path.isdir(os.path.join(fs, x))}
        if not os.path.isdir(self.root):
            raise SystemExit(f"{d}: no rootfs")
        self.ls2 = self._ls2_index()

    def resolve(self, p, depth=0):
        """Canonical path inside the image, or None. Absolute link targets are image-relative."""
        if depth > 40:
            return None
        parts, cur = [x for x in p.split("/") if x], ""
        for i, part in enumerate(parts):
            nxt = cur + "/" + part
            host = self.host(nxt)
            if host is None:
                return None
            if os.path.islink(host):
                t = os.readlink(host)
                base = t if t.startswith("/") else os.path.normpath(cur + "/" + t)
                return self.resolve(base + "/" + "/".join(parts[i + 1:]), depth + 1) if i + 1 < len(parts) else self.resolve(base, depth + 1)
            cur = nxt
        return cur or "/"

    def host(self, p):
        for r in [self.root] + self.extra:
            h = r + p
            if os.path.lexists(h):
                return h
        if p.startswith("/mnt/"):
            for k, v in self.cabi.items():
                if p.startswith(f"/mnt/{k}/"):
                    h = v + p[len(k) + 5:]
                    if os.path.lexists(h):
                        return h
        return None

    def exists(self, p):
        r = self.resolve(p)
        return r is not None and self.host(r) is not None and not os.path.islink(self.host(r))

    def find_bin(self, name):
        for d in BIN_DIRS:
            if self.host(d + "/" + name):
                return self.resolve(d + "/" + name)
        return None

    def unit_file(self, u):
        for d in UNIT_DIRS:
            h = self.host(d + "/" + u)
            if h and os.path.isfile(h):
                return h
        return None

    def unit_exec(self, u):
        h = self.unit_file(u)
        if not h:
            return None
        for line in open(h, errors="replace"):
            m = re.match(r"ExecStart=[-@+!:]*(\S+)", line)
            if m:
                return m.group(1)
        return None

    def _ls2_index(self):
        idx = {}
        roots = [self.root] + self.extra + list(self.cabi.values())
        for r in roots:
            for d in LS2_DIRS:
                for f in glob.glob(r + d + "/*.service"):
                    names, ex, ty = [], "", ""
                    for line in open(f, errors="replace"):
                        line = line.rstrip("\r\n")
                        if line.startswith("Name="):
                            names = [x for x in line[5:].split(";") if x]
                        elif line.startswith("Exec="):
                            ex = line[5:]
                        elif line.startswith("Type="):
                            ty = line[5:]
                    for i, n in enumerate(names):
                        idx.setdefault(n, (ty or "dynamic", ex, i == 0, os.path.relpath(f, r)))
        return idx

    def ls2_system(self):
        """LS2 names in the rootfs registries (what oyg survey compares)."""
        names = set()
        for d in LS2_DIRS:
            for f in glob.glob(self.root + d + "/*.service"):
                for line in open(f, errors="replace"):
                    if line.startswith("Name="):
                        names.update(x for x in line.rstrip("\r\n")[5:].split(";") if x)
        return names

    def ls2_for(self, binpath):
        """LS2 names whose Exec runs this binary (or its JS service dir)."""
        hits = []
        if not binpath:
            return hits
        key = binpath if not binpath.endswith(".js") else os.path.dirname(binpath)
        for n, (ty, ex, first, f) in self.ls2.items():
            if first and re.search(r"(^|\s)" + re.escape(key) + r"(\s|$)", ex):
                hits.append(n)
        return sorted(hits)


def launch_model(ty, ex):
    if "jailer" in ex:
        return "jailed"
    if "run-js-service" in ex and re.search(r"\s-u(\s|$)", ex):
        return "unified"
    return "static" if ty == "static" else "dynamic"


def check_entry(img, f):
    eid, unit, b, comm, arg, ls2, flags = f
    fl = dict((x.split("=", 1) + ["1"])[:2] for x in flags.split(",") if x)
    notes = []
    binp = None
    if b == "?":
        binp = img.find_bin(comm) if comm else None
        if not binp and unit:
            e = img.unit_exec(unit)
            if e and not e.endswith(".sh"):
                binp = img.resolve(e)
    elif b:
        binp = img.resolve(b) if img.exists(b) else None
    unit_ok = bool(unit and img.unit_file(unit))
    reg = img.ls2.get(ls2) if ls2 else None
    present = bool(binp and img.exists(binp)) or unit_ok or bool(reg)
    if ls2 and not reg and present:
        found = img.ls2_for(binp)
        notes.append(f"ls2 {ls2} not registered" + (f" (binary registers {','.join(found)})" if found else ""))
    if reg:
        ty, ex, first, _ = reg
        model = launch_model(ty, ex)
        if not first:
            notes.append(f"{ls2} is not the first name of its file: run-service ignores it")
        want = fl.get("L")
        if want and want != model:
            notes.append(f"launch {want} -> {model}")
    if comm and len(comm) > 15 and b == "?":
        pass  # find_bin uses the full name; the kill match truncates
    if comm == "com.webos.servi":
        notes.append("comm com.webos.servi is shared by many daemons")
    status = "absent" if not present else ("CHANGED" if any(n.startswith("launch") or "not registered" in n for n in notes) else "ok")
    return status, binp or "", notes


def sdx_count(img):
    t = img.host("/usr/palm/sdx/server_addr_version.conf")
    if not t:
        return "no factory table"
    sh = os.environ.get("BUSYBOX")
    cmd = [sh, "sh"] if sh else ["sh"]
    r = subprocess.run(cmd + ["-c", '. "$1/toolkit/modules/sdx.sh"; sdx_entries "$2"', "_", REPO, t], capture_output=True, text=True)
    groups = {}
    for line in r.stdout.splitlines():
        g = line.split("|")[0]
        groups[g] = groups.get(g, 0) + 1
    return ", ".join(f"{g}:{n}" for g, n in groups.items()) or "0 entries (empty table)"


def load_kb_specs(shipped_only=False):
    """[(option, kind, fields)] for every service the KB blocks, planned ones too."""
    import importlib.util
    s = importlib.util.spec_from_file_location("kb", os.path.join(REPO, "tools", "kb.py"))
    kb = importlib.util.module_from_spec(s)
    s.loader.exec_module(kb)
    out = []
    for svc in kb.load()["services"]["service"]:
        if svc.get("action", "block") == "block" and not (shipped_only and svc.get("since") == "planned"):
            out.append((svc["option"], "spec", kb.spec_line(svc).split("|")))
    return out


def generation(img):
    h = img.host("/etc/os-release")
    m = re.search(r'VERSION_ID="?(\d+)\.(\d+)', open(h).read()) if h else None
    return f"{m.group(1)}.{m.group(2)}" if m else "?"


def write_presence(imgs, specs):
    gens = sorted({generation(i) for i in imgs}, key=lambda g: [int(x) for x in g.split(".")] if g != "?" else [0])
    by_gen = {g: [i for i in imgs if generation(i) == g] for g in gens}
    services, changed = {}, {}
    for mod, kind, f in specs:
        row = {}
        for g, gi in by_gen.items():
            st = [check_entry(i, f) for i in gi]
            n = sum(1 for s, _, _ in st if s != "absent")
            row[g] = "all" if n == len(gi) else "some" if n else "none"
            for (s, _, notes), i in zip(st, gi):
                if s == "CHANGED":
                    changed.setdefault(f[0], set()).add(f"{i.name}: {'; '.join(notes)}")
        services[f[0]] = row
    out = {"generations": gens, "images": {i.name: generation(i) for i in imgs}, "services": services}
    path = os.path.join(REPO, "kb", "presence.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print(f"wrote {path}: {len(services)} services x {len(gens)} generations ({len(imgs)} images)")
    known = sorted({n for i in imgs for n in i.ls2_system()})
    kp = os.path.join(REPO, "toolkit", "etc", "known-ls2.txt")
    with open(kp, "w") as fh:
        fh.write("\n".join(known) + "\n")
    print(f"wrote {kp}: {len(known)} LS2 names (oyg survey reports the ones not in it)")
    for sid, notes in sorted(changed.items()):
        print(f"  {sid}: " + " | ".join(sorted(notes)))


def report(img, specs):
    print(f"## {img.name}\n")
    ver = ""
    h = img.host("/etc/os-release")
    if h:
        m = re.search(r'VERSION_ID="?([^"\n]+)', open(h).read())
        ver = m.group(1) if m else ""
    print(f"webOS {ver}; sdx factory table: {sdx_count(img)}\n")
    print("| module | id | status | binary | notes |\n|---|---|---|---|---|")
    counts = {}
    for mod, kind, f in specs:
        if kind != "spec":
            continue
        st, binp, notes = check_entry(img, f)
        counts[st] = counts.get(st, 0) + 1
        print(f"| {mod} | {f[0]} | {st} | {binp} | {'; '.join(notes)} |")
    print(f"\n{', '.join(f'{v} {k}' for k, v in sorted(counts.items()))}\n")
    return counts


def matrix(imgs, specs):
    print("## Presence matrix\n")
    print("| module | id | " + " | ".join(i.name for i in imgs) + " |")
    print("|---|---|" + "---|" * len(imgs))
    sym = {"ok": "●", "absent": "·", "CHANGED": "△"}
    for mod, kind, f in specs:
        if kind != "spec":
            continue
        cells = [sym[check_entry(i, f)[0]] for i in imgs]
        print(f"| {mod} | {f[0]} | " + " | ".join(cells) + " |")
    print("\n● present, · absent, △ present but its launch model or registration changed\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("--all", metavar="DIR", help="every image dir under DIR")
    ap.add_argument("--also", nargs="*", default=[], metavar="DIR")
    ap.add_argument("--matrix", action="store_true", help="only the presence matrix")
    ap.add_argument("--kb", action="store_true", help="check every KB service and write kb/presence.json")
    a = ap.parse_args()
    dirs = list(a.images) + list(a.also)
    if a.all:
        dirs = sorted(d for d in glob.glob(os.path.join(a.all, "*")) if os.path.isdir(os.path.join(d, "fs", "rootfs"))) + dirs
    if not dirs:
        ap.error("no image given")
    imgs = [Image(d) for d in dirs]
    if a.kb:
        write_presence(imgs, load_kb_specs())
        return
    specs = load_specs()
    if not a.matrix:
        for i in imgs:
            report(i, specs)
    if len(imgs) > 1 or a.matrix:
        matrix(imgs, specs)


if __name__ == "__main__":
    main()
