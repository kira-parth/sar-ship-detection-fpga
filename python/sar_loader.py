#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# sar_loader.py   (SOFTWARE ONLY - hardware/bitstream is unchanged)
#
# Feeds a real-looking SAR scene into the already-built 32x32 CFAR overlay.
#   1. get_sar_scene()  -> tries to download a real Sentinel-1 sample image;
#                          if offline / blocked, synthesizes a realistic SAR
#                          ocean with bright ship targets (so it never fails).
#   2. to_hw_frame()    -> crops/resizes to IMG_W x IMG_H and scales to uint16,
#                          the exact format the DMA + PL expect.
#
# Nothing here touches the FPGA design. It only prepares the bytes that get
# streamed through the same AXI-DMA path you already validated.
# -----------------------------------------------------------------------------
import numpy as np

IMG_W, IMG_H = 32, 32          # MUST match the bitstream parameters
HW_MAX       = 60000           # peak uint16 magnitude used for bright targets


def from_file(path):
    """Load any SAR image file (PNG/JPG/TIFF) you dropped on the board.
    This is the cleanest 'real data' path: download one SSDD / HRSID /
    Sentinel-1 ship chip to the board and point here."""
    from PIL import Image
    img = Image.open(path).convert("L")           # grayscale magnitude
    return np.asarray(img, dtype=np.float64)


def try_download(url, timeout=15):
    """Best-effort fetch of a public SAR image. Returns a 2-D array or None.
    The board's open internet can reach public URLs; pass any no-auth SAR
    PNG/JPG. (Not all hosts allow hot-linking - on failure use from_file or
    the synthetic generator.)"""
    try:
        import urllib.request, io
        from PIL import Image
        req = urllib.request.Request(url, headers={"User-Agent": "pynq"})
        raw = urllib.request.urlopen(req, timeout=timeout).read()
        img = Image.open(io.BytesIO(raw)).convert("L")
        return np.asarray(img, dtype=np.float64)
    except Exception as e:
        print(f"  download failed: {e}")
        return None


def synth_sar_ocean(h=256, w=256, n_ships=6, seed=7):
    """Realistic SAR ocean: Rayleigh-speckled dark clutter + bright point ships.
    Real SAR amplitude clutter follows a Rayleigh distribution; ships are strong
    point/extended scatterers an order of magnitude above the local mean."""
    rng = np.random.default_rng(seed)
    # Rayleigh speckle for the sea clutter (this is what real SAR ocean looks like)
    clutter = rng.rayleigh(scale=18.0, size=(h, w))
    img = clutter.copy()
    for _ in range(n_ships):
        r = rng.integers(8, h - 8)
        c = rng.integers(8, w - 8)
        img[r, c] = 230 + rng.random() * 25          # bright hull return
        # small smear so a ship spans >1 pixel
        img[r, min(c + 1, w - 1)] = 150
        img[min(r + 1, h - 1), c] = 130
    return img


def get_sar_scene(url=None, path=None):
    """Pick a SAR scene with graceful fallback:
       1. local file (path)  -> real data you dropped on the board
       2. download (url)     -> real data over the board's internet
       3. synthetic ocean    -> statistically-real SAR clutter, always works"""
    if path:
        try:
            arr = from_file(path)
            print(f"  using REAL SAR file: {path}  shape={arr.shape}")
            return arr, "real-file"
        except Exception as e:
            print(f"  file load failed: {e}")
    if url:
        arr = try_download(url)
        if arr is not None:
            print(f"  using REAL SAR download  shape={arr.shape}")
            return arr, "real-download"
    print("  using synthetic SAR ocean (Rayleigh speckle + ships)")
    return synth_sar_ocean(), "synthetic"


def to_hw_frame(scene, want_bright_patch=True):
    """Crop a IMG_H x IMG_W patch and scale to uint16 for the CFAR hardware.
    If want_bright_patch, centre the patch on the brightest pixel (likely a
    ship) so the demo clearly shows a detection; else take the centre."""
    h, w = scene.shape
    if h < IMG_H or w < IMG_W:
        # upscale small inputs by nearest-neighbour (no extra deps)
        ry = int(np.ceil(IMG_H / h)); rx = int(np.ceil(IMG_W / w))
        scene = np.kron(scene, np.ones((ry, rx)))
        h, w = scene.shape

    if want_bright_patch:
        br, bc = np.unravel_index(np.argmax(scene), scene.shape)
        r0 = int(np.clip(br - IMG_H // 2, 0, h - IMG_H))
        c0 = int(np.clip(bc - IMG_W // 2, 0, w - IMG_W))
    else:
        r0 = (h - IMG_H) // 2; c0 = (w - IMG_W) // 2

    patch = scene[r0:r0 + IMG_H, c0:c0 + IMG_W].astype(np.float64)

    # scale so the brightest pixel maps to HW_MAX (preserves ship-vs-clutter ratio)
    pmin, pmax = patch.min(), patch.max()
    if pmax <= pmin:
        pmax = pmin + 1.0
    frame = (patch - pmin) / (pmax - pmin) * HW_MAX
    return frame.astype(np.uint16)


if __name__ == "__main__":
    scene, kind = get_sar_scene()
    frame = to_hw_frame(scene)
    print(f"scene kind   : {kind}")
    print(f"hw frame     : {frame.shape} {frame.dtype}  "
          f"min={frame.min()} max={frame.max()} mean={frame.mean():.0f}")
