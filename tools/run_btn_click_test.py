import sys
import time

sys.path.insert(0, r'F:\vitual_experiment\ide-claw\cascade')
import windsurf_support
import windsurf_auto_switch_send

# Minimize IDE Claw overlay first
import win32gui
import win32con


def find_ide_claw(hwnd, results):
    title = win32gui.GetWindowText(hwnd)
    if 'IDE Claw' in title and win32gui.IsWindowVisible(hwnd):
        results.append(hwnd)


results = []
win32gui.EnumWindows(find_ide_claw, results)
for hwnd in results:
    win32gui.ShowWindow(hwnd, win32con.SW_MINIMIZE)

time.sleep(1)

config = windsurf_support.load_windsurf_config()
pyautogui = windsurf_auto_switch_send.load_pyautogui()
targets = windsurf_support._normalize_button_targets(config)

for t in targets:
    name = t['name']
    match = windsurf_support.locate_run_button(pyautogui, config, t)
    if match:
        cx = match['center_x']
        cy = match['center_y']
        print(f'{name}: FOUND at center=({cx},{cy})')
        # Move mouse there slowly so user can see
        pyautogui.moveTo(cx, cy, duration=1.5)
        time.sleep(2)
        print(f'Mouse at ({cx},{cy}). Is it on Run button?')
    else:
        print(f'{name}: no match')
