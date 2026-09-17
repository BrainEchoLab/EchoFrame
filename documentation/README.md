# Documentation Directory

Two ways to read the C++ API:

- **Sphinx** — the browsable site, with the API grouped by module. Doxygen parses
  the sources, Sphinx renders them via Breathe.
- **Doxygen on its own** — call graphs, class hierarchies, source browser, and a
  PDF. More detail, less structure.

Both start from the same `Doxyfile`, so Doxygen has to run first either way.

## Sphinx

### Install

```sh
pip install -r documentation/requirements.txt
```

Doxygen is a separate install: <https://www.doxygen.nl/download.html>

So is Graphviz: <https://graphviz.org/download/>. `HAVE_DOT = YES`, so `dot` must
be on `PATH` or every graph fails with `Problems running dot` and the build still
exits 0. `Format: "svg" not recognized` means its plugins are unregistered: run
`dot -c` once.

### Build

From this directory:

```sh
doxygen Doxyfile          # writes _doxygen/xml, which Breathe reads
sphinx-build -b html . _build/html
```

Open `_build/html/index.html`.

Re-run `doxygen Doxyfile` whenever the C++ sources change; Sphinx reads the XML,
not the sources, so it will not pick up edits on its own.

### The Python section is optional

Most of `api/python.md` is written by hand and always builds. The signatures at
the bottom are read from the `echoframe` module itself, so they only appear when
it can be imported by the interpreter running `sphinx-build`. Without it the page
builds fine and says the signatures are missing.

To include them, build the docs from whatever environment has `echoframe`
installed — a wheel, or `pip install -e .` from `echoframe/cpp/src`. Install the doc
requirements into that same environment:

```sh
<that-env>/python -m pip install -r documentation/requirements.txt
<that-env>/sphinx-build -b html documentation documentation/_build/html
```

An out-of-date wheel produces an out-of-date page. If the generated names
disagree with the descriptions above them, rebuild the wheel.

### Layout

- `conf.py` — Sphinx configuration.
- `index.md` — landing page.
- `api/` — one page per module (`efcore`, `beamformer`, `pdi`, `bindings`). Each
  pulls in a Doxygen namespace through Breathe.

## Doxygen on its own

From this directory:

```sh
doxygen Doxyfile
```

Output lands in `_doxygen/`:

- **HTML** — `_doxygen/html/index.html`. To serve it:
  ```sh
  cd _doxygen/html
  python -m http.server
  ```
  Then open <http://localhost:8000>.

- **PDF** — LaTeX sources in `_doxygen/latex/`. Needs a LaTeX distribution (TeX
  Live, MiKTeX). If the PDF is not built automatically:
  ```sh
  cd _doxygen/latex
  pdflatex refman.tex
  ```
  The result is `refman.pdf`.

## Notes

- `Doxyfile` lists the source directories under `echoframe/cpp/src/` explicitly. Add
  new source directories to `INPUT` as they appear.
- `conf.py` sets `cpp_id_attributes` for CUDA's execution-space qualifiers
  (`__global__`, `__device__`, and so on).
- The template member functions in `beamformer.t.hpp` produce two Breathe
  warnings. The build still succeeds and the rest of the namespace renders.
- **Breathe directives in a `.md` page must use MyST's native fence syntax**
  (```` ```{doxygenfunction} name ````), not an `eval-rst` block.
- **`mat:` and `autodoc` directives need an `eval-rst` block** (or a `.rst`
  file); in native fence syntax they silently emit their generated source as a
  literal block instead of rendering. `api/matlab.md` and the generated part of
  `api/python.md` use `eval-rst`; the C++ pages do not.
