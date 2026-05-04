"""
constants.py — All tunable parameters for capture_hdr.py and merge_hdr.py
"""

from pathlib import Path

# ---------------------------------------------------------------------------
# Capture parameters — add/remove rows freely, any number of exposures
# ---------------------------------------------------------------------------
IR_MODE = True          # True = monochrome acquisition (no Bayer demosaic)

CAPTURES = [
    {"exposure_us":  50_000, "gain_db": 5.0, "gamma": 1.0, "digital_shift": 0},  # long
    {"exposure_us":  25_000, "gain_db": 2.0, "gamma": 1.0, "digital_shift": 0},  # medium
    {"exposure_us":   2_500, "gain_db": 0.0, "gamma": 1.0, "digital_shift": 0},  # short
]

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
OUTPUT_DIR = Path("output")

# ---------------------------------------------------------------------------
# Post-processing (after Mertens fusion)
# ---------------------------------------------------------------------------
CLAHE_CLIP_LIMIT    = 3.0    # contrast limit for CLAHE (higher = more contrast)
CLAHE_GRID_SIZE     = 8      # tile grid size for CLAHE
SATURATION_GAIN     = 2.0    # saturation multiplier (1.0 = no change, >1 = more vivid)
GAMMA               = 1.0   # gamma correction (<1 = brighter midtones)
WARM_SHIFT          = 15     # warm tone: adds to R, subtracts from B (0 = neutral)
DENOISE_STRENGTH    = 7      # NLMeans denoising strength (0 = off, 3-5 = light, 10 = strong)
SHARPEN_AMOUNT      = 1.0    # unsharp mask strength (0 = off, 1.0 = moderate, 2.0 = strong)
SHARPEN_RADIUS      = 3.0    # gaussian blur sigma for unsharp mask (bigger image = bigger radius)

# ---------------------------------------------------------------------------
# IR post-processing (meibomian gland enhancement, used when IR_MODE=True)
# ---------------------------------------------------------------------------
IR_CLAHE_CLIP       = 4.0    # aggressive CLAHE for gland contrast (4-8 sweet spot)
IR_CLAHE_GRID       = 8      # smaller grid = more local contrast on gland structures
IR_BILATERAL_D      = 13     # bilateral filter diameter (0 = off, 5-15 = edge-preserving smooth)
IR_BILATERAL_SIGMA  = 120    # bilateral sigma for color/space (higher = smoother)

IR_INVERT           = False  # True = invert image (sometimes glands show better)
IR_GAMMA            = 1.5    # gamma for IR (<1 = brighten midtones to reveal glands)
IR_SHARPEN_AMOUNT   = 4.0    # sharpen after bilateral (moderate, gland edges)
IR_SHARPEN_RADIUS   = 3.0    # sharpen radius for IR

# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------
DEBUG = False   # True = save individual TIFFs + raw HDR (pre-processing)

# ---------------------------------------------------------------------------
# Preview window
# ---------------------------------------------------------------------------
WINDOW = "Basler Preview  —  SPACE: capture  |  Q/ESC: quit"
