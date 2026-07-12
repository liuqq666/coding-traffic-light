#!/usr/bin/env python3
"""Install CodexStatusLight hooks without invalidating existing hook trust."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple


EVENTS: Tuple[str, ...] = (
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "Stop",
    "SubagentStop",
)
BEGIN_MARKER = "# BEGIN CodexStatusLight hooks"
END_MARKER = "# END CodexStatusLight hooks"

HEADER_RE = re.compile(r"^\s*(\[\[|\[)(.*?)(\]\]|\])\s*(?:#.*)?$")
BARE_KEY_RE = re.compile(r"[A-Za-z0-9_-]+")
COMMAND_RE = re.compile(
    r"^\s*command\s*=\s*(?:\"(?P<double>(?:[^\"\\]|\\.)*)\"|'(?P<single>[^']*)')\s*(?:#.*)?$"
)


class HookInstallError(RuntimeError):
    """Raised when an automatic edit could change another hook's identity."""


@dataclass(frozen=True)
class HandlerBlock:
    start: int
    end: int
    command: Optional[str]


@dataclass(frozen=True)
class HookGroup:
    event: str
    start: int
    end: int
    handlers: Tuple[HandlerBlock, ...]


def expected_command(event: str) -> str:
    return f"$HOME/.codex/bin/codex-light-hook {event}"


def command_from_lines(lines: Sequence[str]) -> Optional[str]:
    for line in lines:
        match = COMMAND_RE.match(line.rstrip("\r\n"))
        if match:
            return match.group("double") if match.group("double") is not None else match.group("single")
    return None


def parse_dotted_key(raw: str) -> Optional[List[str]]:
    keys: List[str] = []
    index = 0

    while index < len(raw):
        while index < len(raw) and raw[index].isspace():
            index += 1
        if index >= len(raw):
            return None

        if raw[index] == '"':
            start = index
            index += 1
            escaped = False
            while index < len(raw):
                character = raw[index]
                if character == '"' and not escaped:
                    index += 1
                    break
                if character == "\\" and not escaped:
                    escaped = True
                else:
                    escaped = False
                index += 1
            else:
                return None
            try:
                key = json.loads(raw[start:index])
            except (TypeError, ValueError, json.JSONDecodeError):
                return None
        elif raw[index] == "'":
            end = raw.find("'", index + 1)
            if end < 0:
                return None
            key = raw[index + 1 : end]
            index = end + 1
        else:
            match = BARE_KEY_RE.match(raw, index)
            if not match:
                return None
            key = match.group(0)
            index = match.end()

        keys.append(key)
        while index < len(raw) and raw[index].isspace():
            index += 1
        if index >= len(raw):
            return keys
        if raw[index] != ".":
            return None
        index += 1

    return None


def parse_table_header(line: str) -> Optional[Tuple[bool, List[str]]]:
    match = HEADER_RE.match(line.rstrip("\r\n"))
    if not match:
        return None
    opening, body, closing = match.groups()
    is_array = opening == "[["
    if (is_array and closing != "]]") or (not is_array and closing != "]"):
        return None
    path = parse_dotted_key(body)
    if not path:
        return None
    return is_array, path


def assignment_key_path(line: str) -> Tuple[bool, Optional[List[str]]]:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return False, None

    in_basic = False
    in_literal = False
    escaped = False
    for index, character in enumerate(line):
        if in_basic:
            if character == '"' and not escaped:
                in_basic = False
            if character == "\\" and not escaped:
                escaped = True
            else:
                escaped = False
            continue
        if in_literal:
            if character == "'":
                in_literal = False
            continue
        if character == '"':
            in_basic = True
            continue
        if character == "'":
            in_literal = True
            continue
        if character == "#":
            return False, None
        if character == "=":
            return True, parse_dotted_key(line[:index])
    return False, None


def is_group_boundary(line: str) -> bool:
    stripped = line.strip()
    return parse_table_header(line) is not None or stripped in {BEGIN_MARKER, END_MARKER}


def validate_supported_config(text: str, lines: Sequence[str]) -> None:
    if '"""' in text or "'''" in text:
        raise HookInstallError(
            "multiline TOML strings are not supported by the safe hook merger; config was not changed"
        )

    for line in lines:
        stripped = line.lstrip()
        header = parse_table_header(line)
        if stripped.startswith("[") and HEADER_RE.match(line.rstrip("\r\n")) and header is None:
            raise HookInstallError("unsupported table key syntax found; config was not changed")
        if header is None:
            has_assignment, key_path = assignment_key_path(line)
            if has_assignment and key_path is None:
                raise HookInstallError("unsupported assignment key syntax found; config was not changed")
            if key_path and key_path[0] == "hooks":
                raise HookInstallError("inline hooks configuration is not supported; config was not changed")
            continue

        is_array, path = header
        if not path or path[0] != "hooks":
            continue
        if not is_array and path[:2] == ["hooks", "state"]:
            continue
        if is_array and len(path) == 2:
            continue
        if is_array and len(path) == 3 and path[2] == "hooks":
            continue
        raise HookInstallError("unsupported hooks table shape found; config was not changed")


def parse_hook_groups(lines: Sequence[str]) -> List[HookGroup]:
    groups: List[HookGroup] = []
    index = 0

    while index < len(lines):
        header = parse_table_header(lines[index])
        if header is None or not header[0] or len(header[1]) != 2 or header[1][0] != "hooks":
            index += 1
            continue

        event = header[1][1]
        start = index
        index += 1
        handlers: List[HandlerBlock] = []

        while index < len(lines):
            stripped = lines[index].rstrip("\r\n")
            child = parse_table_header(stripped)
            if child is not None and child[0] and child[1] == ["hooks", event, "hooks"]:
                handler_start = index
                index += 1
                while index < len(lines) and not is_group_boundary(lines[index]):
                    index += 1
                handlers.append(
                    HandlerBlock(
                        start=handler_start,
                        end=index,
                        command=command_from_lines(lines[handler_start:index]),
                    )
                )
                continue

            if is_group_boundary(lines[index]):
                break
            index += 1

        groups.append(HookGroup(event=event, start=start, end=index, handlers=tuple(handlers)))

    return groups


def is_status_light_handler(group: HookGroup, handler: HandlerBlock) -> bool:
    return group.event in EVENTS and handler.command == expected_command(group.event)


def normalized_group(lines: Sequence[str], group: HookGroup) -> Tuple[str, ...]:
    normalized: List[str] = []
    for line in lines[group.start : group.end]:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        normalized.append(stripped)
    return tuple(normalized)


def removable_group_end(lines: Sequence[str], group: HookGroup) -> int:
    end = group.end
    while end > group.start:
        stripped = lines[end - 1].strip()
        if stripped and not stripped.startswith("#"):
            break
        end -= 1
    return end


def validate_markers(lines: Sequence[str]) -> None:
    active = False
    for line in lines:
        marker = line.strip()
        if marker == BEGIN_MARKER:
            if active:
                raise HookInstallError("nested CodexStatusLight hook markers found; config was not changed")
            active = True
        elif marker == END_MARKER:
            if not active:
                raise HookInstallError("unmatched CodexStatusLight END marker found; config was not changed")
            active = False
    if active:
        raise HookInstallError("unmatched CodexStatusLight BEGIN marker found; config was not changed")


def duplicate_group_ranges(lines: Sequence[str], groups: Sequence[HookGroup]) -> Tuple[List[Tuple[int, int]], Set[str]]:
    groups_by_event: Dict[str, List[HookGroup]] = {event: [] for event in EVENTS}
    target_groups_by_event: Dict[str, List[HookGroup]] = {event: [] for event in EVENTS}

    for group in groups:
        if group.event not in EVENTS:
            continue
        groups_by_event[group.event].append(group)
        target_handlers = [handler for handler in group.handlers if is_status_light_handler(group, handler)]
        if len(target_handlers) > 1:
            raise HookInstallError(
                f"multiple CodexStatusLight handlers share one {group.event} group; config was not changed"
            )
        if target_handlers:
            target_groups_by_event[group.event].append(group)

    removals: List[Tuple[int, int]] = []
    present: Set[str] = set()

    for event in EVENTS:
        targets = target_groups_by_event[event]
        if not targets:
            continue
        present.add(event)
        canonical = targets[0]
        duplicates = targets[1:]
        if not duplicates:
            continue

        event_groups = groups_by_event[event]
        earliest_duplicate_index = event_groups.index(duplicates[0])
        duplicate_set = {(group.start, group.end) for group in duplicates}
        tail = event_groups[earliest_duplicate_index:]
        if any((group.start, group.end) not in duplicate_set for group in tail):
            raise HookInstallError(
                f"duplicate {event} hook is not at the end of its event list; refusing to renumber other hooks"
            )

        canonical_shape = normalized_group(lines, canonical)
        for duplicate in duplicates:
            target_handlers = [
                handler for handler in duplicate.handlers if is_status_light_handler(duplicate, handler)
            ]
            if len(duplicate.handlers) != 1 or len(target_handlers) != 1:
                raise HookInstallError(
                    f"duplicate {event} hook shares a group with another handler; config was not changed"
                )
            if normalized_group(lines, duplicate) != canonical_shape:
                raise HookInstallError(
                    f"duplicate {event} hooks are not byte-equivalent in meaning; review them with /hooks"
                )
            removals.append((duplicate.start, removable_group_end(lines, duplicate)))

    return removals, present


def template_groups(hooks_text: str) -> Dict[str, str]:
    lines = hooks_text.splitlines(keepends=True)
    groups = parse_hook_groups(lines)
    result: Dict[str, str] = {}
    for group in groups:
        if group.event in EVENTS:
            result[group.event] = "".join(lines[group.start : group.end]).rstrip() + "\n"
    missing = [event for event in EVENTS if event not in result]
    if missing:
        raise HookInstallError(f"hook template is missing: {', '.join(missing)}")
    return result


def remove_ranges(lines: Sequence[str], ranges: Sequence[Tuple[int, int]]) -> List[str]:
    removed_indices: Set[int] = set()
    for start, end in ranges:
        removed_indices.update(range(start, end))
    return [line for index, line in enumerate(lines) if index not in removed_indices]


def remove_empty_managed_blocks(text: str) -> str:
    lines = text.splitlines(keepends=True)
    output: List[str] = []
    index = 0

    while index < len(lines):
        if lines[index].strip() != BEGIN_MARKER:
            output.append(lines[index])
            index += 1
            continue

        end = index + 1
        while end < len(lines) and lines[end].strip() != END_MARKER:
            end += 1
        if end >= len(lines):
            raise HookInstallError("unmatched CodexStatusLight BEGIN marker found; config was not changed")

        body = lines[index + 1 : end]
        known_comments = {
            "# Add this to ~/.codex/config.toml if you want Codex hooks to update the light.",
            "# After adding hooks, open Codex and run /hooks once to review/trust them.",
        }
        has_hook_group = any(
            (header := parse_table_header(line)) is not None
            and header[0]
            and len(header[1]) == 2
            and header[1][0] == "hooks"
            for line in body
        )
        has_unknown_content = any(
            line.strip() and line.strip() not in known_comments for line in body
        )
        if has_hook_group or has_unknown_content:
            output.extend(lines[index : end + 1])
            index = end + 1
        else:
            index = end + 1
            if index < len(lines) and not lines[index].strip():
                index += 1

    return "".join(output)


def merge_config_text(config_text: str, hooks_text: str) -> str:
    lines = config_text.splitlines(keepends=True)
    validate_supported_config(config_text, lines)
    validate_markers(lines)
    groups = parse_hook_groups(lines)
    removals, present = duplicate_group_ranges(lines, groups)

    candidate = "".join(remove_ranges(lines, removals))
    candidate = remove_empty_managed_blocks(candidate)

    missing = [event for event in EVENTS if event not in present]
    if missing:
        templates = template_groups(hooks_text)
        candidate = candidate.rstrip() + "\n\n" if candidate.strip() else ""
        candidate += BEGIN_MARKER + "\n"
        for index, event in enumerate(missing):
            if index:
                candidate += "\n"
            candidate += templates[event]
        candidate += END_MARKER + "\n"

    return candidate


def write_merged_config(config_path: Path, hooks_path: Path) -> bool:
    if config_path.is_symlink():
        raise HookInstallError("config.toml is a symlink; refusing to replace it automatically")
    original_bytes = config_path.read_bytes() if config_path.exists() else b""
    original = original_bytes.decode("utf-8")
    hooks_text = hooks_path.read_text(encoding="utf-8")
    candidate = merge_config_text(original, hooks_text)
    candidate_bytes = candidate.encode("utf-8")

    if candidate_bytes == original_bytes:
        print("CodexStatusLight hooks already installed; config left unchanged.")
        return False

    config_path.parent.mkdir(parents=True, exist_ok=True)
    if config_path.exists() and config_path.read_bytes() != original_bytes:
        raise HookInstallError("config.toml changed during installation; retry instead of overwriting it")

    mode = stat.S_IMODE(config_path.stat().st_mode) if config_path.exists() else 0o600
    descriptor, temp_name = tempfile.mkstemp(prefix=".codex-status-light.", dir=str(config_path.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(candidate_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_path, mode)
        os.replace(temp_path, config_path)
    finally:
        if temp_path.exists():
            temp_path.unlink()

    print("Installed one deduplicated CodexStatusLight hook set.")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--hooks", required=True, type=Path)
    args = parser.parse_args()

    try:
        write_merged_config(args.config, args.hooks)
    except (HookInstallError, UnicodeDecodeError) as error:
        print(f"Codex hook installation stopped: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
