#!/usr/bin/env python3
"""Negative tests for tools/kb.py check: each rule must catch its violation."""
import copy, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("kb", os.path.join(HERE, "..", "tools", "kb.py"))
kb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kb)
base = kb.load()
fails = 0


def expect(name, mutate, needle):
    global fails
    d = copy.deepcopy(base)
    mutate(d)
    errs = kb.check(d)
    if not any(needle in e for e in errs):
        fails += 1
        print(f"FAIL: {name}: no error containing {needle!r} (got {errs})")


def svc(d, sid):
    return next(s for s in d["services"]["service"] if s["id"] == sid)


def add_host(d, name, option="trackers"):
    d["hosts"]["host"].append({"names": [name], "option": option})


expect("shared comm", lambda d: svc(d, "acr").update(comm="com.webos.service.lsa"), "shared by many")
expect("comm vs binary", lambda d: svc(d, "voice-performer").update(comm="other"), "not the first 15")
expect("hard never path", lambda d: svc(d, "acr").update(binary="/usr/sbin/sdx"), "hard never")
expect("soft never outside Lockdown", lambda d: svc(d, "acr").update(binary="/usr/sbin/iconnectivity"), "soft never")
expect("never ls2", lambda d: svc(d, "acr").update(ls2="com.webos.service.voiceconductor"), "never list")
expect("duplicate ls2", lambda d: svc(d, "acr").update(ls2="com.webos.service.admanager"), "also on")
expect("bad flag", lambda d: svc(d, "acr").update(flags=["L=weird"]), "bad flag")
expect("unknown option", lambda d: svc(d, "acr").update(option="nope"), "unknown option")
expect("gateway host", lambda d: add_host(d, "AU.tv.wiselg.com"), "never list")
expect("online check host", lambda d: add_host(d, "lgtvonline.lge.com"), "never list")
expect("ngfts host", lambda d: add_host(d, "aic-ngfts.lge.com"), "never list")
expect("host in two options", lambda d: add_host(d, "alphonso.tv", "ads"), "two options")
expect("literal region host of another option's {cc} template", lambda d: add_host(d, "kr.lgeapi.com", "thinq"), "on a TV in that country")
expect("never sdx name with option", lambda d: next(n for n in d["sdx"]["name"] if n["name"] == "device_keys").update(option="promos"), "never name")
expect("setting value not JSON", lambda d: d["settings"]["setting"][0].update(value="off"), "not JSON")
expect("unknown preset", lambda d: d["options"]["option"][0].update(presets=["everything"]), "unknown preset")

errs = kb.check(base)
if errs:
    fails += 1
    print("FAIL: the committed KB has problems:", errs)
drift = kb.gen_drift(base)
if drift:
    fails += 1
    print("FAIL: generated files out of date (run tools/kb.py gen):", drift)
print(f"kb tests: {'ok' if not fails else str(fails) + ' failed'}")
sys.exit(1 if fails else 0)
