"""Source-only negative and positive tests for pinned submodule provenance."""
import unittest

from scripts.verify_gitlinks import REQUIRED_GITLINKS, tracked_gitlinks, validate

SHA_API = "a" * 40
SHA_WEB = "b" * 40
API = "apps/gha-indie-worker-api-server.rs"
WEB = "apps/gha-indie-worker-web-server.rs"
BASE_LINKS = {API: SHA_API, WEB: SHA_WEB}
BASE_MODULES = """[submodule "apps/gha-indie-worker-api-server.rs"]
    path = apps/gha-indie-worker-api-server.rs
    url = https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git
[submodule "apps/gha-indie-worker-web-server.rs"]
    path = apps/gha-indie-worker-web-server.rs
    url = https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git
"""


class GitlinkContractTests(unittest.TestCase):
    def assert_bad(self, modules=BASE_MODULES, links=None, lock="", package=""):
        errors = validate(modules, BASE_LINKS if links is None else links, lock, package)
        self.assertTrue(errors, "unsafe gitlink state unexpectedly accepted")
        return "\n".join(errors)

    def test_accepts_exact_pins(self):
        self.assertEqual(validate(BASE_MODULES, BASE_LINKS), [])
        self.assertEqual(set(BASE_LINKS), REQUIRED_GITLINKS)

    def test_rejects_untracked_declaration(self):
        errors = self.assert_bad(links={API: SHA_API})
        self.assertIn("untracked", errors)

    def test_rejects_undeclared_gitlink(self):
        errors = self.assert_bad(links={**BASE_LINKS, "apps/unexpected": "c" * 40})
        self.assertIn("undeclared", errors)

    def test_rejects_missing_required_api_link(self):
        modules = BASE_MODULES.split('[submodule "apps/gha-indie-worker-web-server.rs"]')[1]
        modules = '[submodule "apps/gha-indie-worker-web-server.rs"]' + modules
        errors = self.assert_bad(modules=modules, links={WEB: SHA_WEB})
        self.assertIn("missing mandatory", errors)

    def test_rejects_floating_branch_configuration(self):
        modules = BASE_MODULES.replace(
            "url = https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git",
            "url = https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git\n    branch = main",
        )
        self.assertIn("floating", self.assert_bad(modules=modules))

    def test_rejects_untrusted_git_host(self):
        modules = BASE_MODULES.replace("https://github.com/", "https://git.invalid/")
        self.assertIn("URL must equal", self.assert_bad(modules=modules))

    def test_rejects_relative_submodule_url(self):
        modules = BASE_MODULES.replace(
            "https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git",
            "../gha-indie-worker-web-server.rs",
        )
        self.assertIn("URL must equal", self.assert_bad(modules=modules))

    def test_rejects_submodule_path_traversal(self):
        modules = BASE_MODULES.replace(
            'submodule "apps/gha-indie-worker-web-server.rs"',
            'submodule "../gha-indie-worker-web-server.rs"',
        ).replace(
            "path = apps/gha-indie-worker-web-server.rs",
            "path = ../gha-indie-worker-web-server.rs",
        )
        self.assertIn("normalized", self.assert_bad(modules=modules))

    def test_rejects_duplicate_declaration_sections(self):
        self.assertIn("invalid .gitmodules", self.assert_bad(modules=BASE_MODULES + BASE_MODULES))

    def test_rejects_submodule_name_mismatch(self):
        modules = BASE_MODULES.replace(
            'submodule "apps/gha-indie-worker-web-server.rs"',
            'submodule "apps/other"',
        )
        self.assertIn("mismatched", self.assert_bad(modules=modules))

    def test_rejects_zero_or_non_sha_gitlink(self):
        self.assertIn("nonzero", self.assert_bad(links={API: "0" * 40, WEB: SHA_WEB}))
        self.assertIn("40-character", self.assert_bad(links={API: "deadbeef", WEB: SHA_WEB}))

    def test_rejects_stale_lock_commit(self):
        lock = (
            'version = 1\n[[git-submodule]]\n'
            f'path = "{API}"\ncommit = "{SHA_WEB}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"\n'
            '[[git-submodule]]\n'
            f'path = "{WEB}"\ncommit = "{SHA_WEB}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git"\n'
        )
        self.assertIn("does not match indexed gitlink", self.assert_bad(lock=lock))

    def test_accepts_lock_matching_exact_gitlinks(self):
        lock = (
            'version = 1\n[[git-submodule]]\n'
            f'path = "{API}"\ncommit = "{SHA_API}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"\n'
            '[[git-submodule]]\n'
            f'path = "{WEB}"\ncommit = "{SHA_WEB}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git"\n'
        )
        self.assertEqual(validate(BASE_MODULES, BASE_LINKS, lock), [])

    def test_rejects_partial_locked_submodule_set(self):
        lock = (
            'version = 1\n[[git-submodule]]\n'
            f'path = "{API}"\ncommit = "{SHA_API}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"\n'
        )
        self.assertIn("paths must equal", self.assert_bad(lock=lock))

    def test_rejects_duplicate_locked_submodule(self):
        record = (
            '[[git-submodule]]\n'
            f'path = "{API}"\ncommit = "{SHA_API}"\n'
            'url = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"\n'
        )
        self.assertIn("duplicate", self.assert_bad(lock="version = 1\n" + record + record))

    def test_rejects_workspaces_diverging_from_index(self):
        package = '[workspace]\nmembers = ["apps/gha-indie-worker-api-server.rs"]\n'
        self.assertIn("workspace members", self.assert_bad(package=package))

    def test_accepts_workspace_matching_index(self):
        package = (
            '[workspace]\nmembers = [\n'
            f'  "{API}",\n  "{WEB}",\n]\n'
        )
        self.assertEqual(validate(BASE_MODULES, BASE_LINKS, package=package), [])

    def test_rejects_malformed_toml(self):
        self.assertIn("invalid .zpkg.lock", self.assert_bad(lock="[[oops"))

    def test_parses_exact_git_index_entries(self):
        data = (
            b"100644 " + b"c" * 40 + b" 0\tREADME.md\0"
            + b"160000 " + SHA_API.encode() + b" 0\t" + API.encode() + b"\0"
            + b"160000 " + SHA_WEB.encode() + b" 0\t" + WEB.encode() + b"\0"
        )
        self.assertEqual(tracked_gitlinks(data), BASE_LINKS)

    def test_rejects_unmerged_gitlink_stage(self):
        data = b"160000 " + SHA_API.encode() + b" 2\t" + API.encode() + b"\0"
        with self.assertRaisesRegex(ValueError, "unmerged"):
            tracked_gitlinks(data)

    def test_rejects_duplicate_gitlink_index_entry(self):
        record = b"160000 " + SHA_API.encode() + b" 0\t" + API.encode() + b"\0"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            tracked_gitlinks(record + record)


if __name__ == "__main__":
    unittest.main()
