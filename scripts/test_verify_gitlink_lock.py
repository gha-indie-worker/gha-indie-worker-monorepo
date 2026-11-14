"""Deterministic positive/negative mutations for gitlink+lock admission."""
import copy
import unittest
import tomllib

from verify_gitlink_lock import modules_from_text, tree_gitlinks, verify

API = "apps/gha-indie-worker-api-server.rs"
WEB = "apps/gha-indie-worker-web-server.rs"
LINKS = {API: "a" * 40, WEB: "b" * 40}
API_URL = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"
WEB_URL = "https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git"
MODULES = (
    '[submodule "' + API + '"]\n'
    '\tpath = ' + API + '\n'
    '\turl = ' + API_URL + '\n'
    '[submodule "' + WEB + '"]\n'
    '\tpath = ' + WEB + '\n'
    '\turl = ' + WEB_URL + '\n'
)
MANIFEST = '''[package]
org = "gha-indie-worker"
name = "gha-indie-worker-monorepo"
version = "0.1.0"
[interop.git]
consume_gitmodules = true
[workspace]
members = [
    "apps/gha-indie-worker-api-server.rs",
    "apps/gha-indie-worker-web-server.rs",
]
[dependencies]
"gha-indie-worker/gha-indie-worker-api-server" = "=0.1.0"
"gha-indie-worker/gha-indie-worker-web-server" = "=0.1.0"
'''
LOCK = '''version = 1
[[git-submodule]]
name = "apps/gha-indie-worker-api-server.rs"
path = "apps/gha-indie-worker-api-server.rs"
url = "https://github.com/gha-indie-worker/gha-indie-worker-api-server.rs.git"
commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
format = "tar.gz"
sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
size = 512
package = "gha-indie-worker/gha-indie-worker-api-server"
version = "0.1.0"
[[git-submodule]]
name = "apps/gha-indie-worker-web-server.rs"
path = "apps/gha-indie-worker-web-server.rs"
url = "https://github.com/gha-indie-worker/gha-indie-worker-web-server.rs.git"
commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
format = "tar.gz"
sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
size = 1024
package = "gha-indie-worker/gha-indie-worker-web-server"
version = "0.1.0"
'''


class ProvenanceTest(unittest.TestCase):
    def check_error(self, message, *, links=None, modules=MODULES, manifest=MANIFEST, lock=LOCK):
        errs = verify(LINKS if links is None else links, modules, manifest, lock)
        self.assertTrue(any(message in err for err in errs), errs)

    def test_valid_full_manifest_lock_alignment(self):
        self.assertEqual(verify(LINKS, MODULES, MANIFEST, LOCK), [])

    def test_unmaterialized_base_allowed_without_claim_of_lock_proof(self):
        manifest = '[package]\nname = "gha-indie-worker-monorepo"\n'
        self.assertEqual(verify(LINKS, MODULES, manifest, 'version = 1\n'), [])

    def test_empty_lock_fails_if_manifest_declares_workspace(self):
        self.check_error("no git-submodule lock receipts", lock="version = 1\n")

    def test_stale_web_server_commit_rejected(self):
        self.check_error("lock commit differs", lock=LOCK.replace("b" * 40, "f" * 40))

    def test_stale_api_commit_rejected(self):
        self.check_error("lock commit differs", lock=LOCK.replace("a" * 40, "e" * 40))

    def test_untracked_submodule_is_rejected(self):
        self.check_error("do not exactly match HEAD", links={API: "a" * 40})

    def test_missing_lock_entry_fails(self):
        self.check_error(
            "lock entries do not exactly match",
            lock=LOCK.split("[[git-submodule]]")[0] + "[[git-submodule]]" + LOCK.split("[[git-submodule]]")[1],
        )

    def test_duplicate_lock_entry_fails(self):
        self.check_error("duplicate or invalid path", lock=LOCK + LOCK.split("[[git-submodule]]")[1].join(["[[git-submodule]]", ""]))

    def test_lock_url_mismatch_rejected(self):
        self.check_error("lock URL differs", lock=LOCK.replace(WEB_URL, API_URL))

    def test_noncanonical_submodule_remote_rejected(self):
        self.check_error("noncanonical", modules=MODULES.replace(WEB_URL, "https://example.org/mirror.git"))

    def test_mismatched_workspace_member_rejected(self):
        self.check_error("workspace members do not exactly match", manifest=MANIFEST.replace(WEB, "apps/other.rs"))

    def test_dependency_version_mismatch_rejected(self):
        self.check_error("dependency/version mismatch", manifest=MANIFEST.replace('"=0.1.0"', '"=0.2.0"'))

    def test_missing_archive_hash_rejected(self):
        self.check_error("invalid or missing archive digest", lock=LOCK.replace("c" * 64, "bad"))

    def test_nonpositive_archive_size_rejected(self):
        self.check_error("invalid archive size", lock=LOCK.replace("size = 512", "size = 0"))

    def test_encoded_nul_in_ls_tree_record_is_not_accepted(self):
        with self.assertRaises(ValueError):
            tree_gitlinks(b"160000 commit " + b"a" * 40 + b"invalid\0")

    def test_actual_gitlink_tree_parser(self):
        raw = b"160000 commit " + b"a" * 40 + b"\t" + API.encode() + b"\0"
        raw += b"160000 commit " + b"b" * 40 + b"\t" + WEB.encode() + b"\0"
        raw += b"100644 blob " + b"c" * 40 + b"\t.gitmodules\0"
        self.assertEqual(tree_gitlinks(raw), LINKS)

    def test_duplicate_gitmodule_path_rejected(self):
        with self.assertRaises(ValueError):
            modules_from_text(MODULES + '[submodule "other"]\npath = ' + API + '\nurl = ' + API_URL + '\n')

    def test_invalid_toml_fails_closed(self):
        self.check_error("invalid metadata", lock="[[[git-submodule]\n")


if __name__ == "__main__":
    unittest.main()
