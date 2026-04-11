import sys
sys.path.insert(0, r'F:\vitual_experiment\ide-claw\cascade')
import windsurf_support
import windsurf_auto_switch_send

config = windsurf_support.load_windsurf_config()
targets = windsurf_support._normalize_button_targets(config)
pyautogui = windsurf_auto_switch_send.load_pyautogui()

for t in targets:
    name = t['name']
    explicit = t.get('run_button_search_region')
    print(f'{name}: explicit_region={explicit}')
    region = windsurf_support.resolve_run_button_search_region(pyautogui, config, t)
    print(f'  resolved_region={region}')
    match = windsurf_support.locate_run_button(pyautogui, config, t)
    print(f'  match={match}')
