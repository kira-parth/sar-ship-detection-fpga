#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# cfar_reference.py
# Golden software model of the 2-D Cell-Averaging CFAR (CA-CFAR) detector.
# This file is the single source of truth: the RTL is verified against the
# vectors generated here. Keep the parameters below identical to cfar2d.sv.
# -----------------------------------------------------------------------------
import numpy as np

# ---- Parameters (MUST match cfar2d.sv) --------------------------------------
IMG_W      = 32      # image width  (columns)
IMG_H      = 32      # image height (rows)
DATA_W     = 16      # pixel magnitude width (unsigned)
GUARD      = 1       # guard ring half-width  -> guard region (2*GUARD+1)^2
TRAIN      = 2       # training ring half-width
ALPHA_FRAC = 8       # fractional bits of the threshold multiplier (Q.AF)
ALPHA      = 640     # threshold multiplier in Q(.)8 -> 640/256 = 2.5

WH      = GUARD + TRAIN                 # window half-width (=3 -> 7x7 window)
WIN     = 2 * WH + 1                    # full window side (=7)
GUARD_S = 2 * GUARD + 1                 # guard side (=3)
NTRAIN  = WIN * WIN - GUARD_S * GUARD_S # training-cell count (=40)


def cfar_detect(img):
    """Return a binary detection mask the same size as img.
    Border pixels (within WH of any edge) are forced to 0 (no full window)."""
    h, w = img.shape
    out = np.zeros((h, w), dtype=np.uint8)
    for r in range(WH, h - WH):
        for c in range(WH, w - WH):
            win = img[r - WH:r + WH + 1, c - WH:c + WH + 1].astype(np.int64)
            guard = win[TRAIN:TRAIN + GUARD_S, TRAIN:TRAIN + GUARD_S]
            train_sum = int(win.sum() - guard.sum())   # sum of 40 training cells
            cut = int(img[r, c])
            # detect if cut > (train_sum / NTRAIN) * (ALPHA / 2^AF)
            # rearranged to integer-only (matches RTL exactly):
            lhs = cut * NTRAIN << ALPHA_FRAC
            rhs = train_sum * ALPHA
            out[r, c] = 1 if lhs > rhs else 0
    return out


def make_test_image(seed=7):
    """Dark noisy 'ocean' background with a few bright 'ships'."""
    rng = np.random.default_rng(seed)
    img = rng.integers(40, 110, size=(IMG_H, IMG_W), dtype=np.int64)  # clutter
    ships = [(8, 9), (10, 22), (20, 14), (24, 25), (15, 6)]
    for (r, c) in ships:
        img[r, c] = 60000                      # bright point target (metal hull)
        # smear a little so a ship spans >1 pixel, like real SAR
        if c + 1 < IMG_W:
            img[r, c + 1] = 30000
        if r + 1 < IMG_H:
            img[r + 1, c] = 25000
    return img.astype(np.uint16)


def write_hex(path, flat, width_bits):
    """Write one hex value per line, raster order."""
    nibbles = (width_bits + 3) // 4
    with open(path, "w") as f:
        for v in flat:
            f.write(f"{int(v):0{nibbles}X}\n")


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    simdir = os.path.join(here, "..", "sim")
    os.makedirs(simdir, exist_ok=True)

    img = make_test_image()
    det = cfar_detect(img)

    write_hex(os.path.join(simdir, "in.hex"),       img.flatten(), DATA_W)
    write_hex(os.path.join(simdir, "gold_det.hex"), det.flatten(), 1)

    print(f"window      : {WIN}x{WIN}  guard {GUARD_S}x{GUARD_S}  Ntrain={NTRAIN}")
    print(f"alpha       : {ALPHA}/{2**ALPHA_FRAC} = {ALPHA / 2**ALPHA_FRAC}")
    print(f"image       : {IMG_W}x{IMG_H}  ({IMG_W*IMG_H} pixels)")
    print(f"detections  : {int(det.sum())} pixels flagged")
    print("wrote sim/in.hex and sim/gold_det.hex")
