import sys
import json
import base64
import time
import io
import hashlib
import uiautomation as auto
import pyautogui
from mss import mss

def eprint(*args, **kwargs):
    """Print to stderr for debugging, won't interfere with stdout JSON."""
    print(*args, file=sys.stderr, **kwargs)

class DesktopAgent:
    def __init__(self):
        auto.SetGlobalSearchTimeout(1.0)
        pyautogui.FAILSAFE = True
        self.node_cache = {}

    def run(self):
        eprint("Python bridge starting up. Waiting for JSON commands on stdin...")
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            
            try:
                command = json.loads(line)
                action = command.get("action")
                payload = command.get("payload", {})
                
                if action == "ping":
                    self.send_response(command.get("id"), success=True, data="pong")
                elif action == "get_screen_state":
                    self.handle_get_screen_state(command)
                elif action == "execute_action":
                    self.handle_execute_action(command)
                else:
                    self.send_response(command.get("id"), success=False, error=f"Unknown action: {action}")
            except Exception as e:
                eprint(f"Error processing command {line}: {e}")
                self.send_response(None, success=False, error=str(e))

    def send_response(self, cmd_id, success, data=None, error=None):
        response = {
            "id": cmd_id,
            "success": success
        }
        if success and data is not None:
            response["data"] = data
        if not success and error:
            response["error"] = error
            
        json_resp = json.dumps(response)
        sys.stdout.write(json_resp + '\n')
        sys.stdout.flush()

    def handle_get_screen_state(self, command):
        tier = command.get("payload", {}).get("tier", "accessibilityOnly")
        eprint(f"Getting screen state with tier: {tier}")
        
        elements = self._get_accessibility_tree()
        
        screen_width, screen_height = pyautogui.size()
        
        screenshot_b64 = None
        if tier != "accessibilityOnly":
            screenshot_b64 = self._get_screenshot()
            
        self.send_response(command.get("id"), success=True, data={
            "elements": elements,
            "screenWidth": screen_width,
            "screenHeight": screen_height,
            "screenshotBase64": screenshot_b64
        })

    def handle_execute_action(self, command):
        payload = command.get("payload", {})
        action_type = payload.get("type")
        target_index = payload.get("targetIndex")
        target_stable_id = payload.get("targetStableId") or payload.get("stableId")
        
        try:
            if action_type == "wait":
                time.sleep(1)
            elif action_type == "click":
                self._click_element(target_index, target_stable_id)
            elif action_type == "type":
                text = payload.get("text") or ""
                if target_index is not None or target_stable_id:
                    self._click_element(target_index, target_stable_id)
                pyautogui.write(str(text), interval=0.01)
            elif action_type == "scroll":
                direction = payload.get("direction") or "down"
                amount = -500 if direction == "down" else 500
                pyautogui.scroll(amount)
            elif action_type == "hotkey":
                keys = payload.get("keys") or []
                if keys:
                    pyautogui.hotkey(*keys)
            elif action_type == "done":
                eprint("Agent indicates task is complete.")
            else:
                raise ValueError(f"Unsupported action: {action_type}")
                
            self.send_response(command.get("id"), success=True, data={
                "status": "executed",
                "action": action_type,
                "targetIndex": target_index,
                "targetStableId": target_stable_id
            })
        except Exception as e:
            eprint(f"Action execution error: {e}")
            self.send_response(command.get("id"), success=False, error=str(e))

    def _get_accessibility_tree(self):
        """Walks the UIA tree and returns actionable elements safely."""
        self.node_cache.clear()
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

        def walk(control, depth, path="0"):
            nonlocal node_id_counter
            if depth > 14 or not control:
                return

            try:
                rect = control.BoundingRectangle
                if rect.width() > 0 and rect.height() > 0:
                    control_type = control.ControlType
                    is_clickable = control_type in [
                        auto.ControlType.ButtonControl,
                        auto.ControlType.MenuItemControl,
                        auto.ControlType.TabItemControl,
                        auto.ControlType.HyperlinkControl,
                        auto.ControlType.ListItemControl,
                        auto.ControlType.CheckBoxControl,
                        auto.ControlType.RadioButtonControl
                    ]
                    
                    is_focusable = control_type in [
                        auto.ControlType.EditControl,
                        auto.ControlType.ComboBoxControl
                    ]
                    
                    name = ""
                    try:
                        name = control.Name
                        if name and len(name) > 100:
                            name = name[:97] + "..."
                    except:
                        pass
                        
                    value = ""
                    try:
                        if hasattr(control, 'GetValuePattern'):
                            val_pattern = control.GetValuePattern()
                            if val_pattern:
                                value = val_pattern.Value
                                if value and len(value) > 100:
                                    value = value[:97] + "..."
                    except:
                        pass
                        
                    if name or value or is_clickable or is_focusable:
                        node_id = f"node_{node_id_counter}"
                        node_id_counter += 1
                        automation_id = self._safe_attr(control, "AutomationId")
                        class_name = self._safe_attr(control, "ClassName")
                        framework_id = self._safe_attr(control, "FrameworkId")
                        process_id = self._safe_attr(control, "ProcessId", 0)
                        stable_id = self._stable_id(
                            control=control,
                            rect=rect,
                            path=path,
                            name=name,
                            value=value,
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
                                "height": rect.height()
                            },
                            "isClickable": is_clickable,
                            "isKeyboardFocusable": is_focusable,
                            "isEnabled": bool(self._safe_attr(control, "IsEnabled", True)),
                            "isFocused": bool(self._safe_attr(control, "HasKeyboardFocus", False)),
                            "isOffscreen": bool(self._safe_attr(control, "IsOffscreen", False)),
                            "value": value
                        })
            except Exception:
                # Catch bounding rectangle / general element access errors
                pass

            try:
                children = control.GetChildren()
            except Exception:
                # If COM hangs or fails on GetChildren, skip this branch gracefully
                children = []

            for index, child in enumerate(children):
                walk(child, depth + 1, f"{path}/{index}")

        walk(fg_win, 0)
        return elements

    def _get_role_name(self, control_type):
        type_str = str(control_type)
        return type_str.replace("ControlType", "").replace("Control", "")

    def _safe_attr(self, control, attr_name, default=""):
        try:
            value = getattr(control, attr_name)
            if value is None:
                return default
            return value
        except Exception:
            return default

    def _stable_id(self, control, rect, path, name, value, automation_id, class_name):
        control_type = self._safe_attr(control, "ControlType")
        process_id = self._safe_attr(control, "ProcessId", "")
        framework_id = self._safe_attr(control, "FrameworkId")
        bucketed_bounds = f"{rect.left // 8},{rect.top // 8},{rect.width() // 8},{rect.height() // 8}"
        raw = "|".join([
            str(process_id),
            str(framework_id),
            str(automation_id),
            str(class_name),
            str(control_type),
            str(name or value or ""),
            bucketed_bounds,
            path,
        ])
        return "uia_" + hashlib.sha1(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]

    def _click_element(self, target_index, stable_id=None):
        node_id = stable_id or f"node_{target_index}"
        control = self.node_cache.get(node_id)
        if control:
            # Move mouse and click using pyautogui or UIA
            rect = control.BoundingRectangle
            center_x = rect.left + (rect.width() // 2)
            center_y = rect.top + (rect.height() // 2)
            pyautogui.moveTo(center_x, center_y, duration=0.2)
            pyautogui.click()
            # Move mouse away to prevent hover tooltips from stealing foreground control
            pyautogui.moveTo(10, 10, duration=0.1)
        else:
            raise KeyError(f"Element {node_id} not found in cache")

    def _get_screenshot(self):
        with mss() as sct:
            # Grab the first monitor
            monitor = sct.monitors[1]
            sct_img = sct.grab(monitor)
            
            # Convert mss Image to PNG via PIL if needed, or raw RGB
            # Assuming mss output requires PIL to compress to PNG
            from PIL import Image
            img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
            
            # Scale down slightly to preserve tokens / payload size
            img.thumbnail((1280, 720))
            
            with io.BytesIO() as buf:
                img.save(buf, format="PNG", optimize=True)
                return base64.b64encode(buf.getvalue()).decode('utf-8')

if __name__ == "__main__":
    agent = DesktopAgent()
    agent.run()
