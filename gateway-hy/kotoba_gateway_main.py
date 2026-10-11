"""Launcher: `HERMES_PYTHON kotoba_gateway_main.py [--port N]`.

Puts this directory and its vendored `.deps` (Hy) on sys.path, so the gateway
runs inside Hermes Agent's own environment without installing anything into it.

With the Hermes backend, Hermes' managed dependencies (e.g. `cryptography`) are
activated before any gateway module loads, so every import below sees the same
environment Hermes does (see `_activate_hermes`).
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _backend(argv):
    for i, arg in enumerate(argv):
        if arg == "--backend" and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--backend="):
            return arg.split("=", 1)[1]
    return os.environ.get("KOTOBA_GATEWAY_BACKEND", "hermes")


def _activate_hermes(repo):
    """Put Hermes' managed dependencies on sys.path.

    Calls the step `hermes_bootstrap` itself ends with
    (`pm.environments.activate_dependencies`) rather than importing the whole
    bootstrap: the bootstrap first tries to finish a pending Hermes source
    update, and on 2026-10-09 that blocked forever on a package-manager worker
    while the update's tail was unfinished, so the gateway never started.
    Finishing Hermes updates is not the gateway's job. Run with the
    interpreter of Hermes' managed environment (~/.hermes/tools/python-3.14*)
    so the activated packages match its ABI. Installs without `pm` fall back
    to the full bootstrap.
    """
    if repo not in sys.path:
        sys.path.insert(0, repo)
    try:
        from pathlib import Path

        from pm.environments import activate_dependencies
    except ImportError:
        import hermes_bootstrap  # noqa: F401  (may re-exec this process)
        return
    activate_dependencies(Path(repo))


if _backend(sys.argv[1:]) == "hermes":
    repo = os.environ.get("HERMES_REPO") or os.getcwd()
    if os.path.isfile(os.path.join(repo, "hermes_bootstrap.py")):
        _activate_hermes(repo)

for path in (os.path.join(HERE, ".deps"), HERE):
    if path not in sys.path:
        sys.path.insert(0, path)

import hy  # noqa: E402,F401

from kotoba_gateway.server import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
