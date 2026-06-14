# Hardware CA-CFAR SAR Ship Detector on PYNQ-Z2

A synthesizable **Cell-Averaging CFAR (CA-CFAR)** detector that screens Synthetic
Aperture Radar (SAR) imagery for ships on the **Zynq-7020 programmable logic**,
with a software pipeline that tiles full-scene SAR images, suppresses sea
clutter, and masks land. Built as a low-power, deterministic on-board
**downlink-reduction filter** — flag tiles containing vessels, discard empty
ocean — the kind of front-end an Earth-observation SAR satellite needs and a GPU
cannot run economically at full data rate.

Hardware is verified **bit-for-bit** against a NumPy reference model.

<img width="1888" height="927" alt="image" src="https://github.com/user-attachments/assets/6ef4b222-31e6-448d-9e94-60cc814a4ca9" />

---

## Why CFAR (and why on an FPGA)

A ship on radar is a bright point-return on darker ocean. CA-CFAR detects it not
with a fixed threshold but with one computed **adaptively from the local clutter**
around each pixel — so the false-alarm rate stays constant across calm and rough
seas. The detector is, at its core, a sliding-window average and a compare,
repeated over millions of pixels: trivially parallel, very low power, ideal for
fabric. ML detectors (YOLO-style) belong on a GPU/Jetson; the deterministic
CFAR front-end belongs on the FPGA.

```
detect  <=>  CUT > (mean_of_training_cells) * alpha
```

Geometry (default): 7x7 window, 3x3 guard ring (excluded so a target's own
energy doesn't bias the background estimate), 40 training cells, alpha = 2.5x,
implemented division-free in fixed point.

---

## Results on synthetic SAR 

Simple case
<img width="972" height="526" alt="image" src="https://github.com/user-attachments/assets/577b3e6f-7a69-401e-80c5-64c711f5b4af" />


**Full coastal scene — detect, 

<img width="645" height="641" alt="image" src="https://github.com/user-attachments/assets/ae1af47c-acbd-4165-a0cb-376f879ec9f9" />


---

## How it works

**Hardware (`rtl/`, plain Verilog-2001/2005):**
- `cfar2d.v` — streaming core: cascaded line buffers, 7x7 window shift register,
  training-cell accumulator, fixed-point adaptive threshold, comparator. One
  pixel/clock, 100 MHz.
- `cfar2d_axis.v` — AXI4-Stream + frame-buffer wrapper for PYNQ AXI-DMA; streams
  the detection mask back with `tlast`.

**Software (`python/`, `notebooks/`):**
- Global intensity scaling (whole image, one min/max — keeps dark water dark).
- **Overlapping tiling** (stride 26): the FPGA processes 32x32 tiles; overlap of
  2x the window half-width means no target is lost in a tile seam.
- **Noise-floor gate**: keep a detection only if the pixel is also absolutely
  bright — removes sea-speckle false alarms.
- **Sea-land mask**: large-kernel blur + threshold isolates water; detections
  over land are dropped.

---

## Verification

The RTL is checked bit-for-bit against `python/cfar_reference.py`. Both
testbenches pass across 6 random scenes.

```bash
apt-get install -y iverilog
cd python && python3 cfar_reference.py            # generate vectors
cd ../sim
iverilog -g2012 -DSYNTHESIS -o core ../rtl/cfar2d.v tb_cfar2d.sv && vvp core
iverilog -g2012 -DSYNTHESIS -o axis ../rtl/cfar2d.v ../rtl/cfar2d_axis.v tb_cfar2d_axis.sv && vvp axis
# -> RESULT: PASS  (RTL matches golden model bit-for-bit)
```

On hardware, the demo notebook also asserts `HW == SW reference` for a single
tile before running full scenes.

---

## Build (PYNQ-Z2 / Vivado)

Plain Verilog, so no IP packaging:

1. Add `rtl/cfar2d.v` and `rtl/cfar2d_axis.v` to a Vivado project.
2. Create Block Design -> right-click `cfar2d_axis` -> **Add Module to Block Design**.
3. Add ZYNQ7 PS + AXI DMA (read + write channels, no scatter-gather). Wire DMA
   `M_AXIS_MM2S` -> `s_t*` (16-bit) and `m_t*` (8-bit) -> `S_AXIS_S2MM`. Clock to
   `FCLK_CLK0`, `rst_n` to `peripheral_aresetn`. Run Connection Automation.
4. Generate bitstream, export `cfar.bit` + `cfar.hwh`.
5. Copy `cfar.bit`, `cfar.hwh`, `python/cfar_reference.py`, and a `data/` image
   next to `notebooks/cfar_sar_demo.ipynb`; run it.

Resources on xc7z020: small (line buffers + frame buffer in LUTRAM/BRAM, 2 DSPs
for the multipliers, low LUT/FF). Closes timing at 100 MHz.

---

## Honest limitations / roadmap

- **Fixed alpha** is compile-time (a bitstream constant). Different scenes want
  different thresholds — next step is exposing alpha as a runtime AXI-Lite
  register so one bitstream serves any scene.
- **Image-derived land mask** mislabels dense ship anchorages as land (a tight
  cluster blurs bright). Production systems use external coastline vectors
  (GSHHG / OpenStreetMap) for the mask.
- **Per-tile DMA** in the notebook is Python-overhead-bound; the PL itself runs
  one pixel/clock at 100 MHz. A streaming back-to-back tile feed removes the
  per-tile wait.
- **OS-CFAR** (ordered-statistic) would improve robustness in heterogeneous
  clutter near coastlines.

---

## Repository layout

```
rtl/        cfar2d.v, cfar2d_axis.v          synthesizable Verilog
sim/        tb_cfar2d.sv, tb_cfar2d_axis.sv  self-checking testbenches
python/     cfar_reference.py, sar_loader.py golden model + image loader
notebooks/  cfar_sar_demo.ipynb              hardware demo
data/       sample_*.png                     synthetic SAR test scenes
images/     result figures
```

## License
MIT
