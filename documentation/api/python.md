# Python (pybind11)

The `echoframe` module wraps the same core the MEX gateway calls. Unlike the MEX
interface it is object-oriented: you build a `Resources` object, construct an
`EchoFrame` with it, and call `process` on that.

```python
import echoframe as ef

res = ef.make_resources(receive_dict, recon_dict, pdi_dict)
frame = ef.EchoFrame(res, use_storage=False)
pdi, bmode, bf = frame.process(rf_buffer, start_storage=False)
```

The object owns the CUDA resources and frees them when it is garbage collected,
so there is no `destroy` to call — this is the main difference from the MEX
interface.

:::{note}
The descriptions below are written against
`echoframe/cpp/src/python/echoframe_py_wrapper.cpp`; the signatures under
[Generated reference](#generated-reference) are read from the installed module at
build time. If the two disagree, the installed wheel is older than the source —
rebuild it. See the main README.
:::

## Module contents

| Name | Kind | Purpose |
|------|------|---------|
| `EchoFrame` | class | the pipeline. Owns the handle |
| `Resources` | class | the bundle of specs handed to `EchoFrame` |
| `ReceiveSpec` | class | acquisition dimensions |
| `ReconSpec` | class | reconstruction dimensions and flags |
| `make_resources` | function | build a `Resources` from three dicts |

## make_resources

```python
res = ef.make_resources(receive, recon, pdi)
```

Takes three plain dicts and returns a `Resources`. This is the normal way in —
setting the spec classes field by field is possible but rarely what you want.

The dict keys are the same field names the MATLAB specs use. Validation happens
inside, so a missing or wrongly-typed key raises rather than producing a bad
result.

## EchoFrame

```python
frame = ef.EchoFrame(resources, use_storage=False)
```

| Method | Signature | Returns |
|--------|-----------|---------|
| `process` | `process(rf_buffer, start_storage=False)` | `(pdi, bmode, bf)` |
| `update_pdi_threshold` | `update_pdi_threshold(t)` | none |
| `reinit_storage` | `reinit_storage(resources)` | none |
| `reinit_experiment` | `reinit_experiment(resources)` | none |

### process

`rf_buffer` must be a **1-D int16 numpy array**; anything else raises
`RF buffer must be 1-D int16`. This differs from the MEX interface, which takes
the 2-D `[nSamples * nTransmissions * nRepeats, nChannels]` layout — flatten it
first.

Returns all three outputs as a tuple, always. There is no equivalent of the MEX
interface's "only compute what was asked for" behaviour, so `bf` is copied out
on every call:

| Element | Shape | dtype |
|---------|-------|-------|
| `pdi` | `(nz, nx, num_ensembles)` | float32 |
| `bmode` | `(nz, nx)` | float32 |
| `bf` | `(nz, nx, nRepeats)` | complex64 |

`start_storage` turns on writing for this call, and only does anything if the
object was constructed with `use_storage=True`.

## Specs

`ReceiveSpec` and `ReconSpec` are bound field-by-field mainly so IDEs can
autocomplete them. The fields mirror the C++ structs — see
[efcore](efcore.md) and [beamformer](beamformer.md) for what each one means.

`Resources` bundles them: `receiveSpec`, `reconSpec`, `pdiSpec`,
`bfStorageSpec`, `pdiStorageSpec`, `rfTimeTagStorageSpec`, `fourierReconSpec`.

## Importing

The installed package's `__init__.py` (built from
`echoframe/cpp/src/python/__init__.py`) is a shim that runs before the compiled
module loads. On
Windows it adds the CUDA DLLs to the search path — every `nvidia/*/*/lib`
directory from the CUDA pip wheels, then `%CUDA_PATH%\bin` as a fallback — and
then re-exports everything from the extension.

If `import echoframe` fails with a DLL error, check that `CUDA_PATH` is set.

## Notes

The pybind11 classes carry no docstrings, so `help(ef.EchoFrame)` gives you
signatures without descriptions. The hand-written sections above and the
generated reference below (real signatures and member lists) are meant to be
read together.

Only the upper (tissue) SVD threshold is settable at runtime, via
`update_pdi_threshold`. The MEX additionally exposes the lower (noise) threshold
through `updatePDInoiseThreshold&process`; the Python module has no equivalent, so
set `pdiSpec.lowerThreshold` before constructing `EchoFrame` if you need it.

## Generated reference

Read from the installed `echoframe` module when the documentation is built, so it
reflects the wheel you actually have. If a name here disagrees with the
descriptions above, the wheel is older than the sources.

This section only appears when `echoframe` can be imported by the interpreter
running `sphinx-build` — build from the environment you installed it into.

:::{only} has_echoframe
```{eval-rst}
.. autoclass:: echoframe.EchoFrame
   :members:
   :undoc-members:

.. autofunction:: echoframe.make_resources

.. autoclass:: echoframe.Resources
   :members:
   :undoc-members:

.. autoclass:: echoframe.ReceiveSpec
   :members:
   :undoc-members:

.. autoclass:: echoframe.ReconSpec
   :members:
   :undoc-members:
```
:::

:::{only} not has_echoframe
```{note}
`echoframe` was not importable when these pages were built, so the generated
signatures are missing here. Install the module (a wheel, or `pip install -e .`
from `echoframe/cpp/src`) and rebuild from that environment to get them.
```
:::
