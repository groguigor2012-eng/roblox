#!/usr/bin/env python3
"""Cross-reference checks a compiler cannot do for a Rojo/Luau project.

1. every require(...) of Shared/Server/script-relative paths resolves to a file
2. every Services.<Name> used is registered in Bootstrap's SERVICE_ORDER
3. every Services.<Name>:<Method>( / .<Field> exists in that service module
4. every remote name passed to RemoteService / Net / match:FireAll exists in NetworkConfig
   with the right direction
5. every Controllers.<Name> referenced on the client exists
6. every client->server remote has exactly one server handler
7. every effect the server emits has a client renderer in EffectsController

Run from PumpkinFarm/: python3 tests/static_check.py
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "src")
errors = []

def files():
    for d, _, fs in os.walk(SRC):
        for f in fs:
            if f.endswith(".luau"):
                yield os.path.join(d, f)

def module_dir_for(path):
    return os.path.dirname(path)

ROOTS = {
    "Shared": os.path.join(SRC, "shared"),
    "Server": os.path.join(SRC, "server"),
    "Client": os.path.join(SRC, "client"),
}

def resolve(base_dir, parts):
    cur = base_dir
    for i, part in enumerate(parts):
        cand_dir = os.path.join(cur, part)
        if i == len(parts) - 1:
            for ext in (".luau", ".server.luau", ".client.luau"):
                if os.path.isfile(cand_dir + ext):
                    return True
            if os.path.isfile(os.path.join(cand_dir, "init.luau")):
                return True
            return False
        if not os.path.isdir(cand_dir):
            return False
        cur = cand_dir
    return False

req_re = re.compile(r"require\(([A-Za-z_][\w\.]*)\)")
for path in files():
    text = open(path).read()
    for m in req_re.finditer(text):
        expr = m.group(1)
        parts = expr.split(".")
        if parts[0] == "ReplicatedStorage" and len(parts) > 1 and parts[1] == "Shared":
            ok = resolve(ROOTS["Shared"], parts[2:])
        elif parts[0] in ROOTS:
            ok = resolve(ROOTS[parts[0]], parts[1:])
        elif parts[0] == "script":
            base = path[:-5]  # strip .luau
            base = os.path.dirname(path)
            rest = parts[1:]
            # script.Parent.X -> sibling X
            cur = os.path.dirname(path)
            # first Parent is the folder containing the module
            if rest and rest[0] == "Parent":
                rest = rest[1:]
                while rest and rest[0] == "Parent":
                    cur = os.path.dirname(cur)
                    rest = rest[1:]
                ok = resolve(cur, rest) if rest else True
            else:
                ok = True
        else:
            continue  # local variables holding instances (e.g. moduleScript)
        if not ok:
            errors.append(f"{os.path.relpath(path, ROOT)}: unresolved require({expr})")

# Services registry -----------------------------------------------------------------
boot = open(os.path.join(SRC, "server", "Bootstrap.server.luau")).read()
order = re.findall(r'^\t"(\w+)",$', boot, re.M)
service_members = {}
for name in order:
    p = os.path.join(SRC, "server", "Services", name + ".luau")
    if not os.path.isfile(p):
        errors.append(f"Bootstrap lists {name} but Services/{name}.luau is missing")
        continue
    t = open(p).read()
    members = set(re.findall(rf"function {name}[:.](\w+)\(", t))
    members |= set(re.findall(rf"^{name}\.(\w+)\s*=", t, re.M))
    service_members[name] = members

use_re = re.compile(r"Services\.(\w+)([:.])(\w+)")
for path in files():
    text = open(path).read()
    for m in use_re.finditer(text):
        svc, sep, member = m.groups()
        if svc not in service_members:
            errors.append(f"{os.path.relpath(path, ROOT)}: Services.{svc} is not registered in Bootstrap")
            continue
        if member not in service_members[svc]:
            errors.append(f"{os.path.relpath(path, ROOT)}: Services.{svc}{sep}{member} does not exist")

# Remotes ------------------------------------------------------------------------------
net = open(os.path.join(SRC, "shared", "Config", "NetworkConfig.luau")).read()
remote_dirs = dict(re.findall(r'^\t(\w+) = \{\n\t\tClass = "\w+",\n\t\tDirection = "(\w+)"', net, re.M))
c2s_calls = re.compile(r':(?:OnInvoke|OnEvent)\("(\w+)"')
s2c_calls = re.compile(r':(?:FireClient|FireClients|FireAllClients|FireAll)\("(\w+)"')
client_c2s = re.compile(r'Net[:.](?:Invoke|Fire)\("(\w+)"')
client_s2c = re.compile(r'Net[:.]On\("(\w+)"')
for path in files():
    text = open(path).read()
    rel = os.path.relpath(path, ROOT)
    for rx, want in ((c2s_calls, "ClientToServer"), (s2c_calls, "ServerToClient"), (client_c2s, "ClientToServer"), (client_s2c, "ServerToClient")):
        for name in rx.findall(text):
            if name not in remote_dirs:
                errors.append(f"{rel}: remote {name} is not declared in NetworkConfig")
            elif remote_dirs[name] != want:
                errors.append(f"{rel}: remote {name} used as {want} but declared {remote_dirs[name]}")

# Client controllers --------------------------------------------------------------------
ctrl_dir = os.path.join(SRC, "client", "Controllers")
if os.path.isdir(ctrl_dir):
    controllers = {f[:-5] for f in os.listdir(ctrl_dir) if f.endswith(".luau")}
    ctrl_members = {}
    for name in controllers:
        t = open(os.path.join(ctrl_dir, name + ".luau")).read()
        ms = set(re.findall(rf"function {name}[:.](\w+)\(", t))
        ms |= set(re.findall(rf"^{name}\.(\w+)\s*=", t, re.M))
        ctrl_members[name] = ms
    for path in files():
        text = open(path).read()
        for m in re.finditer(r"Controllers\.(\w+)([:.])(\w+)", text):
            c, sep, member = m.groups()
            if c not in controllers:
                errors.append(f"{os.path.relpath(path, ROOT)}: Controllers.{c} does not exist")
            elif member not in ctrl_members[c]:
                errors.append(f"{os.path.relpath(path, ROOT)}: Controllers.{c}{sep}{member} does not exist")

# Remote handler coverage --------------------------------------------------------------
handled = {}
for path in files():
    if "/server/" not in path:
        continue
    for name in c2s_calls.findall(open(path).read()):
        handled[name] = handled.get(name, 0) + 1
for name, direction in remote_dirs.items():
    if direction == "ClientToServer" and handled.get(name, 0) != 1:
        errors.append(f"remote {name} has {handled.get(name, 0)} server handlers (expected 1)")

# Effect coverage ---------------------------------------------------------------------------
effects_file = os.path.join(SRC, "client", "Controllers", "EffectsController.luau")
if os.path.isfile(effects_file):
    rendered = set(re.findall(r"^renderers\.(\w+) = function", open(effects_file).read(), re.M))
    emit_re = re.compile(r'(?:PlayAt|PlayFor|:Play)\([^,()]*(?:\([^()]*\))?[^,()]*,\s*"(\w+)"')
    for path in files():
        if "/server/" not in path:
            continue
        for name in emit_re.findall(open(path).read()):
            if name not in rendered:
                errors.append(f"{os.path.relpath(path, ROOT)}: effect {name} has no client renderer")

for e in errors:
    print("ERROR:", e)
print(f"static check: {len(errors)} problems")
sys.exit(1 if errors else 0)
