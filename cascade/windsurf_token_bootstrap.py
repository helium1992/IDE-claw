import re
import time

from windsurf_quota_refresh import login_and_exchange_auth_token

FIREBASE_API_KEY = 'AIzaSyDsOl-1XpT5err0Tcnx8FFod1H8gVGIycY'
FIREBASE_SIGNIN_URL = (
    'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword'
    f'?key={FIREBASE_API_KEY}'
)
REGISTER_USER_API = 'https://api.codeium.com/register_user/'
WINDSURF_LOGIN_URL = (
    'https://windsurf.com/account/login'
    '?response_type=token'
    '&redirect_uri=vim-show-auth-token'
    '&state=ide-claw-switcher'
    '&scope=openid%20profile%20email'
    '&redirect_parameters_type=query'
)


def _clean_text(value):
    if value is None:
        return ''
    return str(value).strip()


def _success_result(email, auth_token, method, message, **extra):
    result = {
        'status': 'success',
        'email': _clean_text(email),
        'auth_token': _clean_text(auth_token),
        'method': method,
        'message': message,
    }
    result.update(extra)
    return result


def _error_result(email, method, message, error_code='', **extra):
    result = {
        'status': 'error',
        'email': _clean_text(email),
        'auth_token': '',
        'method': method,
        'message': message,
        'error_code': _clean_text(error_code),
    }
    result.update(extra)
    return result


def _json_preview(payload, limit=240):
    try:
        import json
        text = json.dumps(payload, ensure_ascii=False)
    except Exception:
        text = str(payload)
    return text[:limit]


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


def _is_jwt_like_token(token):
    token = _clean_text(token)
    return token.startswith('eyJ') and token.count('.') >= 2


def _extract_token_from_text(text):
    if not text:
        return ''
    patterns = [
        r'"api_key"\s*:\s*"([^"]{20,})"',
        r'"authToken"\s*:\s*"([^"]{20,})"',
        r'"token"\s*:\s*"([^"]{20,})"',
        r'(ott\$[A-Za-z0-9_\-]{20,})',
        r'(eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,})',
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return _clean_text(match.group(1))
    return ''


def _extract_token_from_url(url):
    url = _clean_text(url)
    if not url:
        return ''
    direct = _extract_token_from_text(url)
    if direct:
        return direct
    match = re.search(r'[?#&](?:token|authToken|api_key)=([^&#]+)', url)
    if match:
        return _clean_text(match.group(1))
    return ''


def exchange_firebase_token(firebase_token):
    firebase_token = _clean_text(firebase_token)
    if not firebase_token:
        return _error_result('', 'exchange', 'firebase token 为空', 'empty_firebase_token')
    try:
        import requests
    except ImportError:
        return _error_result('', 'exchange', 'requests 未安装', 'missing_requests')

    try:
        response = requests.post(
            REGISTER_USER_API,
            json={'firebase_id_token': firebase_token},
            headers={'Content-Type': 'application/json'},
            timeout=20,
        )
    except Exception as exc:
        return _error_result('', 'exchange', f'register_user 请求异常: {exc}', 'exchange_request_failed')

    try:
        payload = response.json()
    except ValueError:
        payload = {'raw': response.text[:200]}

    if response.status_code != 200:
        message = _extract_error_message(payload) or _json_preview(payload)
        return _error_result('', 'exchange', f'register_user 失败: {message}', 'exchange_http_error')

    auth_token = ''
    if isinstance(payload, dict):
        data_payload = payload.get('data') if isinstance(payload.get('data'), dict) else {}
        auth_token = _clean_text(
            payload.get('api_key')
            or payload.get('token')
            or payload.get('authToken')
            or data_payload.get('api_key')
            or data_payload.get('token')
            or data_payload.get('authToken')
        )
    if not auth_token:
        return _error_result('', 'exchange', f'register_user 响应无 token: {_json_preview(payload)}', 'exchange_missing_token')
    return _success_result('', auth_token, 'exchange', 'register_user 成功')


def login_via_api(email, password):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, 'api', '邮箱或密码为空', 'missing_credentials')
    plugin_result = login_and_exchange_auth_token(email, password, allow_cache=True)
    if plugin_result.get('status') != 'success':
        return _error_result(
            email,
            'api',
            plugin_result.get('message') or '插件同款登录链失败',
            plugin_result.get('error_code') or 'plugin_login_failed',
            attempts=plugin_result.get('attempts', []),
        )
    return _success_result(
        email,
        plugin_result.get('auth_token', ''),
        'api',
        '插件同款登录成功',
        firebase_id_token=plugin_result.get('firebase_id_token', ''),
        id_token_source=plugin_result.get('id_token_source', ''),
        attempts=plugin_result.get('attempts', []),
    )


def _extract_token_from_page(page):
    try:
        url = _clean_text(page.url)
    except Exception:
        url = ''
    token = _extract_token_from_url(url)
    if token:
        return token
    try:
        content = page.content()
    except Exception:
        content = ''
    token = _extract_token_from_text(content)
    if token:
        return token
    try:
        local_storage_dump = page.evaluate(
            '() => JSON.stringify({ localStorage: { ...window.localStorage }, sessionStorage: { ...window.sessionStorage } })'
        )
    except Exception:
        local_storage_dump = ''
    return _extract_token_from_text(local_storage_dump)


def _submit_login_form(page, email, password):
    selectors = [
        'input[type="email"]',
        'input[name="email"]',
        'input[placeholder*="email" i]',
        'input[placeholder*="Email" i]',
    ]
    page.wait_for_selector(', '.join(selectors), timeout=12000)
    page.fill(', '.join(selectors), email)
    try:
        page.click(
            'button:has-text("Continue"), button:has-text("Next"), button:has-text("继续"), button[type="submit"]',
            timeout=5000,
        )
        time.sleep(1.2)
    except Exception:
        pass
    page.wait_for_selector('input[type="password"], input[name="password"]', timeout=10000)
    page.fill('input[type="password"], input[name="password"]', password)
    page.click(
        'button[type="submit"], button:has-text("Sign in"), button:has-text("Log in"), button:has-text("Sign In"), button:has-text("Login")',
        timeout=6000,
    )


def _finalize_browser_token(email, raw_token):
    raw_token = _clean_text(raw_token)
    if not raw_token:
        return _error_result(email, 'playwright', '页面中未提取到 token', 'browser_missing_token')
    if _is_jwt_like_token(raw_token):
        exchange_result = exchange_firebase_token(raw_token)
        if exchange_result.get('status') == 'success':
            return _success_result(
                email,
                exchange_result.get('auth_token', ''),
                'playwright',
                'Playwright 登录成功',
                firebase_id_token=raw_token,
            )
    return _success_result(email, raw_token, 'playwright', 'Playwright 登录成功')


def login_via_playwright(email, password, visible=False, timeout_seconds=90):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, 'playwright', '邮箱或密码为空', 'missing_credentials')
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return _error_result(email, 'playwright', 'playwright 未安装', 'missing_playwright')

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=not visible)
            context = browser.new_context()
            page = context.new_page()
            try:
                page.goto(WINDSURF_LOGIN_URL, wait_until='domcontentloaded', timeout=30000)
                time.sleep(2)
                _submit_login_form(page, email, password)
            except Exception as exc:
                browser.close()
                return _error_result(email, 'playwright', f'登录页面交互失败: {exc}', 'browser_interaction_failed')

            raw_token = ''
            deadline = time.time() + max(timeout_seconds, 15)
            while time.time() < deadline:
                raw_token = _extract_token_from_page(page)
                if raw_token:
                    break
                time.sleep(1)

            browser.close()
            return _finalize_browser_token(email, raw_token)
    except Exception as exc:
        return _error_result(email, 'playwright', f'Playwright 登录异常: {exc}', 'playwright_exception')


def bootstrap_one_account(email, password, allow_api=True, allow_playwright=False, visible_browser=False):
    email = _clean_text(email)
    password = _clean_text(password)
    if not email or not password:
        return _error_result(email, 'bootstrap', '邮箱或密码为空', 'missing_credentials', attempts=[])

    attempts = []
    if allow_api:
        api_result = login_via_api(email, password)
        attempts.append({
            'method': 'api',
            'status': api_result.get('status'),
            'message': api_result.get('message', ''),
            'error_code': api_result.get('error_code', ''),
        })
        if api_result.get('status') == 'success':
            api_result['attempts'] = attempts
            return api_result

    if allow_playwright:
        browser_result = login_via_playwright(email, password, visible=visible_browser)
        attempts.append({
            'method': 'playwright',
            'status': browser_result.get('status'),
            'message': browser_result.get('message', ''),
            'error_code': browser_result.get('error_code', ''),
        })
        if browser_result.get('status') == 'success':
            browser_result['attempts'] = attempts
            return browser_result

    message = '；'.join(
        item.get('message')
        for item in attempts
        if item.get('message')
    ) or '未能获取 auth token'
    return _error_result(
        email,
        'bootstrap',
        message,
        attempts[-1].get('error_code') if attempts else 'bootstrap_failed',
        attempts=attempts,
    )


def bootstrap_accounts(accounts, allow_api=True, allow_playwright=False, visible_browser=False):
    results = []
    success = []
    failed = []
    for account in accounts or []:
        if not isinstance(account, dict):
            continue
        email = _clean_text(account.get('email'))
        password = _clean_text(account.get('password'))
        result = bootstrap_one_account(
            email,
            password,
            allow_api=allow_api,
            allow_playwright=allow_playwright,
            visible_browser=visible_browser,
        )
        results.append(result)
        if result.get('status') == 'success':
            success.append(result.get('email', ''))
        else:
            failed.append({
                'email': result.get('email', ''),
                'reason': result.get('error_code') or result.get('message', ''),
                'message': result.get('message', ''),
            })

    if results and failed and success:
        status = 'partial_success'
    elif results and failed:
        status = 'error'
    else:
        status = 'success'

    return {
        'status': status,
        'total': len(results),
        'success_count': len(success),
        'failed_count': len(failed),
        'success': success,
        'failed': failed,
        'results': results,
    }
