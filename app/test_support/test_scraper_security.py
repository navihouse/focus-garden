"""Offline privacy regression checks. All credentials and responses are synthetic."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import requests

SPEC = importlib.util.spec_from_file_location(
    'focus_scraper_security', Path(__file__).resolve().parents[1] / 'assets/study_scraper.py')
SCRAPER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SCRAPER
SPEC.loader.exec_module(SCRAPER)


class PrivacyTests(unittest.TestCase):
    def session(self, domain='chaoxing.com'):
        return SCRAPER.Http({'focus_fixture': 'synthetic-not-a-real-session'},
                            cookie_domain=domain)._session()

    def test_cookie_scope_matches_only_its_platform_over_https(self):
        for domain in ['chaoxing.com', 'icourse163.org']:
            session = self.session(domain)
            for target in ['https://' + domain, 'https://courses.' + domain]:
                request = session.prepare_request(requests.Request('GET', target))
                self.assertIn('focus_fixture=', request.headers.get('Cookie', ''))
            for target in ['http://' + domain, 'https://example.invalid',
                           'https://' + domain + '.example.invalid',
                           'https://not' + domain]:
                request = session.prepare_request(requests.Request('GET', target))
                self.assertNotIn('focus_fixture=', request.headers.get('Cookie', ''))

    def test_disallowed_destinations_never_reach_network_adapter(self):
        for target in ['http://mooc1.chaoxing.com/', 'https://example.invalid/',
                       'https://chaoxing.com.example.invalid/',
                       'https://www.icourse163.org/', 'https://chaoxing.com:444/',
                       'https://user@chaoxing.com/']:
            session = self.session()
            with patch.object(requests.adapters.HTTPAdapter, 'send') as send:
                with self.assertRaises(SCRAPER.HttpError):
                    session.get(target)
                send.assert_not_called()

    def test_redirects_cannot_escape_platform_or_downgrade_https(self):
        for destination in ['https://example.invalid/', 'http://mooc1.chaoxing.com/',
                            'https://www.icourse163.org/']:
            def redirect(adapter, request, **kwargs):
                response = requests.Response()
                response.status_code = 302
                response.headers['Location'] = destination
                response._content = b''
                response.url = request.url
                response.request = request
                return response
            with patch.object(requests.adapters.HTTPAdapter, 'send', autospec=True,
                              side_effect=redirect) as send:
                with self.assertRaises(SCRAPER.HttpError):
                    self.session().get('https://mooc1.chaoxing.com/')
                self.assertEqual(send.call_count, 1)

    def test_redirect_to_sibling_subdomain_still_works(self):
        seen = []
        def reply(adapter, request, **kwargs):
            seen.append(request)
            response = requests.Response()
            response.status_code = 302 if len(seen) == 1 else 200
            if len(seen) == 1:
                response.headers['Location'] = 'https://passport2.chaoxing.com/login'
            response._content = b''
            response.url = request.url
            response.request = request
            return response
        with patch.object(requests.adapters.HTTPAdapter, 'send', autospec=True,
                          side_effect=reply):
            response = self.session().get('https://mooc1.chaoxing.com/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(seen), 2)
        self.assertIn('focus_fixture=', seen[-1].headers.get('Cookie', ''))

    def test_unknown_platform_domain_is_rejected(self):
        with self.assertRaises(ValueError):
            self.session('example.invalid')


if __name__ == '__main__':
    unittest.main()
