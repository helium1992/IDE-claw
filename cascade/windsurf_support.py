import json
import os
import time

SCRIPT_DIR = os.environ.get('IDE_CLAW_CASCADE_DIR') or os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.environ.get('IDE_CLAW_BASE_DIR') or os.path.dirname(SCRIPT_DIR)
WINDSURF_CONFIG_FILE = os.path.join(SCRIPT_DIR, 'config', 'windsurf_dialog_config.json')
WINDSURF_SERVICE_LOG_FILE = os.path.join(PROJECT_DIR, 'data', 'windsurf_auto_service.log')
WINDSURF_SERVICE_STATUS_FILE = os.path.join(PROJECT_DIR, 'data', 'windsurf_auto_service_status.json')
_REFERENCE_IMAGE_CACHE = {}
_IDE_CLAW_HWND_CACHE = None


def _find_ide_claw_hwnd():
    global _IDE_CLAW_HWND_CACHE
    try:
        import win32gui
        results = []
        def _enum(hwnd, _):
            title = win32gui.GetWindowText(hwnd)
            if 'IDE Claw' in title and win32gui.IsWindowVisible(hwnd):
                results.append(hwnd)
        win32gui.EnumWindows(_enum, None)
        if results:
            _IDE_CLAW_HWND_CACHE = results[0]
            return results[0]
    except Exception:
        pass
    return _IDE_CLAW_HWND_CACHE


def minimize_ide_claw():
    try:
        import win32gui, win32con
        hwnd = _find_ide_claw_hwnd()
        if hwnd and win32gui.IsWindowVisible(hwnd):
            win32gui.ShowWindow(hwnd, win32con.SW_MINIMIZE)
            return hwnd
    except Exception:
        pass
    return None


def restore_ide_claw(hwnd=None):
    try:
        import win32gui, win32con
        hwnd = hwnd or _find_ide_claw_hwnd()
        if hwnd:
            win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    except Exception:
        pass


def load_windsurf_config():
    config = {
        'windsurf_input_box': {'x': 812, 'y': 950},
        'reply_text': '继续，将回复推送给我',
        'switch_wait_ms': 20000,
        'button_roi': {'width': 30, 'height': 30},
        'button_match_search_padding': 12,
        'button_reference_dark_ratio_min': 0.02,
        'button_sample_dark_ratio_min': 0.02,
        'button_similarity_min': 0.82,
        'button_similarity_margin': 0.05,
        'button_stable_samples': 3,
        'button_poll_ms': 300,
        'post_send_verify_ms': 1500,
        'auto_detection_service_enabled': True,
        'auto_detection_idle_poll_ms': 1500,
        'auto_detection_post_run_cooldown_ms': 1000,
        'auto_detection_focus_before_check': False,
        'auto_detection_window_gate_enabled': False,
        'auto_detection_require_foreground_window': False,
        'auto_detection_cycle_poll_ms': 2000,
        'auto_detection_confirm_rounds': 5,
        'auto_detection_confirm_required_hits': 4,
        'auto_detection_action_cooldown_ms': 20000,
        'auto_detection_switch_retry_count': 3,
        'auto_detection_switch_ignore_cooldown': True,
        'auto_detection_switch_prefer_local': True,
        'auto_detection_retry_on_ready_verify_failed': True,
        'auto_detection_account_block_minutes': 60,
        'auto_detection_verify_retry_count': 1,
        'auto_detection_verify_retry_ms': 1500,
        'auto_detection_require_progress_reset_after_action': False,
        'auto_detection_user_interrupt_quiet_ms': 3000,
        'auto_detection_mouse_interrupt_px': 6,
        'auto_detection_target_holdoff_ms': 20000,
        'auto_detection_window_gate_min_passes': 2,
        'auto_detection_anchor_similarity_min': 0.78,
        'windsurf_image_grayscale': True,
        'focus_window_before_inject': False,
        'focus_delay_ms': 150,
        'paste_delay_ms': 120,
        'send_delay_ms': 80,
        'window_title_keywords': ['windsurf'],
        'window_title_excludes': ['settings', 'microsoft edge'],
        'paste_shortcut': ['ctrl', 'v'],
        'send_shortcut': ['enter'],
        'windsurf_send_button_reference_image': '',
        'windsurf_target_button_reference_image': '',
        'windsurf_run_button_reference_image': '',
        'windsurf_run_button_enabled': True,
        'windsurf_run_button_cooldown_ms': 4000,
        'windsurf_run_button_post_click_delay_ms': 800,
        'windsurf_run_button_search_lane_width': 960,
        'windsurf_run_button_search_lane_padding': 60,
        'windsurf_run_button_search_right_margin': 45,
        'windsurf_run_button_search_top_offset': 820,
        'windsurf_run_button_search_bottom_margin': 70,
        'button_targets': [
            {
                'name': 'left',
                'send_button': {'x': 935, 'y': 985},
                'input_box': {'x': 812, 'y': 950},
                'switch_button': {'x': 597, 'y': 1023},
            },
            {
                'name': 'right',
                'send_button': {'x': 1895, 'y': 985},
                'input_box': {'x': 1772, 'y': 950},
                'switch_button': {'x': 1557, 'y': 1023},
            },
        ],
    }
    try:
        with open(WINDSURF_CONFIG_FILE, 'r', encoding='utf-8') as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            for key, value in loaded.items():
                if isinstance(value, dict) and isinstance(config.get(key), dict):
                    merged = dict(config[key])
                    merged.update(value)
                    config[key] = merged
                else:
                    config[key] = value
    except Exception:
        pass
    return config


def append_windsurf_service_log(message):
    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        os.makedirs(os.path.dirname(WINDSURF_SERVICE_LOG_FILE), exist_ok=True)
        with open(WINDSURF_SERVICE_LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f'[{timestamp}] {message}\n')
    except Exception:
        pass


def write_windsurf_service_status(status):
    try:
        os.makedirs(os.path.dirname(WINDSURF_SERVICE_STATUS_FILE), exist_ok=True)
        with open(WINDSURF_SERVICE_STATUS_FILE, 'w', encoding='utf-8') as f:
            json.dump(status or {}, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def clear_windsurf_service_status():
    try:
        if os.path.exists(WINDSURF_SERVICE_STATUS_FILE):
            os.remove(WINDSURF_SERVICE_STATUS_FILE)
    except Exception:
        pass


def format_button_state_log(state):
    state = state or {}
    observed_state = state.get('observed_state', state.get('state'))
    return (
        f"name={state.get('name')} state={state.get('state')} observed={observed_state} "
        f"stable={bool(state.get('stable'))} samples={state.get('samples')} "
        f"ready={state.get('ready_score')} target={state.get('target_score')}"
    )


def summarize_button_states(states):
    return ' | '.join(format_button_state_log(state) for state in states) if states else 'none'


def get_named_button_state(states, name):
    for state in states or []:
        if str(state.get('name')) == str(name):
            return state
    return None


def get_ready_button_targets(states):
    ready_targets = []
    for state in states or []:
        if str(state.get('state') or '') != 'ready':
            continue
        if not bool(state.get('stable')):
            continue
        ready_targets.append(state)
    ready_targets.sort(
        key=lambda item: float(item.get('ready_score') or 0.0) - float(item.get('target_score') or 0.0),
        reverse=True,
    )
    return ready_targets


def _normalize_shortcut(value, fallback):
    if isinstance(value, str):
        keys = [value.strip().lower()] if value.strip() else []
    elif isinstance(value, list):
        keys = [str(item).strip().lower() for item in value if str(item).strip()]
    else:
        keys = []
    return keys or list(fallback)


def _press_shortcut(pyautogui, shortcut):
    keys = _normalize_shortcut(shortcut, [])
    if not keys:
        return
    if len(keys) == 1:
        pyautogui.press(keys[0])
        return
    pyautogui.hotkey(*keys)


def _copy_text_to_clipboard(text):
    import win32clipboard
    import win32con

    win32clipboard.OpenClipboard()
    try:
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardData(win32con.CF_UNICODETEXT, text or '')
    finally:
        win32clipboard.CloseClipboard()


def _enable_dpi_awareness():
    try:
        import ctypes
        user32 = ctypes.windll.user32
        try:
            user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        except Exception:
            pass
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            pass
        try:
            user32.SetProcessDPIAware()
        except Exception:
            pass
    except Exception:
        pass


def _match_windsurf_window_title(title, config):
    lower = str(title or '').strip().lower()
    if not lower:
        return False
    keywords = [str(item).strip().lower() for item in config.get('window_title_keywords', ['windsurf']) if str(item).strip()]
    excludes = [str(item).strip().lower() for item in config.get('window_title_excludes', ['settings', 'microsoft edge']) if str(item).strip()]
    if not keywords:
        return False
    if not any(keyword in lower for keyword in keywords):
        return False
    if any(exclude in lower for exclude in excludes):
        return False
    return True


def _get_foreground_window_title():
    return _get_foreground_window_info(load_windsurf_config()).get('title', '')


def _is_windsurf_window_foreground(config):
    return bool(_get_foreground_window_info(config).get('title_match'))


def _get_foreground_window_info(config):
    try:
        import win32gui
    except ImportError:
        return {
            'hwnd': 0,
            'title': '',
            'title_match': False,
            'visible': False,
            'iconic': False,
            'geometry_valid': False,
        }
    hwnd = 0
    title = ''
    visible = False
    iconic = False
    geometry_valid = False
    try:
        hwnd = int(win32gui.GetForegroundWindow() or 0)
        if hwnd:
            title = win32gui.GetWindowText(hwnd) or ''
            visible = bool(win32gui.IsWindowVisible(hwnd))
            iconic = bool(win32gui.IsIconic(hwnd))
            left, top, right, bottom = win32gui.GetWindowRect(hwnd)
            geometry_valid = (int(right) - int(left)) > 0 and (int(bottom) - int(top)) > 0
    except Exception:
        hwnd = 0
        title = ''
        visible = False
        iconic = False
        geometry_valid = False
    return {
        'hwnd': hwnd,
        'title': title,
        'title_match': _match_windsurf_window_title(title, config),
        'visible': visible,
        'iconic': iconic,
        'geometry_valid': geometry_valid,
    }


def _get_last_input_tick():
    try:
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [('cbSize', ctypes.c_uint), ('dwTime', ctypes.c_uint)]

        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(LASTINPUTINFO)
        if ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return int(info.dwTime)
    except Exception:
        pass
    return 0


def _get_cursor_position():
    try:
        import ctypes

        class POINT(ctypes.Structure):
            _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]

        point = POINT()
        if ctypes.windll.user32.GetCursorPos(ctypes.byref(point)):
            return {'x': int(point.x), 'y': int(point.y)}
    except Exception:
        pass
    return {'x': 0, 'y': 0}


def capture_user_activity_snapshot(config):
    window = _get_foreground_window_info(config)
    return {
        'last_input_tick': _get_last_input_tick(),
        'cursor': _get_cursor_position(),
        'foreground_hwnd': int(window.get('hwnd') or 0),
        'foreground_title': window.get('title') or '',
    }


def detect_user_interrupt(snapshot, config):
    snapshot = snapshot or {}
    current_window = _get_foreground_window_info(config)
    current_tick = _get_last_input_tick()
    current_cursor = _get_cursor_position()
    previous_cursor = snapshot.get('cursor') or {}
    delta_x = abs(int(current_cursor.get('x', 0)) - int(previous_cursor.get('x', 0)))
    delta_y = abs(int(current_cursor.get('y', 0)) - int(previous_cursor.get('y', 0)))
    mouse_threshold = max(int(config.get('auto_detection_mouse_interrupt_px', 6)), 0)
    if int(snapshot.get('foreground_hwnd') or 0) and int(current_window.get('hwnd') or 0):
        if int(snapshot.get('foreground_hwnd') or 0) != int(current_window.get('hwnd') or 0):
            return {
                'interrupted': True,
                'reason': 'window_changed',
                'delta_x': delta_x,
                'delta_y': delta_y,
            }
    if int(current_tick or 0) and int(snapshot.get('last_input_tick') or 0):
        if int(current_tick or 0) != int(snapshot.get('last_input_tick') or 0):
            return {
                'interrupted': True,
                'reason': 'user_input',
                'delta_x': delta_x,
                'delta_y': delta_y,
            }
    if delta_x > mouse_threshold or delta_y > mouse_threshold:
        return {
            'interrupted': True,
            'reason': 'mouse_moved',
            'delta_x': delta_x,
            'delta_y': delta_y,
        }
    return {
        'interrupted': False,
        'reason': 'none',
        'delta_x': delta_x,
        'delta_y': delta_y,
    }


def _focus_windsurf_window(config):
    try:
        import win32con
        import win32gui
    except ImportError:
        return False
    candidates = []

    def _enum(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return
        title = win32gui.GetWindowText(hwnd)
        if not _match_windsurf_window_title(title, config):
            return
        candidates.append((hwnd, title))

    win32gui.EnumWindows(_enum, None)
    if not candidates:
        return False
    hwnd, _ = candidates[0]
    try:
        if win32gui.IsIconic(hwnd):
            win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
        else:
            win32gui.ShowWindow(hwnd, win32con.SW_SHOW)
    except Exception:
        pass
    try:
        win32gui.SetForegroundWindow(hwnd)
    except Exception:
        try:
            win32gui.BringWindowToTop(hwnd)
        except Exception:
            pass
    return True


def _get_windsurf_global_storage_path():
    """获取 Windsurf globalStorage 路径"""
    import platform
    system = platform.system()
    if system == 'Windows':
        appdata = os.environ.get('APPDATA') or os.path.join(os.path.expanduser('~'), 'AppData', 'Roaming')
        return os.path.join(appdata, 'Windsurf', 'User', 'globalStorage')
    elif system == 'Darwin':
        return os.path.join(os.path.expanduser('~'), 'Library', 'Application Support', 'Windsurf', 'User', 'globalStorage')
    else:
        return os.path.join(os.path.expanduser('~'), '.config', 'Windsurf', 'User', 'globalStorage')


def inject_auth_token_via_trigger_file(auth_token, timeout=10):
    """通过触发文件注入 auth token（由 windsurf-token-injector 扩展监听并执行内部命令）"""
    auth_token = (auth_token or '').strip()
    if not auth_token:
        return False
    try:
        import json as _json
        global_storage = _get_windsurf_global_storage_path()
        trigger_path = os.path.join(global_storage, 'windsurf-token-inject.json')
        os.makedirs(global_storage, exist_ok=True)

        # 写入触发文件
        trigger_data = {
            'auth_token': auth_token,
            'timestamp': int(time.time() * 1000),
        }
        with open(trigger_path, 'w', encoding='utf-8') as f:
            _json.dump(trigger_data, f, indent=2)

        append_windsurf_service_log(
            f'inject_token: trigger file written token_len={len(auth_token)}'
        )

        # 等待扩展处理并写回结果
        start = time.time()
        while time.time() - start < timeout:
            time.sleep(0.5)
            try:
                with open(trigger_path, 'r', encoding='utf-8') as f:
                    result = _json.load(f)
                if 'injected' in result:
                    injected = bool(result.get('injected'))
                    append_windsurf_service_log(
                        f'inject_token: result injected={injected} '
                        f'injected_at={result.get("injected_at", 0)}'
                    )
                    return injected
            except Exception:
                pass

        append_windsurf_service_log('inject_token: timeout waiting for extension response')
        return False
    except Exception as exc:
        append_windsurf_service_log(f'inject_token: error {exc}')
        return False


def inject_auth_token_via_command_palette(pyautogui, auth_token, config=None):
    """注入 auth token 到 Windsurf（优先使用扩展触发文件，无需 pyautogui）"""
    return inject_auth_token_via_trigger_file(auth_token)


def _normalize_point(value):
    if isinstance(value, dict) and 'x' in value and 'y' in value:
        return {'x': int(value['x']), 'y': int(value['y'])}
    return None


def _normalize_button_targets(config):
    raw_targets = config.get('button_targets', []) or []
    targets = []
    for index, item in enumerate(raw_targets):
        if not isinstance(item, dict):
            continue
        send_button = _normalize_point(item.get('send_button'))
        if send_button is None:
            continue
        switch_button = _normalize_point(item.get('switch_button'))
        entry = {
            'name': str(item.get('name') or f'target_{index}'),
            'send_button': send_button,
            'switch_button': switch_button,
        }
        if item.get('input_box'):
            entry['input_box'] = item['input_box']
        if item.get('run_button_search_region'):
            entry['run_button_search_region'] = item['run_button_search_region']
        targets.append(entry)
    if not targets:
        targets = [
            {
                'name': 'left',
                'send_button': {'x': 935, 'y': 985},
                'switch_button': {'x': 597, 'y': 1023},
            },
            {
                'name': 'right',
                'send_button': {'x': 1895, 'y': 985},
                'switch_button': None,
            },
        ]
    anchor = next((target for target in targets if target.get('switch_button')), None)
    if anchor is not None:
        anchor_send = anchor['send_button']
        anchor_switch = anchor['switch_button']
        for target in targets:
            if target.get('switch_button') is not None:
                continue
            dx = int(target['send_button']['x']) - int(anchor_send['x'])
            dy = int(target['send_button']['y']) - int(anchor_send['y'])
            target['switch_button'] = {
                'x': int(anchor_switch['x']) + dx,
                'y': int(anchor_switch['y']) + dy,
            }
    return targets


def _resolve_reference_image_path(path):
    expanded = os.path.expanduser(str(path or '').strip())
    if not expanded:
        return ''
    if os.path.isabs(expanded):
        return os.path.abspath(expanded)
    bundled_path = os.path.abspath(os.path.join(SCRIPT_DIR, expanded))
    if os.path.exists(bundled_path):
        return bundled_path
    return os.path.abspath(expanded)


def _load_reference_image(source, grayscale=True):
    if not source:
        raise RuntimeError('缺少按钮参考图路径配置')
    crop_rect = None
    path = source
    if isinstance(source, dict):
        path = source.get('path')
        crop = source.get('crop') or {}
        if crop:
            left = max(int(crop.get('left', 0)), 0)
            top = max(int(crop.get('top', 0)), 0)
            width = max(int(crop.get('width', 0)), 1)
            height = max(int(crop.get('height', 0)), 1)
            crop_rect = (left, top, left + width, top + height)
    if not path:
        raise RuntimeError('缺少按钮参考图路径配置')
    absolute_path = _resolve_reference_image_path(path)
    cache_key = (absolute_path, crop_rect, bool(grayscale))
    cached = _REFERENCE_IMAGE_CACHE.get(cache_key)
    if cached is not None:
        return cached.copy()
    from PIL import Image, ImageOps
    image = Image.open(absolute_path)
    if crop_rect is not None:
        image = image.crop(crop_rect)
    if grayscale:
        image = ImageOps.grayscale(image)
    elif image.mode not in ('RGB', 'RGBA'):
        image = image.convert('RGB')
    _REFERENCE_IMAGE_CACHE[cache_key] = image.copy()
    return image.copy()


def _capture_button_roi(pyautogui, center, size, grayscale=True):
    from PIL import ImageOps
    width = max(int(size.get('width', 30)), 1)
    height = max(int(size.get('height', 30)), 1)
    left = int(center['x']) - width // 2
    top = int(center['y']) - height // 2
    image = pyautogui.screenshot(region=(left, top, width, height))
    if grayscale:
        image = ImageOps.grayscale(image)
    return image


def _crop_image_center(image, size):
    target_width = max(int(size.get('width', 30)), 1)
    target_height = max(int(size.get('height', 30)), 1)
    crop_width = min(target_width, int(image.size[0]))
    crop_height = min(target_height, int(image.size[1]))
    left = max((int(image.size[0]) - crop_width) // 2, 0)
    top = max((int(image.size[1]) - crop_height) // 2, 0)
    return image.crop((left, top, left + crop_width, top + crop_height))


def _expand_roi_size(size, padding):
    match_padding = max(int(padding), 0)
    return {
        'width': max(int(size.get('width', 30)), 1) + (match_padding * 2),
        'height': max(int(size.get('height', 30)), 1) + (match_padding * 2),
    }


def _estimate_target_lane_width(config, target):
    current_button = target.get('send_button') or {}
    current_x = int(current_button.get('x', 0))
    widths = []
    for item in _normalize_button_targets(config):
        button = item.get('send_button') or {}
        button_x = int(button.get('x', 0))
        gap = abs(button_x - current_x)
        if gap > 0:
            widths.append(gap)
    if widths:
        return max(min(widths), 400)
    return max(int(config.get('windsurf_run_button_search_lane_width', 960)), 400)


def _clip_region_to_screen(pyautogui, region):
    screen = pyautogui.size()
    if hasattr(screen, 'width') and hasattr(screen, 'height'):
        screen_width = int(screen.width)
        screen_height = int(screen.height)
    else:
        screen_width = int(screen[0])
        screen_height = int(screen[1])
    left = max(int(region.get('left', 0)), 0)
    top = max(int(region.get('top', 0)), 0)
    width = max(int(region.get('width', 0)), 1)
    height = max(int(region.get('height', 0)), 1)
    right = min(left + width, screen_width)
    bottom = min(top + height, screen_height)
    if right <= left:
        right = min(max(left + 1, 1), max(screen_width, 1))
        left = max(right - 1, 0)
    if bottom <= top:
        bottom = min(max(top + 1, 1), max(screen_height, 1))
        top = max(bottom - 1, 0)
    return {
        'left': left,
        'top': top,
        'width': max(right - left, 1),
        'height': max(bottom - top, 1),
    }


def resolve_run_button_search_region(pyautogui, config, target):
    explicit = target.get('run_button_search_region')
    if explicit and 'left' in explicit and 'right' in explicit:
        region = {
            'left': int(explicit['left']),
            'top': int(explicit.get('top', 50)),
            'width': int(explicit['right']) - int(explicit['left']),
            'height': int(explicit.get('bottom', 950)) - int(explicit.get('top', 50)),
        }
        return _clip_region_to_screen(pyautogui, region)
    send_button = target.get('send_button') or {}
    send_x = int(send_button.get('x', 0))
    send_y = int(send_button.get('y', 0))
    lane_width = _estimate_target_lane_width(config, target)
    lane_padding = max(int(config.get('windsurf_run_button_search_lane_padding', 60)), 0)
    search_width = max(lane_width - lane_padding, 240)
    right_margin = max(int(config.get('windsurf_run_button_search_right_margin', 45)), 0)
    top_offset = max(int(config.get('windsurf_run_button_search_top_offset', 820)), 120)
    bottom_margin = max(int(config.get('windsurf_run_button_search_bottom_margin', 70)), 0)
    search_height = max(top_offset - bottom_margin, 180)
    region = {
        'left': send_x - search_width + right_margin,
        'top': send_y - top_offset,
        'width': search_width,
        'height': search_height,
    }
    return _clip_region_to_screen(pyautogui, region)


def _is_blue_button_area(screenshot, match_box, min_blue_ratio=0.55):
    try:
        import numpy as np
        import cv2
        x, y, w, h = int(match_box[0]), int(match_box[1]), int(match_box[2]), int(match_box[3])
        crop = screenshot.crop((x, y, x + w, y + h))
        arr = np.array(crop.convert('RGB'))
        hsv = cv2.cvtColor(arr, cv2.COLOR_RGB2HSV)
        blue_mask = cv2.inRange(hsv, np.array([100, 100, 120]), np.array([130, 255, 255]))
        blue_ratio = float(np.count_nonzero(blue_mask)) / max(blue_mask.size, 1)
        return blue_ratio >= min_blue_ratio
    except Exception:
        return True


def locate_run_button(pyautogui, config, target):
    if not bool(config.get('windsurf_run_button_enabled', True)):
        return None
    reference_source = config.get('windsurf_run_button_reference_image')
    if not reference_source:
        return None
    region = resolve_run_button_search_region(pyautogui, config, target)
    screenshot = pyautogui.screenshot(
        region=(
            int(region['left']),
            int(region['top']),
            int(region['width']),
            int(region['height']),
        )
    )
    for grayscale in (False, True):
        reference = _load_reference_image(reference_source, grayscale=grayscale)
        search_image = screenshot
        if grayscale:
            if screenshot.mode != 'L':
                search_image = screenshot.convert('L')
        else:
            if screenshot.mode != 'RGB':
                search_image = screenshot.convert('RGB')
            if reference.mode != 'RGB':
                reference = reference.convert('RGB')
        try:
            match = pyautogui.locate(reference, search_image, grayscale=False, confidence=0.7)
        except TypeError:
            try:
                match = pyautogui.locate(reference, search_image, grayscale=False)
            except Exception:
                match = None
        except Exception:
            match = None
        if match is None:
            continue
        if not _is_blue_button_area(screenshot, (match.left, match.top, match.width, match.height)):
            continue
        left = int(region['left']) + int(match.left)
        top = int(region['top']) + int(match.top)
        width = int(match.width)
        height = int(match.height)
        return {
            'name': str(target.get('name') or ''),
            'left': left,
            'top': top,
            'width': width,
            'height': height,
            'center_x': left + (width // 2),
            'center_y': top + (height // 2),
            'region': dict(region),
            'grayscale': grayscale,
        }
    return None


def _image_dark_ratio(image, threshold=220):
    pixel_count = max(int(image.size[0]) * int(image.size[1]), 1)
    dark_pixels = 0
    for pixel in image.getdata():
        value = pixel[0] if isinstance(pixel, tuple) else pixel
        if int(value) < int(threshold):
            dark_pixels += 1
    return float(dark_pixels) / float(pixel_count)


def _image_similarity(sample, reference):
    from PIL import ImageChops, ImageOps, ImageStat
    if sample.mode != reference.mode:
        sample = sample.convert(reference.mode)
    if sample.size != reference.size:
        return 0.0
    sample = ImageOps.autocontrast(sample)
    reference = ImageOps.autocontrast(reference)
    diff = ImageChops.difference(sample, reference)
    stat = ImageStat.Stat(diff)
    mean_value = float(stat.mean[0] if stat.mean else 255.0)
    similarity = 1.0 - (mean_value / 255.0)
    return max(0.0, min(1.0, similarity))


def _best_template_similarity(search_image, reference):
    if search_image.mode != reference.mode:
        search_image = search_image.convert(reference.mode)
    search_width = int(search_image.size[0])
    search_height = int(search_image.size[1])
    reference_width = int(reference.size[0])
    reference_height = int(reference.size[1])
    if search_width < reference_width or search_height < reference_height:
        return 0.0, {'x': 0, 'y': 0}, 0.0
    max_left = search_width - reference_width
    max_top = search_height - reference_height
    best_score = -1.0
    best_offset = {'x': 0, 'y': 0}
    best_dark_ratio = 0.0
    for top in range(max_top + 1):
        for left in range(max_left + 1):
            sample = search_image.crop((left, top, left + reference_width, top + reference_height))
            score = _image_similarity(sample, reference)
            if score > best_score:
                best_score = score
                best_offset = {'x': left, 'y': top}
                best_dark_ratio = _image_dark_ratio(sample)
    return max(best_score, 0.0), best_offset, best_dark_ratio


def detect_button_state(pyautogui, config, target):
    roi_size = config.get('button_roi', {}) or {}
    match_padding = max(int(config.get('button_match_search_padding', 12)), 0)
    reference_dark_ratio_min = float(config.get('button_reference_dark_ratio_min', 0.02))
    sample_dark_ratio_min = float(config.get('button_sample_dark_ratio_min', 0.02))
    grayscale = bool(config.get('windsurf_image_grayscale', True))
    search_size = _expand_roi_size(roi_size, match_padding)
    sample = _capture_button_roi(pyautogui, target['send_button'], search_size, grayscale=grayscale)
    ready_reference = _crop_image_center(
        _load_reference_image(config.get('windsurf_send_button_reference_image'), grayscale=grayscale),
        roi_size,
    )
    target_reference = _crop_image_center(
        _load_reference_image(config.get('windsurf_target_button_reference_image'), grayscale=grayscale),
        roi_size,
    )
    ready_reference_dark_ratio = _image_dark_ratio(ready_reference)
    target_reference_dark_ratio = _image_dark_ratio(target_reference)
    ready_score, ready_offset, ready_sample_dark_ratio = _best_template_similarity(sample, ready_reference)
    target_score, target_offset, target_sample_dark_ratio = _best_template_similarity(sample, target_reference)
    if ready_reference_dark_ratio < reference_dark_ratio_min or ready_sample_dark_ratio < sample_dark_ratio_min:
        ready_score = 0.0
    if target_reference_dark_ratio < reference_dark_ratio_min or target_sample_dark_ratio < sample_dark_ratio_min:
        target_score = 0.0
    similarity_min = float(config.get('button_similarity_min', 0.82))
    similarity_margin = float(config.get('button_similarity_margin', 0.05))
    best_score = max(ready_score, target_score)
    score_gap = abs(ready_score - target_score)
    if best_score < similarity_min or score_gap < similarity_margin:
        state = 'unknown'
    elif ready_score > target_score:
        state = 'ready'
    else:
        state = 'target'
    return {
        'name': target['name'],
        'state': state,
        'ready_score': round(ready_score, 4),
        'target_score': round(target_score, 4),
        'ready_reference_dark_ratio': round(ready_reference_dark_ratio, 4),
        'target_reference_dark_ratio': round(target_reference_dark_ratio, 4),
        'ready_sample_dark_ratio': round(ready_sample_dark_ratio, 4),
        'target_sample_dark_ratio': round(target_sample_dark_ratio, 4),
        'ready_offset': ready_offset,
        'target_offset': target_offset,
        'send_button': dict(target['send_button']),
        'switch_button': dict(target['switch_button']) if target.get('switch_button') else None,
    }


def detect_window_state_anchor(pyautogui, config):
    anchor_min = float(config.get('auto_detection_anchor_similarity_min', 0.78))
    best_state = None
    best_score = 0.0
    for target in _normalize_button_targets(config):
        state = detect_button_state(pyautogui, config, target)
        score = max(float(state.get('ready_score') or 0.0), float(state.get('target_score') or 0.0))
        if best_state is None or score > best_score:
            best_state = state
            best_score = score
    return {
        'matched': bool(best_state is not None and best_score >= anchor_min),
        'score': round(float(best_score), 4),
        'state': best_state,
    }


def evaluate_windsurf_window_gate(pyautogui, config):
    if not bool(config.get('auto_detection_window_gate_enabled', False)):
        return {
            'allowed': True,
            'reason': 'disabled',
            'pass_count': 0,
            'min_passes': 0,
            'title': '',
            'checks': {
                'foreground': True,
                'window_interactable': True,
                'anchor_detected': True,
            },
            'anchor_score': 0.0,
            'anchor_state': None,
            'anchor_error': '',
        }
    window = _get_foreground_window_info(config)
    min_passes = max(int(config.get('auto_detection_window_gate_min_passes', 2)), 1)
    required_foreground = bool(config.get('auto_detection_require_foreground_window', True))
    anchor = {
        'matched': False,
        'score': 0.0,
        'state': None,
        'error': '',
    }
    try:
        anchor = detect_window_state_anchor(pyautogui, config)
        anchor['error'] = ''
    except Exception as e:
        anchor['error'] = str(e)
    checks = {
        'foreground': bool(window.get('title_match')),
        'window_interactable': bool(window.get('visible')) and not bool(window.get('iconic')) and bool(window.get('geometry_valid')),
        'anchor_detected': bool(anchor.get('matched')),
    }
    pass_count = sum(1 for value in checks.values() if value)
    allowed = pass_count >= min_passes
    reason = 'ok'
    if required_foreground and not checks['foreground']:
        allowed = False
        reason = 'foreground_mismatch'
    elif not checks['window_interactable']:
        allowed = False
        reason = 'window_hidden'
    elif pass_count < min_passes:
        reason = 'insufficient_gate_passes'
    return {
        'allowed': bool(allowed),
        'reason': reason,
        'pass_count': pass_count,
        'min_passes': min_passes,
        'title': window.get('title') or '',
        'checks': checks,
        'anchor_score': anchor.get('score', 0.0),
        'anchor_state': anchor.get('state'),
        'anchor_error': anchor.get('error', ''),
    }


def sample_stable_button_state(pyautogui, config, target):
    required = max(int(config.get('button_stable_samples', 3)), 1)
    poll_delay = max(float(config.get('button_poll_ms', 300)), 0.0) / 1000.0
    max_samples = max(required * 4, required)
    streak = 0
    last_state = None
    latest = None
    for index in range(max_samples):
        latest = detect_button_state(pyautogui, config, target)
        state = latest['state']
        if state != 'unknown' and state == last_state:
            streak += 1
        elif state != 'unknown':
            streak = 1
        else:
            streak = 0
        last_state = state
        if state != 'unknown' and streak >= required:
            latest['samples'] = index + 1
            latest['stable'] = True
            append_windsurf_service_log(
                f'stable_sample {format_button_state_log(latest)}'
            )
            return latest
        if index + 1 < max_samples and poll_delay > 0:
            time.sleep(poll_delay)
    if latest is None:
        latest = {
            'name': target['name'],
            'state': 'unknown',
            'ready_score': 0.0,
            'target_score': 0.0,
            'send_button': dict(target['send_button']),
            'switch_button': dict(target['switch_button']) if target.get('switch_button') else None,
        }
    else:
        latest = dict(latest)
    latest['samples'] = max_samples
    latest['stable'] = False
    latest['observed_state'] = latest.get('state') or 'unknown'
    latest['state'] = 'unknown'
    append_windsurf_service_log(
        f'stable_sample {format_button_state_log(latest)}'
    )
    return latest


def select_ready_button_target(pyautogui, config):
    states = []
    selected = None
    best_delta = None
    for target in _normalize_button_targets(config):
        state = sample_stable_button_state(pyautogui, config, target)
        states.append(state)
        if state['state'] != 'ready' or not bool(state.get('stable')):
            continue
        delta = float(state['ready_score']) - float(state['target_score'])
        if selected is None or best_delta is None or delta > best_delta:
            selected = state
            best_delta = delta
    summary = summarize_button_states(states)
    if selected is None:
        append_windsurf_service_log(
            f'select_ready_button_target selected=None states={summary}'
        )
    else:
        append_windsurf_service_log(
            f'select_ready_button_target selected={format_button_state_log(selected)} states={summary}'
        )
    return selected, states


def wait_for_target_button_state(pyautogui, config, target, wait_ms=None):
    verify_delay_ms = config.get('post_send_verify_ms', 1500) if wait_ms is None else wait_ms
    verify_delay = max(float(verify_delay_ms), 0.0) / 1000.0
    if verify_delay > 0:
        time.sleep(verify_delay)
    result = sample_stable_button_state(pyautogui, config, target)
    return bool(result.get('stable')) and result.get('state') == 'target', result
