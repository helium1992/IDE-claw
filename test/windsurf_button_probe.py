import argparse
import copy
import os
import sys
import time
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
CASCADE_DIR = os.path.join(PROJECT_DIR, 'cascade')

if CASCADE_DIR not in sys.path:
    sys.path.insert(0, CASCADE_DIR)

import windsurf_auto_switch_send
import windsurf_support

STATE_LABELS = {
    'unknown': '无',
    'target': '工作中',
    'ready': '已停止',
}

TARGET_LABELS = {
    'left': '左',
    'right': '右',
}

SCAN_STATUS_LABELS = {
    'ready_target_detected': '检测到可执行目标',
    'no_ready_target': '未检测到可执行目标',
    'no_template_match': '未匹配到参考图',
    'skipped_window_gate': '窗口门禁未通过',
}


def _parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--interval', type=float, default=1.0)
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--virtual', action='store_true')
    parser.add_argument('--stable', action='store_true')
    parser.add_argument('--focus-windsurf', action='store_true')
    parser.add_argument('--show-gate', action='store_true')
    return parser.parse_args()


def _prepare_config(args):
    config = copy.deepcopy(windsurf_support.load_windsurf_config())
    if args.virtual:
        config['auto_detection_require_foreground_window'] = False
        config['auto_detection_window_gate_min_passes'] = 1
    if args.virtual and not args.stable:
        config['button_stable_samples'] = 1
        config['button_poll_ms'] = 0
    return config


def _resolve_state_label(state):
    return STATE_LABELS.get(str(state or 'unknown'), str(state or 'unknown'))


def _resolve_target_label(name):
    return TARGET_LABELS.get(str(name or ''), str(name or 'unknown'))


def _format_state(state):
    state_name = str(state.get('state') or 'unknown')
    ready_score = float(state.get('ready_score') or 0.0)
    target_score = float(state.get('target_score') or 0.0)
    observed = str(state.get('observed_state') or state_name)
    stable = bool(state.get('stable'))
    return (
        f"{_resolve_target_label(state.get('name'))}={_resolve_state_label(state_name)}"
        f"(raw={observed}, stable={'Y' if stable else 'N'}, ready={ready_score:.4f}, target={target_score:.4f})"
    )


def _scan_states(pyautogui, config, args):
    gate = windsurf_support.evaluate_windsurf_window_gate(pyautogui, config)
    if args.focus_windsurf:
        windsurf_support._focus_windsurf_window(config)
        time.sleep(0.2)
        gate = windsurf_support.evaluate_windsurf_window_gate(pyautogui, config)
    if not args.virtual and not bool(gate.get('allowed')):
        return gate, [], None, 'skipped_window_gate'
    states = []
    for target in windsurf_support._normalize_button_targets(config):
        if args.stable:
            state = windsurf_support.sample_stable_button_state(pyautogui, config, target)
        else:
            state = windsurf_support.detect_button_state(pyautogui, config, target)
            state = dict(state)
            state['samples'] = 1
            state['stable'] = state.get('state') != 'unknown'
            state['observed_state'] = state.get('state')
        states.append(state)
    ready_targets = windsurf_support.get_ready_button_targets(states)
    selected = ready_targets[0] if ready_targets else None
    if selected is not None:
        status = 'ready_target_detected'
    else:
        all_unknown = bool(states) and all((state.get('state') or 'unknown') == 'unknown' for state in states)
        status = 'no_template_match' if all_unknown else 'no_ready_target'
    return gate, states, selected, status


def _print_cycle(gate, states, selected, scan_status):
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    state_part = ' | '.join(_format_state(state) for state in states) if states else '本轮未执行识图'
    selected_name = _resolve_target_label(selected.get('name')) if selected else '无'
    scan_label = SCAN_STATUS_LABELS.get(scan_status, scan_status)
    gate_part = ''
    if gate:
        gate_part = (
            f" | gate={gate.get('reason', '')}"
            f" foreground={bool((gate.get('checks') or {}).get('foreground'))}"
            f" anchor={float(gate.get('anchor_score') or 0.0):.4f}"
        )
    print(f"[{timestamp}] {state_part} | 建议动作={selected_name} | 结果={scan_label}{gate_part}", flush=True)


def main():
    args = _parse_args()
    config = _prepare_config(args)
    pyautogui = windsurf_auto_switch_send.load_pyautogui(enable_click_patch=False)
    mode = 'virtual' if args.virtual else 'normal'
    detect_mode = 'stable' if args.stable else 'single'
    print(
        f"mode={mode} detect_mode={detect_mode} interval={max(args.interval, 0.1):.1f}s config={windsurf_support.WINDSURF_CONFIG_FILE}",
        flush=True,
    )
    try:
        while True:
            gate, states, selected, scan_status = _scan_states(pyautogui, config, args)
            if args.show_gate or states or scan_status == 'skipped_window_gate':
                _print_cycle(gate, states, selected, scan_status)
            else:
                _print_cycle(gate, states, selected, scan_status)
            if args.once:
                break
            time.sleep(max(args.interval, 0.1))
    except KeyboardInterrupt:
        print('stopped', flush=True)


if __name__ == '__main__':
    main()
