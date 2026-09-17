# Sphinx configuration for EchoFrame.
#
# The C++ API pages are generated from Doxygen's XML output via Breathe, so
# `doxygen Doxyfile` has to run before `sphinx-build`. See README.md in this
# directory.

import os

project = "EchoFrame"
copyright = "2022-2025 EchoFrame Contributors"
author = "EchoFrame Contributors"

# -- General -----------------------------------------------------------------

extensions = [
    "breathe",         # C++ API from Doxygen XML
    "myst_parser",     # Markdown sources, so the existing READMEs can be reused
    "sphinx.ext.autodoc",
    "sphinxcontrib.matlab",
]

# -- Optional Python reference -----------------------------------------------

# The generated part of api/python.md reads the compiled `echoframe` module, so
# it only appears when that module can be imported by whatever interpreter is
# running sphinx-build. Everything else builds without it.
#
# Note this documents the module that is *installed*, not the sources. Build the
# docs from the environment you built or installed echoframe into, or the page
# will describe whatever older wheel happens to be on the path.
try:
    import echoframe  # noqa: F401
except Exception:
    # `only` hides the section, but autodoc still runs and reports one warning
    # per directive. Those are expected here and already explained on the page.
    suppress_warnings = ["autodoc"]
else:
    tags.add("has_echoframe")  # noqa: F821  (tags is injected by Sphinx)

# -- MATLAB ------------------------------------------------------------------

# sphinxcontrib.matlab needs sphinx.ext.autodoc loaded alongside it, otherwise it
# raises "No such config value: 'autodoc_default_options'".
#
# Root that MATLAB "modules" are resolved against: echoframe/matlab/core/imaging
# becomes the `core.imaging` module, and so on.
matlab_src_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "echoframe", "matlab"))
matlab_short_links = True

# Most of the documented surface is C++, so keep that the default domain and
# reach for MATLAB explicitly with the `mat:` prefix.
primary_domain = "cpp"

# Sphinx would otherwise treat the Doxygen output and the build tree as sources.
# README.md here documents how to build these docs; it is not one of the pages.
exclude_patterns = [
    "_build",
    "_doxygen",
    "README.md",
    "Thumbs.db",
    ".DS_Store",
]

# -- C++ domain --------------------------------------------------------------

# Sphinx's C++ parser does not know CUDA's execution-space qualifiers, and fails
# on every kernel declaration without these ("Expected identifier in nested
# name, got keyword: void").
cpp_id_attributes = [
    "__global__",
    "__device__",
    "__host__",
    "__forceinline__",
    "__restrict__",
    "__shared__",
    "__constant__",
]
cpp_paren_attributes = [
    "__launch_bounds__",
]

# -- Breathe -----------------------------------------------------------------

breathe_projects = {
    "EchoFrame": os.path.join(os.path.dirname(__file__), "_doxygen", "xml"),
}
breathe_default_project = "EchoFrame"
breathe_default_members = ("members",)

# -- MyST --------------------------------------------------------------------

myst_enable_extensions = [
    "colon_fence",
    "deflist",
]
myst_heading_anchors = 3

# -- HTML --------------------------------------------------------------------

html_theme = "furo"
html_title = "EchoFrame"
