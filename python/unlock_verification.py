"""Observe Windows session state without sending input or reading credentials."""
import ctypes
from ctypes import wintypes
import os
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class SessionSnapshot:
    session_id: int = 0xFFFFFFFF
    unlocked: bool = False
    active: bool = False
    has_user: bool = False


def query_console_session():
    if os.name != "nt":
        return SessionSnapshot()

    class SessionInfo(ctypes.Structure):
        _fields_ = [
            ("SessionId", wintypes.DWORD), ("SessionState", ctypes.c_int),
            ("SessionFlags", wintypes.LONG), ("WinStationName", wintypes.WCHAR * 33),
            ("UserName", wintypes.WCHAR * 21), ("DomainName", wintypes.WCHAR * 18),
            ("Times", ctypes.c_longlong * 5), ("Counters", wintypes.DWORD * 6),
        ]

    class SessionInfoEx(ctypes.Structure):
        _fields_ = [("Level", wintypes.DWORD), ("Data", SessionInfo)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    wts = ctypes.WinDLL("wtsapi32", use_last_error=True)
    kernel.WTSGetActiveConsoleSessionId.restype = wintypes.DWORD
    session_id = kernel.WTSGetActiveConsoleSessionId()
    if session_id == 0xFFFFFFFF:
        return SessionSnapshot()
    wts.WTSQuerySessionInformationW.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_int,
                                              ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)]
    wts.WTSQuerySessionInformationW.restype = wintypes.BOOL
    wts.WTSFreeMemory.argtypes = [ctypes.c_void_p]
    pointer = ctypes.c_void_p()
    length = wintypes.DWORD()
    try:
        if not wts.WTSQuerySessionInformationW(None, session_id, 25, ctypes.byref(pointer), ctypes.byref(length)):
            return SessionSnapshot(session_id)
        if not pointer.value or length.value < ctypes.sizeof(SessionInfoEx):
            return SessionSnapshot(session_id)
        info = ctypes.cast(pointer, ctypes.POINTER(SessionInfoEx)).contents
        if info.Level != 1 or info.Data.SessionId != session_id:
            return SessionSnapshot(session_id)
        return SessionSnapshot(session_id, info.Data.SessionFlags == 1,
                               info.Data.SessionState == 0, bool(info.Data.UserName))
    finally:
        if pointer.value:
            wts.WTSFreeMemory(pointer)


def wait_for_unlock(expected_session, timeout=8.0, query=query_console_session,
                    clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while True:
        state = query()
        if (expected_session != 0xFFFFFFFF and state.session_id == expected_session
                and state.unlocked and state.active and state.has_user):
            return True
        remaining = deadline - clock()
        if remaining <= 0:
            return False
        sleep(min(0.1, remaining))


def confirm_unlock_result(result, expected_session):
    # Updated native helpers already queried WTS from SYSTEM in the target session.
    if result.get("message") in ("unlock_confirmed", "already_unlocked"):
        return dict(result, status="unlock_confirmed")
    if not wait_for_unlock(expected_session):
        raise RuntimeError("Unlock input was sent, but Windows unlock could not be confirmed")
    return dict(result, status="unlock_confirmed")
