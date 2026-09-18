# README comparison animation

`comparison.gif` shows qlover on the left and full coverage on the right.
It illustrates three measured scenarios from the [demo](../../examples/demo):

| Change after baseline | qlover | Full suite | Result |
|:----------------------|-------:|-----------:|:-------|
| Nothing changed | 0 | 48 | Pass |
| Refactor one module | 8 | 48 | Pass |
| Add uncovered code | 1 | 49 | Coverage fails |

The terminal output is condensed and animated for explanation. Playback
speed does **not** represent elapsed command time. The image contains only
the terminal windows and result summary; the README's comparison section
explains the measurement. `comparison.png` is a still of the module-edit
scenario for readers who prefer a static image.

## Regenerate

Requires Python 3 and Pillow (`python3 -m pip install Pillow`):

```sh
python3 docs/assets/render_comparison.py
```

The script looks for DejaVu Sans Mono on Linux or Menlo on macOS. You can
also supply a font explicitly:

```sh
python3 docs/assets/render_comparison.py --font /path/to/monospace.ttf
```

It writes both assets alongside the script. No renderer dependencies are
needed to use qlover or view the README.
