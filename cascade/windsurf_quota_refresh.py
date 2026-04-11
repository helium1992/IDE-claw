import time
import os
import json
from urllib.parse import urlparse, urlunparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, 'config', 'windsurf_dialog_config.json')


FIREBASE_API_KEY = 'AIzaSyDsOl-1XpT5err0Tcnx8FFod1H8gVGIycY'
FIREBASE_SIGNIN_URL = (
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword'
    f'?key={FIREBASE_API_KEY}'
)
REQUEST_TIMEOUT = 30

WINDSURF_GLOBAL_STORAGE = os.path.join(
    os.environ.get('APPDATA', ''), 'Windsurf', 'User', 'globalStorage'
)
TOKEN_CACHE_FILE = os.path.join(WINDSURF_GLOBAL_STORAGE, 'windsurf-token-cache.json')

_BACKUP_DOMAINS = []
_BACKUP_DOMAINS_UPDATED_AT = 0
_LAST_SUCCESS_STRATEGY = ''


def _clean_text(value):
    if value is None:
        return ''
    return str(value).strip()


def _load_server_config():
    config = {}
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r', encoding='utf-8') as handle:
                loaded = json.load(handle)
                if isinstance(loaded, dict):
                    config = loaded
    except Exception:
        config = {}
    server_url = _clean_text(config.get('windsurf_account_server_url')).rstrip('/')
    return {
        'server_url': server_url,
        'server_token': _clean_text(config.get('windsurf_account_server_token')),
    }


_SERVER_CONFIG = _load_server_config()
_SERVER_URL = _SERVER_CONFIG.get('server_url', '')
_SERVER_TOKEN = _SERVER_CONFIG.get('server_token', '')


def _server_endpoint(path, fallback=''):
    path = '/' + path.lstrip('/') if path else ''
    if _SERVER_URL and path:
        return f'{_SERVER_URL}{path}'
    return fallback


def _server_auth_headers(headers=None):
    request_headers = dict(headers or {})
    if _SERVER_TOKEN:
        request_headers['Authorization'] = f'Bearer {_SERVER_TOKEN}'
    return request_headers


PLUGIN_FIREBASE_LOGIN_URL = _server_endpoint('/api/windsurf/firebase/login', 'https://your-proxy.example.com/firebase/login')
PLAN_STATUS_URL = _server_endpoint('/api/windsurf/plan-status', 'https://your-proxy.example.com/windsurf/plan-status')
AUTH_TOKEN_URL = _server_endpoint('/api/windsurf/auth-token', 'https://your-proxy.example.com/windsurf/auth-token')
ACCOUNT_RULES_URL = ''
PRIMARY_DOMAIN = _clean_text(urlparse(_SERVER_URL).hostname) or 'your-proxy.example.com'


def _safe_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _normalize_epoch_seconds(value):
    ts = _safe_int(value, 0)
    if ts <= 0:
        return 0
    if ts > 1000000000000:
        ts = ts // 1000
    return ts


def _first_available_int(sources, keys, default=0):
    for source in sources:
        if not isinstance(source, dict):
            continue
        for key in keys:
            if key not in source:
                continue
            value = _normalize_epoch_seconds(source.get(key))
            if value > 0:
                return value
    return default


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


def derive_quota_state(credits):
    normalized = _normalize_credits(credits)
    if normalized.get('expired'):
        return 'expired'
    if normalized.get('weekly') == 0:
        return 'weekly_depleted'
    daily = normalized.get('daily', -1)
    if daily == 0:
        return 'daily_depleted'
    if daily >= 0 or normalized.get('weekly', -1) >= 0:
        return 'active'
    return 'unknown'


def _error_result(email, message, error_code='', **extra):
    result = {
        'status': 'error',
        'email': _clean_text(email),
        'credits': _normalize_credits(None),
        'quota_state': 'unknown',
        'message': _clean_text(message),
        'error_code': _clean_text(error_code),
    }
    result.update(extra)
    return result


def _success_result(email, credits, message, **extra):
    normalized = _normalize_credits(credits)
    result = {
        'status': 'success',
        'email': _clean_text(email),
        'credits': normalized,
        'quota_state': derive_quota_state(normalized),
        'message': _clean_text(message),
    }
    result.update(extra)
    return result


def _json_preview(payload, limit=240):
    try:
        return json.dumps(payload, ensure_ascii=False)[:limit]
    except Exception:
        return str(payload)[:limit]


def _read_json_file(filepath):
    if not filepath or not os.path.exists(filepath):
        return None
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def _write_json_file(filepath, data):
    try:
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
        return True
    except Exception:
        return False


def _compute_cache_expire_time(payload=None):
    payload = payload if isinstance(payload, dict) else {}
    expires_in = _safe_int(payload.get('expiresIn', 0), 0)
    if expires_in > 300:
        return int(time.time() * 1000) + ((expires_in - 300) * 1000)
    return int(time.time() * 1000) + (50 * 60 * 1000)


def load_plugin_token_cache():
    data = _read_json_file(TOKEN_CACHE_FILE)
    return data if isinstance(data, dict) else {}


def save_plugin_token_cache(cache):
    cache = cache if isinstance(cache, dict) else {}
    return _write_json_file(TOKEN_CACHE_FILE, cache)


def get_cached_id_token(email):
    email = _clean_text(email).lower()
    if not email:
        return None
    cache = load_plugin_token_cache()
    entry = cache.get(email)
    if not isinstance(entry, dict):
        return None
    id_token = _clean_text(entry.get('idToken'))
    expire_time = _safe_int(entry.get('expireTime', 0), 0)
    if not id_token or expire_time <= int(time.time() * 1000):
        return None
    return {
        'status': 'success',
        'email': email,
        'id_token': id_token,
        'source': 'plugin_token_cache',
        'message': '命中插件 token 缓存',
        'expire_time': expire_time,
    }


def store_cached_id_token(email, id_token, expire_time=None):
    email = _clean_text(email).lower()
    id_token = _clean_text(id_token)
    if not email or not id_token:
        return False
    cache = load_plugin_token_cache()
    cache[email] = {
        'idToken': id_token,
        'expireTime': _safe_int(expire_time, int(time.time() * 1000) + (50 * 60 * 1000)),
    }
    return save_plugin_token_cache(cache)


def clear_cached_id_token(email):
    email = _clean_text(email).lower()
    if not email:
        return False
    cache = load_plugin_token_cache()
    if email not in cache:
        return False
    cache.pop(email, None)
    return save_plugin_token_cache(cache)


def _get_env_proxy():
    for key in ('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy'):
        value = _clean_text(os.environ.get(key))
        if value:
            return value
    return ''


def _normalize_domain_list(domains):
    result = []
    for item in domains or []:
        value = _clean_text(item)
        if not value or value in result:
            continue
        result.append(value)
    return result


def _build_request_strategies(original_domain, include_backup_domains=True):
    global _LAST_SUCCESS_STRATEGY
    env_proxy = _get_env_proxy()
    domains = [original_domain]
    if include_backup_domains:
        domains.extend([domain for domain in _BACKUP_DOMAINS if domain != original_domain])
    domains = _normalize_domain_list(domains)
    strategies = []
    for domain in domains:
        strategies.append({
            'name': f'direct-{domain}',
            'domain': domain,
            'netloc': domain,
            'verify': True,
            'proxy_url': '',
        })
        if env_proxy:
            strategies.append({
                'name': f'env-proxy-strict-{domain}',
                'domain': domain,
                'netloc': domain,
                'verify': True,
                'proxy_url': env_proxy,
            })
        strategies.append({
            'name': f'relaxed-ssl-{domain}',
            'domain': domain,
            'netloc': domain,
            'verify': False,
            'proxy_url': '',
        })
        if env_proxy:
            strategies.append({
                'name': f'env-proxy-{domain}',
                'domain': domain,
                'netloc': domain,
                'verify': False,
                'proxy_url': env_proxy,
            })
    if _LAST_SUCCESS_STRATEGY:
        strategies.sort(key=lambda item: 0 if item.get('name') == _LAST_SUCCESS_STRATEGY else 1)
    return strategies


def _parse_response_payload(response, binary=False):
    if binary:
        return {
            'ok': response.status_code == 200,
            'status_code': response.status_code,
            'data': None,
            'text': response.text[:200],
            'content': response.content,
        }
    try:
        data = response.json()
    except ValueError:
        data = {'raw': response.text[:200]}
    return {
        'ok': response.status_code == 200,
        'status_code': response.status_code,
        'data': data,
        'text': response.text[:200],
    }


def _request_with_strategy(url, strategy, method='POST', headers=None, json_payload=None,
                           data=None, timeout=REQUEST_TIMEOUT, binary=False):
    try:
        import requests
    except ImportError:
        return None, _error_result('', 'requests 未安装', 'missing_requests')

    parsed = urlparse(url)
    target_domain = _clean_text(strategy.get('domain')) or parsed.hostname or parsed.netloc
    target_netloc = _clean_text(strategy.get('netloc')) or parsed.netloc
    if ':' not in target_netloc and parsed.port:
        target_netloc = f'{target_netloc}:{parsed.port}'
    target_url = urlunparse((parsed.scheme, target_netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))
    request_headers = dict(headers or {})
    if parsed.hostname:
        request_headers['Host'] = parsed.hostname

    session = requests.Session()
    session.trust_env = False
    proxies = None
    proxy_url = _clean_text(strategy.get('proxy_url'))
    if proxy_url:
        proxies = {
            'http': proxy_url,
            'https': proxy_url,
        }

    try:
        response = session.request(
            method=method,
            url=target_url,
            headers=request_headers,
            json=json_payload,
            data=data,
            timeout=timeout,
            verify=bool(strategy.get('verify', True)),
            proxies=proxies,
        )
    except Exception as exc:
        return None, _error_result('', f'{strategy.get("name", "request")} 请求异常: {exc}', 'request_failed')
    finally:
        session.close()

    return _parse_response_payload(response, binary=binary), None


def _refresh_backup_domains(force=False):
    global _BACKUP_DOMAINS, _BACKUP_DOMAINS_UPDATED_AT
    if not ACCOUNT_RULES_URL:
        return list(_BACKUP_DOMAINS)
    now = int(time.time())
    if not force and _BACKUP_DOMAINS and (now - _BACKUP_DOMAINS_UPDATED_AT) < 300:
        return list(_BACKUP_DOMAINS)
    response, _ = _multi_strategy_request(
        ACCOUNT_RULES_URL,
        method='GET',
        headers={},
        timeout=REQUEST_TIMEOUT,
        include_backup_domains=False,
    )
    if response and response.get('ok'):
        payload = response.get('data') if isinstance(response.get('data'), dict) else {}
        _BACKUP_DOMAINS = _normalize_domain_list(payload.get('backup_domains'))
        _BACKUP_DOMAINS_UPDATED_AT = now
    return list(_BACKUP_DOMAINS)


def _multi_strategy_request(url, method='POST', headers=None, json_payload=None, data=None,
                            timeout=REQUEST_TIMEOUT, binary=False, include_backup_domains=True):
    global _LAST_SUCCESS_STRATEGY
    parsed = urlparse(url)
    original_domain = _clean_text(parsed.hostname)
    if include_backup_domains and original_domain == PRIMARY_DOMAIN:
        _refresh_backup_domains()
    strategies = _build_request_strategies(original_domain, include_backup_domains=include_backup_domains)
    last_error = None
    for strategy in strategies:
        response, error = _request_with_strategy(
            url,
            strategy,
            method=method,
            headers=headers,
            json_payload=json_payload,
            data=data,
            timeout=timeout,
            binary=binary,
        )
        if error is not None:
            last_error = error
            continue
        _LAST_SUCCESS_STRATEGY = strategy.get('name', '')
        response['strategy'] = strategy.get('name', '')
        response['target_domain'] = strategy.get('domain', '')
        return response, None
    return None, last_error or _error_result('', '所有连接策略均失败', 'all_strategies_failed')


def _extract_error_message(payload):
    if isinstance(payload, dict):
        error = payload.get('error')
        if isinstance(error, dict):
            message = error.get('message') or error.get('status')
            if message:
                return _clean_text(message)
        if isinstance(error, str) and error.strip():
            return error.strip()
        for key in ('message', 'detail', 'error_description'):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    if isinstance(payload, str):
        return payload.strip()
    return ''


def _post_json(url, payload, headers=None, timeout=REQUEST_TIMEOUT):
    request_headers = {'Content-Type': 'application/json'}
    request_headers.update(headers or {})
    return _multi_strategy_request(
        url,
        method='POST',
        headers=request_headers,
        json_payload=payload,
        timeout=timeout,
    )


def _post_binary(url, payload, headers=None, timeout=REQUEST_TIMEOUT):
    return _multi_strategy_request(
        url,
        method='POST',
        headers=headers or {},
        data=payload,
        timeout=timeout,
        binary=True,
    )


def login_via_plugin_proxy(email, password):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, '邮箱或密码为空', 'missing_credentials')
    if not _SERVER_URL or not _SERVER_TOKEN:
        return _error_result(email, '未配置 faceflow 服务器登录信息', 'missing_server_config')

    response, error = _post_json(
        PLUGIN_FIREBASE_LOGIN_URL,
        {
            'returnSecureToken': True,
            'email': email,
            'password': password,
            'clientType': 'CLIENT_TYPE_WEB',
        },
        headers=_server_auth_headers(),
    )
    if error is not None:
        return error
    if not response.get('ok'):
        payload = response.get('data')
        message = _extract_error_message(payload) or _json_preview(payload)
        return _error_result(email, f'插件代理 Firebase 登录失败: {message}', 'plugin_firebase_http_error')

    payload = response.get('data') if isinstance(response.get('data'), dict) else {}
    id_token = _clean_text(payload.get('idToken'))
    if not id_token:
        return _error_result(email, f'插件代理登录未返回 idToken: {_json_preview(payload)}', 'plugin_missing_id_token')
    expire_time = _compute_cache_expire_time(payload)
    store_cached_id_token(email, id_token, expire_time=expire_time)
    return {
        'status': 'success',
        'email': email,
        'id_token': id_token,
        'source': 'plugin_proxy',
        'message': '插件代理 Firebase 登录成功',
        'expire_time': expire_time,
    }


def login_via_official_firebase(email, password):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, '邮箱或密码为空', 'missing_credentials')

    response, error = _multi_strategy_request(
        FIREBASE_SIGNIN_URL,
        method='POST',
        headers={'Content-Type': 'application/json'},
        json_payload={
            'email': email,
            'password': password,
            'returnSecureToken': True,
        },
        timeout=REQUEST_TIMEOUT,
        include_backup_domains=False,
    )
    if error is not None:
        return _error_result(email, f'官方 Firebase 请求异常: {error.get("message", "")}', 'firebase_request_failed')

    payload = response.get('data') if isinstance(response.get('data'), dict) else {}

    if not response.get('ok'):
        message = _extract_error_message(payload) or _json_preview(payload)
        return _error_result(email, f'官方 Firebase 登录失败: {message}', 'firebase_http_error')

    id_token = _clean_text(payload.get('idToken') if isinstance(payload, dict) else '')
    if not id_token:
        return _error_result(email, '官方 Firebase 响应中没有 idToken', 'missing_id_token')
    expire_time = _compute_cache_expire_time(payload)
    store_cached_id_token(email, id_token, expire_time=expire_time)

    return {
        'status': 'success',
        'email': email,
        'id_token': id_token,
        'source': 'official_firebase',
        'message': '官方 Firebase 登录成功',
        'expire_time': expire_time,
    }


def get_firebase_id_token(email, password, allow_cache=True):
    if allow_cache:
        cached = get_cached_id_token(email)
        if cached is not None:
            return cached

    proxy_result = login_via_plugin_proxy(email, password)
    if proxy_result.get('status') == 'success':
        return proxy_result

    return _error_result(
        email,
        proxy_result.get('message', '') or '无法获取 Firebase idToken',
        proxy_result.get('error_code') or 'firebase_login_failed',
        attempts=[
            {
                'method': 'plugin_proxy',
                'status': proxy_result.get('status'),
                'message': proxy_result.get('message', ''),
                'error_code': proxy_result.get('error_code', ''),
            },
        ],
    )


def build_protobuf_request(id_token):
    token_bytes = _clean_text(id_token).encode('utf-8')
    if not token_bytes:
        return b''
    length_bytes = bytearray()
    size = len(token_bytes)
    while size > 127:
        length_bytes.append((size & 0x7F) | 0x80)
        size >>= 7
    length_bytes.append(size)
    return bytes(bytearray([0x0A]) + length_bytes + token_bytes)


def _read_varint(buffer, pos):
    result = 0
    shift = 0
    while pos < len(buffer):
        value = buffer[pos]
        pos += 1
        result |= (value & 0x7F) << shift
        if (value & 0x80) == 0:
            break
        shift += 7
        if shift > 63:
            while pos < len(buffer) and (buffer[pos] & 0x80):
                pos += 1
            if pos < len(buffer):
                pos += 1
            return -1, pos
    return result, pos


def _parse_message_fields(buffer, start, end):
    fields = {}
    pos = max(start, 0)
    boundary = min(end, len(buffer))
    while pos < boundary:
        tag, pos = _read_varint(buffer, pos)
        if tag <= 0:
            break
        field_num = tag >> 3
        wire_type = tag & 0x07
        if field_num == 0:
            break
        if wire_type == 0:
            value, pos = _read_varint(buffer, pos)
            fields.setdefault(field_num, []).append({
                'wire_type': wire_type,
                'value': value,
                'data_start': pos,
                'data_len': 0,
            })
        elif wire_type == 2:
            length, pos = _read_varint(buffer, pos)
            if length < 0:
                break
            data_start = pos
            data_len = max(length, 0)
            pos = min(boundary, data_start + data_len)
            fields.setdefault(field_num, []).append({
                'wire_type': wire_type,
                'value': 0,
                'data_start': data_start,
                'data_len': data_len,
            })
        elif wire_type == 5:
            pos = min(boundary, pos + 4)
        elif wire_type == 1:
            pos = min(boundary, pos + 8)
        else:
            break
    return fields


def _get_varint(fields, field_num):
    values = fields.get(field_num) or []
    if not values:
        return -1
    entry = values[-1]
    if entry.get('wire_type') != 0:
        return -1
    return _safe_int(entry.get('value'), -1)


def _get_nested_range(fields, field_num):
    values = fields.get(field_num) or []
    if not values:
        return None
    entry = values[-1]
    if entry.get('wire_type') != 2:
        return None
    return (
        _safe_int(entry.get('data_start'), 0),
        _safe_int(entry.get('data_start'), 0) + _safe_int(entry.get('data_len'), 0),
    )


def _get_string(buffer, fields, field_num):
    nested_range = _get_nested_range(fields, field_num)
    if nested_range is None:
        return ''
    start, end = nested_range
    try:
        return buffer[start:end].decode('utf-8')
    except Exception:
        return ''


def _detect_expired(buffer, fields):
    plan_info_range = _get_nested_range(fields, 1)
    if plan_info_range is None:
        return False
    plan_info_fields = _parse_message_fields(buffer, plan_info_range[0], plan_info_range[1])
    plan_type = _get_string(buffer, plan_info_fields, 2)
    return plan_type == 'Free'


def _extract_quota(fields):
    has_direct_pct = 14 in fields or 15 in fields
    has_reset_timestamps = 17 in fields or 18 in fields
    if not has_direct_pct and not has_reset_timestamps:
        return None
    daily_pct = _get_varint(fields, 14)
    weekly_pct = _get_varint(fields, 15)
    return {
        'daily': daily_pct if daily_pct >= 0 else 0,
        'weekly': weekly_pct if weekly_pct >= 0 else 0,
        'daily_reset_at': _normalize_epoch_seconds(_get_varint(fields, 17)),
        'weekly_reset_at': _normalize_epoch_seconds(_get_varint(fields, 18)),
    }


def parse_json_user_status(data):
    if not isinstance(data, dict):
        return None
    user_status = data.get('userStatus') or {}
    plan_status = user_status.get('planStatus') or {}
    plan_info = plan_status.get('planInfo') or {}
    plan_name = plan_info.get('planName', '')
    expired = (plan_name.lower() == 'free')
    available_flow = _safe_int(plan_status.get('availableFlowCredits', -1), -1)
    available_prompt = _safe_int(plan_status.get('availablePromptCredits', -1), -1)
    monthly_flow = _safe_int(plan_info.get('monthlyFlowCredits', 0), 0)
    monthly_prompt = _safe_int(plan_info.get('monthlyPromptCredits', 0), 0)
    # Return percentages (0-100) for UI backward compatibility
    if monthly_flow > 0 and available_flow >= 0:
        daily = min(100, int(round(available_flow / monthly_flow * 100)))
    elif available_flow >= 0:
        daily = 100 if available_flow > 0 else 0
    else:
        daily = -1
    if monthly_prompt > 0 and available_prompt >= 0:
        weekly = min(100, int(round(available_prompt / monthly_prompt * 100)))
    elif available_prompt >= 0:
        weekly = 100 if available_prompt > 0 else 0
    else:
        weekly = -1
    daily_reset_at = _first_available_int(
        [plan_status, plan_info, user_status, data],
        ['dailyQuotaResetAtUnix', 'dailyQuotaResetAt', 'dailyResetAtUnix', 'dailyResetAt'],
        default=0,
    )
    weekly_reset_at = _first_available_int(
        [plan_status, plan_info, user_status, data],
        ['weeklyQuotaResetAtUnix', 'weeklyQuotaResetAt', 'weeklyResetAtUnix', 'weeklyResetAt'],
        default=0,
    )
    return {
        'daily': daily,
        'weekly': weekly,
        'expired': expired,
        'daily_reset_at': daily_reset_at,
        'weekly_reset_at': weekly_reset_at,
        'plan_name': plan_name,
        'available_flow_credits': available_flow,
        'available_prompt_credits': available_prompt,
        'monthly_flow_credits': monthly_flow,
        'monthly_prompt_credits': monthly_prompt,
    }


def parse_protobuf_quota(plan_bytes):
    if isinstance(plan_bytes, bytearray):
        buffer = bytes(plan_bytes)
    elif isinstance(plan_bytes, bytes):
        buffer = plan_bytes
    else:
        try:
            buffer = bytes(plan_bytes or b'')
        except Exception:
            buffer = b''
    if not buffer:
        return _normalize_credits(None)

    try:
        root_fields = _parse_message_fields(buffer, 0, len(buffer))
        root_result = _extract_quota(root_fields)
        if root_result is not None:
            root_result['expired'] = _detect_expired(buffer, root_fields)
            return _normalize_credits(root_result)

        inner_range = _get_nested_range(root_fields, 1)
        if inner_range is not None:
            response_fields = _parse_message_fields(buffer, inner_range[0], inner_range[1])
            inner_result = _extract_quota(response_fields)
            if inner_result is not None:
                inner_result['expired'] = _detect_expired(buffer, response_fields)
                return _normalize_credits(inner_result)
    except Exception:
        pass
    return _normalize_credits(None)


def parse_auth_token_from_response(response_bytes):
    if isinstance(response_bytes, bytearray):
        response_bytes = bytes(response_bytes)
    elif not isinstance(response_bytes, bytes):
        try:
            response_bytes = bytes(response_bytes or b'')
        except Exception:
            response_bytes = b''
    if len(response_bytes) > 2 and response_bytes[0] == 0x0A:
        token_length = 0
        shift = 0
        position = 1
        while position < len(response_bytes):
            byte_value = response_bytes[position]
            position += 1
            token_length |= (byte_value & 0x7F) << shift
            if (byte_value & 0x80) == 0:
                break
            shift += 7
            if shift > 63:
                break
        if token_length > 0 and position + token_length <= len(response_bytes):
            try:
                return response_bytes[position:position + token_length].decode('utf-8')
            except Exception:
                pass
    try:
        text = response_bytes.decode('utf-8', errors='ignore')
    except Exception:
        text = ''
    import re
    match = re.search(r'[A-Za-z0-9_-]{35,60}', text)
    return match.group(0) if match else ''


def fetch_auth_token_with_id_token(email, id_token):
    email = _clean_text(email)
    id_token = _clean_text(id_token)
    if not id_token:
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': 'idToken 为空',
            'error_code': 'missing_id_token',
        }

    request_data = build_protobuf_request(id_token)
    if not request_data:
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': 'protobuf 请求体构造失败',
            'error_code': 'invalid_protobuf_request',
        }

    response, error = _post_binary(
        AUTH_TOKEN_URL,
        request_data,
        headers=_server_auth_headers({
            'Content-Type': 'application/proto',
            'connect-protocol-version': '1',
        }),
        timeout=REQUEST_TIMEOUT,
    )
    if error is not None:
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': f'auth-token 请求异常: {error.get("message", "")}',
            'error_code': 'auth_token_request_failed',
        }

    if not response.get('ok'):
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': f'auth-token 失败: HTTP {response.get("status_code")}',
            'error_code': 'auth_token_http_error',
            'http_status': response.get('status_code'),
            'strategy': response.get('strategy', ''),
            'target_domain': response.get('target_domain', ''),
        }

    auth_token = _clean_text(parse_auth_token_from_response(response.get('content') or b''))
    if not auth_token:
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': 'auth-token 响应中没有有效 token',
            'error_code': 'auth_token_missing_token',
            'strategy': response.get('strategy', ''),
            'target_domain': response.get('target_domain', ''),
        }

    return {
        'status': 'success',
        'email': email,
        'auth_token': auth_token,
        'message': 'auth-token 获取成功',
        'source': 'plugin_auth_token',
        'strategy': response.get('strategy', ''),
        'target_domain': response.get('target_domain', ''),
    }


def login_and_exchange_auth_token(email, password, allow_cache=True):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return {
            'status': 'error',
            'email': email,
            'auth_token': '',
            'message': '邮箱或密码为空',
            'error_code': 'missing_credentials',
            'attempts': [],
        }

    token_result = get_firebase_id_token(email, password, allow_cache=allow_cache)
    attempts = []
    if token_result.get('attempts'):
        attempts.extend(token_result.get('attempts') or [])
    elif token_result.get('source'):
        attempts.append({
            'method': token_result.get('source'),
            'status': token_result.get('status'),
            'message': token_result.get('message', ''),
            'error_code': token_result.get('error_code', ''),
        })
    if token_result.get('status') != 'success':
        token_result['attempts'] = attempts
        token_result['auth_token'] = ''
        return token_result

    auth_result = fetch_auth_token_with_id_token(email, token_result.get('id_token', ''))
    attempts.append({
        'method': 'plugin_auth_token',
        'status': auth_result.get('status'),
        'message': auth_result.get('message', ''),
        'error_code': auth_result.get('error_code', ''),
    })

    if auth_result.get('status') != 'success' and token_result.get('source') == 'plugin_token_cache':
        clear_cached_id_token(email)
        retry_token_result = get_firebase_id_token(email, password, allow_cache=False)
        if retry_token_result.get('attempts'):
            attempts.extend(retry_token_result.get('attempts') or [])
        elif retry_token_result.get('source'):
            attempts.append({
                'method': retry_token_result.get('source'),
                'status': retry_token_result.get('status'),
                'message': retry_token_result.get('message', ''),
                'error_code': retry_token_result.get('error_code', ''),
            })
        if retry_token_result.get('status') == 'success':
            retry_auth_result = fetch_auth_token_with_id_token(email, retry_token_result.get('id_token', ''))
            attempts.append({
                'method': 'plugin_auth_token',
                'status': retry_auth_result.get('status'),
                'message': retry_auth_result.get('message', ''),
                'error_code': retry_auth_result.get('error_code', ''),
            })
            auth_result = retry_auth_result
            token_result = retry_token_result
        else:
            auth_result = {
                'status': 'error',
                'email': email,
                'auth_token': '',
                'message': retry_token_result.get('message', ''),
                'error_code': retry_token_result.get('error_code', ''),
            }

    auth_result['attempts'] = attempts
    auth_result['firebase_id_token'] = token_result.get('id_token', '')
    auth_result['id_token_source'] = token_result.get('source', '')
    auth_result['id_token_expire_time'] = token_result.get('expire_time', 0)
    return auth_result


def fetch_quota_with_id_token(email, id_token):
    email = _clean_text(email)
    id_token = _clean_text(id_token)
    if not id_token:
        return _error_result(email, 'idToken 为空', 'missing_id_token')

    request_data = build_protobuf_request(id_token)
    if not request_data:
        return _error_result(email, 'protobuf 请求体构造失败', 'invalid_protobuf_request')

    response, error = _post_binary(
        PLAN_STATUS_URL,
        request_data,
        headers=_server_auth_headers({
            'Content-Type': 'application/proto',
            'connect-protocol-version': '1',
        }),
        timeout=REQUEST_TIMEOUT,
    )
    if error is not None:
        return _error_result(email, f'plan-status 请求异常: {error.get("message", "")}', 'plan_status_request_failed')

    if not response.get('ok'):
        return _error_result(
            email,
            f'plan-status 失败: HTTP {response.get("status_code")}',
            'plan_status_http_error',
            http_status=response.get('status_code'),
            response_preview=(response.get('content') or b'')[:120].hex(),
            strategy=response.get('strategy', ''),
            target_domain=response.get('target_domain', ''),
        )

    content = response.get('content') or b''
    credits = None
    try:
        import json as _json
        json_data = _json.loads(content)
        credits = parse_json_user_status(json_data)
    except Exception:
        pass
    if credits is None:
        credits = parse_protobuf_quota(content)
    return _success_result(
        email,
        credits,
        '额度刷新成功',
        source='plan_status',
        refreshed_at=int(time.time()),
        strategy=response.get('strategy', ''),
        target_domain=response.get('target_domain', ''),
    )


def refresh_account_quota(email, password):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, '邮箱或密码为空', 'missing_credentials')

    token_result = get_firebase_id_token(email, password)
    if token_result.get('status') != 'success':
        return token_result

    quota_result = fetch_quota_with_id_token(email, token_result.get('id_token', ''))
    if quota_result.get('status') != 'success' and token_result.get('source') == 'plugin_token_cache':
        clear_cached_id_token(email)
        retry_token_result = get_firebase_id_token(email, password, allow_cache=False)
        if retry_token_result.get('status') == 'success':
            quota_result = fetch_quota_with_id_token(email, retry_token_result.get('id_token', ''))
            token_result = retry_token_result
    quota_result['id_token_source'] = token_result.get('source', '')
    if token_result.get('attempts'):
        quota_result['id_token_attempts'] = token_result.get('attempts')
    return quota_result


def refresh_accounts_quota(accounts):
    results = []
    success = []
    failed = []
    for account in accounts or []:
        if not isinstance(account, dict):
            continue
        email = _clean_text(account.get('email'))
        password = _clean_text(account.get('password'))
        result = refresh_account_quota(email, password)
        results.append(result)
        if result.get('status') == 'success':
            success.append(result.get('email', ''))
        else:
            failed.append({
                'email': result.get('email', ''),
                'reason': result.get('error_code') or result.get('message', ''),
                'message': result.get('message', ''),
            })
    if results and success and failed:
        status = 'partial_success'
    elif failed:
        status = 'error'
    elif results:
        status = 'success'
    else:
        status = 'no_action'
    return {
        'status': status,
        'total': len(results),
        'success_count': len(success),
        'failed_count': len(failed),
        'success': success,
        'failed': failed,
        'results': results,
    }
