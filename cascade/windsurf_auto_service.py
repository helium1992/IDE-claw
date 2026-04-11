import atexit
import os
import time
import traceback

import windsurf_auto_switch_send
import windsurf_support

SCRIPT_DIR = os.environ.get('IDE_CLAW_CASCADE_DIR') or os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.environ.get('IDE_CLAW_BASE_DIR') or os.path.dirname(SCRIPT_DIR)
PID_FILE = os.path.join(PROJECT_DIR, 'data', 'windsurf_auto_service.pid')


def _log(message):
    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
    windsurf_support.append_windsurf_service_log(message)
    print(f'[{timestamp}] {message}', flush=True)


def _pid_alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, SystemError):
        return False
    return True


def _read_pid():
    try:
        with open(PID_FILE, 'r', encoding='utf-8') as f:
            return int((f.read() or '').strip())
    except Exception:
        return None


def _write_pid(pid):
    os.makedirs(os.path.dirname(PID_FILE), exist_ok=True)
    with open(PID_FILE, 'w', encoding='utf-8') as f:
        f.write(str(int(pid)))


def _clear_pid():
    try:
        if not os.path.exists(PID_FILE):
            return
        current_pid = str(os.getpid())
        with open(PID_FILE, 'r', encoding='utf-8') as f:
            pid_text = (f.read() or '').strip()
        if pid_text == current_pid:
            os.remove(PID_FILE)
    except Exception:
        pass


def _ensure_single_instance():
    existing_pid = _read_pid()
    if existing_pid and existing_pid != os.getpid() and _pid_alive(existing_pid):
        return False
    _write_pid(os.getpid())
    return True


def _new_runtime_state():
    return {
        'candidate_name': '',
        'candidate_streak': 0,
        'candidate_window_count': 0,
        'candidate_window': [],
        'confirm_required_hits': 0,
        'confidence_trace': [],
        'cooldown_until': 0.0,
        'user_quiet_until': 0.0,
        'awaiting_progress_reset': False,
        'awaiting_progress_target': '',
        'target_last_action_at': {},
        'run_button_last_clicked_at': {},
        'last_action_target': '',
        'last_action_status': '',
        'last_action_at': 0,
        'recent_cycles': [],
    }


def _reset_candidate(runtime_state, reset_history=True):
    runtime_state['candidate_name'] = ''
    runtime_state['candidate_streak'] = 0
    runtime_state['candidate_window_count'] = 0
    if reset_history:
        runtime_state['candidate_window'] = []


def _record_candidate_observation(runtime_state, selected_name, confirm_rounds):
    selected_name = str(selected_name or '')
    confirm_rounds = max(int(confirm_rounds or 1), 1)
    current_name = str(runtime_state.get('candidate_name') or '')
    candidate_window = list(runtime_state.get('candidate_window') or [])
    if selected_name:
        if current_name != selected_name:
            current_name = selected_name
            candidate_window = []
        candidate_window.append(1)
    elif current_name:
        candidate_window.append(0)
    candidate_window = candidate_window[-confirm_rounds:]
    if current_name and not any(candidate_window):
        current_name = ''
        candidate_window = []
    runtime_state['candidate_name'] = current_name
    runtime_state['candidate_window'] = candidate_window
    runtime_state['candidate_streak'] = int(sum(candidate_window))
    runtime_state['candidate_window_count'] = len(candidate_window)


def _candidate_confirmed(runtime_state, selected_name, confirm_rounds, confirm_required_hits):
    selected_name = str(selected_name or '')
    if not selected_name:
        return False
    if str(runtime_state.get('candidate_name') or '') != selected_name:
        return False
    candidate_window = list(runtime_state.get('candidate_window') or [])
    if len(candidate_window) < max(int(confirm_rounds or 1), 1):
        return False
    return int(sum(candidate_window)) >= max(int(confirm_required_hits or 1), 1)


def _format_candidate_window(runtime_state, confirm_rounds, confirm_required_hits):
    return (
        f'hits={int(runtime_state.get("candidate_streak") or 0)}/{max(int(confirm_required_hits or 1), 1)} '
        f'window={int(runtime_state.get("candidate_window_count") or 0)}/{max(int(confirm_rounds or 1), 1)}'
    )


def _append_confidence_trace(runtime_state, scan_status, selected, states):
    if selected is None:
        entry = f'status={scan_status} states={windsurf_support.summarize_button_states(states)}'
    else:
        entry = f'status={scan_status} selected={windsurf_support.format_button_state_log(selected)}'
    trace = list(runtime_state.get('confidence_trace') or [])
    trace.append(entry)
    runtime_state['confidence_trace'] = trace[-3:]


def _format_confidence_trace(runtime_state):
    trace = runtime_state.get('confidence_trace') or []
    return ' || '.join(trace) if trace else 'none'


def _format_gate(gate):
    gate = gate or {}
    checks = gate.get('checks') or {}
    return (
        f'reason={gate.get("reason")} pass_count={gate.get("pass_count")}/{gate.get("min_passes")} '
        f'foreground={bool(checks.get("foreground"))} window_interactable={bool(checks.get("window_interactable"))} '
        f'anchor_detected={bool(checks.get("anchor_detected"))} anchor_score={gate.get("anchor_score")} '
        f'title={str(gate.get("title") or "").replace(" ", "_")}'
    )


def _build_cycle_entry(*, phase, status, summary, states, selected, action_executed):
    return {
        'timestamp': int(time.time() * 1000),
        'phase': str(phase or ''),
        'status': str(status or ''),
        'summary': str(summary or ''),
        'action_executed': bool(action_executed),
        'selected_target': str((selected or {}).get('name') or ''),
        'button_states': [_serialize_button_state(state) for state in list(states or [])],
    }


def _append_cycle_history(runtime_state, entry, limit=12):
    history = list(runtime_state.get('recent_cycles') or [])
    history.append(dict(entry or {}))
    runtime_state['recent_cycles'] = history[-max(int(limit or 1), 1):]


def _clear_progress_reset(runtime_state):
    runtime_state['awaiting_progress_reset'] = False
    runtime_state['awaiting_progress_target'] = ''


def _select_action_target(runtime_state, ready_targets, now, holdoff_ms):
    ready_targets = list(ready_targets or [])
    if not ready_targets:
        return None, 0
    last_action_times = dict(runtime_state.get('target_last_action_at') or {})
    holdoff_seconds = max(float(holdoff_ms), 0.0) / 1000.0
    eligible = []
    for target in ready_targets:
        name = str(target.get('name') or '')
        last_action_at = float(last_action_times.get(name) or 0.0)
        remaining_ms = max(int((last_action_at + holdoff_seconds - now) * 1000), 0)
        if remaining_ms <= 0:
            eligible.append(target)
    pool = eligible if eligible else ready_targets
    selected = sorted(
        pool,
        key=lambda item: (
            float(last_action_times.get(str(item.get('name') or ''), 0.0)),
            -(float(item.get('ready_score') or 0.0) - float(item.get('target_score') or 0.0)),
        ),
    )[0]
    selected_name = str(selected.get('name') or '')
    last_selected_action = float(last_action_times.get(selected_name) or 0.0)
    remaining_ms = max(int((last_selected_action + holdoff_seconds - now) * 1000), 0)
    if eligible:
        return selected, 0
    return None, remaining_ms


def _update_progress_reset(runtime_state, selected, states):
    if not bool(runtime_state.get('awaiting_progress_reset')):
        return False
    target_name = str(runtime_state.get('awaiting_progress_target') or '')
    if not target_name:
        _clear_progress_reset(runtime_state)
        return True
    tracked = windsurf_support.get_named_button_state(states, target_name)
    selected_name = str((selected or {}).get('name') or '')
    if tracked is None:
        _clear_progress_reset(runtime_state)
        return True
    tracked_state = str(tracked.get('state') or 'unknown')
    observed_state = str(tracked.get('observed_state', tracked_state) or tracked_state)
    if selected_name and selected_name != target_name:
        _clear_progress_reset(runtime_state)
        return True
    if tracked_state == 'target' or observed_state == 'target':
        _clear_progress_reset(runtime_state)
        return True
    if selected is None and (tracked_state == 'unknown' or observed_state == 'unknown'):
        _clear_progress_reset(runtime_state)
        return True
    return False


def _serialize_button_state(state):
    state = state or {}
    return {
        'name': str(state.get('name') or ''),
        'state': str(state.get('state') or ''),
        'observed_state': str(state.get('observed_state', state.get('state')) or ''),
        'stable': bool(state.get('stable')),
        'samples': int(state.get('samples') or 0),
        'ready_score': float(state.get('ready_score') or 0.0),
        'target_score': float(state.get('target_score') or 0.0),
    }


def _write_service_status(
    runtime_state,
    *,
    service_running=True,
    service_enabled=True,
    phase='idle',
    status='idle',
    summary='',
    states=None,
    selected=None,
    action_executed=False,
    cooldown_remaining_ms=0,
    quiet_remaining_ms=0,
    holdoff_remaining_ms=0,
    confirm_rounds=0,
    confirm_required_hits=None,
    gate=None,
):
    states = list(states or [])
    ready_targets = windsurf_support.get_ready_button_targets(states)
    detected_target_names = [
        str(target.get('name') or '')
        for target in ready_targets
        if str(target.get('name') or '').strip()
    ]
    selected_target = str((selected or {}).get('name') or '')
    if selected_target and selected_target not in detected_target_names:
        detected_target_names.insert(0, selected_target)
    cycle_entry = _build_cycle_entry(
        phase=phase,
        status=status,
        summary=summary,
        states=states,
        selected=selected,
        action_executed=action_executed,
    )
    _append_cycle_history(runtime_state, cycle_entry)
    resolved_confirm_required_hits = runtime_state.get('confirm_required_hits') if confirm_required_hits is None else confirm_required_hits
    payload = {
        'updated_at': int(time.time() * 1000),
        'service_running': bool(service_running),
        'service_enabled': bool(service_enabled),
        'phase': str(phase or ''),
        'status': str(status or ''),
        'summary': str(summary or ''),
        'selected_target': selected_target,
        'candidate_target': str(runtime_state.get('candidate_name') or ''),
        'candidate_streak': int(runtime_state.get('candidate_streak') or 0),
        'candidate_window_count': int(runtime_state.get('candidate_window_count') or 0),
        'confirm_rounds': int(confirm_rounds or 0),
        'confirm_required_hits': int(resolved_confirm_required_hits or 0),
        'action_executed': bool(action_executed),
        'last_action_target': str(runtime_state.get('last_action_target') or ''),
        'last_action_status': str(runtime_state.get('last_action_status') or ''),
        'last_action_at': int(runtime_state.get('last_action_at') or 0),
        'awaiting_progress_reset': bool(runtime_state.get('awaiting_progress_reset')),
        'awaiting_progress_target': str(runtime_state.get('awaiting_progress_target') or ''),
        'cooldown_remaining_ms': max(int(cooldown_remaining_ms or 0), 0),
        'quiet_remaining_ms': max(int(quiet_remaining_ms or 0), 0),
        'holdoff_remaining_ms': max(int(holdoff_remaining_ms or 0), 0),
        'has_target_button': bool(detected_target_names),
        'detected_target_names': detected_target_names,
        'button_states': [_serialize_button_state(state) for state in states],
        'recent_cycles': list(runtime_state.get('recent_cycles') or []),
        'confidence_trace': list(runtime_state.get('confidence_trace') or []),
        'gate_reason': str((gate or {}).get('reason') or ''),
    }
    windsurf_support.write_windsurf_service_status(payload)


def _write_stopped_status(summary='检测服务已停止'):
    windsurf_support.write_windsurf_service_status({
        'updated_at': int(time.time() * 1000),
        'service_running': False,
        'service_enabled': True,
        'phase': 'stopped',
        'status': 'stopped',
        'summary': summary,
        'selected_target': '',
        'candidate_target': '',
        'candidate_streak': 0,
        'confirm_rounds': 0,
        'action_executed': False,
        'last_action_target': '',
        'last_action_status': '',
        'last_action_at': 0,
        'awaiting_progress_reset': False,
        'awaiting_progress_target': '',
        'cooldown_remaining_ms': 0,
        'quiet_remaining_ms': 0,
        'holdoff_remaining_ms': 0,
        'has_target_button': False,
        'detected_target_names': [],
        'button_states': [],
        'recent_cycles': [],
        'confidence_trace': [],
        'gate_reason': '',
    })


def main():
    if not _ensure_single_instance():
        _log('windsurf auto service already running')
        return
    atexit.register(_clear_pid)
    atexit.register(_write_stopped_status)
    _log('windsurf auto service started')
    runtime_state = _new_runtime_state()
    _write_service_status(runtime_state, phase='starting', status='starting', summary='检测服务已启动')
    while True:
        config = windsurf_support.load_windsurf_config()
        if not bool(config.get('auto_detection_service_enabled', True)):
            _write_service_status(
                runtime_state,
                service_enabled=False,
                phase='disabled',
                status='disabled',
                summary='检测服务已关闭（配置）',
            )
            time.sleep(2)
            continue
        try:
            cycle_delay_ms = config.get('auto_detection_cycle_poll_ms', config.get('auto_detection_idle_poll_ms', 1500))
            post_action_delay_ms = config.get('auto_detection_post_run_cooldown_ms', 1000)
            cooldown_ms = config.get('auto_detection_action_cooldown_ms', 20000)
            target_holdoff_ms = config.get('auto_detection_target_holdoff_ms', cooldown_ms)
            confirm_rounds = max(int(config.get('auto_detection_confirm_rounds', 5) or 5), 1)
            confirm_required_hits = max(int(config.get('auto_detection_confirm_required_hits', confirm_rounds) or confirm_rounds), 1)
            confirm_required_hits = min(confirm_required_hits, confirm_rounds)
            runtime_state['confirm_required_hits'] = confirm_required_hits
            quiet_ms = max(int(config.get('auto_detection_user_interrupt_quiet_ms', 3000)), 0)
            pyautogui = windsurf_auto_switch_send.load_pyautogui(enable_click_patch=False)
            gate = windsurf_support.evaluate_windsurf_window_gate(pyautogui, config)
            now = time.time()
            if not bool(gate.get('allowed')):
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='skipped_window_gate',
                    summary='未通过窗口门禁，暂不检测按钮',
                    confirm_rounds=confirm_rounds,
                    gate=gate,
                )
                _log(
                    f'cycle status=skipped_window_gate cycle_state=idle abort_reason={gate.get("reason")} '
                    f'candidate_streak=0 confidence_trace={_format_confidence_trace(runtime_state)} gate={_format_gate(gate)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            run_click_result = windsurf_auto_switch_send.click_detected_run_buttons(
                pyautogui=pyautogui,
                config=config,
                last_clicked_at=runtime_state.setdefault('run_button_last_clicked_at', {}),
            )
            clicked_buttons = list(run_click_result.get('clicked_buttons') or [])
            if clicked_buttons:
                clicked_names = '、'.join(
                    str(item.get('name') or 'unknown')
                    for item in clicked_buttons
                    if str(item.get('name') or '').strip()
                ) or 'unknown'
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='observing',
                    status='run_button_clicked',
                    summary=f'已自动点击 Run 按钮：{clicked_names}',
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=run_button_clicked cycle_state=observing run_targets={clicked_names} '
                    f'confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            if float(runtime_state.get('user_quiet_until') or 0.0) > now:
                remaining_ms = max(int((float(runtime_state.get('user_quiet_until') or 0.0) - now) * 1000), 0)
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='user_quiet',
                    summary='检测暂停，检测到用户正在操作',
                    quiet_remaining_ms=remaining_ms,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=user_quiet cycle_state=idle abort_reason=user_interrupt_active '
                    f'quiet_remaining_ms={remaining_ms} confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = min(remaining_ms or cycle_delay_ms, cycle_delay_ms)
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            snapshot = windsurf_support.capture_user_activity_snapshot(config)
            scan_result = windsurf_auto_switch_send.scan_ready_target(pyautogui=pyautogui, config=config)
            states = scan_result.get('button_states') or []
            scan_status = str(scan_result.get('status', 'unknown'))
            ready_targets = windsurf_support.get_ready_button_targets(states)
            selected, target_holdoff_remaining_ms = _select_action_target(
                runtime_state,
                ready_targets,
                time.time(),
                target_holdoff_ms,
            )
            _append_confidence_trace(runtime_state, scan_status, selected, states)
            interrupt = windsurf_support.detect_user_interrupt(snapshot, config)
            if bool(interrupt.get('interrupted')):
                runtime_state['user_quiet_until'] = time.time() + (float(quiet_ms) / 1000.0)
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='interrupted',
                    summary='检测暂停，用户刚刚介入操作',
                    states=states,
                    quiet_remaining_ms=quiet_ms,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=interrupted cycle_state=idle abort_reason={interrupt.get("reason")} quiet_ms={quiet_ms} '
                    f'delta_x={interrupt.get("delta_x")} delta_y={interrupt.get("delta_y")} '
                    f'confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            progress_reset_cleared = _update_progress_reset(runtime_state, selected, states)
            now = time.time()
            cooldown_remaining_ms = max(int((float(runtime_state.get('cooldown_until') or 0.0) - now) * 1000), 0)
            if cooldown_remaining_ms > 0:
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='cooldown',
                    status='cooldown_active',
                    summary='上一轮操作后冷却中',
                    states=states,
                    cooldown_remaining_ms=cooldown_remaining_ms,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=cooldown_active cycle_state=cooldown cooldown_remaining_ms={cooldown_remaining_ms} '
                    f'awaiting_progress_reset={bool(runtime_state.get("awaiting_progress_reset"))} '
                    f'progress_reset_cleared={bool(progress_reset_cleared)} confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = min(cooldown_remaining_ms, cycle_delay_ms)
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            if bool(runtime_state.get('awaiting_progress_reset')):
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='awaiting_progress_reset',
                    summary='等待界面刷新，暂不重复执行',
                    states=states,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=awaiting_progress_reset cycle_state=idle abort_reason=awaiting_progress_reset '
                    f'target={runtime_state.get("awaiting_progress_target")} confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            if selected is None and ready_targets:
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='observing',
                    status='target_holdoff',
                    summary='已捕捉到目标按钮，等待轮到该目标执行',
                    states=states,
                    holdoff_remaining_ms=target_holdoff_remaining_ms,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=target_holdoff cycle_state=observing holdoff_remaining_ms={target_holdoff_remaining_ms} '
                    f'ready_targets={windsurf_support.summarize_button_states(ready_targets)} '
                    f'confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = min(target_holdoff_remaining_ms or cycle_delay_ms, cycle_delay_ms)
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            if selected is None:
                _record_candidate_observation(runtime_state, '', confirm_rounds)
                _write_service_status(
                    runtime_state,
                    phase='observing',
                    status=scan_status,
                    summary='当前未捕捉到可执行目标按钮',
                    states=states,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status={scan_status} cycle_state=observing candidate_streak=0 '
                    f'confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            _record_candidate_observation(runtime_state, str(selected.get('name') or ''), confirm_rounds)
            if not _candidate_confirmed(runtime_state, str(selected.get('name') or ''), confirm_rounds, confirm_required_hits):
                _write_service_status(
                    runtime_state,
                    phase='candidate',
                    status='candidate_confirming',
                    summary=(
                        f'已捕捉到目标按钮 {runtime_state.get("candidate_name")}，正在确认'
                        f'（命中 {runtime_state.get("candidate_streak")}/{confirm_required_hits}，'
                        f'窗口 {runtime_state.get("candidate_window_count")}/{confirm_rounds}）'
                    ),
                    states=states,
                    selected=selected,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=candidate_confirming cycle_state=candidate candidate_target={runtime_state.get("candidate_name")} '
                    f'{_format_candidate_window(runtime_state, confirm_rounds, confirm_required_hits)} '
                    f'confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            pre_action_gate = windsurf_support.evaluate_windsurf_window_gate(pyautogui, config)
            if not bool(pre_action_gate.get('allowed')):
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='pre_action_blocked',
                    summary='检测到目标按钮，但执行前窗口校验未通过',
                    states=states,
                    selected=selected,
                    confirm_rounds=confirm_rounds,
                    gate=pre_action_gate,
                )
                _log(
                    f'cycle status=pre_action_blocked cycle_state=idle abort_reason=pre_action_{pre_action_gate.get("reason")} '
                    f'candidate_target={selected.get("name")} confidence_trace={_format_confidence_trace(runtime_state)} '
                    f'gate={_format_gate(pre_action_gate)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            pre_action_interrupt = windsurf_support.detect_user_interrupt(snapshot, config)
            if bool(pre_action_interrupt.get('interrupted')):
                runtime_state['user_quiet_until'] = time.time() + (float(quiet_ms) / 1000.0)
                _reset_candidate(runtime_state)
                _write_service_status(
                    runtime_state,
                    phase='idle',
                    status='pre_action_interrupted',
                    summary='检测到目标按钮，但执行前用户介入了操作',
                    states=states,
                    selected=selected,
                    quiet_remaining_ms=quiet_ms,
                    confirm_rounds=confirm_rounds,
                )
                _log(
                    f'cycle status=pre_action_interrupted cycle_state=idle abort_reason={pre_action_interrupt.get("reason")} '
                    f'quiet_ms={quiet_ms} delta_x={pre_action_interrupt.get("delta_x")} '
                    f'delta_y={pre_action_interrupt.get("delta_y")} confidence_trace={_format_confidence_trace(runtime_state)}'
                )
                delay_ms = cycle_delay_ms
                time.sleep(max(float(delay_ms), 0.0) / 1000.0)
                continue
            result = windsurf_auto_switch_send.execute_selected_target(
                '',
                selected,
                switch_first=True,
                auto_send=True,
                focus_window=bool(config.get('auto_detection_focus_before_check', False)),
                verify_retry_count=config.get('auto_detection_verify_retry_count', 1),
                verify_retry_delay_ms=config.get('auto_detection_verify_retry_ms', 1500),
                pyautogui=pyautogui,
                config=config,
            )
            status = str(result.get('status', 'unknown'))
            runtime_state['cooldown_until'] = time.time() + (max(float(cooldown_ms), 0.0) / 1000.0)
            runtime_state.setdefault('target_last_action_at', {})[str((selected or {}).get('name') or '')] = time.time()
            runtime_state['last_action_target'] = str((selected or {}).get('name') or '')
            runtime_state['last_action_status'] = status
            runtime_state['last_action_at'] = int(time.time() * 1000)
            _reset_candidate(runtime_state)
            require_progress_reset = bool(config.get('auto_detection_require_progress_reset_after_action', False))
            if status == 'completed' or not require_progress_reset:
                _clear_progress_reset(runtime_state)
            else:
                runtime_state['awaiting_progress_reset'] = True
                runtime_state['awaiting_progress_target'] = str((selected or {}).get('name') or '')
            _write_service_status(
                runtime_state,
                phase='cooldown',
                status=status,
                summary=(
                    f'已执行 {selected.get("name")}，结果完成'
                    if status == 'completed'
                    else f'已执行 {selected.get("name")}，结果 {status}'
                ),
                states=states,
                selected=selected,
                action_executed=True,
                cooldown_remaining_ms=cooldown_ms,
                confirm_rounds=confirm_rounds,
            )
            _log(
                f'cycle status={status} cycle_state=cooldown selected={selected.get("name")} '
                f'cooldown_ms={cooldown_ms} awaiting_progress_reset={bool(runtime_state.get("awaiting_progress_reset"))} '
                f'verify={windsurf_support.format_button_state_log(result.get("verify_result"))} '
                f'confidence_trace={_format_confidence_trace(runtime_state)}'
            )
            delay_ms = post_action_delay_ms
        except KeyboardInterrupt:
            raise
        except Exception as e:
            _reset_candidate(runtime_state)
            _write_service_status(
                runtime_state,
                phase='error',
                status='error',
                summary=f'检测循环异常：{e}',
            )
            _log(f'cycle error={e}')
            traceback.print_exc()
            delay_ms = windsurf_support.load_windsurf_config().get('auto_detection_cycle_poll_ms', 2000)
        time.sleep(max(float(delay_ms), 0.0) / 1000.0)


if __name__ == '__main__':
    main()
