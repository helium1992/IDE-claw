"""Windsurf 账号切换脚本 — 通过直接写入配置文件切换账号，不点击按钮

支持两种模式:
  1. 服务器模式: 从 faceflow 服务器 claim 账号 + auth token
  2. 本地模式: 从本地 windsurf-login-accounts.json 选择下一个账号

冷却时间: 20 分钟内最多切换 1 次
"""
import json
import os
import time
import argparse

from windsurf_account_store import (
    block_account_for_auto_switch,
    clear_account_auto_switch_block,
    find_account,
    get_account_token,
    get_account_quota_state,
    is_account_in_switch_pool,
    is_account_auto_switch_blocked,
    load_accounts,
    load_state,
    mark_account_bootstrap_result,
    mark_account_quota_depleted,
    mark_account_quota_refresh,
    merge_imported_accounts,
    purge_expired_accounts,
    read_current_auth_token,
    save_accounts,
    save_state,
    update_account,
    write_auth_token_files,
)
from windsurf_quota_refresh import (
    derive_quota_state,
    refresh_account_quota,
)
from windsurf_token_bootstrap import bootstrap_one_account

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), 'data')

WINDSURF_GLOBAL_STORAGE = os.path.join(
    os.environ.get('APPDATA', ''), 'Windsurf', 'User', 'globalStorage'
)

LOCAL_FILES = {
    'accounts': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-login-accounts.json'),
    'state': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-login-state.json'),
    'auth': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-auth.json'),
    'cascade_auth': os.path.join(WINDSURF_GLOBAL_STORAGE, 'cascade-auth.json'),
    'settings': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-login-settings.json'),
    'token_cache': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-token-cache.json'),
}

COOLDOWN_FILE = os.path.join(DATA_DIR, 'windsurf_switch_cooldown.json')
COOLDOWN_MINUTES = 20


def _read_json(filepath):
    if not os.path.exists(filepath):
        return None
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return None


def _write_json(filepath, data):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def _clean_text(value):
    if value is None:
        return ''
    return str(value).strip()


def _safe_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _account_total_credits(account):
    credits = (account or {}).get('credits', {}) or {}
    return max(_safe_int(credits.get('daily', 0), 0), 0) + max(_safe_int(credits.get('weekly', 0), 0), 0)


def _account_has_usable_credits(account, threshold):
    credits = (account or {}).get('credits', {}) or {}
    if not is_account_in_switch_pool(account):
        return False
    if credits.get('expired', False):
        return False
    weekly = _safe_int(credits.get('weekly', -1), -1)
    daily = _safe_int(credits.get('daily', -1), -1)
    if weekly == 0:
        return False
    if daily >= 0 and daily <= threshold:
        return False
    return True


def _server_account_to_local(account):
    account = account if isinstance(account, dict) else {}
    return {
        'email': _clean_text(account.get('email')),
        'password': _clean_text(account.get('password')),
        'auth_token': _clean_text(account.get('auth_token')),
        'token': _clean_text(account.get('auth_token')),
        'credits': {
            'daily': _safe_int(account.get('credits_daily', -1), -1),
            'weekly': _safe_int(account.get('credits_weekly', -1), -1),
            'expired': bool(account.get('is_expired', False)),
        },
        'quota_state': derive_quota_state({
            'daily': _safe_int(account.get('credits_daily', -1), -1),
            'weekly': _safe_int(account.get('credits_weekly', -1), -1),
            'expired': bool(account.get('is_expired', False)),
        }),
    }


def _load_accounts_from_input_file(filepath):
    filepath = _clean_text(filepath)
    if not filepath:
        raise ValueError('缺少 input-file')
    payload = _read_json(filepath)
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get('accounts'), list):
        return payload.get('accounts')
    raise ValueError('input-file 内容必须是账号数组或包含 accounts 数组的对象')


class WindsurfAccountSwitcher:
    """通过 faceflow 服务器或本地账号列表切换 Windsurf 账号"""

    def __init__(self, server_url=None, token=None, machine_id=None,
                 cooldown_minutes=COOLDOWN_MINUTES, credit_threshold=1):
        self.server_url = server_url.rstrip('/') if server_url else None
        self.token = token
        self.machine_id = machine_id or os.environ.get('COMPUTERNAME', 'unknown')
        self.cooldown_minutes = cooldown_minutes
        self.credit_threshold = credit_threshold

    # ── 本地文件操作 ──

    def get_current_account(self):
        state = load_state()
        return state.get('currentEmail', '') if state else ''

    def get_current_index(self):
        state = load_state()
        return _safe_int(state.get('currentIndex', -1)) if state else -1

    def get_accounts(self):
        purge_expired_accounts()
        return load_accounts()

    def get_current_auth_token(self):
        return read_current_auth_token()

    def _sync_current_account_token_from_auth_files(self):
        current_email = self.get_current_account()
        current_token = self.get_current_auth_token()
        if current_email and current_token:
            update_account(current_email, {
                'auth_token': current_token,
                'token': current_token,
            })

    def _merge_account_into_local_pool(self, account):
        local_payload = _server_account_to_local(account)
        if not local_payload.get('email'):
            return None, -1
        merge_result = merge_imported_accounts([local_payload])
        merged_accounts = merge_result.get('accounts') or []
        return find_account(local_payload['email'], merged_accounts)

    def _bootstrap_account(self, account, visible_browser=False):
        account = account if isinstance(account, dict) else {}
        email = _clean_text(account.get('email'))
        password = _clean_text(account.get('password'))
        result = bootstrap_one_account(
            email,
            password,
            visible_browser=visible_browser,
        )
        mark_account_bootstrap_result(email, result)
        current_email = self.get_current_account()
        if result.get('status') == 'success' and current_email.lower() == email.lower():
            self.apply_auth_token(result.get('auth_token', ''))
            clear_account_auto_switch_block(email)
        return result

    def block_account_for_auto_switch(self, email, duration_seconds, reason=''):
        return block_account_for_auto_switch(email, duration_seconds, reason)

    def mark_account_quota_depleted(self, email, reason='', source='auto_detect'):
        return mark_account_quota_depleted(email, reason=reason, source=source)

    def refresh_account_credits(self, email, force=False):
        account, _ = find_account(email, self.get_accounts())
        if not account:
            return {
                'status': 'not_found',
                'email': _clean_text(email),
                'message': f'本地账号池中不存在 {email}',
            }
        current_state = get_account_quota_state(account)
        if current_state == 'expired' and not force:
            return {
                'status': 'skipped',
                'email': account.get('email', ''),
                'message': '账号已过期，已永久移出切号池，等待 7 天后清理',
                'reason': 'expired',
                'quota_state': current_state,
            }
        password = _clean_text(account.get('password'))
        if not password:
            result = {
                'status': 'error',
                'email': account.get('email', ''),
                'message': '缺少密码，无法刷新额度',
                'error_code': 'missing_password',
                'credits': account.get('credits', {}),
            }
            mark_account_quota_refresh(account.get('email', ''), result)
            return result
        result = refresh_account_quota(account.get('email', ''), password)
        stored = mark_account_quota_refresh(account.get('email', ''), result)
        if stored is not None:
            result['stored_account'] = stored
            result['quota_state'] = stored.get('quota_state', result.get('quota_state', 'unknown'))
            result['credits'] = stored.get('credits', result.get('credits', {}))
        return result

    def refresh_credits(self, emails=None, force=False):
        selected_emails = [
            _clean_text(email)
            for email in (emails or [])
            if _clean_text(email)
        ]
        accounts = self.get_accounts()
        pool = []
        if selected_emails:
            for email in selected_emails:
                account, _ = find_account(email, accounts)
                if account is None:
                    pool.append({'email': email, 'missing': True})
                else:
                    pool.append(account)
        else:
            pool = list(accounts)

        results = []
        success = []
        failed = []
        skipped = []

        for item in pool:
            if isinstance(item, dict) and item.get('missing'):
                skipped.append({'email': item.get('email', ''), 'reason': 'not_found'})
                continue
            result = self.refresh_account_credits(item.get('email', ''), force=force)
            results.append(result)
            status = result.get('status')
            if status == 'success':
                success.append(result.get('email', ''))
            elif status == 'skipped':
                skipped.append({
                    'email': result.get('email', ''),
                    'reason': result.get('reason') or result.get('message', ''),
                })
            else:
                failed.append({
                    'email': result.get('email', ''),
                    'reason': result.get('error_code') or result.get('message', ''),
                    'message': result.get('message', ''),
                })

        if success and failed:
            status = 'partial_success'
        elif failed:
            status = 'error'
        elif success or skipped:
            status = 'success'
        else:
            status = 'no_action'

        purge_result = purge_expired_accounts()

        return {
            'status': status,
            'processed': len(results),
            'success_count': len(success),
            'failed_count': len(failed),
            'skipped_count': len(skipped),
            'success': success,
            'failed': failed,
            'skipped': skipped,
            'purged_expired_count': purge_result.get('removed_count', 0),
            'results': results,
        }

    # ── 冷却时间 ──

    def check_cooldown(self):
        """返回 (可切换, 剩余秒数)"""
        data = _read_json(COOLDOWN_FILE)
        if not data:
            return True, 0
        last_switch = float(data.get('last_switch_at', 0))
        elapsed = time.time() - last_switch
        cooldown_seconds = self.cooldown_minutes * 60
        if elapsed >= cooldown_seconds:
            return True, 0
        remaining = int(cooldown_seconds - elapsed)
        return False, remaining

    def record_switch(self, email=''):
        _write_json(COOLDOWN_FILE, {
            'last_switch_at': time.time(),
            'last_switch_time': time.strftime('%Y-%m-%d %H:%M:%S'),
            'switched_to': email,
        })

    # ── 本地账号选择 ──

    def pick_next_account(self, require_token=True, avoid_emails=None):
        """按顺序选择下一个有 credits 的账号（round-robin），返回 (account_dict, index) 或 (None, -1)"""
        accounts = self.get_accounts()
        n = len(accounts)
        if n == 0:
            return None, -1
        current_index = max(self.get_current_index(), 0)
        current_email = self.get_current_account().lower()
        avoid = {
            _clean_text(email).lower()
            for email in (avoid_emails or [])
            if _clean_text(email)
        }
        # 从 current_index+1 开始顺序扫描一圈
        for offset in range(1, n + 1):
            i = (current_index + offset) % n
            acc = accounts[i]
            email = _clean_text(acc.get('email'))
            if not email or email.lower() == current_email:
                continue
            if email.lower() in avoid:
                continue
            if is_account_auto_switch_blocked(acc):
                continue
            if not _account_has_usable_credits(acc, self.credit_threshold):
                continue
            has_token = bool(get_account_token(acc))
            if require_token and not has_token:
                continue
            return acc, i
        return None, -1

    # ── 写入本地配置 ──

    def apply_account_locally(self, email, index):
        """更新 state 文件和 accounts 的 loginCount"""
        now_ms = int(time.time() * 1000)
        save_state({
            'currentEmail': email,
            'currentIndex': index,
            'timestamp': now_ms,
        })
        accounts = self.get_accounts()
        for position, acc in enumerate(accounts):
            if _clean_text(acc.get('email')).lower() == _clean_text(email).lower():
                next_account = dict(acc)
                next_account['loginCount'] = _safe_int(acc.get('loginCount', 0)) + 1
                accounts[position] = next_account
                break
        save_accounts(accounts)
        _write_json(LOCAL_FILES['token_cache'], {})

    def apply_auth_token(self, auth_token):
        """写入 auth token 到 windsurf-auth.json 和 cascade-auth.json"""
        write_auth_token_files(auth_token)

    def fetch_ott(self, email, password):
        """从插件同款 API 获取一次性令牌 (OTT)，用于注入 Windsurf 运行时"""
        email = _clean_text(email)
        password = _clean_text(password)
        if not email or not password:
            return None
        try:
            from windsurf_quota_refresh import (
                get_firebase_id_token,
                build_protobuf_request,
                parse_auth_token_from_response,
            )
            import requests
        except ImportError:
            return None
        token_result = get_firebase_id_token(email, password, allow_cache=True)
        if token_result.get('status') != 'success':
            return None
        id_token = token_result.get('id_token', '')
        if not id_token:
            return None
        request_data = build_protobuf_request(id_token)
        if not request_data:
            return None
        try:
            resp = requests.post(
                'https://your-server.example.com/api/windsurf/auth-token',
                data=request_data,
                headers={
                    'Content-Type': 'application/proto',
                    'connect-protocol-version': '1',
                    'Origin': 'https://windsurf.com',
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
                timeout=20,
            )
            if resp.status_code != 200:
                return None
            ott = _clean_text(parse_auth_token_from_response(resp.content))
            if ott and 30 <= len(ott) <= 60:
                return ott
        except Exception:
            pass
        return None

    def inject_via_trigger(self, email, password):
        """将 email+password 写入触发文件，由 ideclaw-session 扩展完成完整登录流程"""
        if not email or not password:
            return False
        trigger_path = os.path.join(WINDSURF_GLOBAL_STORAGE, 'ideclaw-session-trigger.json')
        _write_json(trigger_path, {
            'email': email,
            'password': password,
            'timestamp': int(time.time() * 1000),
            'processed': False,
        })
        return True

    def inject_via_plugin_trigger(self, email, timeout=50):
        """写触发文件让 windsurf-login-helper 插件驱动完整切号流程

        插件收到触发后会自行: Firebase 登录 -> 换 authToken -> 命令注入
        -> 写 auth 文件 -> 更新 UI/状态栏/内部状态

        返回 dict: {'success': bool, 'credits': ..., 'error': ...}
        """
        email = _clean_text(email)
        if not email:
            return {'success': False, 'error': 'missing_email'}
        trigger_path = os.path.join(
            WINDSURF_GLOBAL_STORAGE, 'windsurf-login-switch-trigger.json'
        )
        trigger_data = {
            'email': email,
            'timestamp': int(time.time() * 1000),
            'processed': False,
            'source': 'ide_claw',
        }
        _write_json(trigger_path, trigger_data)
        # 等待插件处理
        start = time.time()
        while time.time() - start < timeout:
            time.sleep(0.5)
            try:
                raw = _read_json(trigger_path)
                if raw and raw.get('processed'):
                    return {
                        'success': bool(raw.get('success')),
                        'credits': raw.get('credits'),
                        'error': raw.get('error'),
                        'processed_at': raw.get('processed_at'),
                    }
            except Exception:
                pass
        return {'success': False, 'error': 'timeout'}

    # ── faceflow 服务器 API ──

    def _api_headers(self):
        return {
            'Authorization': f'Bearer {self.token}',
            'Content-Type': 'application/json',
        }

    def claim_from_server(self):
        """从 faceflow 领取一个可用账号，返回 dict 或 None"""
        if not self.server_url or not self.token:
            return None
        try:
            import requests
            resp = requests.post(
                f'{self.server_url}/api/windsurf/claim',
                headers=self._api_headers(),
                json={
                    'machine_id': self.machine_id,
                    'prefer_daily': True,
                },
                timeout=10,
            )
            if resp.status_code == 200:
                data = resp.json()
                if data.get('email'):
                    return data
        except Exception:
            pass
        return None

    def release_to_server(self, email, credits_daily=0, credits_weekly=0):
        """释放账号回服务器"""
        if not self.server_url or not self.token:
            return
        try:
            import requests
            requests.post(
                f'{self.server_url}/api/windsurf/release',
                headers=self._api_headers(),
                json={
                    'machine_id': self.machine_id,
                    'email': email,
                    'credits_daily': credits_daily,
                    'credits_weekly': credits_weekly,
                },
                timeout=10,
            )
        except Exception:
            pass

    def upload_accounts_to_server(self):
        """将本地全部账号上传到 faceflow 服务器"""
        if not self.server_url or not self.token:
            return {'status': 'error', 'message': '未配置服务器'}
        self._sync_current_account_token_from_auth_files()
        accounts = self.get_accounts()
        if not accounts:
            return {'status': 'error', 'message': '本地账号为空'}
        current_email = self.get_current_account()
        current_token = self.get_current_auth_token()
        upload = []
        for acc in accounts:
            email = _clean_text(acc.get('email'))
            if not email:
                continue
            auth_token = get_account_token(acc)
            if email.lower() == current_email.lower() and current_token:
                auth_token = current_token
            entry = {
                'email': email,
                'password': acc.get('password', ''),
                'credits_daily': acc.get('credits', {}).get('daily', 0),
                'credits_weekly': acc.get('credits', {}).get('weekly', 0),
                'is_expired': acc.get('credits', {}).get('expired', False),
            }
            if auth_token:
                entry['auth_token'] = auth_token
            upload.append(entry)
        try:
            import requests
            resp = requests.post(
                f'{self.server_url}/api/windsurf/accounts',
                headers=self._api_headers(),
                json={'accounts': upload},
                timeout=30,
            )
            if resp.status_code == 200:
                data = resp.json()
                return {
                    'status': 'success',
                    'count': len(upload),
                    'imported': data.get('imported', len(upload)),
                    'total': data.get('total', len(upload)),
                }
            return {'status': 'error', 'message': f'HTTP {resp.status_code}: {resp.text[:200]}'}
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    def get_server_status(self):
        """获取服务器账号池状态"""
        if not self.server_url or not self.token:
            return None
        try:
            import requests
            resp = requests.get(
                f'{self.server_url}/api/windsurf/status',
                headers=self._api_headers(),
                timeout=10,
            )
            if resp.status_code == 200:
                return resp.json()
        except Exception:
            pass
        return None

    def import_accounts(self, accounts):
        return merge_imported_accounts(accounts)

    def bootstrap_missing_tokens(self, emails=None, visible_browser=False):
        selected_emails = {
            _clean_text(email).lower()
            for email in (emails or [])
            if _clean_text(email)
        }
        accounts = self.get_accounts()
        results = []
        skipped = []
        seen = set()

        for account in accounts:
            email = _clean_text(account.get('email'))
            if not email:
                continue
            email_key = email.lower()
            if selected_emails and email_key not in selected_emails:
                continue
            seen.add(email_key)
            if get_account_token(account):
                skipped.append({'email': email, 'reason': 'has_token'})
                continue
            if not _clean_text(account.get('password')):
                skipped.append({'email': email, 'reason': 'missing_password'})
                mark_account_bootstrap_result(email, {
                    'status': 'error',
                    'message': '缺少密码，无法初始化 token',
                    'error_code': 'missing_password',
                })
                continue
            results.append(self._bootstrap_account(account, visible_browser=visible_browser))

        for email in selected_emails:
            if email not in seen:
                skipped.append({'email': email, 'reason': 'not_found'})

        success = [
            item.get('email', '')
            for item in results
            if item.get('status') == 'success'
        ]
        failed = [
            {
                'email': item.get('email', ''),
                'reason': item.get('error_code') or item.get('message', ''),
                'message': item.get('message', ''),
            }
            for item in results
            if item.get('status') != 'success'
        ]

        if success and failed:
            status = 'partial_success'
        elif failed:
            status = 'error'
        elif results or skipped:
            status = 'success'
        else:
            status = 'no_action'

        return {
            'status': status,
            'processed': len(results),
            'success_count': len(success),
            'failed_count': len(failed),
            'skipped_count': len(skipped),
            'success': success,
            'failed': failed,
            'skipped': skipped,
            'results': results,
        }

    def sync_bootstrap_results_to_server(self):
        if not self.server_url or not self.token:
            return {'status': 'skipped', 'message': '未配置服务器'}
        return self.upload_accounts_to_server()

    def import_and_bootstrap(self, accounts, visible_browser=False):
        import_result = self.import_accounts(accounts)
        requested_emails = [
            _clean_text(item.get('email'))
            for item in (accounts or [])
            if isinstance(item, dict) and _clean_text(item.get('email'))
        ]
        upload_before = self.sync_bootstrap_results_to_server()
        bootstrap_result = self.bootstrap_missing_tokens(
            emails=requested_emails or None,
            visible_browser=visible_browser,
        )
        refresh_result = self.refresh_credits(emails=requested_emails or None)
        upload_after = self.sync_bootstrap_results_to_server()

        if bootstrap_result.get('status') == 'error':
            status = 'error'
        elif bootstrap_result.get('status') == 'partial_success':
            status = 'partial_success'
        elif refresh_result.get('status') == 'error':
            status = 'partial_success' if bootstrap_result.get('success_count', 0) > 0 else 'error'
        elif upload_before.get('status') == 'error' or upload_after.get('status') == 'error':
            status = 'partial_success' if bootstrap_result.get('success_count', 0) > 0 else 'error'
        else:
            status = 'success'

        return {
            'status': status,
            'imported': import_result.get('imported', 0),
            'created': import_result.get('created', 0),
            'updated': import_result.get('updated', 0),
            'skipped': import_result.get('skipped', 0),
            'total_accounts': import_result.get('total_accounts', 0),
            'upload_before': upload_before,
            'bootstrap': bootstrap_result,
            'refresh': refresh_result,
            'upload_after': upload_after,
            'bootstrapped_success': bootstrap_result.get('success', []),
            'bootstrapped_failed': bootstrap_result.get('failed', []),
            'current_email': self.get_current_account(),
        }

    def switch_to_specific_account(self, email, allow_bootstrap=False, visible_browser=False):
        ready, remaining = self.check_cooldown()
        if not ready:
            return {
                'status': 'cooldown',
                'remaining_seconds': remaining,
                'message': f'冷却中，还需等待 {remaining // 60}分{remaining % 60}秒',
            }

        accounts = self.get_accounts()
        account, index = find_account(email, accounts)
        if not account:
            return {
                'status': 'not_found',
                'email': _clean_text(email),
                'message': f'本地账号池中不存在 {email}',
            }
        if not is_account_in_switch_pool(account):
            return {
                'status': 'no_account',
                'email': _clean_text(email),
                'message': f'{email} 当前状态为 {get_account_quota_state(account)}，不在切号池内',
            }
        if not _account_has_usable_credits(account, self.credit_threshold):
            return {
                'status': 'no_account',
                'email': _clean_text(email),
                'message': f'{email} 当前没有可用 credits',
            }

        auth_token = get_account_token(account)
        bootstrap_result = None
        if not auth_token and allow_bootstrap:
            bootstrap_result = self._bootstrap_account(account, visible_browser=visible_browser)
            if bootstrap_result.get('status') == 'success':
                account, index = find_account(email, self.get_accounts())
                auth_token = get_account_token(account)

        if not auth_token:
            return {
                'status': 'missing_token',
                'email': _clean_text(email),
                'message': f'{email} 缺少 auth token',
                'bootstrap_result': bootstrap_result,
            }

        old_email = self.get_current_account()

        # 优先通过插件触发文件驱动完整切号流程
        plugin_result = self.inject_via_plugin_trigger(account['email'])
        if plugin_result.get('success'):
            clear_account_auto_switch_block(account['email'])
            self.record_switch(account['email'])
            if plugin_result.get('credits') is not None:
                accounts_fresh = self.get_accounts()
                for pos, acc in enumerate(accounts_fresh):
                    if _clean_text(acc.get('email')).lower() == _clean_text(account['email']).lower():
                        accounts_fresh[pos] = dict(acc)
                        accounts_fresh[pos]['credits'] = plugin_result['credits']
                        save_accounts(accounts_fresh)
                        break
            return {
                'status': 'success',
                'source': 'plugin_specific',
                'old_email': old_email,
                'email': account['email'],
                'index': index,
                'credits': plugin_result.get('credits') or account.get('credits', {}),
                'has_token': True,
                'plugin_result': plugin_result,
                'message': f'已切换到 {account["email"]}（插件驱动）',
            }

        # 回退到旧方式
        self.apply_account_locally(account['email'], index)
        self.apply_auth_token(auth_token)
        clear_account_auto_switch_block(account['email'])
        self.record_switch(account['email'])
        password = _clean_text(account.get('password', ''))
        trigger_sent = self.inject_via_trigger(account['email'], password) if password else False
        return {
            'status': 'success',
            'source': 'local_specific_fallback',
            'trigger_sent': trigger_sent,
            'old_email': old_email,
            'email': account['email'],
            'index': index,
            'credits': account.get('credits', {}),
            'has_token': True,
            'auth_token': auth_token,
            'plugin_error': plugin_result.get('error'),
            'message': f'已切换到 {account["email"]}（本地回退）',
        }

    # ── 主切换逻辑 ──

    def switch(self, allow_bootstrap=False, visible_browser=False, ignore_cooldown=False,
               avoid_emails=None, prefer_local=False):
        """执行账号切换，返回结果 dict"""
        if not ignore_cooldown:
            ready, remaining = self.check_cooldown()
            if not ready:
                return {
                    'status': 'cooldown',
                    'remaining_seconds': remaining,
                    'message': f'冷却中，还需等待 {remaining // 60}分{remaining % 60}秒',
                }

        old_email = self.get_current_account()
        old_account, _ = find_account(old_email, self.get_accounts())
        old_credits = (old_account or {}).get('credits', {})
        server_skip_message = ''
        avoid = {
            _clean_text(email).lower()
            for email in (avoid_emails or [])
            if _clean_text(email)
        }
        if old_email:
            avoid.add(old_email.lower())

        # 本地顺序选择（round-robin）
        account, index = self.pick_next_account(
            require_token=not allow_bootstrap,
            avoid_emails=avoid,
        )
        bootstrap_result = None
        if not account and allow_bootstrap:
            account, index = self.pick_next_account(
                require_token=False,
                avoid_emails=avoid,
            )
        if not account:
            message = '没有可用账号（缺少 token、credits 耗尽或全部过期）'
            if server_skip_message:
                message = f'{server_skip_message}；{message}'
            return {
                'status': 'no_account',
                'message': message,
            }

        auth_token = get_account_token(account)
        if not auth_token and allow_bootstrap:
            bootstrap_result = self._bootstrap_account(account, visible_browser=visible_browser)
            if bootstrap_result.get('status') == 'success':
                account, index = find_account(account.get('email'), self.get_accounts())
                auth_token = get_account_token(account)
                self.sync_bootstrap_results_to_server()

        if not auth_token:
            return {
                'status': 'no_account',
                'message': '没有可用账号（当前账号池都缺少 auth token）',
                'email': account.get('email', ''),
                'bootstrap_result': bootstrap_result,
            }

        # 通过插件触发文件驱动完整切号流程（插件自行登录+注入+状态更新）
        plugin_result = self.inject_via_plugin_trigger(account['email'])
        if plugin_result.get('success'):
            # 插件已完成所有操作，更新本地记录
            clear_account_auto_switch_block(account['email'])
            self.record_switch(account['email'])
            # 同步插件返回的 credits 到本地账号池
            if plugin_result.get('credits') is not None:
                accounts_fresh = self.get_accounts()
                for pos, acc in enumerate(accounts_fresh):
                    if _clean_text(acc.get('email')).lower() == _clean_text(account['email']).lower():
                        accounts_fresh[pos] = dict(acc)
                        accounts_fresh[pos]['credits'] = plugin_result['credits']
                        save_accounts(accounts_fresh)
                        break
            # 释放旧账号到服务器（多机协调）
            if self.server_url and self.token and old_email:
                try:
                    self.release_to_server(
                        old_email,
                        old_credits.get('daily', 0),
                        old_credits.get('weekly', 0),
                    )
                except Exception:
                    pass
            return {
                'status': 'success',
                'source': 'plugin',
                'old_email': old_email,
                'email': account['email'],
                'index': index,
                'credits': plugin_result.get('credits') or account.get('credits', {}),
                'has_token': True,
                'plugin_result': plugin_result,
                'message': f"已切换到 {account['email']}（插件驱动）",
            }

        # 插件触发失败，回退到旧方式（直接写文件+扩展注入）
        self.apply_account_locally(account['email'], index)
        self.apply_auth_token(auth_token)
        clear_account_auto_switch_block(account['email'])
        self.record_switch(account['email'])
        password = _clean_text(account.get('password', ''))
        trigger_sent = self.inject_via_trigger(account['email'], password) if password else False
        # 释放旧账号到服务器（多机协调）
        if self.server_url and self.token and old_email:
            try:
                self.release_to_server(
                    old_email,
                    old_credits.get('daily', 0),
                    old_credits.get('weekly', 0),
                )
            except Exception:
                pass
        return {
            'status': 'success',
            'source': 'local_fallback',
            'old_email': old_email,
            'email': account['email'],
            'index': index,
            'credits': account.get('credits', {}),
            'has_token': True,
            'auth_token': auth_token,
            'trigger_sent': trigger_sent,
            'plugin_error': plugin_result.get('error'),
            'message': f"已切换到 {account['email']}（本地回退）",
        }

    # ── 状态汇总 ──

    def status(self):
        accounts = self.get_accounts()
        current = self.get_current_account()
        ready, remaining = self.check_cooldown()
        available = 0
        blocked = 0
        active = 0
        depleted = 0
        expired = 0
        unknown = 0
        token_ready = 0
        total_credits = 0
        for acc in accounts:
            state = get_account_quota_state(acc)
            if state == 'active':
                active += 1
            elif state == 'depleted':
                depleted += 1
            elif state == 'expired':
                expired += 1
            else:
                unknown += 1
            if is_account_auto_switch_blocked(acc):
                blocked += 1
            if _account_has_usable_credits(acc, self.credit_threshold):
                available += 1
                if get_account_token(acc):
                    token_ready += 1
            if not acc.get('credits', {}).get('expired', False):
                total_credits += _account_total_credits(acc)
        current_account, _ = find_account(current, accounts)
        return {
            'current_email': current,
            'total_accounts': len(accounts),
            'available_accounts': available,
            'blocked_accounts': blocked,
            'active_accounts': active,
            'depleted_accounts': depleted,
            'expired_accounts': expired,
            'unknown_accounts': unknown,
            'token_ready_accounts': token_ready,
            'total_credits': total_credits,
            'cooldown_ready': ready,
            'cooldown_remaining': remaining,
            'server_configured': bool(self.server_url and self.token),
            'current_has_token': bool(self.get_current_auth_token() or get_account_token(current_account)),
        }


def _load_config():
    """从 windsurf_dialog_config.json 加载 faceflow 配置"""
    config_path = os.path.join(SCRIPT_DIR, 'config', 'windsurf_dialog_config.json')
    config = _read_json(config_path) or {}
    return {
        'server_url': config.get('windsurf_account_server_url', ''),
        'server_token': config.get('windsurf_account_server_token', ''),
        'machine_id': config.get('windsurf_account_machine_id', ''),
        'cooldown_minutes': int(config.get('windsurf_account_cooldown_minutes', COOLDOWN_MINUTES)),
        'credit_threshold': int(config.get('windsurf_account_credit_threshold', 1)),
    }


def create_switcher_from_config():
    """从配置文件创建 WindsurfAccountSwitcher 实例"""
    cfg = _load_config()
    return WindsurfAccountSwitcher(
        server_url=cfg['server_url'] or None,
        token=cfg['server_token'] or None,
        machine_id=cfg['machine_id'] or None,
        cooldown_minutes=cfg['cooldown_minutes'],
        credit_threshold=cfg['credit_threshold'],
    )

def main():
    parser = argparse.ArgumentParser(description='Windsurf 账号切换工具')
    sub = parser.add_subparsers(dest='command', help='子命令')
    switch_parser = sub.add_parser('switch', help='切换到下一个可用账号')
    switch_parser.add_argument('--allow-bootstrap', action='store_true')
    switch_parser.add_argument('--visible-browser', action='store_true')
    switch_parser.add_argument('--ignore-cooldown', action='store_true', help='跳过冷却时间（手动切号用）')
    sub.add_parser('status', help='查看当前状态')
    sub.add_parser('upload', help='上传本地账号到 faceflow 服务器')
    import_parser = sub.add_parser('import', help='导入账号到本地账号池')
    import_parser.add_argument('--input-file', required=True, help='账号 JSON 文件路径')
    bootstrap_parser = sub.add_parser('bootstrap', help='为缺少 token 的账号初始化 token')
    bootstrap_parser.add_argument('--input-file', help='账号 JSON 文件路径')
    bootstrap_parser.add_argument('--email', action='append', default=[], help='指定邮箱，可重复传入')
    bootstrap_parser.add_argument('--visible-browser', action='store_true')
    import_and_bootstrap_parser = sub.add_parser('import_and_bootstrap', help='导入账号并初始化 token')
    import_and_bootstrap_parser.add_argument('--input-file', required=True, help='账号 JSON 文件路径')
    import_and_bootstrap_parser.add_argument('--visible-browser', action='store_true')
    refresh_parser = sub.add_parser('refresh_credits', help='刷新账号额度并更新切号池状态')
    refresh_parser.add_argument('--input-file', help='账号 JSON 文件路径')
    refresh_parser.add_argument('--email', action='append', default=[], help='指定邮箱，可重复传入')
    refresh_parser.add_argument('--force', action='store_true', help='即使已过期也强制刷新')
    switch_to_parser = sub.add_parser('switch_to', help='切换到指定账号')
    switch_to_parser.add_argument('--email', required=True, help='目标邮箱')
    switch_to_parser.add_argument('--allow-bootstrap', action='store_true')
    switch_to_parser.add_argument('--visible-browser', action='store_true')
    args = parser.parse_args()

    switcher = create_switcher_from_config()

    if args.command == 'switch':
        result = switcher.switch(
            allow_bootstrap=args.allow_bootstrap,
            visible_browser=args.visible_browser,
            ignore_cooldown=args.ignore_cooldown,
        )
        result.pop('auth_token', None)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'status':
        st = switcher.status()
        print(json.dumps(st, ensure_ascii=False, indent=2))
    elif args.command == 'upload':
        result = switcher.upload_accounts_to_server()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'import':
        accounts = _load_accounts_from_input_file(args.input_file)
        result = switcher.import_accounts(accounts)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'bootstrap':
        emails = list(args.email or [])
        if args.input_file:
            accounts = _load_accounts_from_input_file(args.input_file)
            switcher.import_accounts(accounts)
            emails.extend([
                _clean_text(item.get('email'))
                for item in accounts
                if isinstance(item, dict) and _clean_text(item.get('email'))
            ])
        result = switcher.bootstrap_missing_tokens(
            emails=emails or None,
            visible_browser=args.visible_browser,
        )
        if result.get('success_count', 0) > 0:
            result['upload_result'] = switcher.sync_bootstrap_results_to_server()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'import_and_bootstrap':
        accounts = _load_accounts_from_input_file(args.input_file)
        result = switcher.import_and_bootstrap(
            accounts,
            visible_browser=args.visible_browser,
        )
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'refresh_credits':
        emails = list(args.email or [])
        if args.input_file:
            accounts = _load_accounts_from_input_file(args.input_file)
            switcher.import_accounts(accounts)
            emails.extend([
                _clean_text(item.get('email'))
                for item in accounts
                if isinstance(item, dict) and _clean_text(item.get('email'))
            ])
        result = switcher.refresh_credits(
            emails=emails or None,
            force=args.force,
        )
        if result.get('success_count', 0) > 0:
            result['upload_result'] = switcher.sync_bootstrap_results_to_server()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == 'switch_to':
        result = switcher.switch_to_specific_account(
            args.email,
            allow_bootstrap=args.allow_bootstrap,
            visible_browser=args.visible_browser,
        )
        result.pop('auth_token', None)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
