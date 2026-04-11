import sys
import numpy as np
sys.path.insert(0, r'F:\vitual_experiment\ide-claw\cascade')
import windsurf_support
import windsurf_auto_switch_send
from PIL import Image
import cv2

config = windsurf_support.load_windsurf_config()
pyautogui = windsurf_auto_switch_send.load_pyautogui()

# Load reference
ref_source = config.get('windsurf_run_button_reference_image')
ref = windsurf_support._load_reference_image(ref_source, grayscale=False)
print(f'Reference: size={ref.size} mode={ref.mode}')

# Full screen search
full = pyautogui.screenshot()
full_np = np.array(full.convert('RGB'))
ref_np = np.array(ref.convert('RGB'))
full_bgr = cv2.cvtColor(full_np, cv2.COLOR_RGB2BGR)
ref_bgr = cv2.cvtColor(ref_np, cv2.COLOR_RGB2BGR)
result = cv2.matchTemplate(full_bgr, ref_bgr, cv2.TM_CCOEFF_NORMED)

# Find top 5 matches
for i in range(5):
    min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
    x, y = max_loc
    h, w = ref_np.shape[:2]
    print(f'Match #{i+1}: confidence={max_val:.4f} at abs_pos=({x},{y}) size=({w},{h})')
    if max_val > 0.3:
        matched = full.crop((x, y, x+w, y+h))
        matched.save(f'F:/vitual_experiment/ide-claw/build/fullmatch_{i+1}.png')
    # Suppress this match area for next iteration
    cv2.rectangle(result, (max(x-w//2, 0), max(y-h//2, 0)), (min(x+w//2, result.shape[1]), min(y+h//2, result.shape[0])), 0, -1)

print('Done')
