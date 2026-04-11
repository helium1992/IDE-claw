import argparse
import time

import windsurf_support


def _resolve_input_target(config, target=None):
    target = target or {}
    target_input_box = target.get('input_box') or {}
    if 'x' in target_input_box and 'y' in target_input_box:
        return {
            'x': int(target_input_box.get('x', 1550)),
            'y': int(target_input_box.get('y', 950)),
        }
    input_box = config.get('windsurf_input_box', {}) or {}
    if target and 'x' in input_box and 'y' in input_box:
        base_targets = windsurf_support._normalize_button_targets(config)
        if base_targets:
            base_target = base_targets[0]
            base_send_button = base_target.get('send_button') or {}
            target_send_button = target.get('send_button') or {}
            if (
                'x' in base_send_button
                and 'y' in base_send_button
                and 'x' in target_send_button
                and 'y' in target_send_button
            ):
                return {
                    'x': int(target_send_button.get('x', 0)) + int(input_box.get('x', 1550)) - int(base_send_button.get('x', 0)),
                    'y': int(target_send_button.get('y', 0)) + int(input_box.get('y', 950)) - int(base_send_button.get('y', 0)),
                }
    return {
        'x': int(input_box.get('x', 1550)),
        'y': int(input_box.get('y', 950)),
    }


def _patch_visible_click(pyautogui, move_duration=0.8, settle_delay=0.2):
    original_click = getattr(pyautogui, '_windsurf_original_click', None)
    if original_click is None:
        original_click = pyautogui.click
        pyautogui._windsurf_original_click = original_click
    else:
        pyautogui.click = original_click

    def visible_click(x=None, y=None, *args, **kwargs):
        if x is not None and y is not None:
            pyautogui.moveTo(x, y, duration=move_duration)
            if settle_delay > 0:
                time.sleep(settle_delay)
        return original_click(x=x, y=y, *args, **kwargs)

    pyautogui.click = visible_click


def _switch_to_target(pyautogui, config, target, avoid_emails=None):
    """切换账号：通过脚本直接写入 Windsurf 配置文件（不再点击按钮）"""
    from windsurf_account_switch import create_switcher_from_config
    switcher = create_switcher_from_config()
    current_before = switcher.get_current_account()

    # 切号前先刷新当前账号额度，确认是否真的耗尽
    if current_before and bool(config.get('auto_detection_pre_switch_refresh', True)):
        windsurf_support.append_windsurf_service_log(
            f'pre_switch_refresh email={current_before}'
        )
        refresh_result = switcher.refresh_account_credits(current_before)
        refresh_state = str(refresh_result.get('quota_state', 'unknown'))
        windsurf_support.append_windsurf_service_log(
            f'pre_switch_refresh_done email={current_before} state={refresh_state} '
            f'credits={refresh_result.get("credits", {})}'
        )
        if refresh_state == 'active':
            windsurf_support.append_windsurf_service_log(
                f'pre_switch_refresh_active email={current_before} — 额度未耗尽，跳过切号'
            )
            return {
                'switched': False,
                'reason': 'current_still_active',
                'active_email': current_before,
                'switch_result': {'status': 'skipped', 'message': f'{current_before} 额度未耗尽，无需切号'},
                'wait_seconds': 0,
                'pre_switch_refresh': refresh_result,
            }

    result = switcher.switch(
        ignore_cooldown=bool(config.get('auto_detection_switch_ignore_cooldown', True)),
        avoid_emails=avoid_emails,
        prefer_local=bool(config.get('auto_detection_switch_prefer_local', True)),
    )
    status = result.get('status', 'unknown')
    active_email = result.get('email') or switcher.get_current_account() or current_before

    if status == 'cooldown':
        windsurf_support.append_windsurf_service_log(
            f'switch_skip cooldown remaining={result.get("remaining_seconds")}s'
        )
        return {
            'switched': False,
            'reason': 'cooldown',
            'active_email': active_email,
            'switch_result': result,
            'wait_seconds': 0,
        }

    if status == 'no_account':
        windsurf_support.append_windsurf_service_log(
            f'switch_skip no_account msg={result.get("message")}'
        )
        return {
            'switched': False,
            'reason': 'no_account',
            'active_email': active_email,
            'switch_result': result,
            'wait_seconds': 0,
        }

    if status != 'success':
        windsurf_support.append_windsurf_service_log(
            f'switch_error status={status} msg={result.get("message")}'
        )
        return {
            'switched': False,
            'reason': status,
            'active_email': active_email,
            'switch_result': result,
            'wait_seconds': 0,
        }

    # 切号成功，Windsurf 运行时注入由 ideclaw-session 扩展处理
    windsurf_support.append_windsurf_service_log(
        f'switch_success source={result.get("source")} '
        f'old={result.get("old_email")} new={result.get("email")} '
        f'has_token={result.get("has_token")}'
    )

    wait_seconds = max(float(config.get('switch_wait_ms', 20000)), 0.0) / 1000.0
    if wait_seconds > 0:
        time.sleep(wait_seconds)
    return {
        'switched': True,
        'reason': 'success',
        'active_email': active_email,
        'switch_result': result,
        'wait_seconds': wait_seconds,
        'trigger_sent': bool(result.get('trigger_sent')),
    }


def _resolve_attempt_email(switch_result):
    switch_result = switch_result if isinstance(switch_result, dict) else {}
    nested = switch_result.get('switch_result') if isinstance(switch_result.get('switch_result'), dict) else {}
    return str(
        switch_result.get('active_email')
        or nested.get('email')
        or nested.get('current_email')
        or ''
    ).strip()


def _should_retry_after_verify_failure(config, verify_result):
    if not bool(config.get('auto_detection_retry_on_ready_verify_failed', True)):
        return False
    verify_result = verify_result if isinstance(verify_result, dict) else {}
    observed_state = str(
        verify_result.get('observed_state')
        or verify_result.get('state')
        or ''
    ).strip().lower()
    return observed_state == 'ready'


def _cooldown_failed_account(email, config, reason):
    email = str(email or '').strip()
    if not email:
        return None
    from windsurf_account_switch import create_switcher_from_config
    switcher = create_switcher_from_config()
    duration_minutes = max(int(config.get('auto_detection_account_block_minutes', 60) or 0), 0)
    blocked = switcher.block_account_for_auto_switch(
        email,
        duration_minutes * 60,
        reason=reason,
    )
    windsurf_support.append_windsurf_service_log(
        f'auto_switch_cooldown email={email} minutes={duration_minutes} reason={reason}'
    )
    return blocked


def _inject_text(pyautogui, config, text, target, auto_send=True):
    input_target = _resolve_input_target(config, target=target)
    focus_delay = max(float(config.get('focus_delay_ms', 150)), 0.0) / 1000.0
    paste_delay = max(float(config.get('paste_delay_ms', 120)), 0.0) / 1000.0
    send_delay = max(float(config.get('send_delay_ms', 80)), 0.0) / 1000.0
    paste_shortcut = windsurf_support._normalize_shortcut(config.get('paste_shortcut'), ['ctrl', 'v'])
    send_shortcut = windsurf_support._normalize_shortcut(config.get('send_shortcut'), ['enter'])

    pyautogui.click(input_target['x'], input_target['y'])
    time.sleep(focus_delay)
    windsurf_support._copy_text_to_clipboard(text)
    time.sleep(0.05)
    windsurf_support._press_shortcut(pyautogui, paste_shortcut)
    time.sleep(paste_delay)

    if auto_send:
        windsurf_support._press_shortcut(pyautogui, send_shortcut)
        time.sleep(send_delay)

    return {
        'input_target': input_target,
        'send_mode': 'enter_shortcut' if auto_send else 'none',
    }


def load_pyautogui(enable_click_patch=False):
    try:
        import pyautogui
    except ImportError as e:
        missing = getattr(e, 'name', '') or str(e)
        raise RuntimeError(f'缺少依赖: {missing}') from e
    windsurf_support._enable_dpi_awareness()
    pyautogui.PAUSE = 0.05
    if enable_click_patch:
        _patch_visible_click(pyautogui)
    return pyautogui


def scan_ready_target(pyautogui=None, config=None):
    pyautogui = pyautogui or load_pyautogui(enable_click_patch=False)
    config = config or windsurf_support.load_windsurf_config()
    target, states = windsurf_support.select_ready_button_target(pyautogui, config)
    if target is None:
        all_unknown = bool(states) and all((state.get('state') or 'unknown') == 'unknown' for state in states)
        status = 'no_template_match' if all_unknown else 'no_ready_target'
    else:
        status = 'ready_target_detected'
    return {
        'status': status,
        'selected_target': target,
        'button_states': states,
    }


def click_detected_run_buttons(pyautogui=None, config=None, last_clicked_at=None):
    pyautogui = pyautogui or load_pyautogui(enable_click_patch=False)
    config = config or windsurf_support.load_windsurf_config()
    last_clicked_at = last_clicked_at if isinstance(last_clicked_at, dict) else {}
    if not bool(config.get('windsurf_run_button_enabled', True)):
        return {
            'clicked_buttons': [],
            'post_click_delay_ms': int(config.get('windsurf_run_button_post_click_delay_ms', 800) or 0),
        }
    cooldown_seconds = max(float(config.get('windsurf_run_button_cooldown_ms', 4000)), 0.0) / 1000.0
    post_click_delay_ms = max(int(config.get('windsurf_run_button_post_click_delay_ms', 800) or 0), 0)
    clicked_buttons = []
    now = time.time()
    for target in windsurf_support._normalize_button_targets(config):
        name = str(target.get('name') or '')
        if not name:
            continue
        last_click = float(last_clicked_at.get(name) or 0.0)
        if cooldown_seconds > 0 and (now - last_click) < cooldown_seconds:
            continue
        match = windsurf_support.locate_run_button(pyautogui, config, target)
        if match is None:
            continue
        pyautogui.click(int(match['center_x']), int(match['center_y']))
        last_clicked_at[name] = time.time()
        clicked_buttons.append(match)
        if post_click_delay_ms > 0:
            time.sleep(post_click_delay_ms / 1000.0)
    return {
        'clicked_buttons': clicked_buttons,
        'post_click_delay_ms': post_click_delay_ms,
    }


def _verify_target_state(pyautogui, config, target, retry_count=0, retry_delay_ms=None):
    attempts = []
    matched, result = windsurf_support.wait_for_target_button_state(pyautogui, config, target)
    attempts.append({
        'matched': bool(matched),
        'result': result,
        'wait_ms': config.get('post_send_verify_ms', 1500),
    })
    retries = max(int(retry_count), 0)
    retry_wait = config.get('auto_detection_verify_retry_ms', 1500) if retry_delay_ms is None else retry_delay_ms
    for _ in range(retries):
        if matched:
            break
        matched, result = windsurf_support.wait_for_target_button_state(pyautogui, config, target, wait_ms=retry_wait)
        attempts.append({
            'matched': bool(matched),
            'result': result,
            'wait_ms': retry_wait,
        })
    return bool(matched), result, attempts


def execute_selected_target(
    text,
    target,
    switch_first=True,
    auto_send=True,
    focus_window=False,
    verify_retry_count=None,
    verify_retry_delay_ms=None,
    pyautogui=None,
    config=None,
):
    if not target:
        raise RuntimeError('缺少已选择的目标，无法执行动作')
    config = config or windsurf_support.load_windsurf_config()
    pyautogui = pyautogui or load_pyautogui(enable_click_patch=True)
    if pyautogui is not None:
        _patch_visible_click(pyautogui)

    should_focus = bool(focus_window or config.get('focus_window_before_inject', False))
    if should_focus and not windsurf_support._focus_windsurf_window(config):
        raise RuntimeError('无法找到 Windsurf 窗口')

    reply_text = (text or '').strip() or str(config.get('reply_text') or '继续，将回复推送给我')
    retries = config.get('auto_detection_verify_retry_count', 1) if verify_retry_count is None else verify_retry_count
    windsurf_support.append_windsurf_service_log(
        f'run_selected_target {windsurf_support.format_button_state_log(target)}'
    )
    max_attempts = max(int(config.get('auto_detection_switch_retry_count', 3) or 1), 1) if switch_first else 1
    attempted_emails = []
    attempt_results = []
    switch_result = None
    inject_result = None
    verify_result = None
    verify_attempts = []
    status = 'verify_failed'

    for attempt_index in range(max_attempts):
        windsurf_support.append_windsurf_service_log(
            f'run_attempt attempt={attempt_index + 1} pre_action target={windsurf_support.format_button_state_log(target)}'
        )
        switch_result = None
        inject_result = None
        verify_result = None
        verify_attempts = []

        if switch_first:
            switch_result = _switch_to_target(
                pyautogui,
                config,
                target,
                avoid_emails=attempted_emails,
            )
            switch_reason = str((switch_result or {}).get('reason') or 'unknown')
            if not bool((switch_result or {}).get('switched')) and switch_reason != 'current_still_active':
                windsurf_support.append_windsurf_service_log(
                    f'switch_failed attempt={attempt_index + 1} reason={switch_reason} — 中止注入，避免向已耗尽账号发送'
                )
                return {
                    'text': reply_text,
                    'switch_first': switch_first,
                    'auto_send': auto_send,
                    'status': 'switch_failed',
                    'selected_target': target,
                    'attempts': attempt_index + 1,
                    'switch_result': switch_result,
                    'verify_result': None,
                    'verify_attempts': [],
                    'attempt_results': attempt_results,
                    'input_target': _resolve_input_target(config, target=target),
                    'send_mode': 'none',
                }

        pre_inject_state = windsurf_support.detect_button_state(pyautogui, config, target)
        if str(pre_inject_state.get('state') or '') == 'target':
            windsurf_support.append_windsurf_service_log(
                f'pre_inject_abort target={target.get("name")} state=target (已在运行中，中止注入)'
            )
            return {
                'text': reply_text,
                'switch_first': switch_first,
                'auto_send': auto_send,
                'status': 'aborted_target_running',
                'selected_target': target,
                'attempts': attempt_index + 1,
                'switch_result': switch_result,
                'verify_result': pre_inject_state,
                'verify_attempts': [],
                'attempt_results': attempt_results,
                'input_target': _resolve_input_target(config, target=target),
                'send_mode': 'none',
            }

        inject_result = _inject_text(pyautogui, config, reply_text, target, auto_send=auto_send)
        matched, verify_result, verify_attempts = _verify_target_state(
            pyautogui,
            config,
            target,
            retry_count=retries,
            retry_delay_ms=verify_retry_delay_ms,
        )
        for verify_index, item in enumerate(verify_attempts, start=1):
            windsurf_support.append_windsurf_service_log(
                f'run_verify attempt={attempt_index + 1}.{verify_index} matched={bool(item.get("matched"))} '
                f'wait_ms={item.get("wait_ms")} result={windsurf_support.format_button_state_log(item.get("result"))}'
            )

        status = 'completed' if matched else 'verify_failed'
        attempt_email = _resolve_attempt_email(switch_result)
        attempt_results.append({
            'attempt': attempt_index + 1,
            'status': status,
            'email': attempt_email,
            'switch_result': switch_result,
            'verify_result': verify_result,
            'verify_attempts': verify_attempts,
        })

        if matched:
            break

        if (
            attempt_index + 1 < max_attempts
            and _should_retry_after_verify_failure(config, verify_result)
        ):
            if attempt_email and attempt_email.lower() not in [item.lower() for item in attempted_emails]:
                attempted_emails.append(attempt_email)
            _cooldown_failed_account(
                attempt_email,
                config,
                reason='verify_failed_ready_rate_limit_suspected',
            )
            windsurf_support.append_windsurf_service_log(
                f'run_retry attempt={attempt_index + 1} next_attempt={attempt_index + 2} email={attempt_email}'
            )
            continue
        break

    windsurf_support.append_windsurf_service_log(
        f'run_complete attempts={len(attempt_results) or 1} status={status} '
        f'selected={windsurf_support.format_button_state_log(target)} '
        f'verify={windsurf_support.format_button_state_log(verify_result)}'
    )
    return {
        'text': reply_text,
        'switch_first': switch_first,
        'auto_send': auto_send,
        'status': status,
        'selected_target': target,
        'attempts': len(attempt_results) or 1,
        'attempt_results': attempt_results,
        'switch_result': switch_result,
        'verify_result': verify_result,
        'verify_attempts': verify_attempts,
        'input_target': inject_result['input_target'] if inject_result else _resolve_input_target(config, target=target),
        'send_mode': inject_result['send_mode'] if inject_result else ('enter_shortcut' if auto_send else 'none'),
    }


def run(text, switch_first=True, auto_send=True, focus_window=False):
    config = windsurf_support.load_windsurf_config()
    pyautogui = load_pyautogui(enable_click_patch=False)

    should_focus = bool(focus_window or config.get('focus_window_before_inject', False))
    if should_focus and not windsurf_support._focus_windsurf_window(config):
        raise RuntimeError('无法找到 Windsurf 窗口')

    reply_text = (text or '').strip() or str(config.get('reply_text') or '继续，将回复推送给我')
    windsurf_support.append_windsurf_service_log(
        f'run_start switch_first={switch_first} auto_send={auto_send} focus_window={should_focus} reply_text={reply_text}'
    )
    scan_result = scan_ready_target(pyautogui=pyautogui, config=config)
    target = scan_result.get('selected_target')
    states = scan_result.get('button_states') or []
    if target is None:
        all_unknown = bool(states) and all((state.get('state') or 'unknown') == 'unknown' for state in states)
        status = 'no_template_match' if all_unknown else 'no_ready_target'
        summary = windsurf_support.summarize_button_states(states)
        windsurf_support.append_windsurf_service_log(
            f'run_status status={status} states={summary}'
        )
        return {
            'text': reply_text,
            'switch_first': switch_first,
            'auto_send': auto_send,
            'status': status,
            'button_states': states,
        }
    result = execute_selected_target(
        reply_text,
        target,
        switch_first=switch_first,
        auto_send=auto_send,
        focus_window=False,
        pyautogui=pyautogui,
        config=config,
    )
    result['button_states'] = states
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('text', nargs='?', default='继续，将回复推送给我')
    parser.add_argument('--no-switch', action='store_true')
    parser.add_argument('--no-send', action='store_true')
    parser.add_argument('--focus-window', action='store_true')
    args = parser.parse_args()

    result = run(
        text=args.text,
        switch_first=not args.no_switch,
        auto_send=not args.no_send,
        focus_window=args.focus_window,
    )
    print(result)


if __name__ == '__main__':
    main()
