import sys
import numpy as np
import cv2

sys.path.insert(0, r'F:\vitual_experiment\ide-claw\cascade')
import windsurf_support
import windsurf_auto_switch_send
from PIL import Image

config = windsurf_support.load_windsurf_config()
pyautogui = windsurf_auto_switch_send.load_pyautogui()
ref = windsurf_support._load_reference_image(
    config.get('windsurf_run_button_reference_image'), grayscale=False
)
ref_np = np.array(ref.convert('RGB'))
ref_bgr = cv2.cvtColor(ref_np, cv2.COLOR_RGB2BGR)
print(f'Reference: {ref.size}')

targets = windsurf_support._normalize_button_targets(config)
for t in targets:
    name = t['name']
    region = windsurf_support.resolve_run_button_search_region(pyautogui, config, t)
    shot = pyautogui.screenshot(
        region=(region['left'], region['top'], region['width'], region['height'])
    )
    s_np = np.array(shot.convert('RGB'))
    s_bgr = cv2.cvtColor(s_np, cv2.COLOR_RGB2BGR)
    result = cv2.matchTemplate(s_bgr, ref_bgr, cv2.TM_CCOEFF_NORMED)

    # Find top 3 matches
    for i in range(3):
        mn, mx, mnl, mxl = cv2.minMaxLoc(result)
        x, y = mxl
        h, w = ref_np.shape[:2]
        abs_x = region['left'] + x
        abs_y = region['top'] + y

        # Check blue ratio
        crop = shot.crop((x, y, x + w, y + h))
        crop_np = np.array(crop.convert('RGB'))
        hsv = cv2.cvtColor(crop_np, cv2.COLOR_RGB2HSV)
        blue_mask = cv2.inRange(hsv, np.array([100, 100, 120]), np.array([130, 255, 255]))
        blue_ratio = float(np.count_nonzero(blue_mask)) / max(blue_mask.size, 1)

        print(f'{name} #{i+1}: conf={mx:.4f} abs=({abs_x},{abs_y}) blue={blue_ratio:.3f} pass={blue_ratio>=0.25}')
        crop.save(f'F:/vitual_experiment/ide-claw/build/diag_{name}_{i+1}.png')

        # Suppress
        cv2.rectangle(result, (max(x-w//2, 0), max(y-h//2, 0)),
                       (min(x+w//2, result.shape[1]), min(y+h//2, result.shape[0])), 0, -1)

    # Also save the full search region
    shot.save(f'F:/vitual_experiment/ide-claw/build/diag_region_{name}.png')

    # Run locate_run_button to see what it returns
    match = windsurf_support.locate_run_button(pyautogui, config, t)
    if match:
        cx, cy = match['center_x'], match['center_y']
        print(f'  locate_run_button => click at ({cx},{cy})')
    else:
        print(f'  locate_run_button => None')
