import sys
import os
import json
import base64
import time
import io
import hashlib
import ctypes
import subprocess
import uuid
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
        pyautogui.FAILSAFE = False
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
                elif action == "select_screen_region":
                    self.handle_select_screen_region(command)
                elif action == "template_match":
                    self.handle_template_match(command)
                elif action == "select_ui_element":
                    self.handle_select_ui_element(command)
                elif action == "select_swipe_points":
                    self.handle_select_swipe_points(command)
                elif action == "unlock_desktop":
                    self.handle_unlock_desktop(command)
                elif action == "enumerate_children":
                    self.handle_enumerate_children(command)
                elif action == "preview_children":
                    self.handle_preview_children(command)
                elif action == "get_foreground_hwnd":
                    self.handle_get_foreground_hwnd(command)
                elif action == "focus_window":
                    self.handle_focus_window(command)
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
            elif action_type == "take_screenshot":
                result = self._take_screenshot(payload)
                mouse_x, mouse_y = pyautogui.position()
                self.send_response(command.get("id"), success=True, data={
                    "status": "executed",
                    "action": action_type,
                    "durationMs": int((time.monotonic() - started) * 1000),
                    "mouseX": mouse_x,
                    "mouseY": mouse_y,
                    "filepath": result.get("filepath"),
                })
                return
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
            try:
                pyautogui.hscroll(clicks)
            except AttributeError:
                pyautogui.scroll(clicks)  # fallback for older pyautogui
        else:
            raise ValueError(f"Unsupported scroll direction: {direction}")

    def _take_screenshot(self, payload):
        """Capture full screen via mss and save to Pictures/Autonion Screenshots/."""
        from PIL import Image
        import datetime

        with mss() as sct:
            monitor = sct.monitors[0]  # full virtual desktop
            shot = sct.grab(monitor)
            img = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

        save_dir = os.path.join(os.path.expanduser("~"), "Pictures", "Autonion Screenshots")
        os.makedirs(save_dir, exist_ok=True)
        filename = f"screenshot_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        filepath = os.path.join(save_dir, filename)
        img.save(filepath, "PNG")
        eprint(f"Screenshot saved: {filepath}")
        return {"filepath": filepath}

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
        # Skip screenshot-to-screen remapping when coordinates are already in
        # absolute screen space (e.g. from the swipe point picker overlay).
        coord_space = payload.get("coordinateSpace", "")
        if coord_space != "screen":
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

    def handle_select_screen_region(self, command):
        """Two-phase screen region selection.

        Phase 1 -- Transparent overlay: the user can see and arrange their
        desktop.  Click, Space, or Enter captures the screenshot.
        Phase 2 -- Frozen screenshot overlay: the user drags to select a region.
        """
        cmd_id = command.get("id")
        payload = command.get("payload", {})
        require_area = bool(payload.get("requireArea", False))

        try:
            from PIL import Image, ImageTk
            import tkinter as tk

            # -- helpers ------------------------------------------------
            def clamp(value, lower, upper):
                return max(lower, min(upper, int(round(value))))

            # -- discover virtual-desktop geometry (all monitors) --------
            with mss() as sct:
                monitor = sct.monitors[0] if sct.monitors else {
                    "left": 0, "top": 0, "width": 0, "height": 0,
                }
                screen_left = int(monitor.get("left", 0))
                screen_top = int(monitor.get("top", 0))
                screen_width = int(monitor.get("width", 0))
                screen_height = int(monitor.get("height", 0))

            # ===========================================================
            #  PHASE 1 -- floating toolbar (no fullscreen overlay)
            #  The user can freely interact with their desktop.
            #  Click the Capture button or press Space/Enter to snap.
            # ===========================================================
            phase1_cancelled = False
            phase1_done = False

            p1_root = tk.Tk()
            p1_root.withdraw()
            p1_root.overrideredirect(True)
            p1_root.attributes("-topmost", True)
            try:
                p1_root.attributes("-alpha", 0.94)
            except Exception:
                pass
            toolbar_w, toolbar_h = 420, 52
            toolbar_x = screen_left + (screen_width - toolbar_w) // 2
            toolbar_y = screen_top + 28
            p1_root.geometry(f"{toolbar_w}x{toolbar_h}{toolbar_x:+d}{toolbar_y:+d}")
            p1_root.configure(background="#111827")

            # -- outer frame with border --------------------------------
            outer = tk.Frame(
                p1_root, bg="#111827",
                highlightbackground="#38bdf8", highlightthickness=1,
            )
            outer.pack(fill="both", expand=True)

            inner = tk.Frame(outer, bg="#111827")
            inner.pack(fill="both", expand=True, padx=8, pady=6)

            # -- camera icon + label ------------------------------------
            tk.Label(
                inner,
                text="\U0001f4f7  Arrange your screen, then:",
                fg="#94a3b8", bg="#111827",
                font=("Segoe UI", 10), anchor="w",
            ).pack(side="left", padx=(4, 8))

            # -- Capture button -----------------------------------------
            def p1_trigger(event=None):
                nonlocal phase1_done
                if phase1_done:
                    return
                phase1_done = True
                p1_root.quit()

            def p1_cancel(event=None):
                nonlocal phase1_cancelled, phase1_done
                if phase1_done:
                    return
                phase1_cancelled = True
                phase1_done = True
                p1_root.quit()

            capture_btn = tk.Button(
                inner, text="\u2318 Capture", fg="white", bg="#0ea5e9",
                activeforeground="white", activebackground="#0284c7",
                font=("Segoe UI", 10, "bold"), bd=0,
                padx=14, pady=2, cursor="hand2",
                command=p1_trigger,
            )
            capture_btn.pack(side="left", padx=(0, 6))

            cancel_btn = tk.Button(
                inner, text="Cancel", fg="#94a3b8", bg="#1e293b",
                activeforeground="white", activebackground="#334155",
                font=("Segoe UI", 10), bd=0,
                padx=10, pady=2, cursor="hand2",
                command=p1_cancel,
            )
            cancel_btn.pack(side="left")

            # -- keyboard shortcuts (when toolbar has focus) ------------
            p1_root.bind("<space>", p1_trigger)
            p1_root.bind("<Return>", p1_trigger)
            p1_root.bind("<Escape>", p1_cancel)

            p1_root.deiconify()
            p1_root.focus_force()

            p1_root.mainloop()
            try:
                p1_root.destroy()
            except Exception:
                pass

            if phase1_cancelled:
                self.send_response(cmd_id, success=True, data={"cancelled": True})
                return

            # Brief pause so the toolbar disappears before capture
            time.sleep(0.15)


            # ===========================================================
            #  PHASE 2 -- capture screenshot & region selection
            # ===========================================================
            with mss() as sct:
                monitor = sct.monitors[0] if sct.monitors else {
                    "left": 0, "top": 0, "width": 0, "height": 0,
                }
                shot = sct.grab(monitor)
                image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

            with io.BytesIO() as buf:
                image.save(buf, format="PNG", optimize=True)
                screenshot_base64 = base64.b64encode(buf.getvalue()).decode("utf-8")

            result = {"cancelled": True}
            root = tk.Tk()
            root.withdraw()
            root.overrideredirect(True)
            root.attributes("-topmost", True)
            try:
                root.attributes("-alpha", 0.98)
            except Exception:
                pass
            root.geometry(
                f"{screen_width}x{screen_height}{screen_left:+d}{screen_top:+d}"
            )
            root.deiconify()
            root.focus_force()

            canvas = tk.Canvas(
                root, width=screen_width, height=screen_height,
                highlightthickness=0, cursor="crosshair",
            )
            canvas.pack(fill="both", expand=True)
            photo = ImageTk.PhotoImage(image)
            canvas.create_image(0, 0, image=photo, anchor="nw")
            canvas.create_rectangle(
                0, 0, screen_width, screen_height,
                fill="black", stipple="gray25", outline="",
            )
            canvas.create_rectangle(
                18, 18, 530, 58,
                fill="#111827", outline="#38bdf8", width=1,
            )
            hint_text = "Drag to select an area. Esc/right-click cancels."
            if not require_area:
                hint_text = "Click a point or drag an area. Esc/right-click cancels."
            canvas.create_text(
                32, 38, text=hint_text, fill="white", anchor="w",
                font=("Segoe UI", 12, "bold"),
            )
            rect_id = None
            start = {"x": 0, "y": 0}

            def on_press(event):
                nonlocal rect_id
                start["x"] = clamp(event.x, 0, screen_width)
                start["y"] = clamp(event.y, 0, screen_height)
                if rect_id is not None:
                    canvas.delete(rect_id)
                rect_id = canvas.create_rectangle(
                    start["x"], start["y"], start["x"], start["y"],
                    outline="#38bdf8", width=3, fill="#38bdf8", stipple="gray25",
                )

            def on_drag(event):
                if rect_id is None:
                    return
                x = clamp(event.x, 0, screen_width)
                y = clamp(event.y, 0, screen_height)
                canvas.coords(rect_id, start["x"], start["y"], x, y)

            def on_release(event):
                nonlocal result
                end_x = clamp(event.x, 0, screen_width)
                end_y = clamp(event.y, 0, screen_height)
                left = min(start["x"], end_x)
                top = min(start["y"], end_y)
                right = max(start["x"], end_x)
                bottom = max(start["y"], end_y)
                width = right - left
                height = bottom - top
                if require_area and (width <= 3 or height <= 3):
                    return
                if width <= 3 or height <= 3:
                    left = start["x"]
                    top = start["y"]
                    width = 0
                    height = 0
                result = {
                    "cancelled": False,
                    "x": screen_left + left,
                    "y": screen_top + top,
                    "width": width,
                    "height": height,
                    "imageX": left,
                    "imageY": top,
                    "imageWidth": width,
                    "imageHeight": height,
                    "screenLeft": screen_left,
                    "screenTop": screen_top,
                    "screenWidth": screen_width,
                    "screenHeight": screen_height,
                    "imageWidthFull": image.width,
                    "imageHeightFull": image.height,
                    "screenshotBase64": screenshot_base64,
                }
                root.quit()

            def cancel(event=None):
                root.quit()

            canvas.bind("<ButtonPress-1>", on_press)
            canvas.bind("<B1-Motion>", on_drag)
            canvas.bind("<ButtonRelease-1>", on_release)
            canvas.bind("<ButtonPress-3>", cancel)
            root.bind("<Escape>", cancel)
            root.mainloop()
            try:
                root.destroy()
            except Exception:
                pass

            self.send_response(cmd_id, success=True, data=result)
        except Exception as exc:
            self.send_response(cmd_id, success=False, error=str(exc))

    def handle_select_swipe_points(self, command):
        """Full-screen overlay with two draggable markers (Start & End) connected by an arrow.

        The user clicks to place the start point, then clicks again to place
        the end point.  Both markers are draggable afterwards.  Confirm with
        Enter/Space or the Confirm button.  Esc or right-click cancels.
        """
        cmd_id = command.get("id")

        try:
            from PIL import Image, ImageTk
            import tkinter as tk
            import math

            # -- discover virtual-desktop geometry --------------------------
            with mss() as sct:
                monitor = sct.monitors[0] if sct.monitors else {
                    "left": 0, "top": 0, "width": 0, "height": 0,
                }
                screen_left = int(monitor.get("left", 0))
                screen_top = int(monitor.get("top", 0))
                screen_width = int(monitor.get("width", 0))
                screen_height = int(monitor.get("height", 0))
                shot = sct.grab(monitor)
                image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")

            # -- state ------------------------------------------------------
            result = {"cancelled": True}
            phase = {"value": "start"}  # "start" -> "end" -> "adjust"
            start_pt = {"x": 0, "y": 0}
            end_pt = {"x": 0, "y": 0}
            marker_radius = 18
            dragging = {"item": None, "which": None}

            # -- tkinter root -----------------------------------------------
            root = tk.Tk()
            root.withdraw()
            root.overrideredirect(True)
            root.attributes("-topmost", True)
            try:
                root.attributes("-alpha", 0.98)
            except Exception:
                pass
            root.geometry(
                f"{screen_width}x{screen_height}{screen_left:+d}{screen_top:+d}"
            )

            canvas = tk.Canvas(
                root, width=screen_width, height=screen_height,
                highlightthickness=0, cursor="crosshair",
            )
            canvas.pack(fill="both", expand=True)

            # background screenshot with dim overlay
            photo = ImageTk.PhotoImage(image)
            canvas.create_image(0, 0, image=photo, anchor="nw")
            canvas.create_rectangle(
                0, 0, screen_width, screen_height,
                fill="black", stipple="gray25", outline="",
            )

            # -- hint banner ------------------------------------------------
            hint_bg = canvas.create_rectangle(18, 18, 520, 58, fill="#111827", outline="#38bdf8", width=1)
            hint_text_id = canvas.create_text(
                32, 38, text="Click to place SWIPE START point. Esc cancels.",
                fill="white", anchor="w", font=("Segoe UI", 12, "bold"),
            )

            # -- drawing helpers --------------------------------------------
            line_id = None
            arrow_ids = []
            start_marker_ids = []
            end_marker_ids = []
            confirm_btn_ids = []

            def draw_marker(cx, cy, label, color, tag):
                """Draw a circular marker with label."""
                ids = []
                # outer ring
                ids.append(canvas.create_oval(
                    cx - marker_radius, cy - marker_radius,
                    cx + marker_radius, cy + marker_radius,
                    outline=color, width=3, fill="", tags=(tag,),
                ))
                # inner dot
                ids.append(canvas.create_oval(
                    cx - 5, cy - 5, cx + 5, cy + 5,
                    outline=color, fill=color, tags=(tag,),
                ))
                # label
                ids.append(canvas.create_text(
                    cx, cy - marker_radius - 14, text=label,
                    fill=color, font=("Segoe UI", 10, "bold"), tags=(tag,),
                ))
                return ids

            def draw_arrow_line():
                """Draw a line with arrow from start to end."""
                nonlocal line_id, arrow_ids
                # clear old
                if line_id:
                    canvas.delete(line_id)
                for aid in arrow_ids:
                    canvas.delete(aid)
                arrow_ids = []

                sx, sy = start_pt["x"], start_pt["y"]
                ex, ey = end_pt["x"], end_pt["y"]

                # main line
                line_id = canvas.create_line(
                    sx, sy, ex, ey,
                    fill="#38bdf8", width=3, dash=(8, 4),
                )

                # arrowhead
                dx = ex - sx
                dy = ey - sy
                length = math.sqrt(dx * dx + dy * dy)
                if length > 20:
                    ux, uy = dx / length, dy / length
                    # perpendicular
                    px, py = -uy, ux
                    arrow_size = 16
                    tip_x, tip_y = ex, ey
                    left_x = tip_x - arrow_size * ux + arrow_size * 0.5 * px
                    left_y = tip_y - arrow_size * uy + arrow_size * 0.5 * py
                    right_x = tip_x - arrow_size * ux - arrow_size * 0.5 * px
                    right_y = tip_y - arrow_size * uy - arrow_size * 0.5 * py
                    arrow_ids.append(canvas.create_polygon(
                        tip_x, tip_y, left_x, left_y, right_x, right_y,
                        fill="#38bdf8", outline="#38bdf8",
                    ))

            def update_markers():
                """Redraw markers and line after drag."""
                for mid in start_marker_ids:
                    canvas.delete(mid)
                for mid in end_marker_ids:
                    canvas.delete(mid)
                start_marker_ids.clear()
                end_marker_ids.clear()

                start_marker_ids.extend(
                    draw_marker(start_pt["x"], start_pt["y"], "START", "#22c55e", "start_marker")
                )
                if phase["value"] in ("end", "adjust"):
                    end_marker_ids.extend(
                        draw_marker(end_pt["x"], end_pt["y"], "END", "#ef4444", "end_marker")
                    )
                    draw_arrow_line()

            def show_confirm_ui():
                """Show confirm/cancel buttons after both points are placed."""
                for cid in confirm_btn_ids:
                    canvas.delete(cid)
                confirm_btn_ids.clear()

                canvas.itemconfig(hint_text_id,
                    text="Drag markers to adjust. Enter/Space to confirm. Esc cancels.")

                # confirm button
                bx, by = screen_width - 240, 28
                confirm_btn_ids.append(canvas.create_rectangle(
                    bx, by, bx + 100, by + 34,
                    fill="#0ea5e9", outline="#0ea5e9", tags=("confirm_btn",),
                ))
                confirm_btn_ids.append(canvas.create_text(
                    bx + 50, by + 17, text="Confirm",
                    fill="white", font=("Segoe UI", 11, "bold"), tags=("confirm_btn",),
                ))

                # cancel button
                cx = bx + 115
                confirm_btn_ids.append(canvas.create_rectangle(
                    cx, by, cx + 80, by + 34,
                    fill="#1e293b", outline="#475569", tags=("cancel_btn",),
                ))
                confirm_btn_ids.append(canvas.create_text(
                    cx + 40, by + 17, text="Cancel",
                    fill="#94a3b8", font=("Segoe UI", 11), tags=("cancel_btn",),
                ))

            # -- event handlers ---------------------------------------------
            def on_click(event):
                nonlocal dragging
                x, y = event.x, event.y

                # check for button clicks
                items = canvas.find_overlapping(x - 2, y - 2, x + 2, y + 2)
                tags_at = set()
                for item in items:
                    tags_at.update(canvas.gettags(item))

                if "confirm_btn" in tags_at:
                    confirm()
                    return
                if "cancel_btn" in tags_at:
                    cancel()
                    return

                # check for marker drag
                if phase["value"] == "adjust":
                    if "start_marker" in tags_at:
                        dragging["item"] = "start"
                        return
                    if "end_marker" in tags_at:
                        dragging["item"] = "end"
                        return

                # placement
                if phase["value"] == "start":
                    start_pt["x"] = x
                    start_pt["y"] = y
                    phase["value"] = "end"
                    canvas.itemconfig(hint_text_id,
                        text="Click to place SWIPE END point.")
                    update_markers()
                elif phase["value"] == "end":
                    end_pt["x"] = x
                    end_pt["y"] = y
                    phase["value"] = "adjust"
                    update_markers()
                    show_confirm_ui()

            def on_drag(event):
                if dragging["item"] == "start":
                    start_pt["x"] = max(0, min(event.x, screen_width))
                    start_pt["y"] = max(0, min(event.y, screen_height))
                    update_markers()
                    draw_arrow_line()
                elif dragging["item"] == "end":
                    end_pt["x"] = max(0, min(event.x, screen_width))
                    end_pt["y"] = max(0, min(event.y, screen_height))
                    update_markers()
                    draw_arrow_line()

            def on_release(event):
                dragging["item"] = None

            def confirm(event=None):
                nonlocal result
                if phase["value"] != "adjust":
                    return
                result = {
                    "cancelled": False,
                    "startX": screen_left + start_pt["x"],
                    "startY": screen_top + start_pt["y"],
                    "endX": screen_left + end_pt["x"],
                    "endY": screen_top + end_pt["y"],
                }
                root.quit()

            def cancel(event=None):
                root.quit()

            canvas.bind("<ButtonPress-1>", on_click)
            canvas.bind("<B1-Motion>", on_drag)
            canvas.bind("<ButtonRelease-1>", on_release)
            canvas.bind("<ButtonPress-3>", cancel)
            root.bind("<Escape>", cancel)
            root.bind("<Return>", confirm)
            root.bind("<space>", confirm)

            root.deiconify()
            root.focus_force()
            root.mainloop()
            try:
                root.destroy()
            except Exception:
                pass

            self.send_response(cmd_id, success=True, data=result)
        except Exception as exc:
            self.send_response(cmd_id, success=False, error=str(exc))

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

    def handle_select_ui_element(self, command):
        """Interactive UI element picker with bounding-box overlay.

        Phase 1 -- Floating toolbar: user arranges their screen / switches
                   monitor.  Click Capture or press Space/Enter.
        Phase 2 -- After capture: enumerate UIA tree, take screenshot,
                   show fullscreen overlay with bounding boxes.
        Fallback -- If screenshot fails, show searchable list dialog.

        Debug: saves full_dom.json and detected_dom.json under
               ~/.autonion/debug/ for missing-element analysis.
        """
        cmd_id = command.get("id")

        try:
            import tkinter as tk
            from PIL import Image, ImageTk

            # -- helpers ------------------------------------------------
            def clamp(value, lower, upper):
                return max(lower, min(upper, int(round(value))))

            # -- Discover virtual-desktop geometry (all monitors) -------
            with mss() as sct:
                monitor = sct.monitors[0] if sct.monitors else {
                    "left": 0, "top": 0, "width": 0, "height": 0,
                }
                screen_left = int(monitor.get("left", 0))
                screen_top = int(monitor.get("top", 0))
                screen_width = int(monitor.get("width", 0))
                screen_height = int(monitor.get("height", 0))

            # ===========================================================
            #  PHASE 1 -- floating toolbar (no fullscreen overlay)
            #  The user can freely interact with their desktop, switch
            #  monitors, navigate to the target app, etc.
            # ===========================================================
            phase1_cancelled = False
            phase1_done = False

            p1_root = tk.Tk()
            p1_root.withdraw()
            p1_root.overrideredirect(True)
            p1_root.attributes("-topmost", True)
            try:
                p1_root.attributes("-alpha", 0.94)
            except Exception:
                pass
            toolbar_w, toolbar_h = 480, 52
            toolbar_x = screen_left + (screen_width - toolbar_w) // 2
            toolbar_y = screen_top + 28
            p1_root.geometry(f"{toolbar_w}x{toolbar_h}{toolbar_x:+d}{toolbar_y:+d}")
            p1_root.configure(background="#111827")

            # -- outer frame with border --------------------------------
            outer = tk.Frame(
                p1_root, bg="#111827",
                highlightbackground="#38bdf8", highlightthickness=1,
            )
            outer.pack(fill="both", expand=True)

            inner = tk.Frame(outer, bg="#111827")
            inner.pack(fill="both", expand=True, padx=8, pady=6)

            # -- camera icon + label ------------------------------------
            tk.Label(
                inner,
                text="\U0001f50d  Navigate to your target, then:",
                fg="#94a3b8", bg="#111827",
                font=("Segoe UI", 10), anchor="w",
            ).pack(side="left", padx=(4, 8))

            # -- Capture button -----------------------------------------
            def p1_trigger(event=None):
                nonlocal phase1_done
                if phase1_done:
                    return
                phase1_done = True
                p1_root.quit()

            def p1_cancel(event=None):
                nonlocal phase1_cancelled, phase1_done
                if phase1_done:
                    return
                phase1_cancelled = True
                phase1_done = True
                p1_root.quit()

            capture_btn = tk.Button(
                inner, text="\u2318 Capture Elements", fg="white", bg="#0ea5e9",
                activeforeground="white", activebackground="#0284c7",
                font=("Segoe UI", 10, "bold"), bd=0,
                padx=14, pady=2, cursor="hand2",
                command=p1_trigger,
            )
            capture_btn.pack(side="left", padx=(0, 6))

            cancel_btn_p1 = tk.Button(
                inner, text="Cancel", fg="#94a3b8", bg="#1e293b",
                activeforeground="white", activebackground="#334155",
                font=("Segoe UI", 10), bd=0,
                padx=10, pady=2, cursor="hand2",
                command=p1_cancel,
            )
            cancel_btn_p1.pack(side="left")

            # -- keyboard shortcuts -------------------------------------
            p1_root.bind("<space>", p1_trigger)
            p1_root.bind("<Return>", p1_trigger)
            p1_root.bind("<Escape>", p1_cancel)

            p1_root.deiconify()
            p1_root.focus_force()
            p1_root.mainloop()
            try:
                p1_root.destroy()
            except Exception:
                pass

            if phase1_cancelled:
                self.send_response(cmd_id, success=True, data={"cancelled": True})
                return

            # Brief pause so the toolbar disappears before capture
            time.sleep(0.15)

            # ===========================================================
            #  PHASE 2 -- Enumerate UIA tree + screenshot + overlay
            # ===========================================================

            # -- 1. Enumerate UIA tree NOW (after user arranged screen) --
            elements = self._get_accessibility_tree()
            clickable = [
                el for el in elements
                if el.get("isClickable")
                and not el.get("isOffscreen", False)
                and el.get("isEnabled", True)
                and el.get("boundingBox", {}).get("width", 0) > 2
                and el.get("boundingBox", {}).get("height", 0) > 2
            ]

            # -- 2. Debug dump: save full & filtered DOM to files --------
            try:
                debug_dir = os.path.join(
                    os.environ.get("USERPROFILE") or os.environ.get("HOME") or ".",
                    ".autonion", "debug",
                )
                os.makedirs(debug_dir, exist_ok=True)

                full_path = os.path.join(debug_dir, "full_dom.json")
                detected_path = os.path.join(debug_dir, "detected_dom.json")

                with open(full_path, "w", encoding="utf-8") as f:
                    json.dump({
                        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                        "total_elements": len(elements),
                        "elements": elements,
                    }, f, indent=2, ensure_ascii=False, default=str)

                with open(detected_path, "w", encoding="utf-8") as f:
                    json.dump({
                        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                        "total_elements": len(elements),
                        "clickable_count": len(clickable),
                        "filter_criteria": {
                            "isClickable": True,
                            "isOffscreen": False,
                            "isEnabled": True,
                            "min_width": 3,
                            "min_height": 3,
                        },
                        "elements": clickable,
                    }, f, indent=2, ensure_ascii=False, default=str)

                eprint(f"[DEBUG] DOM dumps saved: {full_path} ({len(elements)} total), "
                       f"{detected_path} ({len(clickable)} clickable)")
            except Exception as dump_exc:
                eprint(f"[DEBUG] Failed to save DOM dumps: {dump_exc}")

            if not clickable:
                self.send_response(cmd_id, success=True, data={
                    "cancelled": True,
                    "error": "No clickable elements found",
                })
                return

            # -- 3. Re-read virtual-desktop geometry (monitors may have
            #       changed if user switched display config) -------------
            with mss() as sct:
                monitor = sct.monitors[0] if sct.monitors else {
                    "left": 0, "top": 0, "width": 0, "height": 0,
                }
                screen_left = int(monitor.get("left", 0))
                screen_top = int(monitor.get("top", 0))
                screen_width = int(monitor.get("width", 0))
                screen_height = int(monitor.get("height", 0))

            # -- 4. Attempt screenshot ----------------------------------
            screenshot_ok = False
            image = None
            try:
                with mss() as sct:
                    monitor = sct.monitors[0]
                    shot = sct.grab(monitor)
                    image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
                screenshot_ok = True
            except Exception as exc:
                eprint(f"Screenshot failed for element picker, using list fallback: {exc}")

            if screenshot_ok and image is not None:
                # =======================================================
                #  OVERLAY MODE: bounding boxes on screenshot
                # =======================================================
                result = {"cancelled": True}
                hover_index = {"value": -1}

                root = tk.Tk()
                root.withdraw()
                root.overrideredirect(True)
                root.attributes("-topmost", True)
                try:
                    root.attributes("-alpha", 0.97)
                except Exception:
                    pass
                root.geometry(
                    f"{screen_width}x{screen_height}{screen_left:+d}{screen_top:+d}"
                )

                canvas = tk.Canvas(
                    root, width=screen_width, height=screen_height,
                    highlightthickness=0, cursor="hand2",
                )
                canvas.pack(fill="both", expand=True)
                photo = ImageTk.PhotoImage(image)
                canvas.create_image(0, 0, image=photo, anchor="nw")

                # Dim overlay
                canvas.create_rectangle(
                    0, 0, screen_width, screen_height,
                    fill="black", stipple="gray25", outline="",
                )

                # -- Draw bounding boxes --------------------------------
                box_ids = []  # (canvas_rect_id, element_dict, bx, by, bw, bh)
                BLUE = "#38bdf8"
                GREEN = "#22c55e"
                HOVER_FILL = "#38bdf8"

                for el in clickable:
                    bb = el.get("boundingBox", {})
                    bx = int(bb.get("x", 0)) - screen_left
                    by = int(bb.get("y", 0)) - screen_top
                    bw = int(bb.get("width", 0))
                    bh = int(bb.get("height", 0))

                    # Skip elements fully outside the virtual screen
                    if bx + bw <= 0 or by + bh <= 0 or bx >= screen_width or by >= screen_height:
                        continue

                    is_input = el.get("isKeyboardFocusable", False)
                    color = GREEN if is_input else BLUE

                    rect_id = canvas.create_rectangle(
                        bx, by, bx + bw, by + bh,
                        outline=color, width=2, fill="", tags="bbox",
                    )
                    box_ids.append((rect_id, el, bx, by, bw, bh))

                # -- Header bar -----------------------------------------
                canvas.create_rectangle(
                    14, 14, 620, 58,
                    fill="#111827", outline="#38bdf8", width=1,
                )
                canvas.create_text(
                    28, 36,
                    text=f"\u2318 Click an element to select it  |  {len(box_ids)} elements  |  Esc to cancel",
                    fill="white", anchor="w",
                    font=("Segoe UI", 12, "bold"),
                )

                # -- Tooltip label (hidden until hover) -----------------
                tooltip_bg = canvas.create_rectangle(0, 0, 0, 0, fill="#1e293b", outline="#38bdf8", width=1, state="hidden")
                tooltip_text = canvas.create_text(0, 0, text="", fill="white", anchor="nw", font=("Segoe UI", 10), state="hidden")

                # -- Hover tracking -------------------------------------
                prev_highlight = {"rect_id": None, "original_outline": None}

                def on_motion(event):
                    mx, my = event.x, event.y
                    best_idx = -1
                    best_area = float("inf")

                    for idx, (rid, el, bx, by, bw, bh) in enumerate(box_ids):
                        if bx <= mx <= bx + bw and by <= my <= by + bh:
                            area = bw * bh
                            if area < best_area:
                                best_area = area
                                best_idx = idx

                    if best_idx == hover_index["value"]:
                        return
                    hover_index["value"] = best_idx

                    # Restore previous highlight
                    if prev_highlight["rect_id"] is not None:
                        canvas.itemconfigure(
                            prev_highlight["rect_id"],
                            outline=prev_highlight["original_outline"],
                            width=2, fill="",
                        )
                        prev_highlight["rect_id"] = None

                    if best_idx < 0:
                        canvas.itemconfigure(tooltip_bg, state="hidden")
                        canvas.itemconfigure(tooltip_text, state="hidden")
                        return

                    rid, el, bx, by, bw, bh = box_ids[best_idx]
                    is_input = el.get("isKeyboardFocusable", False)
                    original_color = GREEN if is_input else BLUE
                    prev_highlight["rect_id"] = rid
                    prev_highlight["original_outline"] = original_color

                    canvas.itemconfigure(
                        rid, outline="#facc15", width=3,
                        fill=HOVER_FILL, stipple="gray25",
                    )

                    # Update tooltip
                    name = el.get("name", "") or ""
                    role = el.get("role", "") or ""
                    auto_id = el.get("automationId", "") or ""
                    tip_parts = []
                    if name:
                        tip_parts.append(f"Name: {name[:60]}")
                    if role:
                        tip_parts.append(f"Role: {role}")
                    if auto_id:
                        tip_parts.append(f"ID: {auto_id[:40]}")
                    tip_parts.append(f"Bounds: {bx},{by} {bw}x{bh}")
                    tip_text = "\n".join(tip_parts)

                    tx = clamp(bx, 10, screen_width - 350)
                    ty = clamp(by - 70, 10, screen_height - 80)
                    if ty >= by - 5:
                        ty = clamp(by + bh + 8, 10, screen_height - 80)

                    canvas.coords(tooltip_text, tx + 8, ty + 6)
                    canvas.itemconfigure(tooltip_text, text=tip_text, state="normal")
                    # Measure text bbox for background
                    tbbox = canvas.bbox(tooltip_text)
                    if tbbox:
                        canvas.coords(tooltip_bg, tbbox[0] - 6, tbbox[1] - 4, tbbox[2] + 6, tbbox[3] + 4)
                        canvas.itemconfigure(tooltip_bg, state="normal")
                    canvas.tag_raise(tooltip_bg)
                    canvas.tag_raise(tooltip_text)

                def on_click(event):
                    nonlocal result
                    idx = hover_index["value"]
                    if idx < 0:
                        return
                    _, el, _, _, _, _ = box_ids[idx]
                    result = {
                        "cancelled": False,
                        "element": el,
                        "screenshotAvailable": True,
                    }
                    root.quit()

                def cancel(event=None):
                    root.quit()

                canvas.bind("<Motion>", on_motion)
                canvas.bind("<ButtonRelease-1>", on_click)
                canvas.bind("<ButtonPress-3>", cancel)
                root.bind("<Escape>", cancel)

                root.deiconify()
                root.focus_force()
                root.mainloop()
                try:
                    root.destroy()
                except Exception:
                    pass

                self.send_response(cmd_id, success=True, data=result)
            else:
                # =======================================================
                #  LIST FALLBACK MODE: searchable list dialog
                # =======================================================
                result = {"cancelled": True}

                root = tk.Tk()
                root.withdraw()
                root.title("Select UI Element")
                root.attributes("-topmost", True)

                dialog_w, dialog_h = 700, 600
                dialog_x = screen_left + (screen_width - dialog_w) // 2
                dialog_y = screen_top + (screen_height - dialog_h) // 2
                root.geometry(f"{dialog_w}x{dialog_h}{dialog_x:+d}{dialog_y:+d}")
                root.configure(bg="#111827")

                # -- Header
                header = tk.Frame(root, bg="#111827")
                header.pack(fill="x", padx=16, pady=(16, 8))

                tk.Label(
                    header, text="\u2318 Select UI Element",
                    fg="white", bg="#111827",
                    font=("Segoe UI", 14, "bold"),
                ).pack(side="left")

                tk.Label(
                    header,
                    text="(Screenshot unavailable \u2014 showing element list)",
                    fg="#94a3b8", bg="#111827",
                    font=("Segoe UI", 10),
                ).pack(side="left", padx=(12, 0))

                # -- Search field
                search_frame = tk.Frame(root, bg="#111827")
                search_frame.pack(fill="x", padx=16, pady=(0, 8))

                search_var = tk.StringVar()
                search_entry = tk.Entry(
                    search_frame, textvariable=search_var,
                    bg="#1e293b", fg="white", insertbackground="white",
                    font=("Segoe UI", 11), relief="flat", bd=0,
                )
                search_entry.pack(fill="x", ipady=6, ipadx=8)
                search_entry.insert(0, "")
                search_entry.focus_set()

                # -- Element listbox
                list_frame = tk.Frame(root, bg="#111827")
                list_frame.pack(fill="both", expand=True, padx=16, pady=(0, 8))

                scrollbar = tk.Scrollbar(list_frame)
                scrollbar.pack(side="right", fill="y")

                listbox = tk.Listbox(
                    list_frame, bg="#1e293b", fg="white",
                    selectbackground="#38bdf8", selectforeground="#111827",
                    font=("Consolas", 10), relief="flat", bd=0,
                    yscrollcommand=scrollbar.set,
                    activestyle="none",
                )
                listbox.pack(fill="both", expand=True)
                scrollbar.config(command=listbox.yview)

                # -- Detail panel at bottom
                detail_var = tk.StringVar(value="Click an element to see details")
                detail_label = tk.Label(
                    root, textvariable=detail_var,
                    fg="#94a3b8", bg="#1e293b",
                    font=("Consolas", 9), anchor="w", justify="left",
                    wraplength=dialog_w - 40,
                )
                detail_label.pack(fill="x", padx=16, pady=(0, 8), ipady=6, ipadx=8)

                # -- Buttons
                btn_frame = tk.Frame(root, bg="#111827")
                btn_frame.pack(fill="x", padx=16, pady=(0, 16))

                # Track filtered elements
                filtered_elements = {"data": list(clickable)}

                def format_element_line(el):
                    name = (el.get("name") or "")[:45]
                    role = el.get("role") or "?"
                    auto_id = (el.get("automationId") or "")[:20]
                    bb = el.get("boundingBox", {})
                    bx, by = bb.get("x", 0), bb.get("y", 0)
                    return f"[{role:12s}]  {name:45s}  {auto_id:20s}  ({bx},{by})"

                def refresh_list(*_args):
                    query = search_var.get().strip().lower()
                    listbox.delete(0, "end")
                    filtered = []
                    for el in clickable:
                        if query:
                            searchable = " ".join([
                                el.get("name") or "",
                                el.get("role") or "",
                                el.get("automationId") or "",
                                el.get("className") or "",
                            ]).lower()
                            if query not in searchable:
                                continue
                        filtered.append(el)
                        listbox.insert("end", format_element_line(el))
                    filtered_elements["data"] = filtered

                def on_select(event):
                    sel = listbox.curselection()
                    if not sel:
                        return
                    idx = sel[0]
                    el = filtered_elements["data"][idx]
                    bb = el.get("boundingBox", {})
                    details = (
                        f"Name: {el.get('name', '')}  |  Role: {el.get('role', '')}  |  "
                        f"AutomationId: {el.get('automationId', '')}  |  "
                        f"Class: {el.get('className', '')}  |  "
                        f"Bounds: {bb.get('x',0)},{bb.get('y',0)} {bb.get('width',0)}x{bb.get('height',0)}"
                    )
                    detail_var.set(details)

                def confirm(event=None):
                    nonlocal result
                    sel = listbox.curselection()
                    if not sel:
                        return
                    idx = sel[0]
                    el = filtered_elements["data"][idx]
                    result = {
                        "cancelled": False,
                        "element": el,
                        "screenshotAvailable": False,
                    }
                    root.quit()

                def cancel(event=None):
                    root.quit()

                search_var.trace_add("write", refresh_list)
                listbox.bind("<<ListboxSelect>>", on_select)
                listbox.bind("<Double-Button-1>", confirm)
                root.bind("<Return>", confirm)
                root.bind("<Escape>", cancel)

                select_btn = tk.Button(
                    btn_frame, text="Select", fg="white", bg="#0ea5e9",
                    activeforeground="white", activebackground="#0284c7",
                    font=("Segoe UI", 10, "bold"), bd=0,
                    padx=20, pady=4, cursor="hand2",
                    command=confirm,
                )
                select_btn.pack(side="right", padx=(8, 0))

                cancel_btn = tk.Button(
                    btn_frame, text="Cancel", fg="#94a3b8", bg="#1e293b",
                    activeforeground="white", activebackground="#334155",
                    font=("Segoe UI", 10), bd=0,
                    padx=14, pady=4, cursor="hand2",
                    command=cancel,
                )
                cancel_btn.pack(side="right")

                refresh_list()
                root.deiconify()
                root.mainloop()
                try:
                    root.destroy()
                except Exception:
                    pass

                self.send_response(cmd_id, success=True, data=result)

        except Exception as exc:
            eprint(f"select_ui_element error: {exc}")
            self.send_response(cmd_id, success=False, error=str(exc))

    def _try_unlock_via_installed_helper(self, password):
        """Use the installed SYSTEM scheduled task helper when available."""
        if os.name != "nt":
            return None

        program_data = os.environ.get("ProgramData", r"C:\ProgramData")
        unlock_dir = Path(program_data) / "Autonion Agent" / "Unlock"
        request_path = unlock_dir / "request.json"
        status_path = unlock_dir / "status.json"

        if not unlock_dir.exists():
            return None

        request_id = uuid.uuid4().hex
        payload = {
            "requestId": request_id,
            "passwordB64": base64.b64encode(
                password.encode("utf-8")
            ).decode("ascii"),
            "createdAt": time.time(),
        }

        try:
            status_path.unlink(missing_ok=True)
        except Exception:
            pass

        try:
            unlock_dir.mkdir(parents=True, exist_ok=True)
            request_path.write_text(json.dumps(payload), encoding="utf-8")
        except Exception as exc:
            raise RuntimeError(f"Could not write unlock helper request: {exc}")

        result = subprocess.run(
            ["schtasks", "/Run", "/TN", "Autonion Unlock Helper"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            try:
                request_path.unlink(missing_ok=True)
            except Exception:
                pass
            output = (result.stderr or result.stdout or "").strip()
            if "cannot find" in output.lower() or "does not exist" in output.lower():
                return None
            raise RuntimeError(output or "Failed to start unlock helper task")

        deadline = time.time() + 25
        last_status = None
        while time.time() < deadline:
            if status_path.exists():
                try:
                    status = json.loads(status_path.read_text(encoding="utf-8"))
                    if status.get("requestId") == request_id:
                        if status.get("success") is True:
                            log = status.get("log") or ""
                            for line in log.splitlines():
                                if line:
                                    eprint(f"  [unlock-helper] {line}")
                            return {
                                "status": "unlock_input_sent",
                                "via": "scheduled_task_helper",
                                "message": status.get("message"),
                            }
                        raise RuntimeError(
                            status.get("message") or "Unlock helper failed"
                        )
                    last_status = status
                except json.JSONDecodeError:
                    pass
            time.sleep(0.25)

        raise RuntimeError(
            f"Timed out waiting for unlock helper status "
            f"(last status: {last_status})"
        )

    # ═══════════════════════════════════════════════════════════════
    #  UNLOCK DESKTOP
    # ═══════════════════════════════════════════════════════════════

    def handle_unlock_desktop(self, command):
        """Unlock the Windows lock-screen by typing a password.

        The password arrives via the local stdin JSON pipe (never over the
        network).  It is used once, then discarded from all variables.
        """
        cmd_id = command.get("id")
        payload = command.get("payload", {})
        password = payload.get("password")

        if not password:
            self.send_response(cmd_id, success=False, error="No password provided")
            return

        helper_error = None
        try:
            helper_result = self._try_unlock_via_installed_helper(password)
            if helper_result is not None:
                self.send_response(cmd_id, success=True, data=helper_result)
                return
        except Exception as exc:
            helper_error = str(exc)
            eprint(f"Installed unlock helper failed: {helper_error}")

        if os.name == "nt" and not ctypes.windll.shell32.IsUserAnAdmin():
            message = "Unlock support is not installed or failed to start."
            if helper_error:
                message += f" Helper error: {helper_error}"
            message += " Reinstall Autonion Agent as administrator to enable Unlock support without UAC at startup."
            self.send_response(cmd_id, success=False, error=message)
            return

        try:
            import tempfile
            import ctypes.wintypes as wt

            # ═══════════════════════════════════════════════════════
            # Launch helper as SYSTEM in the USER'S session via
            # CreateProcessAsUser with a token stolen from
            # winlogon.exe.
            #
            # WHY: SendInput requires SYSTEM integrity to bypass
            # UIPI for the lock screen (LogonUI.exe runs as
            # SYSTEM). But schtasks /RU SYSTEM runs in session 0
            # which has no desktop. We need SYSTEM + user's session.
            #
            # HOW: As admin, enable SeDebugPrivilege → open
            # winlogon.exe in user's session → duplicate its
            # SYSTEM token → CreateProcessAsUser on the Winlogon
            # desktop.
            # ═══════════════════════════════════════════════════════

            # Check admin
            is_admin = ctypes.windll.shell32.IsUserAnAdmin()
            eprint(f"  Running as admin: {bool(is_admin)}")
            if not is_admin:
                raise RuntimeError(
                    "Unlock requires administrator privileges. "
                    "Please run the app from an elevated (admin) terminal."
                )

            advapi32 = ctypes.windll.advapi32
            kernel32 = ctypes.windll.kernel32

            # ── Enable SeDebugPrivilege + SeImpersonatePrivilege ──
            TOKEN_ADJUST_PRIVILEGES = 0x0020
            TOKEN_QUERY = 0x0008
            SE_PRIVILEGE_ENABLED = 0x0002

            class LUID(ctypes.Structure):
                _fields_ = [("LowPart", wt.DWORD), ("HighPart", wt.LONG)]

            class LUID_AND_ATTRIBUTES(ctypes.Structure):
                _fields_ = [("Luid", LUID), ("Attributes", wt.DWORD)]

            class TOKEN_PRIVILEGES(ctypes.Structure):
                _fields_ = [
                    ("PrivilegeCount", wt.DWORD),
                    ("Privileges", LUID_AND_ATTRIBUTES * 1),
                ]

            # Set proper return types for Win32 calls
            kernel32.GetCurrentProcess.restype = wt.HANDLE
            advapi32.OpenProcessToken.argtypes = [
                wt.HANDLE, wt.DWORD, ctypes.POINTER(wt.HANDLE)
            ]
            advapi32.OpenProcessToken.restype = wt.BOOL

            def _enable_privilege(token_handle, priv_name):
                luid = LUID()
                advapi32.LookupPrivilegeValueW(
                    None, priv_name, ctypes.byref(luid)
                )
                tp = TOKEN_PRIVILEGES()
                tp.PrivilegeCount = 1
                tp.Privileges[0].Luid = luid
                tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED
                advapi32.AdjustTokenPrivileges(
                    token_handle, False, ctypes.byref(tp), 0, None, None
                )
                return kernel32.GetLastError()

            h_proc_token = wt.HANDLE()
            ok = advapi32.OpenProcessToken(
                kernel32.GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                ctypes.byref(h_proc_token),
            )
            eprint(f"  OpenProcessToken: ok={ok}, handle={h_proc_token.value}")

            err1 = _enable_privilege(h_proc_token, "SeDebugPrivilege")
            err2 = _enable_privilege(h_proc_token, "SeImpersonatePrivilege")
            kernel32.CloseHandle(h_proc_token)
            eprint(f"  SeDebugPrivilege: err={err1} (0=OK)")
            eprint(f"  SeImpersonatePrivilege: err={err2} (0=OK)")

            # ── Find winlogon.exe in user's session ──────────────
            TH32CS_SNAPPROCESS = 0x00000002

            class PROCESSENTRY32W(ctypes.Structure):
                _fields_ = [
                    ("dwSize", wt.DWORD),
                    ("cntUsage", wt.DWORD),
                    ("th32ProcessID", wt.DWORD),
                    ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                    ("th32ModuleID", wt.DWORD),
                    ("cntThreads", wt.DWORD),
                    ("th32ParentProcessID", wt.DWORD),
                    ("pcPriClassBase", wt.LONG),
                    ("dwFlags", wt.DWORD),
                    ("szExeFile", wt.WCHAR * 260),
                ]

            user_session = kernel32.WTSGetActiveConsoleSessionId()
            eprint(f"  User session: {user_session}")

            snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
            pe = PROCESSENTRY32W()
            pe.dwSize = ctypes.sizeof(PROCESSENTRY32W)

            winlogon_pid = None
            if kernel32.Process32FirstW(snap, ctypes.byref(pe)):
                while True:
                    if pe.szExeFile.lower() == "winlogon.exe":
                        # Check session
                        sess_id = wt.DWORD()
                        kernel32.ProcessIdToSessionId(
                            pe.th32ProcessID, ctypes.byref(sess_id)
                        )
                        if sess_id.value == user_session:
                            winlogon_pid = pe.th32ProcessID
                            break
                    if not kernel32.Process32NextW(snap, ctypes.byref(pe)):
                        break
            kernel32.CloseHandle(snap)

            if not winlogon_pid:
                raise RuntimeError(
                    f"Could not find winlogon.exe in session {user_session}"
                )
            eprint(f"  Found winlogon.exe: PID={winlogon_pid}")

            # ── Duplicate winlogon's SYSTEM token ────────────────
            PROCESS_QUERY_INFORMATION = 0x0400
            TOKEN_DUPLICATE = 0x0002
            TOKEN_ASSIGN_PRIMARY = 0x0001
            TOKEN_ALL_ACCESS = 0x000F01FF
            SecurityImpersonation = 2
            TokenPrimary = 1

            h_winlogon = kernel32.OpenProcess(
                PROCESS_QUERY_INFORMATION, False, winlogon_pid
            )
            if not h_winlogon:
                raise RuntimeError(
                    f"OpenProcess(winlogon) failed: {kernel32.GetLastError()}"
                )

            h_token = wt.HANDLE()
            if not advapi32.OpenProcessToken(
                h_winlogon, TOKEN_DUPLICATE, ctypes.byref(h_token)
            ):
                kernel32.CloseHandle(h_winlogon)
                raise RuntimeError(
                    f"OpenProcessToken(winlogon) failed: {kernel32.GetLastError()}"
                )

            h_dup_token = wt.HANDLE()
            if not advapi32.DuplicateTokenEx(
                h_token,
                TOKEN_ALL_ACCESS,
                None,
                SecurityImpersonation,
                TokenPrimary,
                ctypes.byref(h_dup_token),
            ):
                kernel32.CloseHandle(h_token)
                kernel32.CloseHandle(h_winlogon)
                raise RuntimeError(
                    f"DuplicateTokenEx failed: {kernel32.GetLastError()}"
                )
            kernel32.CloseHandle(h_token)
            kernel32.CloseHandle(h_winlogon)
            eprint("  SYSTEM token duplicated OK")

            # ── Prepare temp files ───────────────────────────────
            tmp_dir = tempfile.gettempdir()
            script_path = os.path.join(tmp_dir, f"_au_{uuid.uuid4().hex[:12]}.py")
            pwd_path = os.path.join(tmp_dir, f"_au_{uuid.uuid4().hex[:12]}.dat")
            log_path = os.path.join(tmp_dir, f"_au_{uuid.uuid4().hex[:12]}.log")
            bat_path = os.path.join(tmp_dir, f"_au_{uuid.uuid4().hex[:12]}.cmd")

            def _cleanup_temp_files():
                for temp_path in [script_path, pwd_path, bat_path]:
                    try:
                        if temp_path == pwd_path and os.path.exists(temp_path):
                            with open(temp_path, "w") as f:
                                f.write("X" * 256)
                        os.remove(temp_path)
                    except FileNotFoundError:
                        pass
                    except Exception:
                        pass

            helper_code = (
                "import ctypes, ctypes.wintypes as wt, sys, os, time\n"
                "\n"
                f'PWD_FILE = r"{pwd_path}"\n'
                f'LOG_FILE = r"{log_path}"\n'
                f'SCRIPT_FILE = r"{script_path}"\n'
                "\n"
                "def log(msg):\n"
                "    print(msg, flush=True)\n"
                "log('OK: helper started')\n"
                "\n"
                "\n"
                "try:\n"
                "    with open(PWD_FILE, 'r') as f:\n"
                "        password = f.read().strip()\n"
                "    with open(PWD_FILE, 'w') as f:\n"
                "        f.write('X' * 256)\n"
                "    os.remove(PWD_FILE)\n"
                "    log('OK: password read and file shredded')\n"
                "except Exception as e:\n"
                "    log(f'ERROR reading password: {e}')\n"
                "    sys.exit(1)\n"
                "\n"
                "if not password:\n"
                "    log('ERROR: empty password')\n"
                "    sys.exit(1)\n"
                "\n"
                "user32 = ctypes.windll.user32\n"
                "kernel32 = ctypes.windll.kernel32\n"
                "\n"
                "INPUT_KEYBOARD = 1\n"
                "KEYEVENTF_UNICODE = 0x0004\n"
                "KEYEVENTF_KEYUP = 0x0002\n"
                "VK_RETURN = 0x0D\n"
                "VK_ESCAPE = 0x1B\n"
                "DESKTOP_ALL_ACCESS = 0x01FF\n"
                "\n"
                "class KEYBDINPUT(ctypes.Structure):\n"
                "    _fields_ = [('wVk', wt.WORD), ('wScan', wt.WORD),\n"
                "                ('dwFlags', wt.DWORD), ('time', wt.DWORD),\n"
                "                ('dwExtraInfo', ctypes.POINTER(ctypes.c_ulong))]\n"
                "class MOUSEINPUT(ctypes.Structure):\n"
                "    _fields_ = [('dx', wt.LONG), ('dy', wt.LONG),\n"
                "                ('mouseData', wt.DWORD), ('dwFlags', wt.DWORD),\n"
                "                ('time', wt.DWORD),\n"
                "                ('dwExtraInfo', ctypes.POINTER(ctypes.c_ulong))]\n"
                "class HARDWAREINPUT(ctypes.Structure):\n"
                "    _fields_ = [('uMsg', wt.DWORD), ('wParamL', wt.WORD), ('wParamH', wt.WORD)]\n"
                "class _U(ctypes.Union):\n"
                "    _fields_ = [('mi', MOUSEINPUT), ('ki', KEYBDINPUT), ('hi', HARDWAREINPUT)]\n"
                "class INPUT(ctypes.Structure):\n"
                "    _fields_ = [('type', wt.DWORD), ('union', _U)]\n"
                "user32.OpenInputDesktop.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]\n"
                "user32.OpenInputDesktop.restype = wt.HANDLE\n"
                "user32.OpenDesktopW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.BOOL, wt.DWORD]\n"
                "user32.OpenDesktopW.restype = wt.HANDLE\n"
                "user32.SetThreadDesktop.argtypes = [wt.HANDLE]\n"
                "user32.SetThreadDesktop.restype = wt.BOOL\n"
                "user32.CloseDesktop.argtypes = [wt.HANDLE]\n"
                "user32.CloseDesktop.restype = wt.BOOL\n"
                "user32.SendInput.argtypes = [wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int]\n"
                "user32.SendInput.restype = wt.UINT\n"
                "\n"
                "\n"
                "def send_vk(vk):\n"
                "    inp = (INPUT * 2)()\n"
                "    inp[0].type = INPUT_KEYBOARD; inp[0].union.ki.wVk = vk; inp[0].union.ki.dwFlags = 0\n"
                "    inp[1].type = INPUT_KEYBOARD; inp[1].union.ki.wVk = vk; inp[1].union.ki.dwFlags = KEYEVENTF_KEYUP\n"
                "    n = user32.SendInput(2, inp, ctypes.sizeof(INPUT))\n"
                "    log(f'  send_vk(0x{vk:02X}) -> {n}')\n"
                "    return n\n"
                "\n"
                "def send_char(ch):\n"
                "    sc = ord(ch)\n"
                "    inp = (INPUT * 2)()\n"
                "    inp[0].type = INPUT_KEYBOARD; inp[0].union.ki.wVk = 0; inp[0].union.ki.wScan = sc; inp[0].union.ki.dwFlags = KEYEVENTF_UNICODE\n"
                "    inp[1].type = INPUT_KEYBOARD; inp[1].union.ki.wVk = 0; inp[1].union.ki.wScan = sc; inp[1].union.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP\n"
                "    n = user32.SendInput(2, inp, ctypes.sizeof(INPUT))\n"
                "    return n\n"
                "\n"
                "desktop_ready = False\n"
                "h_desktop = user32.OpenInputDesktop(0, True, DESKTOP_ALL_ACCESS)\n"
                "if h_desktop:\n"
                "    if user32.SetThreadDesktop(h_desktop):\n"
                "        log('OK: switched to input desktop')\n"
                "        desktop_ready = True\n"
                "    else:\n"
                "        log(f'WARN: SetThreadDesktop err={kernel32.GetLastError()}')\n"
                "else:\n"
                "    log(f'WARN: OpenInputDesktop err={kernel32.GetLastError()}')\n"
                "    h_desktop = user32.OpenDesktopW('Winlogon', 0, True, DESKTOP_ALL_ACCESS)\n"
                "    if h_desktop and user32.SetThreadDesktop(h_desktop):\n"
                "        log('OK: switched to Winlogon desktop')\n"
                "        desktop_ready = True\n"
                "if not desktop_ready:\n"
                "    log('ERROR: could not switch to lock-screen input desktop')\n"
                "    sys.exit(4)\n"
                "\n"
                "log('Step 1: dismissing lock overlay...')\n"
                "if send_vk(VK_ESCAPE) != 2:\n"
                "    log('WARN: Escape key was not accepted by SendInput')\n"
                "time.sleep(2.0)\n"
                "\n"
                "# Re-acquire the input desktop after transition.\n"
                "# Pressing Escape switches the input desktop from\n"
                "# LockApp overlay to LogonUI credential screen.\n"
                "# Our thread is still on the OLD desktop - must switch.\n"
                "if h_desktop:\n"
                "    user32.CloseDesktop(h_desktop)\n"
                "    h_desktop = None\n"
                "desktop_ready = False\n"
                "h_desktop = user32.OpenInputDesktop(0, True, DESKTOP_ALL_ACCESS)\n"
                "if h_desktop:\n"
                "    if user32.SetThreadDesktop(h_desktop):\n"
                "        log('OK: re-acquired input desktop after transition')\n"
                "        desktop_ready = True\n"
                "    else:\n"
                "        log(f'WARN: SetThreadDesktop(2) err={kernel32.GetLastError()}')\n"
                "else:\n"
                "    err = kernel32.GetLastError()\n"
                "    log(f'WARN: OpenInputDesktop(2) err={err}')\n"
                "    # Try explicit Winlogon desktop\n"
                "    h_desktop = user32.OpenDesktopW('Winlogon', 0, True, DESKTOP_ALL_ACCESS)\n"
                "    if h_desktop and user32.SetThreadDesktop(h_desktop):\n"
                "        log('OK: re-acquired Winlogon desktop after transition')\n"
                "        desktop_ready = True\n"
                "if not desktop_ready:\n"
                "    log('ERROR: could not re-acquire lock-screen input desktop')\n"
                "    sys.exit(5)\n"
                "\n"
                "log(f'Step 2: typing password ({len(password)} chars)...')\n"
                "typed = 0\n"
                "for idx, ch in enumerate(password, 1):\n"
                "    n = send_char(ch)\n"
                "    if n == 2:\n"
                "        typed += 1\n"
                "    else:\n"
                "        log(f'ERROR: char {idx} SendInput returned {n}')\n"
                "    time.sleep(0.05)\n"
                "log(f'  chars sent: {typed}/{len(password)}')\n"
                "if typed != len(password):\n"
                "    sys.exit(6)\n"
                "time.sleep(0.3)\n"
                "\n"
                "log('Step 3: pressing Enter...')\n"
                "enter_sent = send_vk(VK_RETURN)\n"
                "if enter_sent != 2:\n"
                "    log(f'WARN: Enter key returned {enter_sent}; continuing because password characters were sent')\n"
                "time.sleep(3.0)\n"
                "\n"
                "if h_desktop:\n"
                "    user32.CloseDesktop(h_desktop)\n"
                "password = None\n"
                "log('OK: unlock finished')\n"
                "\n"
                "try:\n"
                "    os.remove(SCRIPT_FILE)\n"
                "except Exception:\n"
                "    pass\n"
            )
            python_exe = sys.executable

            with open(script_path, "w", encoding="utf-8") as f:
                f.write(helper_code)
            with open(pwd_path, "w") as f:
                f.write(password)
            with open(bat_path, "w") as f:
                f.write("@echo off\r\n")
                f.write(f'"{python_exe}" "{script_path}" >> "{log_path}" 2>&1\r\n')
                f.write("exit /b %ERRORLEVEL%\r\n")

            # ── Launch as SYSTEM via CreateProcessAsUser ──────────
            CREATE_NO_WINDOW = 0x08000000
            CREATE_UNICODE_ENVIRONMENT = 0x00000400

            class STARTUPINFOW(ctypes.Structure):
                _fields_ = [
                    ("cb", wt.DWORD), ("lpReserved", wt.LPWSTR),
                    ("lpDesktop", wt.LPWSTR), ("lpTitle", wt.LPWSTR),
                    ("dwX", wt.DWORD), ("dwY", wt.DWORD),
                    ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
                    ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD),
                    ("dwFillAttribute", wt.DWORD), ("dwFlags", wt.DWORD),
                    ("wShowWindow", wt.WORD), ("cbReserved2", wt.WORD),
                    ("lpReserved2", ctypes.POINTER(ctypes.c_byte)),
                    ("hStdInput", wt.HANDLE), ("hStdOutput", wt.HANDLE),
                    ("hStdError", wt.HANDLE),
                ]

            class PROCESS_INFORMATION(ctypes.Structure):
                _fields_ = [
                    ("hProcess", wt.HANDLE), ("hThread", wt.HANDLE),
                    ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD),
                ]

            cmd_exe = os.path.join(
                os.environ.get("SystemRoot", r"C:\Windows"),
                "System32",
                "cmd.exe",
            )
            cmd_line = f'"{cmd_exe}" /d /c "{bat_path}"'
            cmd_buffer = ctypes.create_unicode_buffer(cmd_line)

            si = STARTUPINFOW()
            si.cb = ctypes.sizeof(STARTUPINFOW)
            si.lpDesktop = "winsta0\\Winlogon"
            pi = PROCESS_INFORMATION()

            # Use CreateProcessWithTokenW instead of CreateProcessAsUserW.
            # CreateProcessAsUserW requires SeAssignPrimaryTokenPrivilege
            # (only SYSTEM has it). CreateProcessWithTokenW only needs
            # SeImpersonatePrivilege which admin accounts have.
            LOGON_WITH_PROFILE = 0x00000001

            advapi32.CreateProcessWithTokenW.restype = wt.BOOL
            advapi32.CreateProcessWithTokenW.argtypes = [
                wt.HANDLE,      # hToken
                wt.DWORD,       # dwLogonFlags
                wt.LPCWSTR,     # lpApplicationName
                wt.LPWSTR,      # lpCommandLine
                wt.DWORD,       # dwCreationFlags
                ctypes.c_void_p,  # lpEnvironment
                wt.LPCWSTR,     # lpCurrentDirectory
                ctypes.POINTER(STARTUPINFOW),   # lpStartupInfo
                ctypes.POINTER(PROCESS_INFORMATION),  # lpProcessInformation
            ]

            kernel32.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
            kernel32.WaitForSingleObject.restype = wt.DWORD
            kernel32.GetExitCodeProcess.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]
            kernel32.GetExitCodeProcess.restype = wt.BOOL
            kernel32.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]
            kernel32.TerminateProcess.restype = wt.BOOL

            eprint("  Launching SYSTEM process via CreateProcessWithTokenW...")
            ok = advapi32.CreateProcessWithTokenW(
                h_dup_token,
                LOGON_WITH_PROFILE,
                cmd_exe,
                cmd_buffer,
                CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                None,
                None,
                ctypes.byref(si),
                ctypes.byref(pi),
            )

            if not ok:
                err = kernel32.GetLastError()
                kernel32.CloseHandle(h_dup_token)
                _cleanup_temp_files()
                raise RuntimeError(f"CreateProcessWithTokenW failed: err={err}")

            eprint(f"  SYSTEM child PID={pi.dwProcessId}")
            kernel32.CloseHandle(h_dup_token)

            # Wait for the child to finish and verify that it really sent input.
            WAIT_TIMEOUT = 0x00000102
            WAIT_FAILED = 0xFFFFFFFF
            STILL_ACTIVE = 259

            wait_result = kernel32.WaitForSingleObject(pi.hProcess, 15000)
            if wait_result == WAIT_TIMEOUT:
                kernel32.TerminateProcess(pi.hProcess, 1)
                kernel32.WaitForSingleObject(pi.hProcess, 2000)

            exit_code = wt.DWORD(STILL_ACTIVE)
            if not kernel32.GetExitCodeProcess(pi.hProcess, ctypes.byref(exit_code)):
                exit_code.value = STILL_ACTIVE

            kernel32.CloseHandle(pi.hProcess)
            kernel32.CloseHandle(pi.hThread)

            time.sleep(0.5)
            log_lines = []
            if os.path.exists(log_path):
                with open(log_path, "r", errors="replace") as f:
                    log_lines = [line.rstrip() for line in f.read().splitlines()]
                for line in log_lines:
                    if line:
                        eprint(f"  [unlock-sys] {line}")
                os.remove(log_path)
            else:
                eprint("  [unlock-sys] No log file found")

            chars_line = next((
                line for line in log_lines if "chars sent:" in line
            ), None)
            typed_ok = False
            if chars_line:
                try:
                    sent_text = chars_line.split("chars sent:", 1)[1].strip()
                    sent, total = sent_text.split("/", 1)
                    typed_ok = int(sent) == int(total) and int(total) > 0
                except Exception:
                    typed_ok = False

            helper_error = None
            if wait_result == WAIT_TIMEOUT:
                helper_error = "Unlock helper timed out before sending input"
            elif wait_result == WAIT_FAILED:
                helper_error = f"Unlock helper wait failed: {kernel32.GetLastError()}"
            elif exit_code.value != 0:
                helper_error = f"Unlock helper exited with code {exit_code.value}"
            elif not log_lines:
                helper_error = "Unlock helper produced no log output"
            elif not any("OK: unlock finished" in line for line in log_lines):
                helper_error = "Unlock helper did not finish"
            elif not typed_ok:
                helper_error = "Unlock helper did not send all password characters"

            detail = "; ".join(log_lines[-8:])
            _cleanup_temp_files()

            if helper_error:
                if detail:
                    raise RuntimeError(f"{helper_error}. Helper log: {detail}")
                raise RuntimeError(helper_error)

            self.send_response(cmd_id, success=True, data={
                "status": "unlock_input_sent",
                "helperExitCode": exit_code.value,
            })
        except Exception as exc:
            eprint(f"Unlock error: {exc}")
            import traceback; traceback.print_exc(file=sys.stderr)
            self.send_response(cmd_id, success=False, error=str(exc))
        finally:
            # Scrub password from local scope
            password = None  # noqa: F841

    # ═══════════════════════════════════════════════════════════════
    #  ENUMERATE CHILDREN (for Data Iterator node)
    # ═══════════════════════════════════════════════════════════════

    def _iterator_items_for_mode(self, child_elements, sort_by, item_mode, has_child_filter):
        """Return logical iterator items without losing explicit leaf iteration."""
        if has_child_filter or item_mode == "directChildren" or len(child_elements) < 4:
            return child_elements, "directChildren"

        grouped = self._infer_visual_iterator_items(child_elements, sort_by)
        if item_mode == "visualGroups":
            return (grouped, "visualGroups") if grouped else (child_elements, "directChildren")

        if grouped and 1 < len(grouped) < len(child_elements):
            return grouped, "visualGroups"
        return child_elements, "directChildren"

    def _infer_visual_iterator_items(self, child_elements, sort_by):
        visible = [
            e for e in child_elements
            if not e.get("isOffscreen") and e.get("boundingBox", {}).get("width", 0) > 0
            and e.get("boundingBox", {}).get("height", 0) > 0
        ]
        if len(visible) < 4:
            return []

        rows = self._cluster_iterator_rows(visible)
        groups = []
        for row in rows:
            cells = self._cluster_iterator_columns(row)
            if len(cells) == 1 and len(row) <= 1:
                continue
            groups.extend(cells)

        logical_items = []
        for index, group in enumerate(groups):
            if len(group) <= 1:
                logical_items.extend(group)
                continue
            logical_items.append(self._make_visual_iterator_item(group, index))

        if len(logical_items) >= len(child_elements):
            return []
        if sort_by == "horizontal":
            logical_items.sort(key=lambda e: (e["boundingBox"]["x"], e["boundingBox"]["y"]))
        else:
            logical_items.sort(key=lambda e: (e["boundingBox"]["y"], e["boundingBox"]["x"]))
        return logical_items

    def _cluster_iterator_rows(self, elements):
        ordered = sorted(elements, key=lambda e: (e["boundingBox"]["y"], e["boundingBox"]["x"]))
        heights = [max(1, e["boundingBox"]["height"]) for e in ordered]
        gap_threshold = max(48, self._median(heights) * 2.0)
        rows = []
        current = []
        current_bottom = None

        for element in ordered:
            box = element["boundingBox"]
            top = box["y"]
            bottom = top + box["height"]
            if current and current_bottom is not None and top - current_bottom > gap_threshold:
                rows.append(current)
                current = [element]
                current_bottom = bottom
            else:
                current.append(element)
                current_bottom = bottom if current_bottom is None else max(current_bottom, bottom)

        if current:
            rows.append(current)
        return rows

    def _cluster_iterator_columns(self, row):
        if len(row) <= 2:
            return [row]

        ordered = sorted(row, key=lambda e: self._center_x(e))
        centers = [self._center_x(e) for e in ordered]
        gaps = [centers[i + 1] - centers[i] for i in range(len(centers) - 1)]
        positive_gaps = [gap for gap in gaps if gap > 0]
        if not positive_gaps:
            return [row]

        threshold = max(96, self._median(positive_gaps) * 2.5)
        cells = []
        current = [ordered[0]]
        for index, gap in enumerate(gaps):
            if gap > threshold:
                cells.append(current)
                current = [ordered[index + 1]]
            else:
                current.append(ordered[index + 1])
        if current:
            cells.append(current)
        return cells

    def _make_visual_iterator_item(self, group, index):
        left = min(e["boundingBox"]["x"] for e in group)
        top = min(e["boundingBox"]["y"] for e in group)
        right = max(e["boundingBox"]["x"] + e["boundingBox"]["width"] for e in group)
        bottom = max(e["boundingBox"]["y"] + e["boundingBox"]["height"] for e in group)
        text_parts = []
        seen = set()
        for element in sorted(group, key=lambda e: (e["boundingBox"]["y"], e["boundingBox"]["x"])):
            value = (element.get("name") or element.get("value") or "").strip()
            if value and value not in seen:
                text_parts.append(value)
                seen.add(value)
        name = self._truncate(" | ".join(text_parts)) if text_parts else ""
        stable_seed = "|".join(str(e.get("stableId") or e.get("index") or "") for e in group)
        stable_seed += f"|{left},{top},{right},{bottom}"
        stable_id = "iter_group_" + hashlib.sha1(stable_seed.encode("utf-8", errors="ignore")).hexdigest()[:16]
        width = right - left
        height = bottom - top
        return {
            "index": index,
            "name": name,
            "value": name,
            "role": "visual_group",
            "type": "visual_group",
            "automationId": "",
            "className": "AutonionVisualItem",
            "stableId": stable_id,
            "boundingBox": {
                "x": left,
                "y": top,
                "width": width,
                "height": height,
            },
            "centerX": left + width // 2,
            "centerY": top + height // 2,
            "isEnabled": any(e.get("isEnabled", True) for e in group),
            "isOffscreen": all(e.get("isOffscreen", False) for e in group),
            "sourceChildCount": len(group),
        }

    def _center_x(self, element):
        box = element["boundingBox"]
        return box["x"] + box["width"] / 2

    def _median(self, values):
        if not values:
            return 0
        ordered = sorted(values)
        mid = len(ordered) // 2
        if len(ordered) % 2:
            return ordered[mid]
        return (ordered[mid - 1] + ordered[mid]) / 2

    def handle_get_foreground_hwnd(self, command):
        """Return the HWND of the current foreground window."""
        cmd_id = command.get("id")
        try:
            user32 = ctypes.windll.user32
            hwnd = user32.GetForegroundWindow()
            self.send_response(cmd_id, success=True, data={"hwnd": int(hwnd)})
        except Exception as exc:
            self.send_response(cmd_id, success=False, error=str(exc))

    def handle_focus_window(self, command):
        """Set the foreground window to the given HWND."""
        cmd_id = command.get("id")
        payload = command.get("payload", {})
        hwnd = payload.get("hwnd", 0)
        try:
            if not hwnd:
                self.send_response(cmd_id, success=False, error="No HWND provided")
                return
            user32 = ctypes.windll.user32
            # ShowWindow SW_RESTORE (9) to unminimize if needed
            if user32.IsIconic(int(hwnd)):
                user32.ShowWindow(int(hwnd), 9)
            # AllowSetForegroundWindow for our process
            user32.AllowSetForegroundWindow(-1)  # ASFW_ANY
            result = user32.SetForegroundWindow(int(hwnd))
            self.send_response(cmd_id, success=bool(result), data={"hwnd": int(hwnd)})
        except Exception as exc:
            self.send_response(cmd_id, success=False, error=str(exc))

    def handle_enumerate_children(self, command):
        """Find a UIA container element and return its direct children.

        The container is identified by matching attributes (automationId,
        className, name, role, stableId) against the live UIA tree.  The
        returned children include bounding boxes and text for each item.
        """
        cmd_id = command.get("id")
        payload = command.get("payload", {})
        sort_by = payload.get("sortBy", "auto")  # "auto", "vertical", "horizontal"
        item_mode = payload.get("itemMode", "auto")

        # Identification attributes for the container
        match_stable_id = payload.get("stableId")
        match_automation_id = payload.get("automationId")
        match_class_name = payload.get("className")
        match_name = payload.get("name")
        match_role = payload.get("role")

        # Optional child filters (only iterate children matching these)
        child_role_filter = payload.get("childRoleFilter")  # e.g. "50006"
        child_class_filter = payload.get("childClassNameFilter")  # e.g. "Image"

        try:
            # Refresh the accessibility tree so node_cache is populated
            self._get_accessibility_tree()

            # Step 1: find the container control
            container = None

            # Try stableId first (most reliable)
            if match_stable_id and match_stable_id in self.node_cache:
                container = self.node_cache[match_stable_id]

            # Fallback: scan all cached controls for matching attributes
            if container is None:
                for key, control in self.node_cache.items():
                    if not isinstance(key, str) or key.startswith("node_"):
                        continue  # skip node_id entries, use stableId entries
                    try:
                        matches = True
                        if match_automation_id:
                            if self._safe_attr(control, "AutomationId", "") != match_automation_id:
                                matches = False
                        if match_class_name and matches:
                            if self._safe_attr(control, "ClassName", "") != match_class_name:
                                matches = False
                        if match_name and matches:
                            if self._safe_attr(control, "Name", "") != match_name:
                                matches = False
                        if match_role and matches:
                            ctrl_role = self._get_role_name(self._safe_attr(control, "ControlType"))
                            if ctrl_role != match_role:
                                matches = False
                        if matches:
                            container = control
                            break
                    except Exception:
                        continue

            # Fallback: search from the desktop root by walking the UIA tree.
            # This handles the case where the target app is not the
            # foreground window (e.g. the Autonion overlay is on top).
            if container is None:
                try:
                    root = auto.GetRootControl()

                    def _find_container(control, depth=0):
                        """DFS to find a control matching the target attributes."""
                        if depth > 12 or not control:
                            return None
                        try:
                            ok = True
                            if match_class_name and ok:
                                if self._safe_attr(control, "ClassName", "") != match_class_name:
                                    ok = False
                            if match_automation_id and ok:
                                if self._safe_attr(control, "AutomationId", "") != match_automation_id:
                                    ok = False
                            if match_name and ok:
                                if self._safe_attr(control, "Name", "") != match_name:
                                    ok = False
                            if match_role and ok:
                                ctrl_role = self._get_role_name(self._safe_attr(control, "ControlType"))
                                if ctrl_role != match_role:
                                    ok = False
                            if ok:
                                return control
                        except Exception:
                            pass
                        try:
                            for child in control.GetChildren():
                                result = _find_container(child, depth + 1)
                                if result is not None:
                                    return result
                        except Exception:
                            pass
                        return None

                    found = _find_container(root)
                    if found:
                        container = found
                except Exception as root_err:
                    eprint(f"enumerate_children root fallback error: {root_err}")

            if container is None:
                self.send_response(cmd_id, success=False,
                                   error="Container element not found in the UIA tree")
                return

            # Step 2: enumerate direct children
            try:
                children = container.GetChildren()
            except Exception as child_err:
                self.send_response(cmd_id, success=False,
                                   error=f"Failed to get children: {child_err}")
                return

            child_elements = []
            for idx, child in enumerate(children):
                try:
                    rect = child.BoundingRectangle
                    if rect.width() <= 0 or rect.height() <= 0:
                        continue  # skip invisible/zero-size children

                    name = self._truncate(self._safe_attr(child, "Name", ""))
                    value = ""
                    try:
                        vp = child.GetValuePattern()
                        if vp:
                            value = self._truncate(vp.Value)
                    except Exception:
                        pass

                    automation_id = self._safe_attr(child, "AutomationId", "")
                    class_name = self._safe_attr(child, "ClassName", "")
                    control_type = self._safe_attr(child, "ControlType")
                    stable_id = self._stable_id(
                        control=child, rect=rect, path=f"iter/{idx}",
                        name=name, automation_id=automation_id,
                        class_name=class_name,
                    )

                    child_elements.append({
                        "index": idx,
                        "name": name,
                        "value": value,
                        "role": self._get_role_name(control_type),
                        "type": str(control_type),
                        "automationId": automation_id,
                        "className": class_name,
                        "stableId": stable_id,
                        "boundingBox": {
                            "x": rect.left,
                            "y": rect.top,
                            "width": rect.width(),
                            "height": rect.height(),
                        },
                        "centerX": rect.left + rect.width() // 2,
                        "centerY": rect.top + rect.height() // 2,
                        "isEnabled": bool(self._safe_attr(child, "IsEnabled", True)),
                        "isOffscreen": bool(self._safe_attr(child, "IsOffscreen", False)),
                    })
                except Exception:
                    continue

            # Step 3: apply child filters (if any)
            unfiltered_count = len(child_elements)
            if child_role_filter:
                child_elements = [
                    e for e in child_elements
                    if e["role"] == child_role_filter
                ]
            if child_class_filter:
                child_elements = [
                    e for e in child_elements
                    if e["className"] == child_class_filter
                ]

            # Step 4: infer logical visual items unless direct leaf mode was requested.
            direct_child_count = len(child_elements)
            child_elements, item_mode_used = self._iterator_items_for_mode(
                child_elements, sort_by, item_mode, bool(child_role_filter or child_class_filter)
            )

            # Step 5: sort by the requested direction
            if sort_by == "vertical":
                child_elements.sort(key=lambda e: e["boundingBox"]["y"])
            elif sort_by == "horizontal":
                child_elements.sort(key=lambda e: e["boundingBox"]["x"])
            # "auto" keeps tree order (already the order from GetChildren)

            # Step 6: auto-recurse if container is a Pane with 0 items
            # Common mistake: user picks a parent wrapper (e.g. CtrlNotifySink)
            # instead of the inner list (e.g. DUIListView). Check children
            # for a List/Grid/Tree and use that instead.
            if len(child_elements) == 0 and container is not None:
                inner = self._find_inner_iterable_container(container)
                if inner is not None:
                    eprint("enumerate_children: auto-correcting to inner iterable container")
                    try:
                        inner_children = inner.GetChildren()
                        child_elements = []
                        for idx2, ch in enumerate(inner_children):
                            try:
                                rect2 = ch.BoundingRectangle
                                if rect2.width() <= 0 or rect2.height() <= 0:
                                    continue
                                name2 = self._truncate(self._safe_attr(ch, "Name", ""))
                                value2 = ""
                                try:
                                    vp2 = ch.GetValuePattern()
                                    if vp2:
                                        value2 = self._truncate(vp2.Value)
                                except Exception:
                                    pass
                                aid2 = self._safe_attr(ch, "AutomationId", "")
                                cn2 = self._safe_attr(ch, "ClassName", "")
                                ct2 = self._safe_attr(ch, "ControlType")
                                sid2 = self._stable_id(
                                    control=ch, rect=rect2, path=f"iter/{idx2}",
                                    name=name2, automation_id=aid2, class_name=cn2,
                                )
                                child_elements.append({
                                    "index": idx2,
                                    "name": name2,
                                    "value": value2,
                                    "role": self._get_role_name(ct2),
                                    "type": str(ct2),
                                    "automationId": aid2,
                                    "className": cn2,
                                    "stableId": sid2,
                                    "boundingBox": {
                                        "x": rect2.left,
                                        "y": rect2.top,
                                        "width": rect2.width(),
                                        "height": rect2.height(),
                                    },
                                    "centerX": rect2.left + rect2.width() // 2,
                                    "centerY": rect2.top + rect2.height() // 2,
                                    "isEnabled": bool(self._safe_attr(ch, "IsEnabled", True)),
                                    "isOffscreen": bool(self._safe_attr(ch, "IsOffscreen", False)),
                                })
                            except Exception:
                                continue
                        unfiltered_count = len(child_elements)
                        direct_child_count = len(child_elements)
                        item_mode_used = "directChildren"
                    except Exception:
                        pass

            # Step 7: determine container suitability
            suitability = self._container_suitability(container)

            self.send_response(cmd_id, success=True, data={
                "children": child_elements,
                "count": len(child_elements),
                "unfilteredCount": unfiltered_count,
                "directChildCount": direct_child_count,
                "itemModeUsed": item_mode_used,
                "containerSuitability": suitability,
            })
        except Exception as exc:
            eprint(f"enumerate_children error: {exc}")
            self.send_response(cmd_id, success=False, error=str(exc))


    # ═══════════════════════════════════════════════════════════════
    #  CONTAINER SUITABILITY & AUTO-RECURSE HELPERS
    # ═══════════════════════════════════════════════════════════════

    # UIA control type IDs for iterable containers
    _ITERABLE_CONTROL_TYPES = {
        50008,   # List
        50012,   # DataGrid
        50023,   # Tree
        50025,   # Tab
    }

    # ClassNames that typically indicate iterable containers
    _ITERABLE_CLASS_HINTS = {
        "listview", "duilistview", "syslistview32", "listbox",
        "datagridview", "treeview", "systreeview32", "tabcontrol",
        "gridview", "itemscontrol", "scrollviewer",
    }

    def _container_suitability(self, container):
        """Return a suitability label for the container element.

        Returns one of: "list", "tree", "grid", "tab", "pane", "unknown".
        """
        if container is None:
            return "unknown"
        try:
            ct = self._safe_attr(container, "ControlType")
            ct_int = int(ct) if ct else 0
        except (ValueError, TypeError):
            ct_int = 0

        if ct_int == 50008:
            return "list"
        if ct_int == 50023:
            return "tree"
        if ct_int == 50012:
            return "grid"
        if ct_int == 50025:
            return "tab"

        # Check className as a hint
        cn = self._safe_attr(container, "ClassName", "").lower()
        aid = self._safe_attr(container, "AutomationId", "").lower()
        for hint in self._ITERABLE_CLASS_HINTS:
            if hint in cn or hint in aid:
                return "list"

        if ct_int == 50033:  # Pane
            return "pane"
        return "unknown"

    def _find_inner_iterable_container(self, container, depth=0):
        """Recursively search immediate children for an iterable container.

        If the selected element is a generic Pane, look up to 3 levels deep
        for a child that is a List, Grid, Tree, etc.
        """
        if depth > 3 or container is None:
            return None
        try:
            for child in container.GetChildren():
                try:
                    ct = self._safe_attr(child, "ControlType")
                    ct_int = int(ct) if ct else 0
                except (ValueError, TypeError):
                    ct_int = 0

                if ct_int in self._ITERABLE_CONTROL_TYPES:
                    return child

                cn = self._safe_attr(child, "ClassName", "").lower()
                aid = self._safe_attr(child, "AutomationId", "").lower()
                for hint in self._ITERABLE_CLASS_HINTS:
                    if hint in cn or hint in aid:
                        return child

                # Recurse into Pane children
                if ct_int == 50033:
                    inner = self._find_inner_iterable_container(child, depth + 1)
                    if inner is not None:
                        return inner
        except Exception:
            pass
        return None

    def handle_preview_children(self, command):
        """Lightweight preview: returns count and first 10 items.

        Uses the same container-finding logic as enumerate_children but
        returns only summaries for the UI preview dialog.
        """
        cmd_id = command.get("id")
        payload = command.get("payload", {})

        match_stable_id = payload.get("stableId")
        match_automation_id = payload.get("automationId")
        match_class_name = payload.get("className")
        match_name = payload.get("name")
        match_role = payload.get("role")

        try:
            self._get_accessibility_tree()

            container = None
            if match_stable_id and match_stable_id in self.node_cache:
                container = self.node_cache[match_stable_id]

            if container is None:
                for key, control in self.node_cache.items():
                    if not isinstance(key, str) or key.startswith("node_"):
                        continue
                    try:
                        matches = True
                        if match_automation_id:
                            if self._safe_attr(control, "AutomationId", "") != match_automation_id:
                                matches = False
                        if match_class_name and matches:
                            if self._safe_attr(control, "ClassName", "") != match_class_name:
                                matches = False
                        if match_name and matches:
                            if self._safe_attr(control, "Name", "") != match_name:
                                matches = False
                        if match_role and matches:
                            ctrl_role = self._get_role_name(self._safe_attr(control, "ControlType"))
                            if ctrl_role != match_role:
                                matches = False
                        if matches:
                            container = control
                            break
                    except Exception:
                        continue

            if container is None:
                self.send_response(cmd_id, success=True, data={
                    "count": 0,
                    "items": [],
                    "containerSuitability": "unknown",
                    "error": "Container not found in the accessibility tree",
                })
                return

            suitability = self._container_suitability(container)
            children = container.GetChildren()

            items = []
            total = 0
            for idx, child in enumerate(children):
                try:
                    rect = child.BoundingRectangle
                    if rect.width() <= 0 or rect.height() <= 0:
                        continue
                    total += 1
                    if len(items) < 10:
                        name = self._truncate(self._safe_attr(child, "Name", ""), 60)
                        cn = self._safe_attr(child, "ClassName", "")
                        ct = self._safe_attr(child, "ControlType")
                        items.append({
                            "name": name,
                            "className": cn,
                            "role": self._get_role_name(ct),
                        })
                except Exception:
                    continue

            # If zero children but has inner iterable, report that
            auto_corrected = False
            if total == 0:
                inner = self._find_inner_iterable_container(container)
                if inner is not None:
                    auto_corrected = True
                    suitability = self._container_suitability(inner)
                    try:
                        for idx, ch in enumerate(inner.GetChildren()):
                            try:
                                rect = ch.BoundingRectangle
                                if rect.width() <= 0 or rect.height() <= 0:
                                    continue
                                total += 1
                                if len(items) < 10:
                                    name = self._truncate(self._safe_attr(ch, "Name", ""), 60)
                                    cn = self._safe_attr(ch, "ClassName", "")
                                    ct = self._safe_attr(ch, "ControlType")
                                    items.append({
                                        "name": name,
                                        "className": cn,
                                        "role": self._get_role_name(ct),
                                    })
                            except Exception:
                                continue
                    except Exception:
                        pass

            self.send_response(cmd_id, success=True, data={
                "count": total,
                "items": items,
                "containerSuitability": suitability,
                "autoCorrected": auto_corrected,
            })
        except Exception as exc:
            eprint(f"preview_children error: {exc}")
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
