import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "install_codex_hooks.py"
SPEC = importlib.util.spec_from_file_location("install_codex_hooks", MODULE_PATH)
installer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)

HOOKS = (ROOT / "examples" / "codex-hooks.example.toml").read_text(encoding="utf-8")


class InstallCodexHooksTests(unittest.TestCase):
    def managed(self, body=HOOKS):
        return (
            installer.BEGIN_MARKER
            + "\n"
            + body.rstrip()
            + "\n"
            + installer.END_MARKER
            + "\n"
        )

    def test_unique_config_is_byte_for_byte_noop(self):
        original = "model = \"gpt-5\"\n\n" + self.managed()
        self.assertEqual(installer.merge_config_text(original, HOOKS), original)

    def test_current_legacy_plus_managed_duplicates_keep_first_set(self):
        legacy = HOOKS.rstrip() + "\n"
        original = (
            "model = \"gpt-5\"\n\n"
            + legacy
            + "\n[memories]\nuse_memories = true\n\n"
            + self.managed()
        )
        merged = installer.merge_config_text(original, HOOKS)

        for event in installer.EVENTS:
            self.assertEqual(merged.count(installer.expected_command(event)), 1)
        self.assertIn("[memories]\nuse_memories = true", merged)
        self.assertNotIn(installer.BEGIN_MARKER, merged)
        self.assertTrue(merged.index(installer.expected_command("UserPromptSubmit")) < merged.index("[memories]"))

    def test_trust_state_is_preserved_while_tail_duplicates_are_removed(self):
        state = (
            '[hooks.state."/tmp/config.toml:user_prompt_submit:0:0"]\n'
            'trusted_hash = "sha256:keep-me"\n'
        )
        original = HOOKS.rstrip() + "\n\n" + state + "\n" + self.managed()
        merged = installer.merge_config_text(original, HOOKS)
        self.assertIn(state.rstrip(), merged)
        self.assertEqual(merged.count("sha256:keep-me"), 1)

    def test_missing_events_are_appended_without_rewriting_existing_hook(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        existing = HOOKS[:first_group_end]
        original = "model = \"gpt-5\"\n\n" + existing
        merged = installer.merge_config_text(original, HOOKS)

        self.assertTrue(merged.startswith(original.rstrip()))
        for event in installer.EVENTS:
            self.assertEqual(merged.count(installer.expected_command(event)), 1)

    def test_user_hook_after_duplicate_fails_closed_to_protect_indices(self):
        user_group = (
            "[[hooks.UserPromptSubmit]]\n"
            "[[hooks.UserPromptSubmit.hooks]]\n"
            'type = "command"\n'
            'command = "$HOME/bin/my-own-hook"\n'
        )
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        unsafe = target_group + target_group + user_group

        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(unsafe, HOOKS)

    def test_user_hook_before_tail_duplicate_keeps_its_index_and_bytes(self):
        user_group = (
            "[[hooks.UserPromptSubmit]]\n"
            "[[hooks.UserPromptSubmit.hooks]]\n"
            'type = "command"\n'
            'command = "$HOME/bin/my-own-hook"\n'
        )
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        config = target_group + user_group + target_group

        merged = installer.merge_config_text(config, HOOKS)

        self.assertEqual(merged.count(installer.expected_command("UserPromptSubmit")), 1)
        self.assertIn(user_group.rstrip(), merged)

    def test_similar_but_modified_duplicate_fails_closed(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        modified = target_group.replace("Codex status light: working", "Custom working hook")

        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(target_group + modified, HOOKS)

    def test_string_whitespace_difference_is_not_treated_as_equivalent(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        modified = target_group.replace(
            'statusMessage = "Codex status light: working"',
            'statusMessage = "Codexstatuslight:working"',
        )

        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(target_group + modified, HOOKS)

    def test_quoted_user_hook_after_duplicate_is_counted_and_fails_closed(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        quoted_user_group = (
            '[[ hooks . "UserPromptSubmit" ]]\n'
            '[[ "hooks" . \'UserPromptSubmit\' . hooks ]]\n'
            'type = "command"\n'
            'command = "$HOME/bin/my-own-hook"\n'
        )

        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(target_group + target_group + quoted_user_group, HOOKS)

    def test_quoted_inline_hooks_assignment_fails_closed(self):
        inline = '"hooks" . UserPromptSubmit = [{ hooks = [] }]\n'
        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(inline, HOOKS)

    def test_unsupported_escaped_hook_header_fails_closed(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        escaped_user_group = (
            '[[ "\\U00000068ooks" . UserPromptSubmit ]]\n'
            '[[ "\\U00000068ooks" . UserPromptSubmit . hooks ]]\n'
            'type = "command"\n'
            'command = "$HOME/bin/my-own-hook"\n'
        )

        self.assertIn(r'"\U00000068ooks"', escaped_user_group)
        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(target_group + target_group + escaped_user_group, HOOKS)

    def test_trailing_user_comment_survives_duplicate_removal(self):
        first_group_end = HOOKS.index("[[hooks.PreToolUse]]")
        target_group = HOOKS[:first_group_end]
        comment = "# KEEP USER COMMENT\n"
        config = target_group + target_group + comment + "[memories]\nuse_memories = true\n"

        merged = installer.merge_config_text(config, HOOKS)

        self.assertIn(comment, merged)
        self.assertIn("[memories]\nuse_memories = true", merged)

    def test_malformed_markers_fail_without_guessing(self):
        with self.assertRaises(installer.HookInstallError):
            installer.merge_config_text(installer.BEGIN_MARKER + "\n" + HOOKS, HOOKS)

    def test_multiline_string_with_fake_hooks_fails_without_writing(self):
        fake = (
            'developer_instructions = """\n'
            + self.managed()
            + self.managed()
            + '"""\n'
        )
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            hooks = Path(directory) / "hooks.toml"
            config.write_text(fake, encoding="utf-8")
            hooks.write_text(HOOKS, encoding="utf-8")
            before = config.stat()
            before_bytes = config.read_bytes()

            with self.assertRaises(installer.HookInstallError):
                installer.write_merged_config(config, hooks)

            after = config.stat()
            self.assertEqual(config.read_bytes(), before_bytes)
            self.assertEqual(after.st_ino, before.st_ino)
            self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)

    def test_symlink_config_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "real-config.toml"
            config = root / "config.toml"
            hooks = root / "hooks.toml"
            target.write_text("model = \"gpt-5\"\n", encoding="utf-8")
            config.symlink_to(target)
            hooks.write_text(HOOKS, encoding="utf-8")
            before = target.read_bytes()

            with self.assertRaises(installer.HookInstallError):
                installer.write_merged_config(config, hooks)

            self.assertTrue(config.is_symlink())
            self.assertEqual(target.read_bytes(), before)

    def test_noop_write_preserves_inode_and_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            hooks = Path(directory) / "hooks.toml"
            config.write_text(self.managed(), encoding="utf-8")
            hooks.write_text(HOOKS, encoding="utf-8")
            before = config.stat()

            changed = installer.write_merged_config(config, hooks)
            after = config.stat()

            self.assertFalse(changed)
            self.assertEqual(before.st_ino, after.st_ino)
            self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)


if __name__ == "__main__":
    unittest.main()
