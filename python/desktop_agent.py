import sys
import os
import json
import base64
import time
import io
import hashlib
import ctypes
import subprocess
from pathlib import Path
from ctypes import wintypes

import uiautomation as auto
import pyautogui
from mss import mss

try:
    import pyperclip
except Exception:
    pyperclip = None


def eprint(*args, **kwargs):
    """Print to stderr for debugging without interfering with stdout JSON."""
    print(*args, file=sys.stderr, **kwargs)


class DesktopAgent:
    def __init__(self):
        self._enable_dpi_awareness()
        auto.SetGlobalSearchTimeout(1.0)
        pyautogui.FAILSAFE = True
        pyautogui.PAUSE = 0.05
        self.node_cache = {}
        self.active_window_info = {}
        self.last_screenshot_info = {}
        self.last_virtual_bounds = self._virtual_desktop_bounds()
        self.pending_capture_bounds = None

    def run(self):
        eprint("Python bridge starting up. Waiting for JSON commands on stdin...")
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            cmd_id = None
            try:
                command = json.loads(line)
                cmd_id = command.get("id")
                action = command.get("action")

                if action == "ping":
                    self.send_response(cmd_id, success=True, data="pong")
                elif action == "get_screen_state":
                    self.handle_get_screen_state(command)
                elif action == "execute_action":
                    self.handle_execute_action(command)
                elif action == "list_apps":
                    self.handle_list_apps(command)
                elif action == "template_match":
                    self.handle_template_match(command)
                else:
                    self.send_response(cmd_id, success=False, error=f"Unknown action: {action}")
            except Exception as exc:
                eprint(f"Error processing command {line}: {exc}")
                self.send_response(cmd_id, success=False, error=str(exc))

    def send_response(self, cmd_id, success, data=None, error=None):
        response = {"id": cmd_id, "success": success}
        if success and data is not None:
            response["data"] = data
        if not success and error:
            response["error"] = error

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()

    def handle_get_screen_state(self, command):
        tier = command.get("payload", {}).get("tier", "accessibilityOnly")
        eprint(f"Getting screen state with tier: {tier}")

        elements = self._get_accessibility_tree()
        left, top, right, bottom = self._virtual_desktop_bounds()
        self.last_virtual_bounds = (left, top, right, bottom)
        screen_width = right - left + 1
        screen_height = bottom - top + 1
        mouse_x, mouse_y = pyautogui.position()
        screenshot = self._capture_screenshot(tier)

        data = {
            "elements": elements,
            "screenWidth": screen_width,
            "screenHeight": screen_height,
            "screenLeft": left,
            "screenTop": top,
            "mouseX": mouse_x,
            "mouseY": mouse_y,
            "elementTreeHash": self._hash_json(elements),
            "activeWindowTitle": self.active_window_info.get("title"),
            "activeWindowClassName": self.active_window_info.get("className"),
            "activeWindowProcessId": self.active_window_info.get("processId"),
            "screenshotBase64": screenshot.get("base64"),
            "screenshotHash": screenshot.get("hash"),
            "screenshotWidth": screenshot.get("width"),
            "screenshotHeight": screenshot.get("height"),
            "screenshotSource": screenshot.get("source"),
            "screenshotError": screenshot.get("error"),
        }
        self.send_response(command.get("id"), success=True, data=data)

    def handle_list_apps(self, command):
        apps = self._list_installed_apps()
        self.send_response(command.get("id"), success=True, data={"apps": apps})

    def handle_execute_action(self, command):
        payload = command.get("payload", {})
        action_type = payload.get("type")
        started = time.monotonic()

        try:
            if action_type == "wait":
                duration_ms = int(payload.get("durationMs") or 1000)
                time.sleep(max(0, min(duration_ms, 10000)) / 1000.0)
            elif action_type in ("click", "double_click", "right_click"):
                clicks = 2 if action_type == "double_click" else 1
                button = "right" if action_type == "right_click" else payload.get("button") or "left"
                self._click(payload, clicks=clicks, button=button)
            elif action_type == "drag":
                self._drag(payload)
            elif action_type == "type":
                if self._has_start_target(payload):
                    self._click(payload, clicks=1, button="left")
                    time.sleep(0.1)
                self._type_text(str(payload.get("text") or ""))
            elif action_type == "scroll":
                self._scroll(payload)
            elif action_type == "hotkey":
                keys = payload.get("keys") or []
                if not keys:
                    raise ValueError("hotkey requires keys")
                pyautogui.hotkey(*[str(k).lower() for k in keys])
            elif action_type == "launch_app":
                self._launch_app(payload)
            elif action_type == "done":
                eprint("Agent indicates task is complete.")
            else:
                raise ValueError(f"Unsupported action: {action_type}")

            mouse_x, mouse_y = pyautogui.position()
            self.send_response(command.get("id"), success=True, data={
                "status": "executed",
                "action": action_type,
                "durationMs": int((time.monotonic() - started) * 1000),
                "mouseX": mouse_x,
                "mouseY": mouse_y,
            })
        except Exception as exc:
            eprint(f"Action execution error: {exc}")
            self.send_response(command.get("id"), success=False, error=str(exc))

    def _list_installed_apps(self):
        if sys.platform == "win32":
            return self._list_windows_apps()
        if sys.platform == "darwin":
            return self._list_macos_apps()
        return self._list_linux_apps()

    def _list_windows_apps(self):
        roots = []
        appdata = os.environ.get("APPDATA")
        programdata = os.environ.get("PROGRAMDATA")
        public = os.environ.get("PUBLIC")
        if appdata:
            roots.append(Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs")
        if programdata:
            roots.append(Path(programdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs")
        roots.append(Path.home() / "Desktop")
        if public:
            roots.append(Path(public) / "Desktop")

        apps = []
        seen = set()
        allowed = {".lnk", ".exe", ".bat", ".cmd", ".appref-ms", ".url"}
        blocked_words = ("uninstall", "readme", "help", "documentation")
        for root in roots:
            if not root.exists():
                continue
            try:
                candidates = root.rglob("*")
            except Exception:
                continue
            for path in candidates:
                try:
                    if not path.is_file() or path.suffix.lower() not in allowed:
                        continue
                    name = path.stem.strip()
                    if not name or name.lower().startswith(blocked_words):
                        continue
                    key = (name.lower(), str(path).lower())
                    if key in seen:
                        continue
                    seen.add(key)
                    apps.append({
                        "name": name,
                        "path": str(path),
                        "source": "startMenu" if "Start Menu" in str(path) else "desktop",
                    })
                except Exception:
                    continue

        apps.sort(key=lambda item: item["name"].lower())
        return apps[:750]

    def _list_macos_apps(self):
        apps = []
        seen = set()
        for root in (Path("/Applications"), Path.home() / "Applications"):
            if not root.exists():
                continue
            for path in root.glob("*.app"):
                name = path.stem.strip()
                key = str(path).lower()
                if name and key not in seen:
                    seen.add(key)
                    apps.append({"name": name, "path": str(path), "source": "applications"})
        apps.sort(key=lambda item: item["name"].lower())
        return apps

    def _list_linux_apps(self):
        apps = []
        seen = set()
        roots = [Path("/usr/share/applications"), Path.home() / ".local" / "share" / "applications"]
        for root in roots:
            if not root.exists():
                continue
            for path in root.glob("*.desktop"):
                try:
                    parsed = self._parse_desktop_file(path)
                    name = parsed.get("Name") or path.stem
                    exec_cmd = parsed.get("Exec") or str(path)
                    key = name.lower()
                    if name and key not in seen:
                        seen.add(key)
                        apps.append({"name": name, "path": exec_cmd, "source": "desktopFile"})
                except Exception:
                    continue
        apps.sort(key=lambda item: item["name"].lower())
        return apps

    def _parse_desktop_file(self, path):
        data = {}
        for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in ("Name", "Exec") and key not in data:
                data[key] = value.strip()
        return data

    def _launch_app(self, payload):
        app_path = str(payload.get("appPath") or payload.get("path") or "").strip()
        app_name = str(payload.get("appName") or payload.get("text") or "").strip()

        if app_path:
            self._launch_path(app_path)
            return
        if app_name:
            self._launch_by_search(app_name)
            return
        raise ValueError("launch_app requires appPath or appName")

    def _launch_path(self, app_path):
        if sys.platform == "win32":
            os.startfile(app_path)  # noqa: S606 - user-selected local shortcut/path
            return
        if sys.platform == "darwin":
            subprocess.Popen(["open", app_path])
            return
        command = app_path
        if app_path.endswith(".desktop") and Path(app_path).exists():
            command = self._parse_desktop_file(Path(app_path)).get("Exec") or app_path
        command = self._clean_desktop_exec(command)
        subprocess.Popen(command, shell=True)

    def _launch_by_search(self, app_name):
        if sys.platform == "darwin":
            pyautogui.hotkey("command", "space")
        elif sys.platform == "win32":
            pyautogui.hotkey("win")
        else:
            pyautogui.hotkey("alt", "f2")
        time.sleep(0.4)
        self._type_text(app_name)
        time.sleep(0.4)
        pyautogui.hotkey("enter")

    def _clean_desktop_exec(self, command):
        for token in ("%f", "%F", "%u", "%U", "%i", "%c", "%k"):
            command = command.replace(token, "")
        return command.strip()

    def _get_accessibility_tree(self):
        """Walk the UIA tree and return actionable elements safely."""
        self.node_cache.clear()
        self.active_window_info = {}
        elements = []
        node_id_counter = 0

        root = auto.GetRootControl()
        fg_win = auto.GetForegroundControl()

        if fg_win:
            try:
                if fg_win.ControlType == auto.ControlType.ToolTipControl:
                    parent = fg_win.GetParentControl()
                    if parent:
                        fg_win = parent.GetTopLevelControl() or parent
                    else:
                        fg_win = root
            except Exception:
                pass

        if not fg_win:
            fg_win = root

        self.active_window_info = {
            "title": self._safe_attr(fg_win, "Name", ""),
            "className": self._safe_attr(fg_win, "ClassName", ""),
            "processId": self._safe_attr(fg_win, "ProcessId", 0),
            "handle": self._safe_attr(fg_win, "NativeWindowHandle", 0),
        }

        clickable_types = self._control_type_set([
            "ButtonControl",
            "MenuItemControl",
            "TabItemControl",
            "HyperlinkControl",
            "ListItemControl",
            "CheckBoxControl",
            "RadioButtonControl",
            "TreeItemControl",
            "DataItemControl",
            "SplitButtonControl",
        ])
        focusable_types = self._control_type_set([
            "EditControl",
            "ComboBoxControl",
            "DocumentControl",
        ])
        canvas_like_types = self._control_type_set([
            "PaneControl",
            "CustomControl",
            "ImageControl",
            "DocumentControl",
        ])

        def walk(control, depth, path="0"):
            nonlocal node_id_counter
            if depth > 14 or not control:
                return

            try:
                rect = control.BoundingRectangle
                if rect.width() > 0 and rect.height() > 0:
                    control_type = control.ControlType
                    is_clickable = control_type in clickable_types
                    is_focusable = control_type in focusable_types
                    is_canvas_like = (
                        control_type in canvas_like_types
                        and rect.width() >= 120
                        and rect.height() >= 120
                    )

                    name = self._truncate(self._safe_attr(control, "Name", ""))
                    value = ""
                    try:
                        value_pattern = control.GetValuePattern()
                        if value_pattern:
                            value = self._truncate(value_pattern.Value)
                    except Exception:
                        pass

                    if name or value or is_clickable or is_focusable or is_canvas_like:
                        is_clickable = is_clickable or is_canvas_like
                        node_id = f"node_{node_id_counter}"
                        node_id_counter += 1
                        automation_id = self._safe_attr(control, "AutomationId", "")
                        class_name = self._safe_attr(control, "ClassName", "")
                        framework_id = self._safe_attr(control, "FrameworkId", "")
                        process_id = self._safe_attr(control, "ProcessId", 0)
                        stable_id = self._stable_id(
                            control=control,
                            rect=rect,
                            path=path,
                            name=name,
                            automation_id=automation_id,
                            class_name=class_name,
                        )

                        self.node_cache[node_id] = control
                        self.node_cache[stable_id] = control

                        elements.append({
                            "id": node_id,
                            "stableId": stable_id,
                            "name": name,
                            "role": self._get_role_name(control_type),
                            "type": str(control_type),
                            "automationId": automation_id,
                            "className": class_name,
                            "frameworkId": framework_id,
                            "processId": process_id,
                            "hierarchyPath": path,
                            "boundingBox": {
                                "x": rect.left,
                                "y": rect.top,
                                "width": rect.width(),
                                "height": rect.height(),
                            },
                            "isClickable": is_clickable,
                            "isKeyboardFocusable": is_focusable,
                            "isEnabled": bool(self._safe_attr(control, "IsEnabled", True)),
                            "isFocused": bool(self._safe_attr(control, "HasKeyboardFocus", False)),
                            "isOffscreen": bool(self._safe_attr(control, "IsOffscreen", False)),
                            "value": value,
                        })
            except Exception:
                pass

            try:
                children = control.GetChildren()
            except Exception:
                children = []

            for index, child in enumerate(children):
                walk(child, depth + 1, f"{path}/{index}")

        walk(fg_win, 0)
        return elements

    def _click(self, payload, clicks=1, button="left"):
        x, y = self._resolve_point(payload)
        pyautogui.moveTo(x, y, duration=0.12)
        pyautogui.click(x=x, y=y, clicks=clicks, interval=0.05, button=button)

    def _enable_dpi_awareness(self):
        if sys.platform != "win32":
            return
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            try:
                ctypes.windll.user32.SetProcessDPIAware()
            except Exception:
                pass

    def _drag(self, payload):
        points = self._resolve_drag_path(payload)
        duration = int(payload.get("durationMs") or 350) / 1000.0
        duration = max(0.1, min(duration, 5.0))
        button = payload.get("button") or "left"
        sampled_points = self._sample_path(points, max_step_px=6)
        step_duration = max(0.005, duration / max(1, len(sampled_points) - 1))

        start_x, start_y = sampled_points[0]
        pyautogui.moveTo(start_x, start_y, duration=0.12)
        time.sleep(0.08)
        try:
            self._native_drag(sampled_points, button=button, step_duration=step_duration)
        except Exception as native_exc:
            eprint(f"Native drag failed, falling back to pyautogui: {native_exc}")
            pyautogui.mouseDown(x=start_x, y=start_y, button=button)
            try:
                for x, y in sampled_points[1:]:
                    pyautogui.moveTo(x, y, duration=step_duration)
                time.sleep(0.04)
            finally:
                pyautogui.mouseUp(button=button)

    def _scroll(self, payload):
        if self._has_start_target(payload):
            x, y = self._resolve_point(payload)
            pyautogui.moveTo(x, y, duration=0.08)

        direction = str(payload.get("direction") or "down").lower()
        amount = int(payload.get("amount") or 600)
        wheel_clicks = max(1, min(20, round(abs(amount) / 120)))

        if direction == "down":
            pyautogui.scroll(-wheel_clicks)
        elif direction == "up":
            pyautogui.scroll(wheel_clicks)
        elif direction in ("left", "right"):
            clicks = -wheel_clicks if direction == "left" else wheel_clicks
            if hasattr(pyautogui, "hscroll"):
                pyautogui.hscroll(clicks)
            else:
                pyautogui.keyDown("shift")
                try:
                    pyautogui.scroll(clicks)
                finally:
                    pyautogui.keyUp("shift")
        else:
            raise ValueError(f"Unsupported scroll direction: {direction}")

    def _type_text(self, text):
        if not text:
            return

        should_paste = (
            pyperclip is not None
            and (len(text) > 40 or "\n" in text or any(ord(ch) > 126 for ch in text))
        )

        if should_paste:
            previous = None
            try:
                previous = pyperclip.paste()
                pyperclip.copy(text)
                pyautogui.hotkey("ctrl", "v")
                time.sleep(0.05)
            finally:
                if previous is not None:
                    try:
                        pyperclip.copy(previous)
                    except Exception:
                        pass
            return

        pyautogui.write(text, interval=0.01)

    def _resolve_point(self, payload, end=False):
        stable_key = "endTargetStableId" if end else "targetStableId"
        index_key = "endTargetIndex" if end else "targetIndex"
        x_key = "endX" if end else "x"
        y_key = "endY" if end else "y"

        stable_id = payload.get(stable_key)
        target_index = payload.get(index_key)

        if stable_id:
            control = self.node_cache.get(stable_id)
            if not control:
                raise KeyError(f"Element {stable_id} not found in cache")
            return self._control_center(control)

        if target_index is not None:
            node_id = f"node_{int(target_index)}"
            control = self.node_cache.get(node_id)
            if not control:
                raise KeyError(f"Element {node_id} not found in cache")
            return self._control_center(control)

        x = payload.get(x_key)
        y = payload.get(y_key)
        if x is None or y is None:
            label = "end point" if end else "start point"
            raise ValueError(f"Missing {label}: provide element target or coordinates")

        x = int(round(float(x)))
        y = int(round(float(y)))
        x, y = self._map_screenshot_point_if_needed(x, y)
        self._assert_point_in_virtual_desktop(x, y)
        return x, y

    def _resolve_drag_path(self, payload):
        raw_path = payload.get("path")
        if raw_path is not None:
            points = []
            if not isinstance(raw_path, list):
                raise ValueError("drag path must be a list of points")
            for raw_point in raw_path:
                if isinstance(raw_point, dict):
                    x = raw_point.get("x")
                    y = raw_point.get("y")
                elif isinstance(raw_point, (list, tuple)) and len(raw_point) >= 2:
                    x, y = raw_point[0], raw_point[1]
                else:
                    raise ValueError("drag path points must be {x, y} objects or [x, y] pairs")
                if x is None or y is None:
                    raise ValueError("drag path point is missing x or y")
                x = int(round(float(x)))
                y = int(round(float(y)))
                x, y = self._map_screenshot_point_if_needed(x, y)
                self._assert_point_in_virtual_desktop(x, y)
                points.append((x, y))
            if len(points) < 2:
                raise ValueError("drag path requires at least two points")
            return points

        return [self._resolve_point(payload), self._resolve_point(payload, end=True)]

    def _sample_path(self, points, max_step_px=6):
        sampled = [points[0]]
        for start, end in zip(points, points[1:]):
            start_x, start_y = start
            end_x, end_y = end
            dx = end_x - start_x
            dy = end_y - start_y
            distance = max(abs(dx), abs(dy))
            steps = max(1, int(distance / max_step_px))
            for step in range(1, steps + 1):
                t = step / steps
                sampled.append((
                    int(round(start_x + dx * t)),
                    int(round(start_y + dy * t)),
                ))
        return sampled

    def _native_drag(self, points, button="left", step_duration=0.02):
        if sys.platform != "win32":
            raise RuntimeError("native drag is only available on Windows")
        if len(points) < 2:
            raise ValueError("native drag requires at least two points")

        down_flag, up_flag = self._native_button_flags(button)
        start_x, start_y = points[0]
        self._send_mouse_move(start_x, start_y)
        time.sleep(0.06)
        self._send_mouse_event(down_flag)
        try:
            for x, y in points[1:]:
                self._send_mouse_move(x, y)
                time.sleep(step_duration)
            time.sleep(0.04)
        finally:
            self._send_mouse_event(up_flag)

    def _native_button_flags(self, button):
        normalized = str(button or "left").lower()
        if normalized == "left":
            return 0x0002, 0x0004
        if normalized == "right":
            return 0x0008, 0x0010
        if normalized == "middle":
            return 0x0020, 0x0040
        raise ValueError(f"unsupported mouse button: {button}")

    def _send_mouse_move(self, x, y):
        left, top, right, bottom = self._virtual_desktop_bounds()
        width = max(1, right - left)
        height = max(1, bottom - top)
        normalized_x = int(round(((x - left) * 65535) / width))
        normalized_y = int(round(((y - top) * 65535) / height))
        self._send_mouse_event(
            0x0001 | 0x8000 | 0x4000,
            dx=normalized_x,
            dy=normalized_y,
        )

    def _send_mouse_event(self, flags, dx=0, dy=0, mouse_data=0):
        ulong_ptr = ctypes.c_ulonglong if ctypes.sizeof(ctypes.c_void_p) == 8 else ctypes.c_ulong

        class MOUSEINPUT(ctypes.Structure):
            _fields_ = [
                ("dx", wintypes.LONG),
                ("dy", wintypes.LONG),
                ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD),
                ("dwExtraInfo", ulong_ptr),
            ]

        class INPUT_UNION(ctypes.Union):
            _fields_ = [("mi", MOUSEINPUT)]

        class INPUT(ctypes.Structure):
            _fields_ = [
                ("type", wintypes.DWORD),
                ("union", INPUT_UNION),
            ]

        event = INPUT()
        event.type = 0
        event.union.mi = MOUSEINPUT(dx, dy, mouse_data, flags, 0, 0)

        sent = ctypes.windll.user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(INPUT))
        if sent != 1:
            raise ctypes.WinError(ctypes.windll.kernel32.GetLastError())

    def _control_center(self, control):
        rect = control.BoundingRectangle
        x = rect.left + (rect.width() // 2)
        y = rect.top + (rect.height() // 2)
        self._assert_point_in_virtual_desktop(x, y)
        return x, y

    def _map_screenshot_point_if_needed(self, x, y):
        info = self.last_screenshot_info or {}
        screenshot_width = info.get("width")
        screenshot_height = info.get("height")
        virtual_left = info.get("virtualLeft")
        virtual_top = info.get("virtualTop")
        virtual_width = info.get("virtualWidth")
        virtual_height = info.get("virtualHeight")

        if not all([
            screenshot_width,
            screenshot_height,
            virtual_width,
            virtual_height,
        ]):
            return x, y

        if x < 0 or y < 0 or x > screenshot_width or y > screenshot_height:
            return x, y

        if screenshot_width == virtual_width and screenshot_height == virtual_height:
            return x + int(virtual_left or 0), y + int(virtual_top or 0)

        mapped_x = int(round((x / screenshot_width) * virtual_width)) + int(virtual_left or 0)
        mapped_y = int(round((y / screenshot_height) * virtual_height)) + int(virtual_top or 0)
        return mapped_x, mapped_y

    def _has_start_target(self, payload):
        return (
            payload.get("targetStableId")
            or payload.get("targetIndex") is not None
            or (payload.get("x") is not None and payload.get("y") is not None)
        )

    def _assert_point_in_virtual_desktop(self, x, y):
        left, top, right, bottom = self._virtual_desktop_bounds()
        if x < left or x > right or y < top or y > bottom:
            raise ValueError(
                f"Point ({x}, {y}) is outside virtual desktop "
                f"({left}, {top})-({right}, {bottom})"
            )

    def _virtual_desktop_bounds(self):
        try:
            with mss() as sct:
                monitor = sct.monitors[0]
                left = int(monitor.get("left", 0))
                top = int(monitor.get("top", 0))
                width = int(monitor.get("width", 0))
                height = int(monitor.get("height", 0))
                return left, top, left + width - 1, top + height - 1
        except Exception:
            width, height = pyautogui.size()
            return 0, 0, width - 1, height - 1

    def handle_template_match(self, command):
        """Template matching: find a template image on screen using OpenCV."""
        cmd_id = command.get("id")
        payload = command.get("payload", {})
        template_path = payload.get("templatePath", "")
        threshold = payload.get("threshold", 0.8)
        search_region = payload.get("searchRegion")

        try:
            import cv2
            import numpy as np

            # Capture the screen
            with mss() as sct:
                monitor = sct.monitors[0]
                screenshot = sct.grab(monitor)
                screen_img = np.array(screenshot)
                screen_img = cv2.cvtColor(screen_img, cv2.COLOR_BGRA2BGR)

            # Optionally crop to search region
            if search_region:
                rx = search_region.get("x", 0)
                ry = search_region.get("y", 0)
                rw = search_region.get("width", screen_img.shape[1])
                rh = search_region.get("height", screen_img.shape[0])
                screen_img = screen_img[ry:ry+rh, rx:rx+rw]
            else:
                rx, ry = 0, 0

            # Load template
            if not os.path.exists(template_path):
                self.send_response(cmd_id, success=False,
                                   error=f"Template file not found: {template_path}")
                return

            template = cv2.imread(template_path)
            if template is None:
                self.send_response(cmd_id, success=False,
                                   error=f"Failed to read template: {template_path}")
                return

            # Run template matching
            result = cv2.matchTemplate(screen_img, template, cv2.TM_CCOEFF_NORMED)
            _, max_val, _, max_loc = cv2.minMaxLoc(result)

            if max_val >= threshold:
                # Calculate center of the match
                th, tw = template.shape[:2]
                center_x = max_loc[0] + tw // 2 + rx
                center_y = max_loc[1] + th // 2 + ry

                self.send_response(cmd_id, success=True, data={
                    "found": True,
                    "x": center_x,
                    "y": center_y,
                    "confidence": round(float(max_val), 4),
                    "matchWidth": tw,
                    "matchHeight": th,
                })
            else:
                self.send_response(cmd_id, success=True, data={
                    "found": False,
                    "confidence": round(float(max_val), 4),
                })

        except ImportError:
            self.send_response(cmd_id, success=False,
                               error="OpenCV (cv2) is not installed. Install with: pip install opencv-python")
        except Exception as exc:
            self.send_response(cmd_id, success=False, error=str(exc))

    def _capture_screenshot(self, tier):
        if tier == "accessibilityOnly":
            self.last_screenshot_info = {}
            return {}

        errors = []
        self.pending_capture_bounds = None
        for source, capture in (
            ("mss", self._capture_with_mss),
            ("pyautogui", self._capture_with_pyautogui),
            ("imagegrab", self._capture_with_imagegrab),
            ("printwindow", self._capture_with_printwindow),
        ):
            try:
                image = capture()
                return self._encode_screenshot(image, tier=tier, source=source)
            except Exception as exc:
                errors.append(f"{source}: {exc}")
                eprint(f"Screenshot capture failed via {source}: {exc}")

        return {"error": "; ".join(errors)}

    def _capture_with_mss(self):
        from PIL import Image

        with mss() as sct:
            monitor = sct.monitors[0] if sct.monitors else {"left": 0, "top": 0, "width": 0, "height": 0}
            left = int(monitor.get("left", 0))
            top = int(monitor.get("top", 0))
            width = int(monitor.get("width", 0))
            height = int(monitor.get("height", 0))
            self.pending_capture_bounds = (left, top, left + width - 1, top + height - 1)
            shot = sct.grab(monitor)
            return Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

    def _capture_with_pyautogui(self):
        image = pyautogui.screenshot()
        self.pending_capture_bounds = (0, 0, image.width - 1, image.height - 1)
        return image

    def _capture_with_imagegrab(self):
        from PIL import ImageGrab

        self.pending_capture_bounds = self.last_virtual_bounds
        return ImageGrab.grab(all_screens=True)

    def _capture_with_printwindow(self):
        import ctypes
        from ctypes import wintypes
        from PIL import Image

        hwnd = int(self.active_window_info.get("handle") or 0)
        if not hwnd:
            raise RuntimeError("active window handle is unavailable")

        user32 = ctypes.windll.user32
        gdi32 = ctypes.windll.gdi32

        class RECT(ctypes.Structure):
            _fields_ = [
                ("left", wintypes.LONG),
                ("top", wintypes.LONG),
                ("right", wintypes.LONG),
                ("bottom", wintypes.LONG),
            ]

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [
                ("biSize", wintypes.DWORD),
                ("biWidth", wintypes.LONG),
                ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD),
                ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD),
            ]

        class BITMAPINFO(ctypes.Structure):
            _fields_ = [
                ("bmiHeader", BITMAPINFOHEADER),
                ("bmiColors", wintypes.DWORD * 3),
            ]

        rect = RECT()
        if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            raise RuntimeError("GetWindowRect failed")

        width = rect.right - rect.left
        height = rect.bottom - rect.top
        if width <= 0 or height <= 0:
            raise RuntimeError(f"invalid active window size: {width}x{height}")
        self.pending_capture_bounds = (rect.left, rect.top, rect.right - 1, rect.bottom - 1)

        window_dc = user32.GetWindowDC(hwnd)
        if not window_dc:
            raise RuntimeError("GetWindowDC failed")

        memory_dc = gdi32.CreateCompatibleDC(window_dc)
        bitmap = gdi32.CreateCompatibleBitmap(window_dc, width, height)
        old_object = gdi32.SelectObject(memory_dc, bitmap)

        try:
            captured = user32.PrintWindow(hwnd, memory_dc, 2)
            if not captured:
                captured = user32.PrintWindow(hwnd, memory_dc, 0)
            if not captured:
                raise RuntimeError("PrintWindow failed")

            bmi = BITMAPINFO()
            bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            bmi.bmiHeader.biWidth = width
            bmi.bmiHeader.biHeight = -height
            bmi.bmiHeader.biPlanes = 1
            bmi.bmiHeader.biBitCount = 32
            bmi.bmiHeader.biCompression = 0

            buffer = ctypes.create_string_buffer(width * height * 4)
            result = gdi32.GetDIBits(
                memory_dc,
                bitmap,
                0,
                height,
                buffer,
                ctypes.byref(bmi),
                0,
            )
            if result == 0:
                raise RuntimeError("GetDIBits failed")

            return Image.frombuffer(
                "RGB",
                (width, height),
                buffer,
                "raw",
                "BGRX",
                0,
                1,
            )
        finally:
            if old_object:
                gdi32.SelectObject(memory_dc, old_object)
            if bitmap:
                gdi32.DeleteObject(bitmap)
            if memory_dc:
                gdi32.DeleteDC(memory_dc)
            user32.ReleaseDC(hwnd, window_dc)

    def _encode_screenshot(self, image, tier, source):
        if image.mode != "RGB":
            image = image.convert("RGB")

        left, top, right, bottom = self.pending_capture_bounds or self.last_virtual_bounds
        capture_width = right - left + 1
        capture_height = bottom - top + 1

        max_size = (1280, 720) if tier == "treeWithThumbnail" else (1920, 1080)
        image.thumbnail(max_size)

        with io.BytesIO() as buf:
            image.save(buf, format="PNG", optimize=True)
            raw = buf.getvalue()

        self.last_screenshot_info = {
            "width": image.width,
            "height": image.height,
            "virtualLeft": left,
            "virtualTop": top,
            "virtualWidth": capture_width,
            "virtualHeight": capture_height,
        }

        return {
            "base64": base64.b64encode(raw).decode("utf-8"),
            "hash": hashlib.sha1(raw).hexdigest()[:16],
            "width": image.width,
            "height": image.height,
            "source": source,
        }

    def _get_role_name(self, control_type):
        type_str = str(control_type)
        return type_str.replace("ControlType", "").replace("Control", "")

    def _control_type_set(self, names):
        values = set()
        for name in names:
            value = getattr(auto.ControlType, name, None)
            if value is not None:
                values.add(value)
        return values

    def _safe_attr(self, control, attr_name, default=""):
        try:
            value = getattr(control, attr_name)
            if value is None:
                return default
            return value
        except Exception:
            return default

    def _stable_id(self, control, rect, path, name, automation_id, class_name):
        control_type = self._safe_attr(control, "ControlType")
        process_id = self._safe_attr(control, "ProcessId", "")
        framework_id = self._safe_attr(control, "FrameworkId", "")
        bucketed_bounds = f"{rect.left // 8},{rect.top // 8},{rect.width() // 8},{rect.height() // 8}"
        raw = "|".join([
            str(process_id),
            str(framework_id),
            str(automation_id),
            str(class_name),
            str(control_type),
            str(name or ""),
            bucketed_bounds,
            path,
        ])
        return "uia_" + hashlib.sha1(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]

    def _truncate(self, value, limit=100):
        value = "" if value is None else str(value)
        return value if len(value) <= limit else value[: limit - 3] + "..."

    def _hash_json(self, value):
        raw = json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        return hashlib.sha1(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]


if __name__ == "__main__":
    agent = DesktopAgent()
    agent.run()
