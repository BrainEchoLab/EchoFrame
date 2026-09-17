"""
Python shim for the C++/CUDA extension.

* On Windows it adds every `nvidia/*/*/lib` directory (from CUDA wheels) or
  the Toolkit’s `bin\` folder to the DLL search path before loading the
  compiled module.
* Then it re-exports all symbols from echoframe.
"""

from importlib import import_module
import os, pathlib, sys

# --------------------------------------------------------------------- DLL path
if os.name == "nt" and hasattr(os, "add_dll_directory"):
    _root = pathlib.Path(__file__).resolve().parents[2]   # site-packages
    # CUDA runtime wheels (if they exist)
    for _p in _root.glob("nvidia/*/*/lib"):
        os.add_dll_directory(str(_p))
    # Fallback to Toolkit’s bin\  (safe if user has full toolkit)
    _cuda_bin = os.environ.get("CUDA_PATH")
    if _cuda_bin:
        os.add_dll_directory(os.path.join(_cuda_bin, "bin"))

# ---------------------------------------------------------------------- import
_mod = import_module(__name__ + ".echoframe")
globals().update(_mod.__dict__)
del _mod, import_module, os, pathlib, sys  # clean symbol table
