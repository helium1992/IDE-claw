"""Lightweight scan: find all Run button candidates on screen using color + template matching."""
import sys
import numpy as np
import cv2

sys.path.insert(0, r'F:\vitual_experiment\ide-claw\cascade')
import windsurf_support
import windsurf_auto_switch_send

config = windsurf_support.load_windsurf_config()
pyautogui = windsurf_auto_switch_send.load_pyautogui()
ref = windsurf_support._load_reference_image(
    config.get('windsurf_run_button_reference_image'), grayscale=False
)
ref_np = np.array(ref.convert('RGB'))
ref_bgr = cv2.cvtColor(ref_np, cv2.COLOR_RGB2BGR)

targets = windsurf_support._normalize_button_targets(config)
print(f'Reference: {ref.size}')
print()

for t in targets:
    name = t['name']
    region = windsurf_support.resolve_run_button_search_region(pyautogui, config, t)
    print(f'=== {name} === search: x={region["left"]}-{region["left"]+region["width"]}, y={region["top"]}-{region["top"]+region["height"]}')

    shot = pyautogui.screenshot(
        region=(region['left'], region['top'], region['width'], region['height'])
    )
    s_np = np.array(shot.convert('RGB'))
    s_bgr = cv2.cvtColor(s_np, cv2.COLOR_RGB2BGR)
    result = cv2.matchTemplate(s_bgr, ref_bgr, cv2.TM_CCOEFF_NORMED)
    mn, mx, mnl, mxl = cv2.minMaxLoc(result)
    x, y = mxl
    abs_x = region['left'] + x
    abs_y = region['top'] + y

    # Blue ratio of best match
    h, w = ref_np.shape[:2]
    crop = shot.crop((x, y, x + w, y + h))
    hsv = cv2.cvtColor(np.array(crop.convert('RGB')), cv2.COLOR_RGB2HSV)
    blue_mask = cv2.inRange(hsv, np.array([100, 100, 120]), np.array([130, 255, 255]))
    blue_ratio = float(np.count_nonzero(blue_mask)) / max(blue_mask.size, 1)

    is_run = mx >= 0.7 and blue_ratio >= 0.55
    print(f'  Best: conf={mx:.4f} abs=({abs_x},{abs_y}) blue={blue_ratio:.3f} is_run={is_run}')

    # Also check via locate_run_button
    match = windsurf_support.locate_run_button(pyautogui, config, t)
    if match:
        print(f'  locate_run_button: YES -> click ({match["center_x"]},{match["center_y"]})')
    else:
        print(f'  locate_run_button: None (no Run button found)')
    print()
