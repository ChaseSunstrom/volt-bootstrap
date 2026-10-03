"""A PEP 517 build backend for a Volt package: `pip install .` builds it with bolt and installs its
Python module. Standard library only, so pip needs nothing from the network: copy this file into
the project and name it in pyproject.toml,

    [build-system]
    requires = []
    build-backend = "volt_build"
    backend-path = ["."]

    [project]
    name = "mathlib"
    version = "0.1.0"

next to a bolt.toml whose [lib] has kind "shared" and bindings "python" (and "pyi" for types).
It needs Python 3.11 or later (tomllib).
The wheel holds package NAME (the Volt package's name): the bindings as its __init__.py, the
library they load (libNAME.so) beside them. bolt comes from $BOLT, else the PATH; it finds voltc
as it always does ($VOLTC, next to bolt, the PATH).
"""

import base64
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import sysconfig
import tarfile
import zipfile

try:
    import tomllib
except ImportError:  # before 3.11
    raise RuntimeError("volt_build needs Python 3.11 or later (it reads pyproject.toml and bolt.toml with tomllib)")


def _project():
    """the project's name and version ([project] in pyproject.toml) and its Volt package's name"""
    with open("pyproject.toml", "rb") as f:
        project = tomllib.load(f).get("project", {})
    if not project.get("name") or not project.get("version"):
        raise RuntimeError("volt_build: pyproject.toml's [project] needs a name and a version")
    if not os.path.isfile("bolt.toml"):
        raise RuntimeError("volt_build: there's no bolt.toml next to pyproject.toml")
    with open("bolt.toml", "rb") as f:
        bolt = tomllib.load(f)
    volt = bolt.get("package", {}).get("name")
    if not volt:
        raise RuntimeError("volt_build: bolt.toml's [package] has no name")
    lib = bolt.get("lib", {})
    if "shared" not in lib.get("kind", []) or "python" not in lib.get("bindings", []):
        raise RuntimeError('volt_build: bolt.toml\'s [lib] needs kind = [..., "shared"] and bindings = [..., "python"]')
    return project, volt


def _dist(name):
    """a distribution name as wheel and sdist file names spell it"""
    return re.sub(r"[-_.]+", "_", name).lower()


def _version(project):
    """the version as file names spell it (a - would split the wheel's name)"""
    return re.sub(r"[-\s]+", "_", str(project["version"]))


def _metadata(project):
    lines = ["Metadata-Version: 2.1", f"Name: {project['name']}", f"Version: {project['version']}"]
    if project.get("description"):
        lines.append(f"Summary: {' '.join(str(project['description']).split())}")
    if project.get("requires-python"):
        lines.append(f"Requires-Python: {project['requires-python']}")
    return "\n".join(lines) + "\n"


def _tag():
    """py3-none-<platform>: the module is ctypes over a native library, for any CPython"""
    return "py3-none-" + re.sub(r"[-.]", "_", sysconfig.get_platform())


def _bolt_build():
    """runs bolt build --release: target/release has the library and the bindings"""
    bolt = os.environ.get("BOLT") or shutil.which("bolt")
    if not bolt:
        raise RuntimeError("volt_build: bolt isn't on the PATH (or set $BOLT to it)")
    r = subprocess.run([bolt, "build", "--release"], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"volt_build: bolt build failed:\n{r.stderr}")
    return os.path.join("target", "release")


def get_requires_for_build_wheel(config_settings=None):
    return []


def get_requires_for_build_sdist(config_settings=None):
    return []


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):
    project, _ = _project()
    info = f"{_dist(project['name'])}-{_version(project)}.dist-info"
    os.makedirs(os.path.join(metadata_directory, info), exist_ok=True)
    with open(os.path.join(metadata_directory, info, "METADATA"), "w", encoding="utf-8") as f:
        f.write(_metadata(project))
    return info


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    project, volt = _project()
    target = _bolt_build()
    lib = os.path.join(target, f"lib{volt}.so")
    py = os.path.join(target, "bindings", f"{volt}.py")
    for f in (lib, py):
        if not os.path.isfile(f):
            raise RuntimeError(f"volt_build: bolt build made no {f}")
    files = [(f"{volt}/__init__.py", py), (f"{volt}/lib{volt}.so", lib)]
    pyi = os.path.join(target, "bindings", f"{volt}.pyi")
    if os.path.isfile(pyi):
        files += [(f"{volt}/__init__.pyi", pyi), (f"{volt}/py.typed", None)]

    dist, version, tag = _dist(project["name"]), _version(project), _tag()
    info = f"{dist}-{version}.dist-info"
    name = f"{dist}-{version}-{tag}.whl"
    record = []

    def entry(arc):
        zi = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
        zi.external_attr = 0o644 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi

    def add(z, arc, data):
        z.writestr(entry(arc), data)
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        record.append(f"{arc},sha256={digest},{len(data)}")

    os.makedirs(wheel_directory, exist_ok=True)
    with zipfile.ZipFile(os.path.join(wheel_directory, name), "w", zipfile.ZIP_DEFLATED) as z:
        for arc, src in files:
            data = b""
            if src:
                with open(src, "rb") as f:
                    data = f.read()
            add(z, arc, data)
        add(z, f"{info}/METADATA", _metadata(project).encode())
        add(z, f"{info}/WHEEL", f"Wheel-Version: 1.0\nGenerator: volt_build\nRoot-Is-Purelib: false\nTag: {tag}\n".encode())
        record.append(f"{info}/RECORD,,")
        z.writestr(entry(f"{info}/RECORD"), "\n".join(record) + "\n")
    return name


def build_sdist(sdist_directory, config_settings=None):
    """the sources: what pip builds a wheel from elsewhere (not target/, node_modules/, caches or
    dot files)"""
    project, _ = _project()
    base = f"{_dist(project['name'])}-{_version(project)}"
    name = f"{base}.tar.gz"
    os.makedirs(sdist_directory, exist_ok=True)
    out = os.path.abspath(sdist_directory)
    # what builds write at the top (bolt's target/, npm's, pip's and python -m build's outputs)
    top = ("target", "node_modules", "dist", "build")
    with tarfile.open(os.path.join(sdist_directory, name), "w:gz", format=tarfile.PAX_FORMAT) as t:
        for root, dirs, files in os.walk("."):
            dirs[:] = sorted(
                d
                for d in dirs
                if not d.startswith(".")
                and d != "__pycache__"
                and not d.endswith(".egg-info")
                and not (root == "." and d in top)
                and os.path.abspath(os.path.join(root, d)) != out
            )
            for f in sorted(files):
                if not f.startswith("."):
                    path = os.path.normpath(os.path.join(root, f))
                    t.add(path, arcname=f"{base}/{path}")
        data = _metadata(project).encode()
        info = tarfile.TarInfo(f"{base}/PKG-INFO")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    return name


if __name__ == "__main__":
    # python volt_build.py DIR: the wheel, without pip
    print(build_wheel(sys.argv[1] if len(sys.argv) > 1 else "dist"))
