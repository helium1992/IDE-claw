import json
import os
import time
from datetime import datetime, timedelta, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
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
    'quota_pool_snapshot': os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-quota-pool-snapshot.json'),
}
BEIJING_TZ = timezone(timedelta(hours=8))


def _read_json(filepath):
    if not os.path.exists(filepath):
        return None
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError, TypeError, ValueError):
        return None


def _write_json(filepath, data):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def _safe_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _clean_text(value):
    if value is None:
        return ''
    return str(value).strip()


def _normalize_epoch_seconds(value):
    ts = _safe_int(value, 0)
    if ts <= 0:
        return 0
    if ts > 1000000000000:
        ts = ts // 1000
    return ts


def _format_timestamp_text(value):
    ts = _normalize_epoch_seconds(value)
    if ts <= 0:
        return ''
    try:
        return datetime.fromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S')
    except Exception:
        return ''


def _next_daily_reset_at(now=None):
    current = datetime.fromtimestamp(int(time.time() if now is None else now), tz=BEIJING_TZ)
    target = current.replace(hour=16, minute=0, second=0, microsecond=0)
    if current >= target:
        target += timedelta(days=1)
    return int(target.timestamp())


def _next_weekly_reset_at(now=None):
    current = datetime.fromtimestamp(int(time.time() if now is None else now), tz=BEIJING_TZ)
    target = current.replace(hour=16, minute=0, second=0, microsecond=0)
    days_until_sunday = (6 - current.weekday()) % 7
    target += timedelta(days=days_until_sunday)
    if days_until_sunday == 0 and current >= target:
        target += timedelta(days=7)
    return int(target.timestamp())


def get_account_token(account):
    if not isinstance(account, dict):
        return ''
    return _clean_text(
        account.get('auth_token')
        or account.get('token')
        or account.get('authToken')
        or account.get('api_key')
    )


def _normalize_credits(credits):
    credits = credits if isinstance(credits, dict) else {}
    return {
        'daily': _safe_int(credits.get('daily', -1), -1),
        'weekly': _safe_int(credits.get('weekly', -1), -1),
        'expired': bool(credits.get('expired', False)),
        'daily_reset_at': _normalize_epoch_seconds(credits.get('daily_reset_at', 0)),
        'weekly_reset_at': _normalize_epoch_seconds(credits.get('weekly_reset_at', 0)),
        'plan_name': _clean_text(credits.get('plan_name')),
        'available_flow_credits': _safe_int(credits.get('available_flow_credits', -1), -1),
        'available_prompt_credits': _safe_int(credits.get('available_prompt_credits', -1), -1),
        'monthly_flow_credits': _safe_int(credits.get('monthly_flow_credits', 0), 0),
        'monthly_prompt_credits': _safe_int(credits.get('monthly_prompt_credits', 0), 0),
    }


def _normalize_quota_state(value, credits=None):
    text = _clean_text(value)
    if text == 'depleted':
        derived = _derive_quota_state(credits)
        if derived in ('daily_depleted', 'weekly_depleted'):
            return derived
        return 'daily_depleted'
    if text in ('active', 'daily_depleted', 'weekly_depleted', 'expired', 'unknown'):
        return text
    return ''


def _derive_quota_state(credits):
    credits = _normalize_credits(credits)
    if credits.get('expired', False):
        return 'expired'
    if credits.get('weekly', -1) == 0:
        return 'weekly_depleted'
    if credits.get('daily', -1) == 0:
        return 'daily_depleted'
    if credits.get('daily', -1) >= 0 or credits.get('weekly', -1) >= 0:
        return 'active'
    return 'unknown'


def _derive_next_refresh_reason(quota_state):
    if quota_state == 'daily_depleted':
        return 'daily_reset'
    if quota_state == 'weekly_depleted':
        return 'weekly_reset'
    return ''


def _derive_next_refresh_at(quota_state, credits, fallback=0, now=None):
    normalized = _normalize_credits(credits)
    fallback_ts = _normalize_epoch_seconds(fallback)
    if quota_state == 'daily_depleted':
        return normalized.get('daily_reset_at', 0) or fallback_ts or _next_daily_reset_at(now)
    if quota_state == 'weekly_depleted':
        return normalized.get('weekly_reset_at', 0) or fallback_ts or _next_weekly_reset_at(now)
    return 0


def get_account_next_refresh_at(account, now=None):
    if not isinstance(account, dict):
        return 0
    quota_state = get_account_quota_state(account)
    credits = account.get('credits') or {}
    return _derive_next_refresh_at(quota_state, credits, account.get('next_refresh_at', 0), now=now)


def is_account_refresh_due(account, now=None):
    current = int(time.time() if now is None else now)
    next_refresh_at = get_account_next_refresh_at(account, now=current)
    return next_refresh_at > 0 and next_refresh_at <= current


def normalize_account(account):
    account = account if isinstance(account, dict) else {}
    token = get_account_token(account)
    credits = _normalize_credits(account.get('credits'))
    quota_state = _normalize_quota_state(account.get('quota_state'), credits) or _derive_quota_state(credits)
    next_refresh_at = _derive_next_refresh_at(quota_state, credits, account.get('next_refresh_at', 0))
    normalized = dict(account)
    normalized['email'] = _clean_text(account.get('email'))
    normalized['password'] = _clean_text(account.get('password'))
    normalized['auth_token'] = token
    normalized['token'] = token
    normalized['credits'] = credits
    normalized['quota_state'] = quota_state
    normalized['next_refresh_at'] = next_refresh_at
    normalized['loginCount'] = _safe_int(account.get('loginCount', 0))
    normalized['last_bootstrap_status'] = _clean_text(account.get('last_bootstrap_status'))
    normalized['last_bootstrap_message'] = _clean_text(account.get('last_bootstrap_message'))
    normalized['token_initialized_at'] = _clean_text(account.get('token_initialized_at'))
    normalized['last_bootstrap_at'] = _clean_text(account.get('last_bootstrap_at'))
    normalized['quota_state_reason'] = _clean_text(account.get('quota_state_reason'))
    normalized['quota_state_source'] = _clean_text(account.get('quota_state_source'))
    normalized['quota_state_updated_at'] = _clean_text(account.get('quota_state_updated_at'))
    normalized['last_quota_refresh_status'] = _clean_text(account.get('last_quota_refresh_status'))
    normalized['last_quota_refresh_message'] = _clean_text(account.get('last_quota_refresh_message'))
    normalized['last_quota_refresh_at'] = _clean_text(account.get('last_quota_refresh_at'))
    normalized['daily_reset_at'] = credits.get('daily_reset_at', 0)
    normalized['weekly_reset_at'] = credits.get('weekly_reset_at', 0)
    normalized['next_refresh_reason'] = _derive_next_refresh_reason(quota_state)
    normalized['next_refresh_time'] = _format_timestamp_text(next_refresh_at)
    normalized['purge_after_at'] = _safe_int(account.get('purge_after_at', 0))
    normalized['auto_switch_blocked_until'] = _safe_int(account.get('auto_switch_blocked_until', 0))
    normalized['auto_switch_blocked_reason'] = _clean_text(account.get('auto_switch_blocked_reason'))
    return normalized


def build_account_pool_snapshot(accounts=None, now=None):
    pool = list(accounts or load_accounts())
    current = int(time.time() if now is None else now)
    grouped = {
        'active': [],
        'daily_depleted': [],
        'weekly_depleted': [],
        'expired': [],
        'unknown': [],
    }
    entries = []
    for item in pool:
        account = normalize_account(item)
        state = get_account_quota_state(account)
        credits = account.get('credits', {}) or {}
        next_refresh_at = _normalize_epoch_seconds(account.get('next_refresh_at', 0))
        entry = {
            'email': account.get('email', ''),
            'quota_state': state,
            'daily': _safe_int(credits.get('daily', -1), -1),
            'weekly': _safe_int(credits.get('weekly', -1), -1),
            'expired': bool(credits.get('expired', False)),
            'in_switch_pool': is_account_in_switch_pool(account),
            'auto_switch_blocked_until': _safe_int(account.get('auto_switch_blocked_until', 0)),
            'last_quota_refresh_at': account.get('last_quota_refresh_at', ''),
            'next_refresh_at': next_refresh_at,
            'next_refresh_time': _format_timestamp_text(next_refresh_at),
            'next_refresh_reason': _clean_text(account.get('next_refresh_reason')),
            'is_refresh_due': next_refresh_at > 0 and next_refresh_at <= current,
        }
        grouped.setdefault(state, []).append(entry)
        entries.append(entry)
    return {
        'generated_at': current,
        'generated_at_text': _format_timestamp_text(current),
        'total_accounts': len(entries),
        'active_accounts': len(grouped.get('active', [])),
        'daily_depleted_accounts': len(grouped.get('daily_depleted', [])),
        'weekly_depleted_accounts': len(grouped.get('weekly_depleted', [])),
        'expired_accounts': len(grouped.get('expired', [])),
        'unknown_accounts': len(grouped.get('unknown', [])),
        'accounts': entries,
        'groups': grouped,
    }


def save_account_pool_snapshot(accounts=None, now=None):
    snapshot = build_account_pool_snapshot(accounts=accounts, now=now)
    _write_json(LOCAL_FILES['quota_pool_snapshot'], snapshot)
    return snapshot


def load_accounts():
    data = _read_json(LOCAL_FILES['accounts'])
    if not isinstance(data, list):
        return []
    accounts = []
    for item in data:
        normalized = normalize_account(item)
        if normalized.get('email'):
            accounts.append(normalized)
    return accounts


def save_accounts(accounts):
    deduped = []
    seen = set()
    for item in accounts or []:
        normalized = normalize_account(item)
        email = normalized.get('email', '')
        if not email:
            continue
        key = email.lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(normalized)
    _write_json(LOCAL_FILES['accounts'], deduped)
    save_account_pool_snapshot(deduped)
    return deduped


def load_state():
    state = _read_json(LOCAL_FILES['state'])
    return state if isinstance(state, dict) else {}


def save_state(state):
    payload = state if isinstance(state, dict) else {}
    _write_json(LOCAL_FILES['state'], payload)
    return payload


def read_current_auth_token():
    auth = _read_json(LOCAL_FILES['auth'])
    if not isinstance(auth, dict):
        return ''
    return _clean_text(auth.get('authToken') or auth.get('token') or auth.get('api_key'))


def write_auth_token_files(token):
    token = _clean_text(token)
    if not token:
        return False
    now_ms = int(time.time() * 1000)
    auth_data = {
        'authToken': token,
        'token': token,
        'api_key': token,
        'timestamp': now_ms,
    }
    _write_json(LOCAL_FILES['auth'], auth_data)
    _write_json(LOCAL_FILES['cascade_auth'], auth_data)
    _write_json(LOCAL_FILES['token_cache'], {})
    return True


def find_account(email, accounts=None):
    email = _clean_text(email)
    if not email:
        return None, -1
    pool = accounts if accounts is not None else load_accounts()
    for index, account in enumerate(pool):
        if _clean_text(account.get('email')).lower() == email.lower():
            return account, index
    return None, -1


def update_account(email, updates):
    email = _clean_text(email)
    if not email or not isinstance(updates, dict):
        return None
    accounts = load_accounts()
    updated_account = None
    for index, account in enumerate(accounts):
        if _clean_text(account.get('email')).lower() != email.lower():
            continue
        merged = dict(account)
        merged.update(updates)
        if 'credits' in updates:
            merged['credits'] = _normalize_credits(updates.get('credits'))
        normalized = normalize_account(merged)
        accounts[index] = normalized
        updated_account = normalized
        break
    if updated_account is None:
        return None
    save_accounts(accounts)
    return updated_account


def get_account_auto_switch_block_until(account):
    if not isinstance(account, dict):
        return 0
    return _safe_int(account.get('auto_switch_blocked_until', 0))


def is_account_auto_switch_blocked(account, now=None):
    current = int(time.time() if now is None else now)
    return get_account_auto_switch_block_until(account) > current


def block_account_for_auto_switch(email, duration_seconds, reason=''):
    seconds = max(_safe_int(duration_seconds, 0), 0)
    until = int(time.time()) + seconds if seconds > 0 else 0
    return update_account(email, {
        'auto_switch_blocked_until': until,
        'auto_switch_blocked_reason': _clean_text(reason),
    })


def clear_account_auto_switch_block(email):
    return update_account(email, {
        'auto_switch_blocked_until': 0,
        'auto_switch_blocked_reason': '',
    })


def get_account_quota_state(account):
    if not isinstance(account, dict):
        return 'unknown'
    stored_state = _normalize_quota_state(account.get('quota_state'), account.get('credits'))
    if stored_state == 'expired':
        return 'expired'
    derived = _derive_quota_state(account.get('credits'))
    if derived != 'unknown':
        return derived
    return stored_state or 'unknown'


def is_account_in_switch_pool(account):
    state = get_account_quota_state(account)
    return state not in ('daily_depleted', 'weekly_depleted', 'expired')


def mark_account_quota_refresh(email, refresh_result, retention_days=7):
    refresh_result = refresh_result if isinstance(refresh_result, dict) else {}
    existing, _ = find_account(email)
    if existing is None:
        return None
    now_text = time.strftime('%Y-%m-%d %H:%M:%S')
    current_state = get_account_quota_state(existing)

    updates = {
        'last_quota_refresh_status': _clean_text(refresh_result.get('status')),
        'last_quota_refresh_message': _clean_text(refresh_result.get('message')),
        'last_quota_refresh_at': now_text,
    }

    if refresh_result.get('status') != 'success':
        return update_account(email, updates)

    credits = _normalize_credits(refresh_result.get('credits'))
    next_state = current_state if current_state == 'expired' else _derive_quota_state(credits)
    purge_after_at = _safe_int(existing.get('purge_after_at', 0))
    if next_state == 'expired':
        purge_after_at = purge_after_at or int(time.time()) + (max(_safe_int(retention_days, 7), 1) * 86400)
    else:
        purge_after_at = 0

    updates.update({
        'credits': credits,
        'quota_state': next_state,
        'quota_state_reason': _clean_text(refresh_result.get('message')),
        'quota_state_source': _clean_text(refresh_result.get('source') or 'refresh'),
        'quota_state_updated_at': now_text,
        'purge_after_at': purge_after_at,
        'auto_switch_blocked_until': 0,
        'auto_switch_blocked_reason': '',
    })
    return update_account(email, updates)


def mark_account_quota_depleted(email, reason='', source='auto_detect'):
    existing, _ = find_account(email)
    if existing is None:
        return None
    if get_account_quota_state(existing) == 'expired':
        return existing
    now_text = time.strftime('%Y-%m-%d %H:%M:%S')
    next_state = _derive_quota_state(existing.get('credits'))
    if next_state not in ('daily_depleted', 'weekly_depleted'):
        next_state = 'daily_depleted'
    return update_account(email, {
        'quota_state': next_state,
        'quota_state_reason': _clean_text(reason) or 'quota_depleted',
        'quota_state_source': _clean_text(source) or 'auto_detect',
        'quota_state_updated_at': now_text,
        'purge_after_at': 0,
    })


def purge_expired_accounts(retention_days=7):
    accounts = load_accounts()
    keep = []
    removed = []
    now_ts = int(time.time())
    default_keep_seconds = max(_safe_int(retention_days, 7), 1) * 86400
    changed = False

    for account in accounts:
        state = get_account_quota_state(account)
        purge_after_at = _safe_int(account.get('purge_after_at', 0))
        if state == 'expired' and purge_after_at <= 0:
            purge_after_at = now_ts + default_keep_seconds
            account = normalize_account({
                **account,
                'purge_after_at': purge_after_at,
            })
            changed = True
        if state == 'expired' and purge_after_at > 0 and purge_after_at <= now_ts:
            removed.append(account)
            continue
        keep.append(account)

    if removed or changed:
        save_accounts(keep)

    return {
        'removed_count': len(removed),
        'removed': removed,
        'accounts': keep,
    }


def mark_account_bootstrap_result(email, result):
    result = result if isinstance(result, dict) else {}
    now_text = time.strftime('%Y-%m-%d %H:%M:%S')
    token = _clean_text(result.get('auth_token'))
    updates = {
        'last_bootstrap_status': _clean_text(result.get('status')),
        'last_bootstrap_message': _clean_text(result.get('message')),
        'last_bootstrap_at': now_text,
    }
    if token:
        updates['auth_token'] = token
        updates['token'] = token
        updates['token_initialized_at'] = now_text
    return update_account(email, updates)


def _should_replace_credits(raw_account):
    if not isinstance(raw_account, dict):
        return False
    credits = raw_account.get('credits')
    if not isinstance(credits, dict):
        return False
    return any(key in credits for key in ('daily', 'weekly', 'expired'))


def merge_imported_accounts(accounts):
    existing = load_accounts()
    merged = []
    by_email = {}
    for account in existing:
        email = _clean_text(account.get('email'))
        if not email:
            continue
        key = email.lower()
        by_email[key] = normalize_account(account)
        merged.append(by_email[key])

    created = 0
    updated = 0
    skipped = 0
    imported = 0

    for raw in accounts or []:
        normalized = normalize_account(raw)
        email = normalized.get('email', '')
        if not email:
            skipped += 1
            continue
        imported += 1
        key = email.lower()
        current = by_email.get(key)
        if current is None:
            by_email[key] = normalized
            merged.append(normalized)
            created += 1
            continue

        next_account = dict(current)
        if normalized.get('password'):
            next_account['password'] = normalized['password']
        token = get_account_token(normalized)
        if token:
            next_account['auth_token'] = token
            next_account['token'] = token
        if _should_replace_credits(raw):
            next_account['credits'] = normalized.get('credits', current.get('credits', {}))
        by_email[key] = normalize_account(next_account)
        for index, existing_account in enumerate(merged):
            if _clean_text(existing_account.get('email')).lower() == key:
                merged[index] = by_email[key]
                break
        updated += 1

    saved = save_accounts(merged)
    return {
        'status': 'success',
        'imported': imported,
        'created': created,
        'updated': updated,
        'skipped': skipped,
        'total_accounts': len(saved),
        'accounts': saved,
    }
