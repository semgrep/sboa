#!/usr/bin/env python3
"""Install helper for the CPython runtime files of an sboa application.

``sboa.config`` (written by sboa's toolchain/describe.py; installed as
``%{lib:sboa:sboa.config}``) lists, in ``runtime_files``, the files that must
sit next to the final executable: the shared library and the extension
modules. ``gen_runtime_files.py CONFIG --layout libs|bin --out DIR`` copies
them into DIR (modes preserved) when the platform's layout matches, and
creates an empty DIR otherwise. Run as the action of a dune rule with
``(targets (dir DIR))`` it lets a dune project install the files without any
platform knowledge:

  libs  Linux/macOS: runtime_subdir is ``libs``; the files land in bin/libs/.
  bin   Windows: runtime_subdir is empty; DLLs and .pyd land in bin/, next to
        the .exe, which is where the Windows loader looks.

(dune cannot read external files in an ``install`` stanza, ``install`` has no
``:include``, and a generated dune file cannot be ``include``d, so the names
cannot flow into the stanza; whole directories can.)

The Windows ``install`` stanza therefore names every file by hand. With
``--check-install-list FILE`` (the dune file holding that stanza) the staged
``bin`` layout must be exactly the ``(runtime_bin/NAME as NAME)`` entries of
FILE, otherwise the build fails: a CPython upgrade that adds, drops or
renames a DLL or extension module is caught here instead of as a missing file
at run time.

Standard library only.
"""
import argparse
import os
import re
import shutil
import sys
from typing import Dict
from typing import List
from typing import Tuple
from typing import Union

Sexp = Union[str, List["Sexp"]]

_TOKEN = re.compile(
    r'\s+|(?P<lp>\()|(?P<rp>\))|"(?P<str>(?:[^"\\]|\\.)*)"|(?P<atom>[^\s()"]+)'
)


def parse_sexp(text: str) -> Sexp:
    """Parse one sexp made of lists, atoms and double-quoted strings."""
    stack: List[List[Sexp]] = [[]]
    pos = 0
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if m is None:
            raise ValueError(f"cannot parse sexp at offset {pos}")
        pos = m.end()
        if m.group("lp"):
            stack.append([])
        elif m.group("rp"):
            if len(stack) < 2:
                raise ValueError("unbalanced ')'")
            done = stack.pop()
            stack[-1].append(done)
        elif m.group("str") is not None:
            stack[-1].append(re.sub(r"\\(.)", r"\1", m.group("str")))
        elif m.group("atom"):
            stack[-1].append(m.group("atom"))
    if len(stack) != 1 or len(stack[0]) != 1:
        raise ValueError("expected exactly one complete sexp")
    return stack[0][0]


def load_config(path: str) -> Dict[str, Sexp]:
    """Return the config as a field-name to value mapping."""
    with open(path, encoding="utf-8") as f:
        top = parse_sexp(f.read())
    if not isinstance(top, list):
        raise ValueError("config must be a list of (field value) pairs")
    cfg: Dict[str, Sexp] = {}
    for entry in top:
        if not (
            isinstance(entry, list) and len(entry) == 2 and isinstance(entry[0], str)
        ):
            raise ValueError(f"malformed config entry: {entry!r}")
        cfg[entry[0]] = entry[1]
    return cfg


def _str(cfg: Dict[str, Sexp], key: str) -> str:
    v = cfg.get(key)
    if not isinstance(v, str):
        raise ValueError(f"config field '{key}' missing or not a string")
    return v


def runtime_entries(cfg: Dict[str, Sexp]) -> List[Tuple[str, str]]:
    """(absolute source, destination relative to bin/<subdir>/)."""
    files = cfg.get("runtime_files")
    if not isinstance(files, list):
        raise ValueError("config field 'runtime_files' missing or not a list")
    out: List[Tuple[str, str]] = []
    for item in files:
        if not (isinstance(item, list) and len(item) == 2):
            raise ValueError(f"malformed runtime_files entry: {item!r}")
        src, dest = item
        if not (isinstance(src, str) and isinstance(dest, str)):
            raise ValueError(f"malformed runtime_files entry: {item!r}")
        if not os.path.isabs(src):
            raise ValueError(f"runtime file {src!r} is not an absolute path")
        if os.path.isabs(dest) or ".." in dest.replace("\\", "/").split("/"):
            raise ValueError(f"runtime file destination {dest!r} escapes the directory")
        out.append((src, dest))
    return out


def stage(cfg: Dict[str, Sexp], layout: str, out_dir: str) -> bool:
    """Copy the runtime files into [out_dir]/<dest> if the config's layout is
    [layout] ("libs": runtime_subdir is non-empty; "bin": it is empty), else
    just create the empty [out_dir]. Returns whether anything was staged."""
    os.makedirs(out_dir, exist_ok=True)
    if ("libs" if _str(cfg, "runtime_subdir") else "bin") != layout:
        return False
    for src, dest in runtime_entries(cfg):
        out = os.path.join(out_dir, dest)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copyfile(src, out)
        shutil.copymode(src, out)
    return True


_INSTALL_ENTRY = re.compile(r"\(\s*runtime_bin/([^\s()]+)\s+as\s+([^\s()]+)\s*\)")


def install_list(path: str) -> List[str]:
    """The NAMEs of the ``(runtime_bin/NAME as NAME)`` entries of a dune file
    (``;`` comments ignored)."""
    with open(path, encoding="utf-8") as f:
        text = "\n".join(line.split(";", 1)[0] for line in f.read().splitlines())
    names: List[str] = []
    for src, dest in _INSTALL_ENTRY.findall(text):
        if src != dest:
            raise ValueError(f"{path}: runtime_bin/{src} is installed as {dest}")
        names.append(src)
    return names


def check_install_list(out_dir: str, list_file: str) -> None:
    """Fail unless the files staged in [out_dir] are exactly the install
    list of [list_file]."""
    staged = set()
    for dirpath, _dirs, files in os.walk(out_dir):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), out_dir)
            staged.add(rel.replace(os.sep, "/"))
    listed = set(install_list(list_file))
    if staged == listed:
        return
    lines = [
        f"the runtime files staged in {out_dir} differ from the install list"
        f" in {list_file}:"
    ]
    for name in sorted(staged - listed):
        lines.append(f"  staged but not installed: {name}")
    for name in sorted(listed - staged):
        lines.append(f"  installed but not staged: {name}")
    lines.append(
        "Update the (runtime_bin/NAME as NAME) entries of the Windows install"
        " stanza."
    )
    raise SystemExit("gen_runtime_files.py: " + "\n".join(lines))


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="sboa runtime-file helper")
    ap.add_argument("config", help="path to sboa.config")
    ap.add_argument("--layout", choices=["libs", "bin"], required=True)
    ap.add_argument("--out", required=True, help="directory to populate")
    ap.add_argument(
        "--check-install-list",
        metavar="FILE",
        help="with --layout bin: the dune file whose (runtime_bin/NAME as NAME)"
        " entries must be exactly the staged files",
    )
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    staged_here = stage(cfg, args.layout, args.out)
    if args.check_install_list and args.layout == "bin" and staged_here:
        check_install_list(args.out, args.check_install_list)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
