import ast
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from unlock_verification import SessionSnapshot, wait_for_unlock, confirm_unlock_result


class UnlockVerificationTests(unittest.TestCase):
    def wait(self, query):
        self.now = 0.0
        def sleep(amount):
            self.now += amount
        return wait_for_unlock(7, timeout=0.5, query=query,
                               clock=lambda: self.now, sleep=sleep)

    def test_observed_unlock_succeeds(self):
        self.assertTrue(self.wait(lambda: SessionSnapshot(7, self.now >= 0.2, True, True)))

    def test_locked_or_unknown_session_does_not_succeed_after_timeout(self):
        self.assertFalse(self.wait(lambda: SessionSnapshot(7, False, True, True)))
        self.assertEqual(self.now, 0.5)
        self.assertFalse(self.wait(SessionSnapshot))

    def test_other_session_or_prelogin_without_user_is_not_success(self):
        for state in [SessionSnapshot(8, True, True, True), SessionSnapshot(7, True, True, False),
                      SessionSnapshot(7, True, False, True)]:
            self.assertFalse(self.wait(lambda: state))

    def test_input_only_helper_requires_observation(self):
        with patch('unlock_verification.wait_for_unlock', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'could not be confirmed'):
                confirm_unlock_result({'status': 'unlock_input_sent'}, 7)
        with patch('unlock_verification.wait_for_unlock', return_value=True):
            self.assertEqual(confirm_unlock_result({}, 7)['status'], 'unlock_confirmed')

    def test_native_verified_result_is_preserved(self):
        with patch('unlock_verification.wait_for_unlock', side_effect=AssertionError('unnecessary polling')):
            self.assertEqual(confirm_unlock_result({'message': 'unlock_confirmed'}, 7)['status'], 'unlock_confirmed')

    def handler(self, confirm):
        # Compile the real dispatch method without importing UI/input automation packages.
        tree = ast.parse((Path(__file__).resolve().parents[1] / 'desktop_agent.py').read_text(encoding='utf-8'))
        cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'DesktopAgent')
        method = next(node for node in cls.body if isinstance(node, ast.FunctionDef) and node.name == 'handle_unlock_desktop')
        namespace = {'query_console_session': lambda: SessionSnapshot(7), 'confirm_unlock_result': confirm,
                     'eprint': lambda *args: None, 'os': SimpleNamespace(name='nt')}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[method], type_ignores=[])), 'desktop_agent.py', 'exec'), namespace)
        return namespace['handle_unlock_desktop']

    def test_unconfirmed_service_attempt_does_not_submit_password_again(self):
        agent = SimpleNamespace(_try_unlock_via_service=Mock(return_value={'status': 'unlock_input_sent'}),
                                _try_unlock_via_installed_helper=Mock(), send_response=Mock())
        confirm = Mock(side_effect=RuntimeError('unlock not confirmed'))
        self.handler(confirm)(agent, {'id': 'test', 'payload': {'password': 'synthetic'}})
        agent._try_unlock_via_installed_helper.assert_not_called()
        self.assertFalse(agent.send_response.call_args.kwargs['success'])

    def test_failed_service_attempt_does_not_submit_password_again(self):
        agent = SimpleNamespace(_try_unlock_via_service=Mock(side_effect=RuntimeError('helper failed')),
                                _try_unlock_via_installed_helper=Mock(), send_response=Mock())
        self.handler(Mock())(agent, {'id': 'test', 'payload': {'password': 'synthetic'}})
        agent._try_unlock_via_installed_helper.assert_not_called()
        self.assertFalse(agent.send_response.call_args.kwargs['success'])

    def test_missing_service_can_use_legacy_helper(self):
        agent = SimpleNamespace(_try_unlock_via_service=Mock(return_value=None),
                                _try_unlock_via_installed_helper=Mock(return_value={}), send_response=Mock())
        self.handler(lambda result, session: {'status': 'unlock_confirmed'})(agent, {'id': 'test', 'payload': {'password': 'synthetic'}})
        agent._try_unlock_via_installed_helper.assert_called_once()
        self.assertTrue(agent.send_response.call_args.kwargs['success'])


if __name__ == '__main__':
    unittest.main()
