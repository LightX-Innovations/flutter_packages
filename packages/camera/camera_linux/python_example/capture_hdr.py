"""
Basler ace2 a2A3840-45ucBAS — multi-exposure HDR capture with live preview.

Live preview window:
    SPACE  — capture all HDR frames, merge with Debevec, display result
    Q / ESC — quit

Dependencies:
    pip install pypylon opencv-python numpy
"""

from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from pypylon import pylon

import sys
sys.path.insert(0, str(Path(__file__).parent))
from constants import CAPTURES, DEBUG, IR_MODE, OUTPUT_DIR, WINDOW
from merge_hdr import merge_debevec, save_result


def configure_camera(camera: pylon.InstantCamera) -> None:
    camera.ExposureAuto.SetValue("Off")
    camera.GainAuto.SetValue("Off")
    camera.ExposureMode.SetValue("Timed")
    if IR_MODE:
        camera.PixelFormat.SetValue("Mono8")
    else:
        camera.PixelFormat.SetValue("BayerRG8")
        camera.BalanceWhiteAuto.SetValue("Continuous")


# Bayer → BGR converter
_converter = pylon.ImageFormatConverter()
_converter.OutputPixelFormat = pylon.PixelType_BGR8packed
_converter.OutputBitAlignment = pylon.OutputBitAlignment_MsbAligned


def result_to_bgr(grab_result) -> np.ndarray:
    """Convert a pypylon GrabResult to a BGR uint8 NumPy array."""
    return _converter.Convert(grab_result).GetArray()


def grab_single(
    camera: pylon.InstantCamera,
    exposure_us: float,
    gain_db: float,
    gamma: float = 1.0,
    digital_shift: int = 0,
) -> np.ndarray:
    """Snap one frame at given settings, return BGR array."""
    camera.StopGrabbing()
    camera.ExposureTime.SetValue(exposure_us)
    camera.Gain.SetValue(gain_db)
    camera.Gamma.SetValue(gamma)
    camera.DigitalShift.SetValue(digital_shift)
    camera.StartGrabbingMax(1)
    with camera.RetrieveResult(5_000, pylon.TimeoutHandling_ThrowException) as result:
        if not result.GrabSucceeded():
            raise RuntimeError(f"Grab failed: {result.GetErrorDescription()}")
        return result_to_bgr(result)


def grab_burst(camera: pylon.InstantCamera) -> list[np.ndarray]:
    """
    Capture all CAPTURES frames as fast as possible.
    Uses continuous grabbing — changes exposure on the fly and skips one
    frame after each parameter change to ensure the new settings are applied.
    """
    import time
    camera.StopGrabbing()
    camera.StartGrabbing(pylon.GrabStrategy_LatestImageOnly)

    raws: list[np.ndarray] = []
    for i, params in enumerate(CAPTURES):
        t0 = time.perf_counter()
        camera.ExposureTime.SetValue(params["exposure_us"])
        camera.Gain.SetValue(params["gain_db"])
        camera.Gamma.SetValue(params["gamma"])
        camera.DigitalShift.SetValue(params["digital_shift"])

        # Skip one frame (still has old settings)
        with camera.RetrieveResult(5_000, pylon.TimeoutHandling_ThrowException) as _:
            pass

        # Grab the frame with new settings
        with camera.RetrieveResult(5_000, pylon.TimeoutHandling_ThrowException) as result:
            if not result.GrabSucceeded():
                raise RuntimeError(f"Grab failed: {result.GetErrorDescription()}")
            raws.append(result.Array.copy())

        dt = (time.perf_counter() - t0) * 1000
        print(f"    frame {i}: {params['exposure_us']/1000:.0f} ms exp → {dt:.0f} ms grab")

    camera.StopGrabbing()

    # Convert raw arrays to usable frames
    if IR_MODE:
        # Mono8: already grayscale, convert to 3-channel for consistent pipeline
        frames = [cv2.cvtColor(raw, cv2.COLOR_GRAY2BGR) for raw in raws]
    else:
        # Basler BayerRG8 = OpenCV BayerBG (naming convention offset)
        frames = [cv2.cvtColor(raw, cv2.COLOR_BayerBG2BGR) for raw in raws]
    return frames


def save_frame(
    frame: np.ndarray,
    session_ts: str,
    idx: int,
    exposure_us: float,
    gain_db: float,
    gamma: float,
    digital_shift: int,
) -> Path:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUTPUT_DIR / (
        f"{session_ts}_{idx:02d}_exp{int(exposure_us)}us_gain{gain_db}dB"
        f"_gamma{gamma}_ds{digital_shift}.tiff"
    )
    if not cv2.imwrite(str(path), frame):
        raise IOError(f"Failed to write: {path}")
    return path


def capture_hdr(camera: pylon.InstantCamera) -> None:
    """Capture all frames (burst), then save and merge."""
    import time
    session_ts = datetime.now().strftime("%Y%m%d_%H%M%S")

    # --- BURST: grab all frames as fast as possible --------------------------
    t_acq_start = time.perf_counter()
    frames = grab_burst(camera)
    t_acq_total = (time.perf_counter() - t_acq_start) * 1000
    print(f"  Burst capture: {len(frames)} frames in {t_acq_total:.0f} ms")

    # --- SAVE TIFFs (after burst, no longer blocking acquisition) ------------
    if DEBUG:
        for idx, (frame, params) in enumerate(zip(frames, CAPTURES)):
            exp  = params["exposure_us"]
            gain = params["gain_db"]
            gam  = params["gamma"]
            ds   = params["digital_shift"]
            path = save_frame(frame, session_ts, idx, exp, gain, gam, ds)
            print(f"  [{idx+1}/{len(CAPTURES)}] {exp/1_000:.0f} ms exp  |  {path.name}")

    # Sort frames by ascending exposure time (same order as merge_hdr CLI)
    exposure_secs = [p["exposure_us"] / 1_000_000.0 for p in CAPTURES]
    order = sorted(range(len(exposure_secs)), key=lambda i: exposure_secs[i])
    frames        = [frames[i] for i in order]
    exposure_secs = [exposure_secs[i] for i in order]

    # HDR merge (Mertens)
    t0 = time.perf_counter()
    raw, hdr, timings = merge_debevec(*frames, exposure_times=exposure_secs)
    t_merge = (time.perf_counter() - t0) * 1000

    t0 = time.perf_counter()
    if DEBUG:
        save_result(raw, "mertens_raw", session_ts)
    path_m = save_result(hdr, "mertens", session_ts)
    t_save = (time.perf_counter() - t0) * 1000

    print(f"\n  Timing:")
    print(f"    Acquisition   : {t_acq_total:6.1f} ms  ({len(frames)} frames)")
    print(f"    Align (ECC)   : {timings['align_ms']:6.1f} ms")
    print(f"    Mertens fusion: {timings['fusion_ms']:6.1f} ms")
    print(f"    Post-process  : {timings['postprocess_ms']:6.1f} ms")
    print(f"    Save PNG      : {t_save:6.1f} ms")
    print(f"    ─────────────────────────")
    print(f"    Total         : {t_acq_total + t_merge + t_save:6.1f} ms")
    print(f"  HDR → {path_m.name}")

    cv2.putText(hdr, f"Mertens ({len(frames)} exp)  —  resuming…", (10, 40),
                cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
    cv2.imshow(WINDOW, hdr)
    cv2.waitKey(3_000)


def main() -> None:
    tlf     = pylon.TlFactory.GetInstance()
    devices = tlf.EnumerateDevices()
    if not devices:
        raise RuntimeError("No Basler camera found. Check the USB connection.")

    dev_info = devices[0]
    print(f"Camera : {dev_info.GetModelName()} — {dev_info.GetSerialNumber()}")
    print("Preview running.  SPACE = capture  |  Q / ESC = quit\n")

    camera = pylon.InstantCamera(tlf.CreateDevice(dev_info))
    camera.Open()

    try:
        configure_camera(camera)

        # Start live preview with medium exposure settings
        _p = CAPTURES[1]
        camera.ExposureTime.SetValue(_p["exposure_us"])
        camera.Gain.SetValue(_p["gain_db"])
        camera.Gamma.SetValue(_p["gamma"])
        camera.DigitalShift.SetValue(_p["digital_shift"])
        camera.StartGrabbing(pylon.GrabStrategy_LatestImageOnly)

        cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL | cv2.WINDOW_KEEPRATIO)

        while camera.IsGrabbing():
            with camera.RetrieveResult(5_000, pylon.TimeoutHandling_ThrowException) as result:
                if result.GrabSucceeded():
                    live = result_to_bgr(result)
                    cv2.imshow(WINDOW, live)

            key = cv2.waitKey(1) & 0xFF

            if key == ord(" "):
                print("\n[SPACE] — capturing HDR …")
                capture_hdr(camera)
                print("Done. Resuming preview …\n")
                _p = CAPTURES[1]
                camera.ExposureTime.SetValue(_p["exposure_us"])
                camera.Gain.SetValue(_p["gain_db"])
                camera.Gamma.SetValue(_p["gamma"])
                camera.DigitalShift.SetValue(_p["digital_shift"])
                camera.StartGrabbing(pylon.GrabStrategy_LatestImageOnly)

            elif key in (ord("q"), ord("Q"), 27):
                print("Quit.")
                break

    finally:
        camera.StopGrabbing()
        camera.Close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
