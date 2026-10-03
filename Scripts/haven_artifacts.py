#!/usr/bin/env python3
"""Owner-private metadata journal for registered jobs; never reads file contents.

The journal is local evidence, not a grant. Uploads still require the GraphStore's
normal signed resolver path. Inventory is observation, never creator attribution.
"""
import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import time
import uuid

SCHEMA = "haven.artifacts.v1"
EXCLUDED = (".git", ".ssh", ".gnupg", ".env*", "*.pem", "*.key", "Keychains")
DEFAULT_SNAPSHOT_BYTES = 256 * 1024
MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024


class Rejected(ValueError):
    pass


class SnapshotTooLarge(Rejected):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def identifier(value):
    if not isinstance(value, str) or not value or len(value) > 200:
        raise Rejected("invalid identifier")
    if any(ord(c) < 32 for c in value):
        raise Rejected("invalid identifier")
    return value


def private_file(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Rejected("configuration and spool must be private and owned by this user")


class Collector:
    def __init__(self, config_path):
        config_path = Path(config_path)
        private_file(config_path)
        if config_path.stat().st_size > 32768:
            raise Rejected("configuration too large")
        config = json.loads(config_path.read_text())
        if config.get("schema") != SCHEMA:
            raise Rejected("unsupported configuration")
        self.owner = identifier(config["ownerRef"])
        self.host = identifier(config["hostID"])
        self.roots = config["roots"]
        if not isinstance(self.roots, list) or not 1 <= len(self.roots) <= 32:
            raise Rejected("invalid roots")
        for root in self.roots:
            path = Path(root["path"])
            if not path.is_absolute() or path == Path("/") or str(path.resolve()) != str(path):
                raise Rejected("roots must be canonical absolute paths")
            identifier(root["volumeID"])
            if type(root.get("device")) is not int:
                raise Rejected("each volume requires its enrolled device number")
        self.maximum = config.get("maxEntries", 2000)
        self.max_bytes = config.get("maxJournalBytes", 64 * 1024 * 1024)
        if type(self.maximum) is not int or not 1 <= self.maximum <= 10000:
            raise Rejected("invalid scan limit")
        if type(self.max_bytes) is not int or not 1048576 <= self.max_bytes <= 268435456:
            raise Rejected("invalid journal limit")
        spool = Path(config["spool"])
        if not spool.is_absolute() or str(spool.resolve()) != str(spool):
            raise Rejected("spool must be a canonical absolute path")
        # An enrolled, private directory is required; never chmod an existing tree.
        private_file(spool, directory=True)
        self.db_path = spool / "events.sqlite3"
        for suffix in ("", "-journal", "-wal", "-shm"):
            candidate = Path(str(self.db_path) + suffix)
            if candidate.exists() or candidate.is_symlink():
                private_file(candidate)
        fd = os.open(self.db_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        self.db = sqlite3.connect(str(self.db_path), timeout=10)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        page_size = self.db.execute("PRAGMA page_size").fetchone()[0]
        self.db.execute("PRAGMA max_page_count=%d" % (self.max_bytes // page_size))
        self.db.execute("CREATE TABLE IF NOT EXISTS binding (owner TEXT, host TEXT, writer TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, id TEXT UNIQUE, body TEXT NOT NULL)")
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            binding = self.db.execute("SELECT owner, host, writer FROM binding").fetchall()
            if not binding:
                self.writer = str(uuid.uuid4())
                self.db.execute("INSERT INTO binding VALUES (?, ?, ?)", (self.owner, self.host, self.writer))
            elif len(binding) == 1 and binding[0][:2] == (self.owner, self.host):
                self.writer = binding[0][2]
            else:
                raise Rejected("journal owner or host mismatch")

    def close(self):
        self.db.close()

    def scoped(self, path):
        path = Path(path)
        if not path.is_absolute() or ".." in path.parts:
            raise Rejected("path must be absolute and normalized")
        # Deny ancestor symlinks, including symlinks within an enrolled root.
        for parent in [path] + list(path.parents):
            if parent.is_symlink():
                raise Rejected("symlink path is outside capture scope")
        matches = [root for root in self.roots
                   if path == Path(root["path"]) or Path(root["path"]) in path.parents]
        if not matches:
            raise Rejected("path outside enrolled roots")
        root = max(matches, key=lambda item: len(item["path"]))
        if any(any(fnmatch.fnmatch(part, pattern) for pattern in EXCLUDED)
               for part in path.relative_to(root["path"]).parts):
            raise Rejected("path excluded from capture")
        return path, root

    def scan(self, path):
        path, root = self.scoped(path)
        records, gaps = [], set()
        started = time.monotonic()

        def visit(parent_fd, name, absolute):
            if len(records) >= self.maximum or time.monotonic() - started > 5:
                gaps.add("scan_limit")
                return
            try:
                info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if info.st_dev != root["device"]:
                    gaps.add("volume_changed_or_mount_excluded")
                    return
                if stat.S_ISLNK(info.st_mode):
                    gaps.add("symlink_excluded")
                    return
                if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                    gaps.add("special_file_excluded")
                    return
                birth = getattr(info, "st_birthtime", None)
                records.append({"path": str(absolute), "volumeID": root["volumeID"],
                                "device": info.st_dev, "inode": info.st_ino,
                                "birthNs": round(birth * 1e9) if birth is not None else None,
                                "kind": "directory" if stat.S_ISDIR(info.st_mode) else "file",
                                "bytes": info.st_size if stat.S_ISREG(info.st_mode) else 0,
                                "allocatedBytes": info.st_blocks * 512 if stat.S_ISREG(info.st_mode) else 0,
                                "modifiedNs": info.st_mtime_ns, "changeNs": info.st_ctime_ns})
                if stat.S_ISDIR(info.st_mode):
                    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
                    try:
                        opened = os.fstat(fd)
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            gaps.add("scan_race")
                            return
                        with os.scandir(fd) as entries:
                            for entry in entries:
                                if any(fnmatch.fnmatch(entry.name, pattern) for pattern in EXCLUDED):
                                    gaps.add("excluded_paths")
                                    continue
                                visit(fd, entry.name, absolute / entry.name)
                                if "scan_limit" in gaps:
                                    break
                    finally:
                        os.close(fd)
            except (OSError, ValueError):
                gaps.add("unreadable_or_changed")

        # Open each ancestor without following symlinks to avoid a rename race
        # between scope validation and opening the selected directory.
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in path.parts[1:-1]:
                next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            visit(fd, path.name, path)
        except OSError:
            gaps.add("unreadable_or_changed")
        finally:
            os.close(fd)
        return {"entries": records, "gaps": sorted(gaps), "measuredAtMs": time.time_ns() // 1000000,
                "coverage": "partial", "coverageReason": "boundary_inventory_misses_transient_files"}

    def state(self):
        runs, artifacts = {}, {}
        sequence = 0
        for sequence, encoded in self.db.execute("SELECT seq, body FROM events ORDER BY seq"):
            event = json.loads(encoded)
            run = event["run"]
            runs[run["attemptID"]] = run
            for item in event["artifacts"]:
                artifacts[item["id"]] = item
        return sequence, runs, artifacts

    def record(self, kind, attempt=None, job=None, project=None, path=None, result=None):
        if kind not in ("start", "finish", "created", "recover"):
            raise Rejected("unsupported event")
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            _, runs, artifacts = self.state()
            if kind == "start":
                attempt = str(uuid.uuid4())
                path, _ = self.scoped(path)
                run = {"attemptID": attempt, "jobID": identifier(job), "projectID": identifier(project),
                       "path": str(path), "status": "running", "startedAtMs": time.time_ns() // 1000000}
            else:
                if attempt not in runs:
                    raise Rejected("unknown attempt")
                run = dict(runs[attempt])
                if run["status"] != "running":
                    if kind == "finish" and run["status"] == result:
                        return attempt  # Retrying the same terminal receipt is harmless.
                    raise Rejected("attempt already terminal")
                if kind in ("finish", "recover"):
                    if result not in ("succeeded", "failed", "cancelled", "interrupted"):
                        raise Rejected("invalid terminal status")
                    run.update(status=result, endedAtMs=time.time_ns() // 1000000)
                    path = run["path"]
                else:
                    target, _ = self.scoped(path)
                    if target != Path(run["path"]) and Path(run["path"]) not in target.parents:
                        raise Rejected("writer path outside job scope")
            inventory = self.scan(path)
            run.update(coverage=inventory["coverage"], coverageReason=inventory["coverageReason"],
                       gaps=inventory["gaps"], measuredAtMs=inventory["measuredAtMs"])
            by_path = {item["path"]: item for item in artifacts.values() if item["presence"] == "observed"}
            updates = []
            for entry in inventory["entries"]:
                old = by_path.get(entry["path"])
                identity_keys = ("device", "inode", "birthNs") if entry["birthNs"] else ("device", "inode", "changeNs")
                same = old and all(old.get(k) == entry[k] for k in identity_keys)
                # Without birth time an inode reused between inventories cannot be
                # distinguished from modification. Keep that uncertainty explicit.
                if old and not same:
                    updates.append(dict(old, presence="replaced", measuredAtMs=inventory["measuredAtMs"]))
                item = dict(old) if same else {"id": str(uuid.uuid4()), "observedDuring": [], "usedBy": [], "createdBy": None}
                item.update(entry)
                item.update(presence="observed", measuredAtMs=inventory["measuredAtMs"],
                            identityEvidence="birth_time" if entry["birthNs"] else "observation_only")
                item["observedDuring"] = sorted(set(item["observedDuring"] + [attempt]))
                if entry["path"] == run["path"]:
                    item["usedBy"] = sorted(set(item["usedBy"] + [attempt]))
                if kind == "created" and entry["path"] == str(Path(path)):
                    if item["createdBy"] not in (None, attempt):
                        raise Rejected("conflicting registered creator")
                    item["createdBy"] = attempt
                    item["originEvidence"] = "registered_writer"
                else:
                    item.setdefault("originEvidence", "observed_during")
                updates.append(item)
            if kind in ("finish", "recover") and not inventory["gaps"]:
                observed = {item["path"] for item in inventory["entries"]}
                for item in artifacts.values():
                    if attempt in item["observedDuring"] and item["path"] not in observed and item["presence"] == "observed":
                        missing = dict(item, presence="not_observed", measuredAtMs=inventory["measuredAtMs"])
                        updates.append(missing)  # Absence is not deletion proof.
            event = {"schema": SCHEMA, "run": run, "artifacts": updates}
            self.db.execute("INSERT INTO events (id, body) VALUES (?, ?)", (str(uuid.uuid4()), canonical(event)))
        return attempt

    def snapshot(self):
        # One read transaction binds the sequence to the exported state.
        with self.db:
            self.db.execute("BEGIN")
            sequence, runs, artifacts = self.state()
        for item in artifacts.values():
            active = any(runs[key]["status"] == "running" for key in item["observedDuring"])
            item["retentionStatus"] = "active" if active else "unknown"
            item["retentionReasons"] = (["registered_job_running"] if active else []) + [
                "partial_coverage", "fresh_lease_process_git_dependency_checks_required"]
        payload = {"schema": SCHEMA, "ownerRef": self.owner, "hostID": self.host,
                   "writerID": self.writer, "sequence": sequence, "runs": list(runs.values()),
                   "artifacts": list(artifacts.values())}
        payload["digest"] = hashlib.sha256(canonical(payload).encode()).hexdigest()
        return payload

    def encoded_snapshot(self, maximum_bytes=DEFAULT_SNAPSHOT_BYTES):
        """Return a complete bounded frame, or nothing; never trim journal rows.

        The caller must drain stdout while this process runs. This bound is a
        payload bound, not proof that the signed transport's envelope will fit.
        """
        if type(maximum_bytes) is not int or not 1024 <= maximum_bytes <= MAX_SNAPSHOT_BYTES:
            raise Rejected("invalid snapshot limit")
        encoded = canonical(self.snapshot()).encode("utf-8") + b"\n"
        if len(encoded) > maximum_bytes:
            raise SnapshotTooLarge("snapshot exceeds delivery bound")
        return encoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("command", choices=("start", "finish", "created", "recover", "snapshot"))
    parser.add_argument("--attempt")
    parser.add_argument("--job")
    parser.add_argument("--project")
    parser.add_argument("--path")
    parser.add_argument("--result")
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_SNAPSHOT_BYTES,
                        help="snapshot stdout limit including newline (1024 to 4194304 bytes)")
    args = parser.parse_args()
    collector = None
    try:
        collector = Collector(args.config)
        if args.command == "snapshot":
            # Validate the full frame before emitting any bytes. An oversized
            # snapshot must not look like a successful partial import.
            sys.stdout.buffer.write(collector.encoded_snapshot(args.max_bytes))
        else:
            print(collector.record(args.command, args.attempt, args.job, args.project, args.path, args.result))
        return 0
    except SnapshotTooLarge:
        print("artifact_provenance_pending: snapshot_too_large; local journal retained", file=sys.stderr)
        return 2
    except (Rejected, OSError, sqlite3.Error, ValueError, KeyError, TypeError):
        # No raw exception text: it may contain private paths or configuration.
        print("artifact_provenance_degraded: rejected scope/configuration, unavailable volume, or full journal", file=sys.stderr)
        return 1
    finally:
        if collector:
            collector.close()


if __name__ == "__main__":
    sys.exit(main())
