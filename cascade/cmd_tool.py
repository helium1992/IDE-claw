from __future__ import annotations

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / 'data' / 'cmd_tool'
RUNS_DIR = DATA_DIR / 'runs'
LOGS_DIR = DATA_DIR / 'logs'
TERMINAL_STATES = {
    'completed',
    'failed',
    'timed_out',
    'idle_timeout',
    'stopped',
    'start_failed',
}
TAIL_LIMIT = 20


def ensure_dirs() -> None:
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')


def sanitize_name(value: str) -> str:
    cleaned = re.sub(r'[^A-Za-z0-9._-]+', '_', value.strip())
    cleaned = cleaned.strip('._-')
    return cleaned or 'cmd'


def build_run_id(name: str) -> str:
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    return f'{sanitize_name(name)}_{stamp}_{uuid.uuid4().hex[:6]}'


def status_file(run_id: str) -> Path:
    return RUNS_DIR / f'{run_id}.json'


def log_file(run_id: str) -> Path:
    return LOGS_DIR / f'{run_id}.log'


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    temp_path = path.with_suffix(path.suffix + '.tmp')
    temp_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding='utf-8',
    )
    temp_path.replace(path)


def read_status(run_id: str) -> dict[str, Any]:
    path = status_file(run_id)
    if not path.exists():
        raise FileNotFoundError(f'run_id 不存在: {run_id}')
    return json.loads(path.read_text(encoding='utf-8'))


def write_status(run_id: str, data: dict[str, Any]) -> dict[str, Any]:
    data['updated_at'] = now_iso()
    atomic_write_json(status_file(run_id), data)
    return data


def update_status(run_id: str, **fields: Any) -> dict[str, Any]:
    data = read_status(run_id)
    data.update(fields)
    return write_status(run_id, data)


def append_log(run_id: str, text: str) -> None:
    with log_file(run_id).open('a', encoding='utf-8', errors='replace') as handle:
        handle.write(text)


def build_base_status(
    run_id: str,
    name: str,
    command: str,
    cwd: str,
    shell: str,
    timeout_sec: int,
    idle_timeout_sec: int,
) -> dict[str, Any]:
    timestamp = now_iso()
    return {
        'run_id': run_id,
        'name': name,
        'command': command,
        'cwd': cwd,
        'shell': shell,
        'timeout_sec': timeout_sec,
        'idle_timeout_sec': idle_timeout_sec,
        'state': 'queued',
        'created_at': timestamp,
        'updated_at': timestamp,
        'started_at': None,
        'finished_at': None,
        'heartbeat_at': None,
        'last_output_at': None,
        'pid': None,
        'runner_pid': None,
        'return_code': None,
        'error': None,
        'stop_requested': False,
        'stop_requested_at': None,
        'timed_out': False,
        'idle_timed_out': False,
        'output_lines': 0,
        'tail': [],
        'log_path': str(log_file(run_id)),
        'status_path': str(status_file(run_id)),
    }


def build_shell_command(shell: str, command: str) -> list[str]:
    shell = shell.lower()
    if os.name == 'nt':
        if shell == 'cmd':
            return ['cmd.exe', '/C', command]
        return [
            'powershell.exe',
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            command,
        ]
    if shell == 'bash':
        return ['bash', '-lc', command]
    return ['/bin/sh', '-lc', command]


def kill_process_tree(pid: int) -> None:
    if pid <= 0:
        return
    if os.name == 'nt':
        try:
            subprocess.run(
                ['taskkill', '/PID', str(pid), '/T', '/F'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=5,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            )
        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass
        return
    try:
        import signal
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except Exception:
        pass


def terminate_process(process: subprocess.Popen[Any]) -> int | None:
    try:
        process.kill()
    except Exception:
        pass
    try:
        return process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        kill_process_tree(process.pid)
    except Exception:
        kill_process_tree(process.pid)
    try:
        return process.wait(timeout=3)
    except Exception:
        return process.poll()


def format_status(data: dict[str, Any], tail_lines: int = 10) -> str:
    lines = [
        f"run_id: {data.get('run_id', '')}",
        f"name: {data.get('name', '')}",
        f"state: {data.get('state', '')}",
        f"pid: {data.get('pid', '')}",
        f"runner_pid: {data.get('runner_pid', '')}",
        f"return_code: {data.get('return_code', '')}",
        f"cwd: {data.get('cwd', '')}",
        f"shell: {data.get('shell', '')}",
        f"timeout_sec: {data.get('timeout_sec', '')}",
        f"idle_timeout_sec: {data.get('idle_timeout_sec', '')}",
        f"created_at: {data.get('created_at', '')}",
        f"started_at: {data.get('started_at', '')}",
        f"finished_at: {data.get('finished_at', '')}",
        f"last_output_at: {data.get('last_output_at', '')}",
        f"command: {data.get('command', '')}",
        f"log_path: {data.get('log_path', '')}",
    ]
    error = data.get('error')
    if error:
        lines.append(f'error: {error}')
    tail = data.get('tail') or []
    if tail_lines > 0 and tail:
        lines.append('tail:')
        for line in tail[-tail_lines:]:
            lines.append(f'  {line}')
    return '\n'.join(lines)


def detached_creationflags() -> int:
    if os.name != 'nt':
        return 0
    flags = 0
    for name in ('CREATE_NEW_PROCESS_GROUP', 'DETACHED_PROCESS', 'CREATE_NO_WINDOW'):
        flags |= getattr(subprocess, name, 0)
    return flags


def start_worker_process(args: argparse.Namespace, run_id: str, cwd: str) -> int:
    worker_command = [
        sys.executable,
        str(Path(__file__).resolve()),
        '_worker',
        '--run-id',
        run_id,
        '--name',
        args.name,
        '--cwd',
        cwd,
        '--shell',
        args.shell,
        '--timeout',
        str(args.timeout),
        '--idle-timeout',
        str(args.idle_timeout),
        '--command',
        args.command,
    ]
    process = subprocess.Popen(
        worker_command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        creationflags=detached_creationflags(),
    )
    update_status(run_id, runner_pid=process.pid)
    return 0


def enqueue_run(args: argparse.Namespace) -> int:
    ensure_dirs()
    cwd = str(Path(args.cwd).resolve()) if args.cwd else str(BASE_DIR)
    run_id = build_run_id(args.name)
    base_status = build_base_status(
        run_id=run_id,
        name=args.name,
        command=args.command,
        cwd=cwd,
        shell=args.shell,
        timeout_sec=args.timeout,
        idle_timeout_sec=args.idle_timeout,
    )
    write_status(run_id, base_status)
    append_log(run_id, f'[{now_iso()}] queued\n')
    start_worker_process(args, run_id, cwd)
    print(
        json.dumps(
            {
                'run_id': run_id,
                'status_path': str(status_file(run_id)),
                'log_path': str(log_file(run_id)),
            },
            ensure_ascii=False,
        )
    )
    return 0


def run_and_wait(args: argparse.Namespace) -> int:
    ensure_dirs()
    cwd = str(Path(args.cwd).resolve()) if args.cwd else str(BASE_DIR)
    run_id = build_run_id(args.name)
    base_status = build_base_status(
        run_id=run_id,
        name=args.name,
        command=args.command,
        cwd=cwd,
        shell=args.shell,
        timeout_sec=args.timeout,
        idle_timeout_sec=args.idle_timeout,
    )
    write_status(run_id, base_status)
    exit_code = worker_main(
        run_id=run_id,
        name=args.name,
        cwd=cwd,
        shell=args.shell,
        command=args.command,
        timeout=args.timeout,
        idle_timeout=args.idle_timeout,
    )
    final_status = read_status(run_id)
    if args.json:
        print(json.dumps(final_status, ensure_ascii=False, indent=2))
    else:
        print(format_status(final_status, tail_lines=args.tail))
    return exit_code


def cmd_status(args: argparse.Namespace) -> int:
    data = read_status(args.run_id)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(format_status(data, tail_lines=args.tail))
    return 0


def cmd_wait(args: argparse.Namespace) -> int:
    deadline = None if args.timeout <= 0 else time.monotonic() + args.timeout
    while True:
        data = read_status(args.run_id)
        if data.get('state') in TERMINAL_STATES:
            if args.json:
                print(json.dumps(data, ensure_ascii=False, indent=2))
            else:
                print(format_status(data, tail_lines=args.tail))
            return 0 if data.get('state') == 'completed' else 1
        if deadline is not None and time.monotonic() >= deadline:
            print(f'wait 超时: {args.run_id}')
            return 2
        time.sleep(args.poll)


def cmd_stop(args: argparse.Namespace) -> int:
    data = read_status(args.run_id)
    if data.get('state') in TERMINAL_STATES:
        if args.json:
            print(json.dumps(data, ensure_ascii=False, indent=2))
        else:
            print(format_status(data, tail_lines=args.tail))
        return 0
    data['stop_requested'] = True
    data['stop_requested_at'] = now_iso()
    write_status(args.run_id, data)
    pid = int(data.get('pid') or 0)
    if pid > 0:
        kill_process_tree(pid)
    else:
        data['state'] = 'stopped'
        data['finished_at'] = now_iso()
        write_status(args.run_id, data)
    refreshed = read_status(args.run_id)
    if args.json:
        print(json.dumps(refreshed, ensure_ascii=False, indent=2))
    else:
        print(format_status(refreshed, tail_lines=args.tail))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    ensure_dirs()
    files = sorted(RUNS_DIR.glob('*.json'), key=lambda item: item.stat().st_mtime, reverse=True)
    rows: list[dict[str, Any]] = []
    for file_path in files[: args.limit]:
        try:
            rows.append(json.loads(file_path.read_text(encoding='utf-8')))
        except Exception:
            continue
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    for row in rows:
        print(
            f"{row.get('run_id', '')} | {row.get('state', '')} | pid={row.get('pid', '')} | {row.get('name', '')} | {row.get('command', '')}"
        )
    return 0


def worker_main(
    run_id: str,
    name: str,
    cwd: str,
    shell: str,
    command: str,
    timeout: int,
    idle_timeout: int,
) -> int:
    ensure_dirs()
    append_log(run_id, f'[{now_iso()}] starting\n')
    run_path = Path(cwd)
    if not run_path.exists():
        update_status(
            run_id,
            state='start_failed',
            finished_at=now_iso(),
            error=f'cwd 不存在: {cwd}',
            runner_pid=os.getpid(),
        )
        append_log(run_id, f'[{now_iso()}] start_failed: cwd 不存在: {cwd}\n')
        return 1
    try:
        process = subprocess.Popen(
            build_shell_command(shell, command),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace',
            bufsize=1,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0) if os.name == 'nt' else 0,
        )
    except Exception as exc:
        update_status(
            run_id,
            state='start_failed',
            finished_at=now_iso(),
            error=str(exc),
            runner_pid=os.getpid(),
        )
        append_log(run_id, f'[{now_iso()}] start_failed: {exc}\n')
        return 1

    started_at = now_iso()
    update_status(
        run_id,
        state='running',
        started_at=started_at,
        heartbeat_at=started_at,
        last_output_at=started_at,
        pid=process.pid,
        runner_pid=os.getpid(),
        error=None,
    )
    append_log(run_id, f'[{started_at}] running pid={process.pid}\n')

    output_queue: queue.Queue[str | None] = queue.Queue()

    def reader() -> None:
        try:
            assert process.stdout is not None
            for line in iter(process.stdout.readline, ''):
                if line == '':
                    break
                output_queue.put(line)
        finally:
            output_queue.put(None)

    reader_thread = threading.Thread(target=reader, daemon=True)
    reader_thread.start()

    start_monotonic = time.monotonic()
    last_output_monotonic = start_monotonic
    last_heartbeat_monotonic = start_monotonic
    output_lines = 0
    tail: list[str] = []
    reached_eof = False

    while True:
        drained = False
        while True:
            try:
                item = output_queue.get_nowait()
            except queue.Empty:
                break
            drained = True
            if item is None:
                reached_eof = True
                continue
            append_log(run_id, item)
            output_lines += 1
            last_output_monotonic = time.monotonic()
            clean = item.rstrip('\r\n')
            if clean:
                tail.append(clean)
                tail = tail[-TAIL_LIMIT:]

        current_status = read_status(run_id)
        if current_status.get('stop_requested'):
            terminate_process(process)

        current_monotonic = time.monotonic()
        if timeout > 0 and current_monotonic - start_monotonic >= timeout:
            return_code = terminate_process(process)
            finished_at = now_iso()
            update_status(
                run_id,
                state='timed_out',
                finished_at=finished_at,
                timed_out=True,
                error=f'超过超时限制: {timeout}s',
                return_code=return_code,
                output_lines=output_lines,
                tail=tail,
            )
            append_log(run_id, f'[{finished_at}] timed_out after {timeout}s\n')
            return 1

        if idle_timeout > 0 and current_monotonic - last_output_monotonic >= idle_timeout:
            return_code = terminate_process(process)
            finished_at = now_iso()
            update_status(
                run_id,
                state='idle_timeout',
                finished_at=finished_at,
                idle_timed_out=True,
                error=f'超过静默超时限制: {idle_timeout}s',
                return_code=return_code,
                output_lines=output_lines,
                tail=tail,
            )
            append_log(run_id, f'[{finished_at}] idle_timeout after {idle_timeout}s\n')
            return 1

        return_code = process.poll()
        if return_code is not None and reached_eof:
            final_status = read_status(run_id)
            final_state = 'completed'
            if final_status.get('stop_requested'):
                final_state = 'stopped'
            elif return_code != 0:
                final_state = 'failed'
            finished_at = now_iso()
            update_status(
                run_id,
                state=final_state,
                finished_at=finished_at,
                return_code=return_code,
                output_lines=output_lines,
                tail=tail,
            )
            append_log(run_id, f'[{finished_at}] finished state={final_state} return_code={return_code}\n')
            return 0 if final_state == 'completed' else (130 if final_state == 'stopped' else return_code or 1)

        if current_monotonic - last_heartbeat_monotonic >= 1.0:
            update_status(run_id, heartbeat_at=now_iso(), output_lines=output_lines, tail=tail)
            last_heartbeat_monotonic = current_monotonic

        time.sleep(0.2)


def cmd_worker(args: argparse.Namespace) -> int:
    return worker_main(
        run_id=args.run_id,
        name=args.name,
        cwd=args.cwd,
        shell=args.shell,
        command=args.command,
        timeout=args.timeout,
        idle_timeout=args.idle_timeout,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog='cmd_tool')
    subparsers = parser.add_subparsers(dest='subcommand', required=True)

    def add_common_run_options(target: argparse.ArgumentParser) -> None:
        target.add_argument('--name', default='cmd_run')
        target.add_argument('--cwd', default=str(BASE_DIR))
        target.add_argument('--shell', choices=['powershell', 'cmd', 'bash'], default='powershell')
        target.add_argument('--timeout', type=int, default=0)
        target.add_argument('--idle-timeout', type=int, default=0)
        target.add_argument('--command', required=True)

    start_parser = subparsers.add_parser('start')
    add_common_run_options(start_parser)
    start_parser.set_defaults(func=enqueue_run)

    run_parser = subparsers.add_parser('run')
    add_common_run_options(run_parser)
    run_parser.add_argument('--json', action='store_true')
    run_parser.add_argument('--tail', type=int, default=10)
    run_parser.set_defaults(func=run_and_wait)

    status_parser = subparsers.add_parser('status')
    status_parser.add_argument('--run-id', required=True)
    status_parser.add_argument('--json', action='store_true')
    status_parser.add_argument('--tail', type=int, default=10)
    status_parser.set_defaults(func=cmd_status)

    wait_parser = subparsers.add_parser('wait')
    wait_parser.add_argument('--run-id', required=True)
    wait_parser.add_argument('--timeout', type=int, default=0)
    wait_parser.add_argument('--poll', type=float, default=1.0)
    wait_parser.add_argument('--json', action='store_true')
    wait_parser.add_argument('--tail', type=int, default=10)
    wait_parser.set_defaults(func=cmd_wait)

    stop_parser = subparsers.add_parser('stop')
    stop_parser.add_argument('--run-id', required=True)
    stop_parser.add_argument('--json', action='store_true')
    stop_parser.add_argument('--tail', type=int, default=10)
    stop_parser.set_defaults(func=cmd_stop)

    list_parser = subparsers.add_parser('list')
    list_parser.add_argument('--limit', type=int, default=10)
    list_parser.add_argument('--json', action='store_true')
    list_parser.set_defaults(func=cmd_list)

    worker_parser = subparsers.add_parser('_worker')
    worker_parser.add_argument('--run-id', required=True)
    worker_parser.add_argument('--name', required=True)
    worker_parser.add_argument('--cwd', required=True)
    worker_parser.add_argument('--shell', required=True)
    worker_parser.add_argument('--timeout', type=int, default=0)
    worker_parser.add_argument('--idle-timeout', type=int, default=0)
    worker_parser.add_argument('--command', required=True)
    worker_parser.set_defaults(func=cmd_worker)

    return parser


def main() -> int:
    ensure_dirs()
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == '__main__':
    raise SystemExit(main())
