#!/usr/bin/env python3
"""Build Roblox Studio files for THE SHUTTER straight from shutter/src (no Rojo needed).

Outputs (in shutter/build/):
  TheShutter.rbxlx                       - complete place: File > Open in Studio, press Play
  TheShutter_ReplicatedStorage.rbxmx     - model: drag into ReplicatedStorage
  TheShutter_ServerScriptService.rbxmx   - model: drag into ServerScriptService
  TheShutter_StarterPlayerScripts.rbxmx  - model: drag into StarterPlayer > StarterPlayerScripts

File naming follows Rojo:  X.server.luau -> Script,  X.client.luau -> LocalScript,
X.luau -> ModuleScript.  Usage:  python3 shutter/tools/build_studio_files.py
"""
from __future__ import annotations

import itertools
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "build"

REMOTES = [
    ("CamcorderToggle", "RemoteEvent"),
    ("SprintState", "RemoteEvent"),
    ("LookUpdate", "UnreliableRemoteEvent"),
    ("WatcherFeedback", "RemoteEvent"),
]

_ids = itertools.count(1)


class Node:
    def __init__(self, cls: str, name: str, source: str | None = None, children: list["Node"] | None = None):
        self.cls, self.name, self.source = cls, name, source
        self.children = children or []

    def xml(self, indent: int = 1) -> str:
        pad = "\t" * indent
        ref = f"RBX{next(_ids):08X}"
        props = [f'{pad}\t\t<string name="Name">{escape(self.name)}</string>']
        if self.source is not None:
            # CDATA can't contain "]]>": split it across two sections if it ever appears.
            body = self.source.replace("]]>", "]]]]><![CDATA[>")
            props.append(f'{pad}\t\t<ProtectedString name="Source"><![CDATA[{body}]]></ProtectedString>')
        lines = [f'{pad}<Item class="{self.cls}" referent="{ref}">', f"{pad}\t<Properties>", *props, f"{pad}\t</Properties>"]
        lines += [child.xml(indent + 1) for child in self.children]
        lines.append(f"{pad}</Item>")
        return "\n".join(lines)


def script_node(path: Path) -> Node:
    name = path.name
    source = path.read_text(encoding="utf-8")
    if name.endswith(".server.luau"):
        return Node("Script", name[: -len(".server.luau")], source)
    if name.endswith(".client.luau"):
        return Node("LocalScript", name[: -len(".client.luau")], source)
    return Node("ModuleScript", name[: -len(".luau")], source)


def folder_from(directory: Path, name: str, extra: list[Node] | None = None) -> Node:
    children = [script_node(p) for p in sorted(directory.glob("*.luau"))]
    return Node("Folder", name, children=children + (extra or []))


def remotes_folder() -> Node:
    return Node("Folder", "Remotes", children=[Node(cls, name) for name, cls in REMOTES])


HEADER = (
    '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">'
)


def write(path: Path, items: list[Node]) -> None:
    global _ids
    _ids = itertools.count(1)
    body = "\n".join(item.xml() for item in items)
    path.write_text(f"{HEADER}\n{body}\n</roblox>\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT.parent)}")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    shared = folder_from(SRC / "shared", "Shutter", [remotes_folder()])
    server = folder_from(SRC / "server", "Shutter")
    client = folder_from(SRC / "client", "Shutter")

    write(OUT / "TheShutter_ReplicatedStorage.rbxmx", [shared])
    write(OUT / "TheShutter_ServerScriptService.rbxmx", [server])
    write(OUT / "TheShutter_StarterPlayerScripts.rbxmx", [client])

    place = [
        Node("Workspace", "Workspace"),
        Node("ReplicatedStorage", "ReplicatedStorage", children=[shared]),
        Node("ServerScriptService", "ServerScriptService", children=[server]),
        Node("StarterPlayer", "StarterPlayer", children=[Node("StarterPlayerScripts", "StarterPlayerScripts", children=[client])]),
    ]
    write(OUT / "TheShutter.rbxlx", place)


if __name__ == "__main__":
    main()
