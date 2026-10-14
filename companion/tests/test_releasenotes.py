"""Tests for the bundled release notes."""

import pytest

from shuffledetector import releasenotes


@pytest.fixture
def notes(tmp_path, monkeypatch):
    for v in ("0.8.0", "0.8.1", "0.9.0", "0.10.0"):
        (tmp_path / f"v{v}.md").write_text(f"notes {v}", encoding="utf-8")
    (tmp_path / "README.md").write_text("not a version")
    monkeypatch.setenv("SHUFFLEDETECTOR_NOTES", str(tmp_path))


def versions(found):
    return [v for _, v, _ in found]


def test_all_notes_newest_first_with_numeric_ordering(notes):
    assert versions(releasenotes.all_notes()) == ["0.10.0", "0.9.0", "0.8.1", "0.8.0"]


def test_unseen_notes_cover_every_skipped_version(notes):
    assert versions(releasenotes.unseen_notes("0.8.0", "0.9.0")) == ["0.9.0", "0.8.1"]
    assert releasenotes.unseen_notes("0.9.0", "0.9.0") == []


def test_unseen_notes_without_history_show_only_the_current_version(notes):
    assert versions(releasenotes.unseen_notes(None, "0.8.1")) == ["0.8.1"]
    assert releasenotes.unseen_notes(None, "0.8.5") == []


def test_unseen_notes_ignore_unparseable_current_version(notes):
    assert releasenotes.unseen_notes("0.8.0", "dev-abc1234") == []


def test_no_notes_directory(tmp_path, monkeypatch):
    monkeypatch.setenv("SHUFFLEDETECTOR_NOTES", str(tmp_path))
    monkeypatch.setattr(releasenotes, "_PACKAGED", tmp_path / "x")
    monkeypatch.setattr(releasenotes, "_REPO", tmp_path / "y")
    assert releasenotes.all_notes() == [] and releasenotes.notes_dir() is None
