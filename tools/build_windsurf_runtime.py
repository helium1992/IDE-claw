from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

PROJECT_DIR = Path(__file__).resolve().parents[1]
CASCADE_DIR = PROJECT_DIR / 'cascade'
CONFIG_PATH = CASCADE_DIR / 'config' / 'windsurf_dialog_config.json'
DEFAULT_RUNTIME_DIR = PROJECT_DIR / 'windsurf_runtime'
DEFAULT_BUILD_DIR = PROJECT_DIR / 'build' / 'windsurf_runtime_build'
SERVICE_SCRIPT = CASCADE_DIR / 'windsurf_auto_service.py'
CASCADE_FILES = [
    'windsurf_auto_service.py',
    'windsurf_auto_switch_send.py',
    'windsurf_support.py',
]
HIDDEN_IMPORTS = [
    'win32api',
    'win32clipboard',
    'win32con',
    'win32gui',
    'win32ui',
    'pythoncom',
    'pywintypes',
]
COLLECT_ALL = [
    'PIL',
    'mouseinfo',
    'pyautogui',
    'pygetwindow',
    'pymsgbox',
    'pyrect',
    'pyscreeze',
    'pytweening',
]


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime-dir', default=str(DEFAULT_RUNTIME_DIR))
    parser.add_argument('--build-dir', default=str(DEFAULT_BUILD_DIR))
    parser.add_argument('--python-executable', default=sys.executable)
    parser.add_argument('--skip-pyinstaller', action='store_true')
    return parser.parse_args()


def _normalize_runtime_dir(runtime_dir: Path) -> tuple[Path, Path | None]:
    resolved = runtime_dir.resolve()
    if resolved.name.lower() == 'cascade' and resolved.parent.name.lower() == 'windsurf_runtime':
        return resolved.parent, resolved
    return resolved, None


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding='utf-8'))


def _resolve_source_path(path_value: str) -> Path:
    expanded = Path(path_value).expanduser()
    if expanded.is_absolute():
        return expanded.resolve()
    bundled = (CASCADE_DIR / expanded).resolve()
    if bundled.exists():
        return bundled
    return expanded.resolve()


def _load_reference_image(source) -> Image.Image:
    if not source:
        raise RuntimeError('缺少按钮参考图路径配置')
    crop_rect = None
    path_value = source
    if isinstance(source, dict):
        path_value = source.get('path')
        crop = source.get('crop') or {}
        if crop:
            left = max(int(crop.get('left', 0)), 0)
            top = max(int(crop.get('top', 0)), 0)
            width = max(int(crop.get('width', 0)), 1)
            height = max(int(crop.get('height', 0)), 1)
            crop_rect = (left, top, left + width, top + height)
    source_path = _resolve_source_path(str(path_value or ''))
    if not source_path.exists():
        raise FileNotFoundError(f'参考图不存在: {source_path}')
    image = Image.open(source_path)
    if crop_rect is not None:
        image = image.crop(crop_rect)
    return image.copy()


def _validate_build_python(python_executable: str) -> str:
    required_modules = ['PyInstaller', *HIDDEN_IMPORTS, *COLLECT_ALL]
    check_script = (
        'import importlib, json, sys\n'
        'modules = sys.argv[1:]\n'
        'missing = []\n'
        'for name in modules:\n'
        '    try:\n'
        '        importlib.import_module(name)\n'
        '    except Exception:\n'
        '        missing.append(name)\n'
        'print(json.dumps({"python": sys.executable, "missing": missing}, ensure_ascii=False))\n'
        'raise SystemExit(0 if not missing else 3)\n'
    )
    try:
        result = subprocess.run(
            [python_executable, '-c', check_script, *required_modules],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as e:
        raise RuntimeError(f'构建解释器不存在：{python_executable}') from e
    payload = {'python': python_executable, 'missing': []}
    stdout = (result.stdout or '').strip()
    if stdout:
        last_line = stdout.splitlines()[-1].strip()
        try:
            decoded = json.loads(last_line)
            if isinstance(decoded, dict):
                payload = decoded
        except Exception:
            pass
    resolved_python = str(payload.get('python') or python_executable)
    missing = [str(name or '').strip() for name in list(payload.get('missing') or []) if str(name or '').strip()]
    if result.returncode != 0 or missing:
        missing_label = ', '.join(missing) if missing else '未知依赖'
        stderr = (result.stderr or '').strip()
        detail = f'；stderr={stderr}' if stderr else ''
        raise RuntimeError(
            f'构建解释器缺少依赖：{missing_label}；python={resolved_python}{detail}'
        )
    return resolved_python


def _prepare_runtime_tree(runtime_dir: Path, build_dir: Path) -> tuple[Path, Path, Path]:
    runtime_dir.mkdir(parents=True, exist_ok=True)
    build_dir.mkdir(parents=True, exist_ok=True)
    runtime_cascade_dir = runtime_dir / 'cascade'
    runtime_assets_dir = runtime_cascade_dir / 'assets' / 'windsurf'
    runtime_config_dir = runtime_cascade_dir / 'config'
    if runtime_cascade_dir.exists():
        shutil.rmtree(runtime_cascade_dir)
    runtime_assets_dir.mkdir(parents=True, exist_ok=True)
    runtime_config_dir.mkdir(parents=True, exist_ok=True)
    return runtime_cascade_dir, runtime_assets_dir, runtime_config_dir


def _copy_runtime_sources(runtime_cascade_dir: Path, runtime_config_dir: Path) -> None:
    for relative_name in CASCADE_FILES:
        source_file = CASCADE_DIR / relative_name
        target_file = runtime_cascade_dir / relative_name
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file)
    shutil.copytree(CASCADE_DIR / 'config', runtime_config_dir, dirs_exist_ok=True)


def _write_runtime_config(runtime_config_dir: Path, runtime_assets_dir: Path) -> dict:
    config = _load_json(CONFIG_PATH)
    ready_image = _load_reference_image(config.get('windsurf_send_button_reference_image'))
    target_image = _load_reference_image(config.get('windsurf_target_button_reference_image'))
    run_button_source = config.get('windsurf_run_button_reference_image')
    run_button_image = _load_reference_image(run_button_source) if run_button_source else None
    ready_target_path = runtime_assets_dir / 'windsurf_send_button_reference.png'
    target_target_path = runtime_assets_dir / 'windsurf_target_button_reference.png'
    run_button_target_path = runtime_assets_dir / 'windsurf_run_button_reference.png'
    ready_image.save(ready_target_path)
    target_image.save(target_target_path)
    if run_button_image is not None:
        run_button_image.save(run_button_target_path)
    config['windsurf_send_button_reference_image'] = 'assets/windsurf/windsurf_send_button_reference.png'
    config['windsurf_target_button_reference_image'] = 'assets/windsurf/windsurf_target_button_reference.png'
    if run_button_image is not None:
        config['windsurf_run_button_reference_image'] = 'assets/windsurf/windsurf_run_button_reference.png'
    runtime_config_path = runtime_config_dir / 'windsurf_dialog_config.json'
    runtime_config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding='utf-8')
    return {
        'ready_reference': str(ready_target_path),
        'target_reference': str(target_target_path),
        'run_button_reference': str(run_button_target_path) if run_button_image is not None else '',
        'runtime_config': str(runtime_config_path),
    }


def _run_pyinstaller(runtime_dir: Path, build_dir: Path, python_executable: str) -> Path:
    pyinstaller_args = [
        python_executable,
        '-m',
        'PyInstaller',
        '--noconfirm',
        '--clean',
        '--onefile',
        '--noconsole',
        '--name',
        'windsurf_auto_service',
        '--distpath',
        str(runtime_dir),
        '--workpath',
        str(build_dir / 'pyinstaller-work'),
        '--specpath',
        str(build_dir / 'pyinstaller-spec'),
        '--paths',
        str(CASCADE_DIR),
    ]
    for hidden_import in HIDDEN_IMPORTS:
        pyinstaller_args.extend(['--hidden-import', hidden_import])
    for package_name in COLLECT_ALL:
        pyinstaller_args.extend(['--collect-all', package_name])
    pyinstaller_args.append(str(SERVICE_SCRIPT))
    subprocess.run(pyinstaller_args, check=True, cwd=str(PROJECT_DIR))
    output = runtime_dir / 'windsurf_auto_service.exe'
    if not output.exists():
        raise FileNotFoundError(f'PyInstaller 输出不存在: {output}')
    return output


def main() -> int:
    args = _parse_args()
    requested_runtime_dir = Path(args.runtime_dir)
    runtime_dir, normalized_from = _normalize_runtime_dir(requested_runtime_dir)
    build_dir = Path(args.build_dir).resolve()
    python_executable = str(args.python_executable or sys.executable)
    if not args.skip_pyinstaller:
        python_executable = _validate_build_python(python_executable)
    if normalized_from is not None:
        print(f'normalized_runtime_dir={runtime_dir}')
        print(f'normalized_from={normalized_from}')
    runtime_cascade_dir, runtime_assets_dir, runtime_config_dir = _prepare_runtime_tree(runtime_dir, build_dir)
    _copy_runtime_sources(runtime_cascade_dir, runtime_config_dir)
    runtime_files = _write_runtime_config(runtime_config_dir, runtime_assets_dir)
    executable_path = None
    if not args.skip_pyinstaller:
        executable_path = _run_pyinstaller(runtime_dir, build_dir, python_executable)
    print('windsurf runtime ready')
    print(f'runtime_dir={runtime_dir}')
    print(f'python_executable={python_executable}')
    print(f'runtime_config={runtime_files["runtime_config"]}')
    print(f'ready_reference={runtime_files["ready_reference"]}')
    print(f'target_reference={runtime_files["target_reference"]}')
    if runtime_files.get('run_button_reference'):
        print(f'run_button_reference={runtime_files["run_button_reference"]}')
    if executable_path is not None:
        print(f'executable={executable_path}')
    else:
        print('executable=skipped')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
