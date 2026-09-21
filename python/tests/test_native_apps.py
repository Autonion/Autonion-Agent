from pathlib import Path
import sys
import unittest
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_apps import native_identity, resolve_app, window_matches, open_verified_app


class NativeAppTests(unittest.TestCase):
    def setUp(self):
        self.app = {'name': 'ChatGPT', 'kind': 'packaged', 'aumid': 'OpenAI.ChatGPT_abc!App'}
        self.window = {'hwnd': 7, 'title': 'ChatGPT', 'processId': 10, 'isVisible': True, 'isMinimized': False}

    def test_packaged_identity_is_resolved_and_web_shortcuts_are_excluded(self):
        web = {'name': 'ChatGPT', 'kind': 'win32', 'path': r'C:\links\ChatGPT.lnk',
               'executable': r'C:\Chrome\chrome.exe', 'arguments': '--app=https://chatgpt.com'}
        self.assertIsNone(native_identity(web))
        self.assertEqual(resolve_app('chatgpt', [web, self.app]), self.app)
        with self.assertRaisesRegex(RuntimeError, 'not found'):
            resolve_app('ChatGPT', [web])

    def test_ambiguous_apps_are_not_arbitrarily_launched(self):
        other = dict(self.app, aumid='Another.App_abc!App')
        with self.assertRaisesRegex(RuntimeError, 'Multiple'):
            resolve_app('ChatGPT', [self.app, other])

    def test_browser_window_with_same_title_is_not_native_app_evidence(self):
        self.assertFalse(window_matches(self.app, self.window, get_aumid=lambda pid: None))
        self.assertFalse(window_matches(self.app, self.window, get_aumid=lambda pid: 'Other.App!App'))
        self.assertTrue(window_matches(self.app, self.window, get_aumid=lambda pid: self.app['aumid']))

    def test_win32_identity_checks_executable_not_window_title(self):
        app = {'kind': 'win32', 'executable': r'C:\Apps\Editor.exe'}
        self.assertTrue(window_matches(app, {'processPath': r'c:\apps\editor.exe'}))
        self.assertFalse(window_matches(app, {'title': 'Editor', 'processPath': r'C:\Chrome\chrome.exe'}))

    def launch(self, windows, foreground=True):
        now = [0.0]
        self.launcher = Mock()
        return open_verified_app('ChatGPT', [self.app], windows=windows,
            activate=lambda hwnd: True, describe=lambda hwnd: self.window,
            is_foreground=lambda hwnd: foreground, launch=self.launcher,
            matches=lambda app, window: window.get('processId') == 10,
            clock=lambda: now[0], sleep=lambda amount: now.__setitem__(0, now[0] + amount), timeout=0.5)

    def test_existing_window_is_focused_without_duplicate_launch(self):
        self.assertEqual(self.launch(lambda: [self.window])['status'], 'verified')
        self.launcher.assert_not_called()

    def test_launch_without_visible_foreground_window_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'could not be verified'):
            self.launch(lambda: [], foreground=False)
        self.launcher.assert_called_once()

    def test_window_appearing_after_launch_can_complete(self):
        count = [0]
        def windows():
            count[0] += 1
            return [] if count[0] == 1 else [self.window]
        self.assertEqual(self.launch(windows)['status'], 'verified')
        self.launcher.assert_called_once()


if __name__ == '__main__':
    unittest.main()
