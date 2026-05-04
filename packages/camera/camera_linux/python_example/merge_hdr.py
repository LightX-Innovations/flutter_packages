"""
HDR merge — Mertens exposure fusion.

Automatically finds TIFF groups sharing a session timestamp in output/
and produces output/<session_ts>_hdr_mertens.png.

Works with 2, 3, or any number of captures.

Usage:
    python merge_hdr.py              # process latest session
    python merge_hdr.py --list       # show available sessions
"""

import argparse
import re
import time
from pathlib import Path

import cv2
import numpy as np

from constants import (
    CLAHE_CLIP_LIMIT,
    CLAHE_GRID_SIZE,
    DEBUG,
    DENOISE_STRENGTH,
    GAMMA,
    IR_BILATERAL_D,
    IR_BILATERAL_SIGMA,
    IR_CLAHE_CLIP,
    IR_CLAHE_GRID,
    IR_GAMMA,
    IR_INVERT,
    IR_MODE,

    IR_SHARPEN_AMOUNT,
    IR_SHARPEN_RADIUS,
    OUTPUT_DIR,
    SATURATION_GAIN,
    SHARPEN_AMOUNT,
    SHARPEN_RADIUS,
    WARM_SHIFT,
)


# ---------------------------------------------------------------------------
# Session discovery
# ---------------------------------------------------------------------------

_SESSION_RE = re.compile(r"^(?P<ts>\d{8}_\d{6})_\d{2}_exp(?P<exp>\d+)us_")


def _find_sessions() -> list[tuple[list[Path], str]]:
    """
    Group TIFFs by session timestamp.  Returns sessions with ≥2 files,
    sorted newest-first.  Within a session files are sorted by ascending
    exposure time (dark → bright).
    """
    buckets: dict[str, list[tuple[int, Path]]] = {}
    for p in OUTPUT_DIR.glob("*.tiff"):
        m = _SESSION_RE.match(p.name)
        if m:
            ts  = m.group("ts")
            exp = int(m.group("exp"))
            buckets.setdefault(ts, []).append((exp, p))

    sessions = []
    for ts, items in sorted(buckets.items(), reverse=True):
        if len(items) >= 2:
            items.sort()
            sessions.append(([p for _, p in items], ts))
    return sessions


def load_session(paths: list[Path]) -> list[np.ndarray]:
    """Load a list of BGR uint8 TIFFs (already sorted dark → bright)."""
    imgs = []
    for path in paths:
        img = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if img is None:
            raise IOError(f"Cannot read: {path}")
        imgs.append(img)
    return imgs


# ---------------------------------------------------------------------------
# Alignment (phase correlation)
# ---------------------------------------------------------------------------

_ECC_SCALE    = 0.25   # downsample ratio for ECC (0.25 = 4× faster, sufficient for alignment)
_ECC_MAX_ITER = 30     # max iterations (was 50)
_ECC_EPS      = 1e-3   # convergence threshold (was 1e-4, looser = fewer iterations)


def align_images(*imgs: np.ndarray) -> list[np.ndarray]:
    """
    Align BGR images using ECC on a downscaled copy, then apply warp to full resolution.
    Falls back to identity if alignment fails.
    """
    imgs_list = list(imgs)
    h0, w0    = imgs_list[0].shape[:2]
    ref_idx   = len(imgs_list) // 2

    # Downscaled grayscale reference for ECC
    ref_small = cv2.resize(imgs_list[ref_idx], (0, 0), fx=_ECC_SCALE, fy=_ECC_SCALE,
                           interpolation=cv2.INTER_AREA)
    ref_gray  = cv2.cvtColor(ref_small, cv2.COLOR_BGR2GRAY)

    criteria  = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, _ECC_MAX_ITER, _ECC_EPS)

    aligned = []
    for i, img in enumerate(imgs_list):
        if i == ref_idx:
            aligned.append(img)
            continue
        small = cv2.resize(img, (0, 0), fx=_ECC_SCALE, fy=_ECC_SCALE,
                           interpolation=cv2.INTER_AREA)
        gray  = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        warp_matrix = np.eye(2, 3, dtype=np.float32)
        try:
            _, warp_matrix = cv2.findTransformECC(
                ref_gray, gray, warp_matrix, cv2.MOTION_EUCLIDEAN, criteria,
            )
        except cv2.error:
            pass  # keep identity if ECC fails
        # Scale translation back to full resolution
        warp_matrix[0, 2] /= _ECC_SCALE
        warp_matrix[1, 2] /= _ECC_SCALE
        aligned.append(cv2.warpAffine(img, warp_matrix, (w0, h0),
                                      flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP))
    return aligned


# ---------------------------------------------------------------------------
# HDR merge
# ---------------------------------------------------------------------------

def merge_debevec(*imgs: np.ndarray,
                  exposure_times: list[float] | None = None) -> tuple:
    """
    Exposure fusion using Mertens (contrast + saturation + well-exposedness).
    Preserves original colors — no CRF, no radiance map, no tonemapping.
    Returns (raw, result, timings) where timings is a dict of ms per step.
    """
    if exposure_times is None:
        raise ValueError(
            "merge_debevec requires exposure_times (list of durations in seconds)."
        )

    t0 = time.perf_counter()
    aligned = align_images(*imgs)
    t_align = (time.perf_counter() - t0) * 1000

    # Mertens fusion — weight parameters
    t0 = time.perf_counter()
    merge = cv2.createMergeMertens(
        contrast_weight=1.0,
        saturation_weight=1.0,
        exposure_weight=1.0,
    )
    fusion = merge.process(aligned)
    t_fusion = (time.perf_counter() - t0) * 1000

    # Convert to 8-bit
    result = np.clip(fusion * 255.0, 0, 255).astype(np.uint8)
    raw = result.copy()

    # --- Post-processing -----------------------------------------------------
    t0 = time.perf_counter()
    if IR_MODE:
        result = _postprocess_ir(result)
    else:
        result = _postprocess_color(result)
    t_post = (time.perf_counter() - t0) * 1000

    timings = {"align_ms": t_align, "fusion_ms": t_fusion, "postprocess_ms": t_post}
    return raw, result, timings


def _postprocess_ir(result: np.ndarray) -> np.ndarray:
    """IR pipeline optimised for meibomian gland visualisation."""
    # Work on single channel
    gray = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)

    # 1) Bilateral filter (edge-preserving denoise)
    if IR_BILATERAL_D > 0:
        gray = cv2.bilateralFilter(gray, IR_BILATERAL_D, IR_BILATERAL_SIGMA, IR_BILATERAL_SIGMA)

    # 2) Aggressive CLAHE for gland structures
    clahe = cv2.createCLAHE(
        clipLimit=IR_CLAHE_CLIP,
        tileGridSize=(IR_CLAHE_GRID, IR_CLAHE_GRID),
    )
    gray = clahe.apply(gray)

    # 3) Gamma
    if IR_GAMMA != 1.0:
        lut = np.array([(i / 255.0) ** IR_GAMMA * 255.0
                        for i in range(256)], dtype=np.uint8)
        gray = cv2.LUT(gray, lut)

    # 4) Sharpen
    if IR_SHARPEN_AMOUNT > 0:
        blurred = cv2.GaussianBlur(gray, (0, 0), IR_SHARPEN_RADIUS)
        gray = cv2.addWeighted(gray, 1.0 + IR_SHARPEN_AMOUNT, blurred, -IR_SHARPEN_AMOUNT, 0)

    # 5) Optional inversion
    if IR_INVERT:
        gray = 255 - gray

    return cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)


def _postprocess_color(result: np.ndarray) -> np.ndarray:
    """Color pipeline for visible-light captures."""
    # 1) CLAHE on L channel for local contrast
    lab = cv2.cvtColor(result, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(
        clipLimit=CLAHE_CLIP_LIMIT,
        tileGridSize=(CLAHE_GRID_SIZE, CLAHE_GRID_SIZE),
    )
    l = clahe.apply(l)
    lab = cv2.merge([l, a, b])
    result = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)

    # 2) Saturation boost in HSV
    hsv = cv2.cvtColor(result, cv2.COLOR_BGR2HSV).astype(np.float32)
    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * SATURATION_GAIN, 0, 255)
    result = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)

    # 3) Gamma correction
    if GAMMA != 1.0:
        lut = np.array([(i / 255.0) ** GAMMA * 255.0
                        for i in range(256)], dtype=np.uint8)
        result = cv2.LUT(result, lut)

    # 4) Warm tone shift (add red, reduce blue)
    if WARM_SHIFT != 0:
        b, g, r = cv2.split(result)
        r = np.clip(r.astype(np.int16) + WARM_SHIFT, 0, 255).astype(np.uint8)
        b = np.clip(b.astype(np.int16) - WARM_SHIFT, 0, 255).astype(np.uint8)
        result = cv2.merge([b, g, r])

    # 5) Denoising (before sharpen to avoid amplifying noise)
    if DENOISE_STRENGTH > 0:
        result = cv2.fastNlMeansDenoisingColored(
            result, None, DENOISE_STRENGTH, DENOISE_STRENGTH, 7, 21,
        )

    # 6) Unsharp mask sharpening
    if SHARPEN_AMOUNT > 0:
        blurred = cv2.GaussianBlur(result, (0, 0), SHARPEN_RADIUS)
        result = cv2.addWeighted(result, 1.0 + SHARPEN_AMOUNT, blurred, -SHARPEN_AMOUNT, 0)

    return result


def save_result(img: np.ndarray, tag: str, session_ts: str) -> Path:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    base = f"{session_ts}_hdr_{tag}"
    path = OUTPUT_DIR / f"{base}.png"
    # Ne pas écraser : ajouter un suffixe incrémental
    counter = 1
    while path.exists():
        path = OUTPUT_DIR / f"{base}_{counter:02d}.png"
        counter += 1
    cv2.imwrite(str(path), img)
    return path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="HDR merge (Mertens) for Basler captures")
    parser.add_argument("--list", action="store_true", help="List available sessions and exit")
    parser.add_argument(
        "--session",
        metavar="YYYYMMDD_HHMMSS",
        help="Process a specific session instead of the latest",
    )
    args = parser.parse_args()

    sessions = _find_sessions()
    if not sessions:
        raise RuntimeError(f"No TIFF sessions (≥2 files) found in {OUTPUT_DIR}/")

    if args.list:
        print(f"{'Session':<20}  {'N':>2}  Files")
        for paths, ts in sessions:
            names = "  ".join(p.name for p in paths)
            print(f"{ts:<20}  {len(paths):>2}  {names}")
        return

    if args.session:
        match = [(p, t) for p, t in sessions if t == args.session]
        if not match:
            raise ValueError(f"Session '{args.session}' not found. Use --list.")
        paths, session_ts = match[0]
    else:
        paths, session_ts = sessions[0]

    print(f"Processing session: {session_ts}  ({len(paths)} frames)")
    for p in paths:
        print(f"  {p.name}")
    print()

    # Extract exposure times from filenames
    exp_re = re.compile(r"exp(\d+)us")
    exposure_secs = []
    for p in paths:
        m = exp_re.search(p.name)
        if m:
            exposure_secs.append(int(m.group(1)) / 1_000_000.0)
    if len(exposure_secs) != len(paths):
        raise ValueError("Could not extract exposure times from filenames.")

    imgs        = load_session(paths)
    t0 = time.perf_counter()
    raw, result, timings = merge_debevec(*imgs, exposure_times=exposure_secs)
    t_merge_total = (time.perf_counter() - t0) * 1000

    t0 = time.perf_counter()
    if DEBUG:
        path_r = save_result(raw, "mertens_raw", session_ts)
        print(f"HDR raw    → {path_r}")
    path_m = save_result(result, "mertens", session_ts)
    t_save = (time.perf_counter() - t0) * 1000
    print(f"HDR merged → {path_m}")

    print(f"\n  Timing:")
    print(f"    Align (ECC)   : {timings['align_ms']:6.1f} ms")
    print(f"    Mertens fusion: {timings['fusion_ms']:6.1f} ms")
    print(f"    Post-process  : {timings['postprocess_ms']:6.1f} ms")
    print(f"    Save PNG      : {t_save:6.1f} ms")
    print(f"    ─────────────────────────")
    print(f"    Total merge   : {t_merge_total:6.1f} ms")
    print("\nDone.")


if __name__ == "__main__":
    main()
