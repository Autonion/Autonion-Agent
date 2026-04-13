import sys
import json
import base64
import time
import io
import uiautomation as auto
import pyautogui
from mss import mss

def eprint(*args, **kwargs):
    """Print to stderr for debugging, won't interfere with stdout JSON."""
    print(*args, file=sys.stderr, **kwargs)

class DesktopAgent:
    def __init__(self):
        auto.SetGlobalSearchTimeout(1.0)
        pyautogui.FAILSAFE = False
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
        action_type = command.get("payload", {}).get("type")
        target_index = command.get("payload", {}).get("targetIndex")
        
        try:
            if action_type == "wait":
                time.sleep(1)
            elif action_type == "click":
                self._click_element(target_index)
            elif action_type == "type":
                text = command.get("payload", {}).get("text", "")
                if target_index is not None:
                    self._click_element(target_index)
                pyautogui.write(text, interval=0.01)
            elif action_type == "scroll":
                direction = command.get("payload", {}).get("direction", "down")
                amount = -500 if direction == "down" else 500
                pyautogui.scroll(amount)
            elif action_type == "hotkey":
                keys = command.get("payload", {}).get("keys", [])
                if keys:
                    pyautogui.hotkey(*keys)
            elif action_type == "done":
                eprint("Agent indicates task is complete.")
            else:
                raise ValueError(f"Unsupported action: {action_type}")
                
            self.send_response(command.get("id"), success=True, data={"status": "executed"})
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
        if not fg_win:
            fg_win = root

        def walk(control, depth):
            nonlocal node_id_counter
            if depth > 10 or not control:
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
                        
                        self.node_cache[node_id] = control
                        
                        elements.append({
                            "id": node_id,
                            "name": name,
                            "role": self._get_role_name(control_type),
                            "type": str(control_type),
                            "boundingBox": {
                                "x": rect.left,
                                "y": rect.top,
                                "width": rect.width(),
                                "height": rect.height()
                            },
                            "isClickable": is_clickable,
                            "isKeyboardFocusable": is_focusable,
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

            for child in children:
                walk(child, depth + 1)

        walk(fg_win, 0)
        return elements

    def _get_role_name(self, control_type):
        type_str = str(control_type)
        return type_str.replace("ControlType", "").replace("Control", "")

    def _click_element(self, target_index):
        node_id = f"node_{target_index}"
        control = self.node_cache.get(node_id)
        if control:
            # Move mouse and click using pyautogui or UIA
            rect = control.BoundingRectangle
            center_x = rect.left + (rect.width() // 2)
            center_y = rect.top + (rect.height() // 2)
            pyautogui.moveTo(center_x, center_y, duration=0.2)
            pyautogui.click()
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
