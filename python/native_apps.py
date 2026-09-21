"""Discover native launch identities and verify their windows without UIA scans."""
import base64
import ctypes
from ctypes import wintypes
import json
import ntpath
import os
import re
import subprocess
import time


_INVENTORY_SCRIPT = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$apps = [System.Collections.Generic.List[object]]::new()
Get-StartApps | Where-Object { $_.AppID -match '^[^!]+![^!]+$' } | ForEach-Object {
    $apps.Add(@{name=$_.Name; aumid=$_.AppID; kind='packaged'; source='startApps'})
}
$shell = New-Object -ComObject WScript.Shell
$roots = @(
    [Environment]::GetFolderPath('StartMenu'),
    [Environment]::GetFolderPath('CommonStartMenu'),
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('CommonDesktopDirectory')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $link = $shell.CreateShortcut($_.FullName)
            if ($link.TargetPath -and [IO.Path]::GetExtension($link.TargetPath) -eq '.exe') {
                $apps.Add(@{name=$_.BaseName; path=$_.FullName; executable=$link.TargetPath;
                    arguments=$link.Arguments; kind='win32'; source='shortcut'})
            }
        } catch { }
    }
}
ConvertTo-Json -InputObject @($apps.ToArray()) -Depth 3 -Compress
'''


def discover_windows_apps():
    encoded = base64.b64encode(_INVENTORY_SCRIPT.encode('utf-16-le')).decode('ascii')
    result = subprocess.run(
        ['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
        capture_output=True, encoding='utf-8', errors='replace', timeout=15,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), check=True,
    )
    apps = json.loads(result.stdout.lstrip('\ufeff'))
    return [app for app in apps if isinstance(app, dict)]


def normalized_name(name):
    name = re.sub(r'\s+', ' ', str(name).strip()).casefold()
    return re.sub(r'^microsoft\s+', '', name)


def native_identity(app):
    if app.get('kind') == 'packaged' and re.fullmatch(r'[\w.\-]+![\w.\-]+', app.get('aumid', '')):
        return 'aumid:' + app['aumid'].casefold()
    executable = app.get('executable', '')
    args = app.get('arguments') or ''
    # Browser app shortcuts are not native applications, even if backed by an exe.
    if re.search(r'--app(?:-id)?(?:[=\s]|$)|https?://', args, re.I):
        return None
    if app.get('kind') == 'win32' and ntpath.isabs(executable) and executable.lower().endswith('.exe'):
        return 'exe:' + ntpath.normcase(ntpath.normpath(executable))
    return None


def resolve_app(name, apps):
    key = normalized_name(name)
    matches = [app for app in apps if normalized_name(app.get('name', '')) == key and native_identity(app)]
    if not matches:
        raise RuntimeError(f'Installed native app "{name}" was not found. No website was opened.')
    identities = {native_identity(app): app for app in matches}
    if len(identities) != 1:
        raise RuntimeError(f'Multiple native applications match "{name}". Specify the installed application more precisely.')
    return next(iter(identities.values()))


def process_aumid(pid):
    if os.name != 'nt' or not pid:
        return None
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.GetApplicationUserModelId.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.UINT), wintypes.LPWSTR]
    handle = kernel.OpenProcess(0x1000, False, int(pid))
    if not handle:
        return None
    try:
        length = wintypes.UINT(0)
        if kernel.GetApplicationUserModelId(handle, ctypes.byref(length), None) != 122:
            return None
        buffer = ctypes.create_unicode_buffer(length.value)
        if kernel.GetApplicationUserModelId(handle, ctypes.byref(length), buffer) == 0:
            return buffer.value
        return None
    finally:
        kernel.CloseHandle(handle)


def window_matches(app, window, get_aumid=process_aumid):
    identity = native_identity(app)
    if not identity or window.get('isSystemSurface') or window.get('isCloaked'):
        return False
    if identity.startswith('aumid:'):
        return (get_aumid(window.get('processId')) or '').casefold() == app['aumid'].casefold()
    actual = window.get('processPath') or ''
    return bool(actual) and ntpath.normcase(ntpath.normpath(actual)) == identity[4:]


def launch_identity(app):
    if not native_identity(app):
        raise RuntimeError('App has no verified native launch identity')
    path = ('shell:AppsFolder\\' + app['aumid']) if app['kind'] == 'packaged' else app['path']
    os.startfile(path)


def open_verified_app(name, apps, windows, activate, describe, is_foreground,
                      launch=launch_identity, matches=window_matches,
                      clock=time.monotonic, sleep=time.sleep, timeout=10.0):
    app = resolve_app(name, apps)

    def focus_matching_window():
        for window in windows():
            if not matches(app, window):
                continue
            hwnd = window.get('hwnd')
            if not hwnd or not activate(hwnd):
                continue
            observed = describe(hwnd) or {}
            if (matches(app, observed) and observed.get('isVisible')
                    and not observed.get('isMinimized') and is_foreground(hwnd)):
                return {'status': 'verified', 'appName': app['name'],
                        'identity': native_identity(app), 'window': observed}
        return None

    existing = focus_matching_window()
    if existing:
        return existing
    launch(app)
    deadline = clock() + timeout
    while clock() < deadline:
        result = focus_matching_window()
        if result:
            return result
        sleep(min(0.2, max(0, deadline - clock())))
    raise RuntimeError(f'Launched "{name}", but its native foreground window could not be verified.')
