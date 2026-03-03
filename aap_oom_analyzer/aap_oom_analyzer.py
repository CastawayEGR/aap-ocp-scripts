#!/usr/bin/env python3
# AAP OOM Root Cause Analyzer
# Correlates kernel OOM events with AAP API job data to identify which
# playbooks/job templates are causing task pod or job pod OOM kills.
# Supports offline (sosreport) and live (oc CLI) modes.
# Author: Michael Tipton
# Python port of aap_oom_analyzer.sh

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from urllib.error import URLError
from urllib.request import Request, urlopen

# --- Exit codes ---
EXIT_OOMS_FOUND = 0
EXIT_NO_OOMS = 1
EXIT_ERROR = 2

# --- API query window slack (seconds) ---
WINDOW_SLACK = 600


# --- Color setup ---
class Colors:
    def __init__(self):
        if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
            self.RED = "\033[31m"
            self.GREEN = "\033[32m"
            self.YELLOW = "\033[33m"
            self.CYAN = "\033[36m"
            self.HIGHLIGHT = "\033[1;33m"
            self.RESET = "\033[0m"
        else:
            self.RED = self.GREEN = self.YELLOW = ""
            self.CYAN = self.HIGHLIGHT = self.RESET = ""

    def highlight_output(self, text: str, *terms: str) -> str:
        if not self.HIGHLIGHT:
            return text
        for term in terms:
            if term:
                text = text.replace(term, f"{self.HIGHLIGHT}{term}{self.RESET}")
        return text


C = Colors()


# --- File cache: read each file once, search in memory ---
class FileCache:
    def __init__(self):
        self._lines: Dict[str, List[str]] = {}

    def get_lines(self, filepath: str) -> List[str]:
        if filepath in self._lines:
            return self._lines[filepath]
        if not os.path.isfile(filepath):
            self._lines[filepath] = []
            return []
        try:
            with open(filepath, "r", errors="replace") as f:
                lines = [line.rstrip("\n") for line in f]
        except OSError:
            lines = []
        self._lines[filepath] = lines
        return lines

    def grep(self, filepath: str, pattern: str, fixed: bool = False) -> List[str]:
        lines = self.get_lines(filepath)
        if fixed:
            return [l for l in lines if pattern in l]
        pat = re.compile(pattern)
        return [l for l in lines if pat.search(l)]

    def grep_numbered(self, filepath: str, pattern: str, fixed: bool = False) -> List[Tuple[int, str]]:
        """Returns [(1-indexed line_number, line), ...]."""
        lines = self.get_lines(filepath)
        if fixed:
            return [(i + 1, l) for i, l in enumerate(lines) if pattern in l]
        pat = re.compile(pattern)
        return [(i + 1, l) for i, l in enumerate(lines) if pat.search(l)]


FC = FileCache()


# --- Formatting helpers ---
def _to_kb_int(kb):
    if isinstance(kb, int):
        return kb
    try:
        return int(kb)
    except (ValueError, TypeError):
        return None


def format_kb(kb) -> str:
    v = _to_kb_int(kb)
    if v is None:
        return f"{kb}kB"
    if v >= 1048576:
        return f"{v // 1048576}.{(v % 1048576) * 10 // 1048576}GB"
    return f"{v // 1024}MB" if v >= 1024 else f"{v}kB"


def format_kb_long(kb) -> str:
    v = _to_kb_int(kb)
    if v is None:
        return f"{kb}kB"
    return f"{v}kB ({format_kb(v)})" if v >= 1024 else f"{v}kB"


# --- Dataclasses ---
@dataclass
class OomRecord:
    timestamp: str = ""
    epoch: Optional[int] = None
    node: str = ""
    namespace: str = ""
    pod: str = ""
    oom_type: str = ""
    container_id: str = ""
    kubelet_file: str = ""
    sos_root: str = ""
    pod_uid: str = ""
    is_node_level: bool = False
    dmesg_file: str = ""
    line_num: Optional[int] = None
    mem_limit: Optional[int] = None
    mem_usage: Optional[int] = None
    worker_count: int = 0
    max_worker_rss: int = 0
    job_id: Optional[int] = None
    killed_rss: int = 0
    killed_name: str = ""
    tasks_section: str = ""
    template_name: str = ""
    playbook: str = ""


@dataclass
class OomReport:
    mem_usage: Optional[int] = None
    mem_limit: Optional[int] = None
    failcnt: Optional[int] = None
    killed_pid: Optional[int] = None
    killed_name: str = ""
    killed_total_vm: int = 0
    killed_anon_rss: int = 0
    killed_file_rss: int = 0
    killed_shmem_rss: int = 0
    tasks_section: str = ""


# --- Helpers ---
def _is_aap_pod(pod_name: str) -> bool:
    return "-task-" in pod_name or "automation-job-" in pod_name


def _is_outside_time_window(epoch: Optional[int], time_hours: Optional[int]) -> bool:
    if not time_hours or not epoch:
        return False
    now = int(datetime.now(timezone.utc).timestamp())
    return epoch < now - time_hours * 3600


def _normalize(value, default="unknown") -> str:
    return default if not value or value == "null" else str(value)


def _categorize_record(rec: OomRecord, report: Optional[OomReport],
                       task_ooms: List[OomRecord], job_ooms: List[OomRecord]):
    """Apply OOM report data and sort into task or job list."""
    if report:
        rec.mem_limit = report.mem_limit
        rec.mem_usage = report.mem_usage
        rec.tasks_section = report.tasks_section
        rec.killed_rss = report.killed_anon_rss
        rec.killed_name = report.killed_name

    if "-task-" in rec.pod:
        if report and report.tasks_section:
            rec.worker_count, rec.max_worker_rss = parse_awx_workers_from_tasks(report.tasks_section)
        task_ooms.append(rec)
    elif "automation-job-" in rec.pod:
        rec.job_id = extract_job_id_from_pod_name(rec.pod)
        job_ooms.append(rec)


# --- Table printing ---
SEP = "\x01"


def print_table(header: str, rows: List[str]):
    hdrs = header.split(SEP)
    ncols = len(hdrs)
    widths = [len(h) for h in hdrs]

    parsed_rows = []
    for row in rows:
        cells = row.split(SEP)
        while len(cells) < ncols:
            cells.append("")
        parsed_rows.append(cells)
        for c in range(ncols):
            if len(cells[c]) > widths[c]:
                widths[c] = len(cells[c])

    print(f"  {C.CYAN}{'  '.join(h.ljust(w) for h, w in zip(hdrs, widths))}{C.RESET}")
    for cells in parsed_rows:
        print(f"  {'  '.join(cells[c].ljust(widths[c]) for c in range(ncols))}")


# --- Sosreport discovery ---
def discover_sosreports(search_dir: str) -> List[str]:
    seen = set()
    results = []
    for dmesg_file in sorted(Path(search_dir).rglob("sos_commands/kernel/dmesg_-T")):
        sos_root = str(dmesg_file.parent.parent.parent)
        if sos_root not in seen:
            seen.add(sos_root)
            results.append(sos_root)
    return results


def get_node_from_sosreport(sos_root: str) -> str:
    hostname_file = Path(sos_root) / "sos_commands" / "host" / "hostname"
    if hostname_file.is_file():
        return hostname_file.read_text().strip()
    dirname = Path(sos_root).name
    name = re.sub(r"^sosreport-", "", dirname)
    return re.sub(r"-\d{4}-\d{2}-\d{2}-.*", "", name)


# --- Cgroup parsing ---
def parse_pod_uid_from_cgroup(cgroup_path: str) -> Optional[str]:
    m = re.search(r"pod([a-f0-9_]{36})", cgroup_path)
    return m.group(1).replace("_", "-") if m else None


def parse_container_id_from_cgroup(cgroup_path: str) -> Optional[str]:
    m = re.search(r"crio-([a-f0-9]{64})", cgroup_path)
    return m.group(1) if m else None


# --- Pod resolution from kubelet journal (cached) ---
def resolve_pod_from_journal(journal_file: str, pod_uid: str,
                             container_id: str = "") -> Tuple[str, str, str]:
    """Returns (namespace, pod_name, container_name). Uses FileCache. Single pass."""
    namespace = pod_name = container_name = ""
    uid_str = f'podUID="{pod_uid}"'
    for line in FC.get_lines(journal_file):
        if pod_uid not in line:
            continue
        if not pod_name:
            if uid_str in line:
                m_ns = re.search(r'podNamespace="([^"]+)"', line)
                m_name = re.search(r'podName="([^"]+)"', line)
                if m_ns:
                    namespace = m_ns.group(1)
                if m_name:
                    pod_name = m_name.group(1)
            if not pod_name and 'pod="' in line:
                m = re.search(r'pod="([^/]+)/([^"]+)"', line)
                if m:
                    namespace, pod_name = m.group(1), m.group(2)
        if container_id and not container_name and 'containerName="' in line:
            m = re.search(r'containerName="([^"]+)"', line)
            if m:
                container_name = m.group(1)
        if pod_name and (not container_id or container_name):
            break
    return namespace, pod_name, container_name


# --- OOM report parsing ---
def parse_oom_report_from_lines(lines: List[str], oom_line_num: int) -> Optional[OomReport]:
    """Parse OOM report from cached lines. oom_line_num is 1-indexed."""
    report_start = None
    for i in range(oom_line_num - 1):
        if "invoked oom-killer" in lines[i]:
            report_start = i
    if report_start is None:
        return None

    report = OomReport()
    block = lines[report_start:oom_line_num]

    for line in reversed(block):
        if "memory: usage" in line:
            m_u = re.search(r"usage (\d+)", line)
            m_l = re.search(r"limit (\d+)", line)
            m_f = re.search(r"failcnt (\d+)", line)
            if m_u:
                report.mem_usage = int(m_u.group(1))
            if m_l:
                report.mem_limit = int(m_l.group(1))
            if m_f:
                report.failcnt = int(m_f.group(1))
            break

    killed_line = next((l for l in block if "Killed process" in l), None)
    if killed_line is None:
        for i in range(oom_line_num, min(oom_line_num + 2, len(lines))):
            if "Killed process" in lines[i]:
                killed_line = lines[i]
                break

    if killed_line:
        m = re.search(r"Killed process (\d+) \(([^)]+)\)", killed_line)
        if m:
            report.killed_pid = int(m.group(1))
            report.killed_name = m.group(2)

        for key, attr in [("total-vm:", "killed_total_vm"), ("anon-rss:", "killed_anon_rss"),
                          ("file-rss:", "killed_file_rss"), ("shmem-rss:", "killed_shmem_rss")]:
            idx = killed_line.find(key)
            if idx >= 0:
                m2 = re.match(r"(\d+)", killed_line[idx + len(key):])
                if m2:
                    setattr(report, attr, int(m2.group(1)))

    tasks_start = next((i for i, l in enumerate(block) if "Tasks state (memory values in pages):" in l), None)
    if tasks_start is not None and len(block) > tasks_start + 1:
        report.tasks_section = "\n".join(block[tasks_start:-1])

    return report


def parse_oom_report(source_file: str, oom_line_num: int) -> Optional[OomReport]:
    """Parse OOM report using FileCache."""
    return parse_oom_report_from_lines(FC.get_lines(source_file), oom_line_num)


def _iter_task_entries(tasks_section: str):
    """Yield (name, rss_kb) for each task line in an OOM report tasks section."""
    _task_re = re.compile(r"\[\s*\d+\s*\]")
    for line in tasks_section.split("\n"):
        m = _task_re.search(line)
        if not m:
            continue
        parts = line[m.end():].strip().split()
        if len(parts) >= 8:
            try:
                yield " ".join(parts[7:]) or "(unknown)", int(parts[3]) * 4
            except (ValueError, IndexError):
                continue


def parse_tasks_summary(tasks_section: str) -> List[Tuple[str, int, int]]:
    """Parse tasks section: returns [(name, count, rss_kb), ...] plus ("TOTAL", 0, total)."""
    rss_by_name: Dict[str, int] = {}
    count_by_name: Dict[str, int] = {}
    for name, rss_kb in _iter_task_entries(tasks_section):
        rss_by_name[name] = rss_by_name.get(name, 0) + rss_kb
        count_by_name[name] = count_by_name.get(name, 0) + 1
    if not rss_by_name:
        return []
    total = sum(rss_by_name.values())
    return [(n, count_by_name[n], rss_by_name[n]) for n in rss_by_name] + [("TOTAL", 0, total)]


def parse_awx_workers_from_tasks(tasks_section: str) -> Tuple[int, int]:
    """Returns (worker_count, max_worker_rss_kb)."""
    count = max_rss = 0
    for name, rss_kb in _iter_task_entries(tasks_section):
        if name == "awx-manage":
            count += 1
            if rss_kb > max_rss:
                max_rss = rss_kb
    return count, max_rss


def extract_job_id_from_pod_name(pod_name: str) -> Optional[int]:
    m = re.search(r"automation-job-(\d+)", pod_name)
    return int(m.group(1)) if m else None


# --- Timestamp parsing ---
def parse_timestamp(line: str) -> Tuple[str, Optional[int]]:
    m = re.match(r"^([A-Z][a-z]+ \d+ [\d:]+)", line)
    if m:
        ts = m.group(1)
        year = datetime.now(timezone.utc).year
        for fmt in ("%b %d %H:%M:%S %Y", "%B %d %H:%M:%S %Y"):
            try:
                dt = datetime.strptime(f"{ts} {year}", fmt).replace(tzinfo=timezone.utc)
                return ts, int(dt.timestamp())
            except ValueError:
                continue
        return ts, None

    m = re.match(r"^\[([^\]]+)\]", line)
    if m:
        ts = m.group(1).strip()
        for fmt in ("%a %b %d %H:%M:%S %Y", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
            try:
                dt = datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
                return ts, int(dt.timestamp())
            except ValueError:
                continue
        return ts, None

    return "", None


def _parse_epoch_journal(ts: str) -> Optional[int]:
    """Parse journal timestamp like 'Feb 23 20:54:54' to epoch."""
    return parse_timestamp(ts)[1] if ts else None


# --- Kernel OOM parsing from dmesg ---
def parse_kernel_ooms_from_dmesg(
    dmesg_file: str, kubelet_journal: str, node: str, sos_root: str,
    seen_pods: Set[str], seen_cids: Set[str], seen_uids: Set[str],
    namespace_filter: str = "", time_hours: Optional[int] = None
) -> Tuple[List[OomRecord], List[OomRecord]]:
    task_ooms: List[OomRecord] = []
    job_ooms: List[OomRecord] = []

    oom_entries = FC.grep_numbered(dmesg_file, "oom-kill:constraint=CONSTRAINT_MEMCG", fixed=True)
    if not oom_entries:
        return task_ooms, job_ooms

    # Pre-collect eviction pod names from kubelet journal (once, not per-OOM)
    eviction_pod_names: Set[str] = set()
    if kubelet_journal:
        for line in FC.grep(kubelet_journal, "eviction_manager", fixed=True):
            # Extract pod names from eviction lines
            for m in re.finditer(r'pod="[^/]*/([^"]+)"', line):
                eviction_pod_names.add(m.group(1))
            m_pods = re.search(r'pods=\[([^\]]+)\]', line)
            if m_pods:
                for entry in m_pods.group(1).replace('"', '').split(","):
                    if "/" in entry.strip():
                        eviction_pod_names.add(entry.strip().split("/", 1)[1])

    dmesg_lines = FC.get_lines(dmesg_file)

    for line_num, oom_line in oom_entries:
        timestamp, timestamp_epoch = parse_timestamp(oom_line)
        if _is_outside_time_window(timestamp_epoch, time_hours):
            continue

        # Parse cgroup paths
        m_memcg = re.search(r"oom_memcg=([^,]+)", oom_line)
        oom_memcg = m_memcg.group(1) if m_memcg else ""

        is_node_level = False
        pod_uid = parse_pod_uid_from_cgroup(oom_memcg) if oom_memcg else None
        if not pod_uid:
            m_task = re.search(r"task_memcg=([^,]+)", oom_line)
            task_memcg = m_task.group(1) if m_task else ""
            pod_uid = parse_pod_uid_from_cgroup(task_memcg) if task_memcg else None
            is_node_level = True
            container_id = parse_container_id_from_cgroup(task_memcg) if task_memcg else None
        else:
            container_id = parse_container_id_from_cgroup(oom_line)

        if not pod_uid:
            continue
        if container_id and container_id in seen_cids:
            continue
        if pod_uid in seen_uids:
            continue

        # Resolve pod name (uses FileCache — no redundant reads)
        pod_namespace, pod_name = "?", "?"
        if kubelet_journal:
            ns, pn, _cn = resolve_pod_from_journal(kubelet_journal, pod_uid)
            if ns:
                pod_namespace = ns
            if pn:
                pod_name = pn

        if namespace_filter and pod_namespace != namespace_filter:
            continue

        oom_type = "Node Pressure" if is_node_level else "Kernel OOM"
        if pod_name != "?" and pod_name in eviction_pod_names:
            oom_type += " + Eviction"

        report = parse_oom_report_from_lines(dmesg_lines, line_num)

        if pod_name != "?":
            seen_pods.add(pod_name)
        if container_id:
            seen_cids.add(container_id)
        seen_uids.add(pod_uid)

        rec = OomRecord(
            timestamp=timestamp, epoch=timestamp_epoch, node=node,
            namespace=pod_namespace, pod=pod_name, oom_type=oom_type,
            container_id=container_id or "", kubelet_file=kubelet_journal,
            sos_root=sos_root, pod_uid=pod_uid, is_node_level=is_node_level,
            dmesg_file=dmesg_file, line_num=line_num,
        )
        _categorize_record(rec, report, task_ooms, job_ooms)

    return task_ooms, job_ooms


# --- Eviction parsing from kubelet ---
def parse_evictions_from_kubelet(
    kubelet_journal: str, node: str, sos_root: str,
    seen_pods: Set[str], namespace_filter: str = "", time_hours: Optional[int] = None
) -> Tuple[List[OomRecord], List[OomRecord]]:
    task_ooms: List[OomRecord] = []
    job_ooms: List[OomRecord] = []

    eviction_lines = [l for l in FC.grep(kubelet_journal, "eviction_manager", fixed=True)
                      if any(kw in l for kw in ("pods evicted", "pod failed to evict",
                                                 "pods successfully cleaned up",
                                                 "timed out waiting for pods"))]
    if not eviction_lines:
        return task_ooms, job_ooms

    evicted_pods: Dict[str, Tuple[str, str]] = {}  # pod_name -> (timestamp, namespace)
    for evict_line in eviction_lines:
        m_ts = re.match(r"^([A-Z][a-z]+ \d+ [\d:]+)", evict_line)
        evict_ts = m_ts.group(1) if m_ts else ""

        # pods=[ns/pod,...] format
        m_pods = re.search(r'pods=\[([^\]]+)\]', evict_line)
        if m_pods:
            for entry in m_pods.group(1).replace('"', '').split(","):
                entry = entry.strip()
                if "/" in entry:
                    ev_ns, ev_pod = entry.split("/", 1)
                    if _is_aap_pod(ev_pod) and ev_pod not in evicted_pods:
                        evicted_pods[ev_pod] = (evict_ts, ev_ns)

        # pod="ns/pod" format
        m_single = re.search(r'pod="([^"]+)"', evict_line)
        if m_single and "/" in m_single.group(1):
            ev_ns, ev_pod = m_single.group(1).split("/", 1)
            if _is_aap_pod(ev_pod) and ev_pod not in evicted_pods:
                evicted_pods[ev_pod] = (evict_ts, ev_ns)

    # Build pod-name index: {pod_name: (container_id, pod_uid)} — single pass
    pod_info: Dict[str, Tuple[str, str]] = {}
    for pl in FC.get_lines(kubelet_journal):
        for pn in evicted_pods:
            if pn not in pl or pn in pod_info and all(pod_info[pn]):
                continue
            cid, uid = pod_info.get(pn, ("", ""))
            if not cid:
                m_cid = re.search(r'containerID="cri-o://([a-f0-9]{64})', pl)
                if m_cid:
                    cid = m_cid.group(1)
            if not uid:
                m_uid = re.search(r'podUID="([^"]+)"', pl)
                if m_uid:
                    uid = m_uid.group(1)
            pod_info[pn] = (cid, uid)

    for ev_pod_name, (ev_timestamp, ev_namespace) in evicted_pods.items():
        if ev_pod_name in seen_pods:
            continue
        if namespace_filter and ev_namespace != namespace_filter:
            continue

        ev_epoch = _parse_epoch_journal(ev_timestamp)
        if _is_outside_time_window(ev_epoch, time_hours):
            continue

        ev_container_id, ev_pod_uid = pod_info.get(ev_pod_name, ("", ""))
        seen_pods.add(ev_pod_name)

        rec = OomRecord(
            timestamp=ev_timestamp, epoch=ev_epoch, node=node,
            namespace=ev_namespace, pod=ev_pod_name, oom_type="Eviction",
            container_id=ev_container_id, kubelet_file=kubelet_journal,
            sos_root=sos_root, pod_uid=ev_pod_uid,
        )
        _categorize_record(rec, None, task_ooms, job_ooms)

    return task_ooms, job_ooms


# --- Offline mode ---
def find_aap_ooms_offline(
    sos_root: str, namespace_filter: str = "", time_hours: Optional[int] = None
) -> Tuple[List[OomRecord], List[OomRecord]]:
    dmesg_file = os.path.join(sos_root, "sos_commands", "kernel", "dmesg_-T")
    kubelet_journal = os.path.join(sos_root, "sos_commands", "openshift",
                                    "journalctl_--no-pager_--unit_kubelet")
    node = get_node_from_sosreport(sos_root)

    seen_pods: Set[str] = set()
    seen_cids: Set[str] = set()
    seen_uids: Set[str] = set()

    task_ooms, job_ooms = parse_kernel_ooms_from_dmesg(
        dmesg_file, kubelet_journal, node, sos_root,
        seen_pods, seen_cids, seen_uids, namespace_filter, time_hours)

    ev_tasks, ev_jobs = parse_evictions_from_kubelet(
        kubelet_journal, node, sos_root, seen_pods, namespace_filter, time_hours)
    task_ooms.extend(ev_tasks)
    job_ooms.extend(ev_jobs)

    return task_ooms, job_ooms


# --- OC client wrapper ---
class OcClient:
    def __init__(self):
        self._cache: Dict[str, str] = {}  # "type:node" -> tmpfile path
        self.tmpdir = ""

    def run(self, *args, **kwargs) -> Optional[str]:
        try:
            result = subprocess.run(
                ["oc"] + list(args),
                capture_output=True, text=True, timeout=120, **kwargs)
            return result.stdout if result.returncode == 0 else None
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return None

    def _fetch_node_file(self, node: str, file_type: str,
                         oc_args: List[list]) -> Optional[str]:
        """Fetch a node file with fallback OC commands. Returns cached tmpfile path."""
        key = f"{file_type}:{node}"
        if key in self._cache:
            return self._cache[key]
        safe = node.replace("/", "_")
        tmpfile = os.path.join(self.tmpdir, f"{file_type}_{safe}")
        out = None
        for args in oc_args:
            out = self.run(*args)
            if out is not None:
                break
        if out is None:
            return None
        with open(tmpfile, "w") as f:
            f.write(out)
        self._cache[key] = tmpfile
        return tmpfile

    def fetch_node_dmesg(self, node: str) -> Optional[str]:
        return self._fetch_node_file(node, "dmesg", [
            ["adm", "node-logs", node, "--raw", "--", "SYSLOG_IDENTIFIER=kernel"],
            ["adm", "node-logs", node],
        ])

    def fetch_node_journal(self, node: str) -> Optional[str]:
        path = self._fetch_node_file(node, "journal", [
            ["adm", "node-logs", node, "-u", "kubelet"],
        ])
        if path is None:
            print(f"  {C.YELLOW}Warning: Could not fetch journal from node {node}{C.RESET}",
                  file=sys.stderr)
        return path


# --- AAP API client ---
class AapApiClient:
    def __init__(self, controller_url: str = "", api_token: str = "",
                 jobs_file: str = ""):
        self.controller_url = controller_url.rstrip("/") if controller_url else ""
        self.api_token = api_token
        self.jobs_file = jobs_file
        self.template_cache: Dict[str, str] = {}
        self._jobs_data = None

    @property
    def has_api(self) -> bool:
        return bool(self.jobs_file) or (bool(self.controller_url) and bool(self.api_token))

    def _load_jobs_file(self) -> List[dict]:
        if self._jobs_data is not None:
            return self._jobs_data
        if not self.jobs_file:
            self._jobs_data = []
            return self._jobs_data
        try:
            with open(self.jobs_file) as f:
                data = json.load(f)
            self._jobs_data = data if isinstance(data, list) else data.get("results", [])
        except (json.JSONDecodeError, OSError):
            self._jobs_data = []
        return self._jobs_data

    def _api_get(self, path: str) -> Optional[dict]:
        if not self.controller_url or not self.api_token:
            return None
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = Request(f"{self.controller_url}{path}", headers={
            "Authorization": f"Bearer {self.api_token}",
            "Content-Type": "application/json",
        })
        try:
            with urlopen(req, context=ctx, timeout=30) as resp:
                data = json.loads(resp.read())
            if isinstance(data, dict) and "detail" in data:
                print(f"  {C.YELLOW}API error: {data['detail']}{C.RESET}", file=sys.stderr)
                return None
            return data
        except (URLError, OSError, json.JSONDecodeError):
            return None

    def _fetch_paginated(self, initial_path: str) -> List[dict]:
        all_results = []
        path = initial_path
        while path:
            page = self._api_get(path)
            if not page:
                break
            all_results.extend(page.get("results", []))
            next_url = page.get("next")
            path = next_url.replace(self.controller_url, "") if next_url and isinstance(next_url, str) else ""
        return all_results

    def fetch_job_by_id(self, job_id: int) -> Optional[dict]:
        if self.jobs_file:
            return next((j for j in self._load_jobs_file() if j.get("id") == job_id), None)
        return self._api_get(f"/api/v2/jobs/{job_id}/")

    def fetch_jobs_by_controller_node(self, pod_name: str) -> List[dict]:
        if self.jobs_file:
            return [j for j in self._load_jobs_file() if j.get("controller_node") == pod_name]
        return self._fetch_paginated(f"/api/v2/jobs/?page_size=200&controller_node={pod_name}")

    def fetch_jobs_for_window(self, start_epoch: int, end_epoch: int) -> List[dict]:
        start_ts = datetime.utcfromtimestamp(start_epoch).strftime("%Y-%m-%dT%H:%M:%S")
        end_ts = datetime.utcfromtimestamp(end_epoch).strftime("%Y-%m-%dT%H:%M:%S")
        return self._fetch_paginated(
            f"/api/v2/jobs/?page_size=200&started__lte={end_ts}&started__gte={start_ts}")

    def fetch_jobs_for_window_from_file(self, oom_epoch: int) -> List[dict]:
        start_epoch = oom_epoch - WINDOW_SLACK
        result = []
        for j in self._load_jobs_file():
            started = j.get("started")
            if not started:
                continue
            try:
                started_clean = re.sub(r"\.\d+", "", started)
                started_dt = datetime.strptime(started_clean, "%Y-%m-%dT%H:%M:%SZ")
                started_epoch = int(started_dt.replace(tzinfo=timezone.utc).timestamp())
            except (ValueError, TypeError):
                continue
            if started_epoch > oom_epoch or started_epoch < start_epoch:
                continue
            finished = j.get("finished")
            if finished:
                try:
                    finished_clean = re.sub(r"\.\d+", "", finished)
                    finished_dt = datetime.strptime(finished_clean, "%Y-%m-%dT%H:%M:%SZ")
                    finished_epoch = int(finished_dt.replace(tzinfo=timezone.utc).timestamp())
                    if finished_epoch < oom_epoch:
                        continue
                except (ValueError, TypeError):
                    pass
            result.append(j)
        return result

    def fetch_job_template_name(self, template_id) -> str:
        """Returns 'name|playbook'."""
        tid = str(template_id)
        if tid in self.template_cache:
            return self.template_cache[tid]

        if self.jobs_file:
            for j in self._load_jobs_file():
                if j.get("unified_job_template") == template_id:
                    name = j.get("summary_fields", {}).get("unified_job_template", {}).get("name", "unknown")
                    playbook = j.get("playbook", "unknown")
                    result = f"{name}|{playbook}"
                    self.template_cache[tid] = result
                    return result

        if self.controller_url and self.api_token:
            data = self._api_get(f"/api/v2/unified_job_templates/{template_id}/")
            if data:
                result = f"{data.get('name', 'unknown')}|{data.get('playbook', 'unknown')}"
                self.template_cache[tid] = result
                return result

        self.template_cache[tid] = "unknown|unknown"
        return "unknown|unknown"

    def ping(self) -> bool:
        return self._api_get("/api/v2/ping/") is not None


# --- Live mode ---
def find_aap_ooms_live(
    oc: OcClient, namespace: str, time_hours: Optional[int]
) -> Tuple[List[OomRecord], List[OomRecord]]:
    task_ooms: List[OomRecord] = []
    job_ooms: List[OomRecord] = []

    ns_flag = ["-n", namespace] if namespace else ["--all-namespaces"]
    out = oc.run("get", "pods", *ns_flag, "-o", "json")
    if not out:
        print("Error: Failed to fetch pods.", file=sys.stderr)
        return task_ooms, job_ooms

    try:
        pods_json = json.loads(out)
    except json.JSONDecodeError:
        return task_ooms, job_ooms

    seen_pods: Set[str] = set()

    for item in pods_json.get("items", []):
        metadata = item.get("metadata", {})
        pod_name = metadata.get("name", "")
        if not _is_aap_pod(pod_name):
            continue

        ns = metadata.get("namespace", "")
        pod_uid_val = metadata.get("uid", "")
        node_name = item.get("spec", {}).get("nodeName", "")

        for cs in item.get("status", {}).get("containerStatuses", []):
            last_term = cs.get("lastState", {}).get("terminated", {})
            curr_term = cs.get("state", {}).get("terminated", {})
            reason_last = last_term.get("reason", "")
            reason_curr = curr_term.get("reason", "")

            is_oom = (
                reason_last == "OOMKilled" or reason_curr == "OOMKilled" or
                reason_curr == "Evicted" or
                (last_term.get("exitCode") == 137 and reason_last) or
                (curr_term.get("exitCode") == 137 and reason_curr)
            )
            if not is_oom or pod_name in seen_pods:
                continue
            seen_pods.add(pod_name)

            oom_ts = last_term.get("finishedAt") or curr_term.get("finishedAt") or ""
            cid_raw = (last_term.get("containerID") or curr_term.get("containerID") or
                       cs.get("containerID") or "")
            cid = cid_raw.replace("cri-o://", "")

            # Parse timestamp epoch
            timestamp_epoch = None
            if oom_ts:
                try:
                    ts_clean = oom_ts.replace("Z", "").split("+")[0].split(".")[0]
                    dt = datetime.strptime(ts_clean, "%Y-%m-%dT%H:%M:%S")
                    timestamp_epoch = int(dt.replace(tzinfo=timezone.utc).timestamp())
                except ValueError:
                    pass

            if _is_outside_time_window(timestamp_epoch, time_hours):
                continue

            oom_type = "Kernel OOM"
            is_node_level = False
            report = None
            live_dmesg_file = ""
            live_oom_line = None
            live_journal_file = ""

            if node_name and cid:
                dmesg_path = oc.fetch_node_dmesg(node_name)
                if dmesg_path:
                    live_dmesg_file = dmesg_path
                    for ln, ll in FC.grep_numbered(dmesg_path, "oom-kill", fixed=True):
                        if cid in ll:
                            live_oom_line = ln
                            m_memcg = re.search(r"oom_memcg=([^,]+)", ll)
                            if m_memcg and not parse_pod_uid_from_cgroup(m_memcg.group(1)):
                                is_node_level = True
                            report = parse_oom_report(dmesg_path, ln)
                            break

            if is_node_level:
                oom_type = "Node Pressure"

            if node_name:
                journal_path = oc.fetch_node_journal(node_name)
                if journal_path:
                    live_journal_file = journal_path
                    for el in FC.grep(journal_path, "eviction_manager", fixed=True):
                        if pod_name in el:
                            oom_type += " + Eviction"
                            break

            reason = reason_curr or reason_last or ""
            if reason == "Evicted" and "Eviction" not in oom_type:
                oom_type = "Eviction"

            rec = OomRecord(
                timestamp=oom_ts, epoch=timestamp_epoch, node=node_name,
                namespace=ns, pod=pod_name, oom_type=oom_type,
                container_id=cid, kubelet_file=live_journal_file,
                pod_uid=pod_uid_val, is_node_level=is_node_level,
                dmesg_file=live_dmesg_file, line_num=live_oom_line,
            )
            _categorize_record(rec, report, task_ooms, job_ooms)
            break  # Only first matching container status per pod

    return task_ooms, job_ooms


def find_aap_ooms_live_historical(
    oc: OcClient, namespace: str, time_hours: Optional[int],
    existing_task_ooms: List[OomRecord], existing_job_ooms: List[OomRecord]
) -> Tuple[List[OomRecord], List[OomRecord]]:
    seen_pods: Set[str] = set()
    seen_cids: Set[str] = set()
    seen_uids: Set[str] = set()
    for rec in existing_task_ooms + existing_job_ooms:
        if rec.container_id:
            seen_cids.add(rec.container_id)
        if rec.pod_uid:
            seen_uids.add(rec.pod_uid)
        if rec.pod:
            seen_pods.add(rec.pod)

    out = oc.run("get", "nodes", "-l", "node-role.kubernetes.io/worker",
                 "-o", "jsonpath={.items[*].metadata.name}")
    if not out:
        return [], []

    task_ooms: List[OomRecord] = []
    job_ooms: List[OomRecord] = []

    for node in out.split():
        dmesg_path = oc.fetch_node_dmesg(node)
        journal_path = oc.fetch_node_journal(node)
        if dmesg_path:
            t, j = parse_kernel_ooms_from_dmesg(
                dmesg_path, journal_path or "", node, "",
                seen_pods, seen_cids, seen_uids, namespace, time_hours)
            task_ooms.extend(t)
            job_ooms.extend(j)

        if journal_path:
            t, j = parse_evictions_from_kubelet(
                journal_path, node, "", seen_pods, namespace, time_hours)
            task_ooms.extend(t)
            job_ooms.extend(j)

    return task_ooms, job_ooms


# --- Correlation logic ---
@dataclass
class CorrelationResult:
    template_counts: Dict[str, int] = field(default_factory=dict)
    template_playbook: Dict[str, str] = field(default_factory=dict)
    template_ids: Dict[str, str] = field(default_factory=dict)
    task_pod_jobs: List[List[dict]] = field(default_factory=list)
    used_controller_node: bool = False


def _extract_job_entry(j: dict) -> dict:
    return {
        "job_id": j.get("id", 0),
        "status": _normalize(j.get("status")),
        "tmpl_id": j.get("unified_job_template", 0),
        "tmpl_name": _normalize(j.get("summary_fields", {}).get("unified_job_template", {}).get("name")),
        "playbook": _normalize(j.get("playbook")),
        "explanation": j.get("job_explanation", ""),
    }


def _count_template(corr: CorrelationResult, seen: Set[str], entry: dict):
    tmpl = entry["tmpl_name"]
    if tmpl not in seen:
        seen.add(tmpl)
        corr.template_counts[tmpl] = corr.template_counts.get(tmpl, 0) + 1
        corr.template_playbook[tmpl] = entry["playbook"]
        corr.template_ids[tmpl] = str(entry["tmpl_id"])


def correlate_task_ooms_with_jobs(
    task_ooms: List[OomRecord], api: AapApiClient
) -> CorrelationResult:
    corr = CorrelationResult()
    if not task_ooms or not api.has_api:
        return corr

    # Primary: controller_node lookup
    cn_data: Dict[int, List[dict]] = {}
    cn_success = False

    for i, oom in enumerate(task_ooms):
        if not oom.pod:
            continue
        jobs = api.fetch_jobs_by_controller_node(oom.pod)
        if not jobs:
            continue
        cn_success = True
        cn_data[i] = [_extract_job_entry(j) for j in jobs]

    if cn_success:
        corr.used_controller_node = True
        for i in range(len(task_ooms)):
            entries = cn_data.get(i, [])
            corr.task_pod_jobs.append(entries)
            seen: Set[str] = set()
            for e in entries:
                _count_template(corr, seen, e)
        return corr

    # Fallback: timestamp window
    for i, oom in enumerate(task_ooms):
        if not oom.epoch:
            continue
        if api.jobs_file:
            jobs = api.fetch_jobs_for_window_from_file(oom.epoch)
        else:
            jobs = api.fetch_jobs_for_window(oom.epoch - WINDOW_SLACK, oom.epoch)
        if not jobs:
            continue

        # Filter to running at OOM time
        running = []
        for j in jobs:
            finished = j.get("finished")
            if not finished:
                running.append(j)
                continue
            try:
                fin_clean = re.sub(r"\.\d+", "", finished)
                fin_dt = datetime.strptime(fin_clean, "%Y-%m-%dT%H:%M:%SZ")
                if int(fin_dt.replace(tzinfo=timezone.utc).timestamp()) >= oom.epoch:
                    running.append(j)
            except ValueError:
                running.append(j)

        seen: Set[str] = set()
        for j in running:
            entry = _extract_job_entry(j)
            _count_template(corr, seen, entry)

    return corr


def enrich_job_pod_ooms(job_ooms: List[OomRecord], api: AapApiClient):
    for rec in job_ooms:
        if not api.has_api or not rec.job_id:
            continue
        job_json = api.fetch_job_by_id(rec.job_id)
        if not job_json:
            continue

        tmpl_name = job_json.get("summary_fields", {}).get("unified_job_template", {}).get("name", "")
        playbook = job_json.get("playbook", "")
        tmpl_id = job_json.get("unified_job_template")

        if not tmpl_name and tmpl_id:
            info = api.fetch_job_template_name(tmpl_id)
            tmpl_name, playbook = info.split("|", 1) if "|" in info else (info, "")

        rec.template_name = tmpl_name or ""
        rec.playbook = playbook or ""


def build_memory_profile(job_ooms: List[OomRecord]) -> Dict[str, Tuple[int, int, int, int]]:
    """Returns {template: (samples, min_rss, max_rss, sum_rss)}."""
    profile: Dict[str, Tuple[int, int, int, int]] = {}
    for rec in job_ooms:
        if rec.is_node_level or not rec.template_name or not rec.killed_rss:
            continue
        rss = rec.killed_rss
        if rec.template_name in profile:
            s, mn, mx, sm = profile[rec.template_name]
            profile[rec.template_name] = (s + 1, min(rss, mn), max(rss, mx), sm + rss)
        else:
            profile[rec.template_name] = (1, rss, rss, rss)
    return profile


# --- Display functions ---
def display_verbose_oom(report: OomReport, indent: str, node_level: bool):
    if report.mem_usage is not None:
        label = f"{C.YELLOW}Node Cgroup Memory (not pod-specific):" if node_level else f"{C.RED}Cgroup Memory:"
        print(f"{indent}{label}{C.RESET}")
        print(f"{indent}  Usage:     {format_kb_long(report.mem_usage)}")
        print(f"{indent}  Limit:     {format_kb_long(report.mem_limit)}")
        if report.failcnt is not None:
            print(f"{indent}  Failcnt:   {report.failcnt}")

    if report.tasks_section:
        tasks_summary = parse_tasks_summary(report.tasks_section)
        if tasks_summary:
            if node_level:
                print(f"{indent}{C.YELLOW}All tasks on node (node-level OOM — includes all pods):{C.RESET}")
            else:
                print(f"{indent}{C.RED}Tasks in cgroup (RSS by process name):{C.RESET}")
                print(f"{indent}  (Same pod: kernel CONSTRAINT_MEMCG report lists only this cgroup's tasks.)")
            total_kb = 0
            for name, count, rss_kb in tasks_summary:
                if name == "TOTAL":
                    total_kb = rss_kb
                else:
                    print(f"{indent}  {count}x {name}: {format_kb_long(rss_kb)}")
            if total_kb:
                print(f"{indent}  Total RSS (all tasks): {format_kb_long(total_kb)}")

    if report.killed_pid is not None:
        print(f"{indent}{C.RED}OOM Victim:{C.RESET}")
        if report.killed_name:
            print(f"{indent}  Process:   {report.killed_name} (PID {report.killed_pid})")
        if report.killed_anon_rss:
            print(f"{indent}  Anon RSS:  {format_kb_long(report.killed_anon_rss)}")
        if report.killed_file_rss:
            print(f"{indent}  File RSS:  {format_kb_long(report.killed_file_rss)}")
        if report.killed_shmem_rss:
            print(f"{indent}  Shmem RSS: {format_kb_long(report.killed_shmem_rss)}")


def display_verbose_logs(rec: OomRecord, indent: str):
    if "Eviction" in rec.oom_type and rec.kubelet_file:
        eviction_logs = [l for l in FC.grep(rec.kubelet_file, "eviction_manager", fixed=True)
                         if rec.pod in l]
        if eviction_logs:
            print(f"{indent}{C.RED}Eviction Manager Logs:{C.RESET}")
            for line in eviction_logs:
                print(f"{indent}  {C.highlight_output(line, rec.pod, 'eviction_manager')}")

    if rec.container_id and rec.kubelet_file:
        cid_short = rec.container_id[:12]
        cid_lines = [l for l in FC.grep(rec.kubelet_file, cid_short, fixed=True)
                      if "eviction_manager" not in l][:20]
        if cid_lines:
            print(f"{indent}{C.RED}Kubelet Container Logs:{C.RESET}")
            for line in cid_lines:
                print(f"{indent}  {C.highlight_output(line, cid_short, rec.pod)}")

    if rec.sos_root and rec.container_id:
        crio_log = os.path.join(rec.sos_root, "sos_commands", "crio", "containers",
                                "logs", f"crictl_logs_-t_{rec.container_id}")
        if os.path.isfile(crio_log) and os.path.getsize(crio_log) > 0:
            try:
                with open(crio_log, "r", errors="replace") as f:
                    all_lines = f.readlines()
                line_count = len(all_lines)
                print(f"{indent}{C.RED}CRI-O Container Logs ({line_count} lines):{C.RESET}")
                for line in all_lines[-20:]:
                    print(f"{indent}  {C.highlight_output(line.rstrip(), rec.pod)}")
                if line_count > 20:
                    print(f"{indent}  ... ({line_count - 20} more lines, see: {crio_log})")
            except OSError:
                pass


def display_task_oom_timeline(task_ooms: List[OomRecord], verbose: bool):
    if not task_ooms:
        return

    print(f"\n{C.RED}=== Task Pod OOM Timeline ==={C.RESET}\n")

    rows = []
    for rec in task_ooms:
        node_display = rec.node[:27] + "..." if len(rec.node) > 30 else rec.node
        lim = format_kb(rec.mem_limit) if not rec.is_node_level and rec.mem_limit is not None else ""
        use = format_kb(rec.mem_usage) if not rec.is_node_level and rec.mem_usage is not None else ""
        rss = format_kb(rec.max_worker_rss) if rec.max_worker_rss > 0 else ""
        rows.append(SEP.join([rec.timestamp, rec.oom_type, node_display, rec.pod,
                              lim, use, str(rec.worker_count), rss]))

    print_table(SEP.join(["TIMESTAMP", "TYPE", "NODE", "POD",
                           "MEM LIMIT", "MEM USAGE", "WORKERS", "MAX WORKER RSS"]), rows)

    peak_workers = max((r.worker_count for r in task_ooms), default=0)
    peak_limit = next((format_kb(r.mem_limit) for r in task_ooms
                       if not r.is_node_level and r.mem_limit is not None), "")

    print(f"\n  {C.HIGHLIGHT}{len(task_ooms)}{C.RESET} task pod OOM event(s) found.")
    if peak_workers > 0:
        suffix = f" in a {peak_limit} cgroup" if peak_limit else ""
        print(f"  Peak: {C.HIGHLIGHT}{peak_workers}{C.RESET} awx-manage workers{suffix}.")

    if verbose:
        print(f"\n{C.RED}--- Detailed Task Pod OOM Reports ---{C.RESET}")
        for i, rec in enumerate(task_ooms):
            print(f"\n  {C.HIGHLIGHT}[{i+1}/{len(task_ooms)}] {rec.pod} on {rec.node}{C.RESET}")
            print(f"  Timestamp: {rec.timestamp}")
            print(f"  OOM Type:  {rec.oom_type}")
            if rec.container_id:
                print(f"  Container: {rec.container_id}")
            if rec.dmesg_file and rec.line_num:
                report = parse_oom_report(rec.dmesg_file, rec.line_num)
                if report:
                    display_verbose_oom(report, "  ", rec.is_node_level)
            display_verbose_logs(rec, "  ")


def display_frequency_analysis(task_ooms: List[OomRecord], corr: CorrelationResult):
    if not task_ooms or not corr.template_counts:
        return

    print(f"\n{C.RED}=== Job Template Frequency Analysis ==={C.RESET}")
    if corr.used_controller_node:
        print(f"    {C.CYAN}(Which job templates had jobs controlled by each OOM'd task pod?){C.RESET}")
    else:
        print(f"    {C.CYAN}(Which job templates were running at each task pod OOM? — timestamp fallback){C.RESET}")
    print()

    sorted_templates = sorted(corr.template_counts.items(), key=lambda x: -x[1])
    total = len(task_ooms)
    rows = []
    for rank, (tmpl, count) in enumerate(sorted_templates, 1):
        pct = count * 100 // total
        rows.append(SEP.join([str(rank), tmpl, corr.template_playbook.get(tmpl, ""),
                              f"{count}/{total}", f"{pct}%"]))

    print_table(SEP.join(["RANK", "TEMPLATE", "PLAYBOOK", "TASK POD OOMS", "CORRELATION"]), rows)

    if sorted_templates:
        top_name, top_count = sorted_templates[0]
        top_pct = top_count * 100 // total
        print()
        if top_pct >= 50:
            scope = "had jobs on" if corr.used_controller_node else "was running during"
            pct_word = f"{C.HIGHLIGHT}ALL{C.RESET}" if top_pct == 100 else f"{C.HIGHLIGHT}{top_pct}%{C.RESET} of"
            qualifier = "most likely" if top_pct == 100 else "likely"
            suffix = "OOM'd task pods" if corr.used_controller_node else "task pod OOM events"
            print(f"  {C.HIGHLIGHT}\"{top_name}\"{C.RESET} {scope} {pct_word} {suffix} — {qualifier} contributor.")


def display_affected_jobs(task_ooms: List[OomRecord], corr: CorrelationResult):
    if not corr.used_controller_node or not task_ooms:
        return
    if not any(corr.task_pod_jobs):
        return

    print(f"\n{C.RED}=== Affected Jobs by Task Pod OOM ==={C.RESET}\n")

    for i, rec in enumerate(task_ooms):
        jobs = corr.task_pod_jobs[i] if i < len(corr.task_pod_jobs) else []
        if not jobs:
            continue

        print(f"  {C.HIGHLIGHT}{rec.pod}{C.RESET} ({rec.oom_type} at {rec.timestamp}):")

        max_tmpl = max(8, *(len(j["tmpl_name"]) for j in jobs))
        max_status = max(6, *(len(j["status"]) for j in jobs))

        print(f"    {C.CYAN}{'JOB ID':<8}  {'TEMPLATE':<{max_tmpl}}  {'STATUS':<{max_status}}  ROOT CAUSE{C.RESET}")

        type_lower = rec.oom_type.lower()
        for j in jobs:
            expl = j["explanation"]
            if "running at system start up" in expl:
                rc = f'Task pod {type_lower} — "Task marked as running at system start up"'
            elif "reaped due to instance shutdown" in expl:
                rc = f'Task pod {type_lower} — "Job reaped due to instance shutdown"'
            elif "worker stream" in expl or "empty line" in expl:
                rc = f'Job pod OOM — "{expl}"'
            elif expl:
                rc = expl
            else:
                rc = "\u2014"
            print(f"    {str(j['job_id']):<8}  {j['tmpl_name']:<{max_tmpl}}  {j['status']:<{max_status}}  {rc}")
        print()


def display_job_pod_summary(job_ooms: List[OomRecord], verbose: bool):
    if not job_ooms:
        return

    print(f"\n{C.RED}=== Job Pod OOM Summary ==={C.RESET}\n")

    show_api = any(r.template_name for r in job_ooms)
    rows = []
    for rec in job_ooms:
        lim = format_kb(rec.mem_limit) if not rec.is_node_level and rec.mem_limit is not None else ""
        rss = format_kb(rec.killed_rss) if not rec.is_node_level and rec.killed_rss else ""
        base = [rec.timestamp, rec.oom_type, str(rec.job_id or "")]
        rows.append(SEP.join(base + ([rec.template_name, rec.playbook] if show_api else []) + [lim, rss]))

    hdrs = ["TIMESTAMP", "TYPE", "JOB ID"] + (["TEMPLATE", "PLAYBOOK"] if show_api else []) + ["MEM LIMIT", "KILLED PROC RSS"]
    print_table(SEP.join(hdrs), rows)

    print()
    ev = sum(1 for r in job_ooms if "Eviction" in r.oom_type)
    np = sum(1 for r in job_ooms if "Node Pressure" in r.oom_type)
    kr = sum(1 for r in job_ooms if r.oom_type in ("Kernel OOM", "Kernel OOM + Eviction"))

    print(f"  {C.HIGHLIGHT}{len(job_ooms)}{C.RESET} job pod OOM event(s) found.")
    breakdown = []
    if ev:
        breakdown.append(f"{ev} eviction(s)")
    if np:
        breakdown.append(f"{np} node pressure kill(s)")
    if kr:
        breakdown.append(f"{kr} kernel OOM kill(s)")
    if len(breakdown) > 1:
        print(f"  {', '.join(breakdown)}.")

    if show_api:
        unique = set(r.template_name for r in job_ooms if r.template_name)
        if len(unique) == 1:
            print(f"  All using template {C.HIGHLIGHT}\"{next(iter(unique))}\"{C.RESET}.")

    if verbose:
        print(f"\n{C.RED}--- Detailed Job Pod OOM Reports ---{C.RESET}")
        for i, rec in enumerate(job_ooms):
            print(f"\n  {C.HIGHLIGHT}[{i+1}/{len(job_ooms)}] {rec.pod} (Job {rec.job_id}) on {rec.node}{C.RESET}")
            print(f"  Timestamp: {rec.timestamp}")
            print(f"  OOM Type:  {rec.oom_type}")
            if rec.container_id:
                print(f"  Container: {rec.container_id}")
            if rec.oom_type not in ("Eviction",) and rec.dmesg_file and rec.line_num:
                report = parse_oom_report(rec.dmesg_file, rec.line_num)
                if report:
                    display_verbose_oom(report, "  ", rec.is_node_level)
            display_verbose_logs(rec, "  ")


def display_memory_profile(profile: Dict[str, Tuple[int, int, int, int]], corr: CorrelationResult):
    if not profile:
        return
    print(f"\n{C.RED}=== Memory Profile ==={C.RESET}\n")
    rows = []
    for tmpl, (samples, min_rss, max_rss, sum_rss) in profile.items():
        avg = sum_rss // samples if samples else 0
        rows.append(SEP.join([tmpl, corr.template_playbook.get(tmpl, ""), str(samples),
                              format_kb(min_rss), format_kb(max_rss), format_kb(avg)]))
    print_table(SEP.join(["TEMPLATE", "PLAYBOOK", "SAMPLES", "MIN RSS", "MAX RSS", "AVG RSS"]), rows)


def display_recommendations(task_ooms: List[OomRecord], job_ooms: List[OomRecord],
                            corr: CorrelationResult):
    if not task_ooms and not job_ooms:
        return

    print(f"\n{C.RED}=== Recommendations ==={C.RESET}\n")
    rec_num = 0
    total_task = len(task_ooms)

    # Find top correlator
    top_template = top_playbook = ""
    top_pct = 0
    if total_task > 0:
        for tmpl, count in corr.template_counts.items():
            pct = count * 100 // total_task
            if pct > top_pct:
                top_pct, top_template = pct, tmpl
                top_playbook = corr.template_playbook.get(tmpl, "")

    job_matches = sum(1 for r in job_ooms if r.template_name == top_template) if top_template else 0

    if top_template and top_pct >= 50:
        rec_num += 1
        strength = "LIKELY ROOT CAUSE" if top_pct >= 75 else "POSSIBLE ROOT CAUSE"
        pb = f" ({top_playbook})" if top_playbook else ""
        js = f" and {job_matches}/{len(job_ooms)} job pod OOM events" if job_matches else ""
        print(f"  {rec_num}. {C.HIGHLIGHT}{strength}:{C.RESET} \"{top_template}\"{pb} correlates with {top_pct}% of task pod")
        print(f"     OOM events{js}.")
        print()

    if corr.used_controller_node:
        rc_k = rc_e = rc_j = rc_o = 0
        for i, rec in enumerate(task_ooms):
            for j in (corr.task_pod_jobs[i] if i < len(corr.task_pod_jobs) else []):
                if j["status"] == "successful":
                    continue
                expl = j["explanation"]
                if "running at system start up" in expl:
                    rc_k += 1
                elif "reaped due to instance shutdown" in expl:
                    rc_e += 1
                elif "worker stream" in expl or "empty line" in expl:
                    rc_j += 1
                else:
                    rc_o += 1

        rc_total = rc_k + rc_e + rc_j + rc_o
        if rc_total > 0:
            rec_num += 1
            print(f"  {rec_num}. {C.HIGHLIGHT}Root-cause breakdown{C.RESET} of {rc_total} failed job(s) on OOM'd task pods:")
            if rc_k:
                print(f'     - {rc_k} killed by task pod kernel OOM ("Task marked as running at system start up")')
            if rc_e:
                print(f'     - {rc_e} killed by task pod eviction ("Job reaped due to instance shutdown")')
            if rc_j:
                print(f"     - {rc_j} killed by own job pod OOM (worker stream / empty line)")
            if rc_o:
                print(f"     - {rc_o} failed for other reasons")
            print()

    peak_workers = max((r.worker_count for r in task_ooms), default=0)
    peak_limit_kb = max((r.mem_limit for r in task_ooms
                         if not r.is_node_level and r.mem_limit is not None), default=0)

    if task_ooms and peak_workers > 0:
        rec_num += 1
        lim = f" {format_kb(peak_limit_kb)}" if peak_limit_kb else ""
        print(f"  {rec_num}. With {C.HIGHLIGHT}{peak_workers}{C.RESET} concurrent awx-manage workers, the task pod's aggregate")
        print(f"     memory exceeded its{lim} limit. Consider:")
        print("     - Increase task pod memory in the AutomationController CR: spec.task_resource_requirements.limits.memory")
        print("     - Reduce concurrent jobs: lower forks on job templates or set SYSTEM_TASK_FORKS_MEM / SYSTEM_TASK_ABS_MEM via spec.extra_settings")
        if top_playbook:
            print(f'     - Investigate playbook "{top_playbook}" for excessive resource usage')
        print()

    if job_ooms:
        job_kernel = sum(1 for r in job_ooms if r.oom_type in ("Kernel OOM", "Kernel OOM + Eviction"))
        if job_kernel > 0:
            rec_num += 1
            print(f"  {rec_num}. {C.HIGHLIGHT}{job_kernel}{C.RESET} job pod(s) were individually OOM-killed. Consider:")
            print("     - Increase job pod memory via Container Group pod_spec_override (Administration -> Instance Groups)")
            print("     - Reduce forks on the job template (each fork uses ~100MB)")
            print("     - Review playbooks for memory-intensive operations (large fact gathering, template rendering)")
            print()

    total_np = (sum(1 for r in task_ooms if "Eviction" in r.oom_type or "Node Pressure" in r.oom_type) +
                sum(1 for r in job_ooms if "Eviction" in r.oom_type or "Node Pressure" in r.oom_type))
    if total_np > 0:
        rec_num += 1
        print(f"  {rec_num}. {C.HIGHLIGHT}{total_np}{C.RESET} pod(s) were killed due to node memory pressure. Consider:")
        print("     - Increase node memory or add worker nodes")
        print("     - Reduce pod resource requests to improve scheduling")
        print("     - Review kubelet eviction thresholds (eviction-hard, eviction-soft)")
        print()

    if rec_num == 0:
        print("  No specific recommendations. Review the OOM details above for manual analysis.")
        print()


def display_no_api_fallback(task_ooms: List[OomRecord], job_ooms: List[OomRecord],
                            sosreport_dir: str, script_name: str):
    print(f"\n{C.YELLOW}=== OOM Analysis (no AAP API — add -c/-t for playbook correlation) ==={C.RESET}\n")

    if task_ooms:
        peak = max((r.worker_count for r in task_ooms), default=0)
        ev = sum(1 for r in task_ooms if "Eviction" in r.oom_type)
        detail = f"{peak} workers at peak"
        if ev:
            detail += f", {ev} eviction(s)"
        print(f"  Found {C.HIGHLIGHT}{len(task_ooms)}{C.RESET} task pod OOM event(s) ({detail}).")

    job_ids = list(dict.fromkeys(str(r.job_id) for r in job_ooms if r.job_id is not None)) if job_ooms else []

    if job_ooms:
        ev = sum(1 for r in job_ooms if "Eviction" in r.oom_type)
        detail = f" ({ev} eviction(s), {len(job_ooms) - ev} kernel OOM)" if ev else ""
        print(f"  Found {C.HIGHLIGHT}{len(job_ooms)}{C.RESET} job pod OOM event(s){detail}.")
        if job_ids:
            print(f"  Job IDs from pod names: {' '.join(job_ids)}")

    d_flag = f" -d {sosreport_dir}" if sosreport_dir else ""
    print(f"\n  To identify which playbooks caused this:")
    print(f"    {script_name}{d_flag} -c https://aap.example.com -t $AAP_TOKEN")

    if job_ids:
        ids_csv = ",".join(job_ids)
        print(f"\n  Or export first:")
        print(f'    curl -sk -H "Authorization: Bearer $TOKEN" \\')
        print(f'      "https://aap.example.com/api/v2/jobs/?page_size=200&id__in={ids_csv}" > jobs.json')
        print(f"    {script_name}{d_flag} -f jobs.json")


# --- CLI + main ---
def usage(script_name: str):
    print(f"""Usage: {script_name} [OPTIONS]

Analyze AAP OOM kills and correlate with job templates/playbooks.

  Data source (choose one):
    -d <directory>     Path to sosreport(s) — offline mode
    (no -d)            Live mode using 'oc' CLI

  AAP API connection (optional — enables playbook correlation):
    -c <url>           AAP controller URL (or AAP_CONTROLLER_URL env var)
    -t <token>         OAuth token (or AAP_TOKEN env var)
    -f <jobs.json>     Pre-exported jobs JSON (alternative to live API)

  Filtering:
    -n <namespace>     AAP namespace (default: auto-detect from oc)
    -T <hours>         Only analyze OOMs from last N hours (live mode)

  Output:
    -v                 Verbose: show full kernel OOM reports
    -h                 Help

Exit codes: 0 = OOMs found, 1 = no OOMs found, 2 = error""")
    sys.exit(EXIT_ERROR)


def main():
    global C, FC
    script_name = sys.argv[0]

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("-d", dest="sosreport_dir", default="")
    parser.add_argument("-c", dest="controller_url", default=os.environ.get("AAP_CONTROLLER_URL", ""))
    parser.add_argument("-t", dest="api_token", default=os.environ.get("AAP_TOKEN", ""))
    parser.add_argument("-f", dest="jobs_file", default="")
    parser.add_argument("-n", dest="namespace", default="")
    parser.add_argument("-T", dest="time_hours", default=None)
    parser.add_argument("-v", dest="verbose", action="store_true")
    parser.add_argument("-h", dest="show_help", action="store_true")
    args = parser.parse_args()

    if args.show_help:
        usage(script_name)

    C = Colors()
    FC = FileCache()

    time_hours = None
    if args.time_hours is not None:
        if not args.time_hours.isdigit():
            print("Error: -T requires a numeric value (hours).", file=sys.stderr)
            sys.exit(EXIT_ERROR)
        time_hours = int(args.time_hours)

    if args.jobs_file and not os.path.isfile(args.jobs_file):
        print(f"Error: Jobs file '{args.jobs_file}' does not exist.", file=sys.stderr)
        sys.exit(EXIT_ERROR)

    api = AapApiClient(args.controller_url, args.api_token, args.jobs_file)
    task_ooms: List[OomRecord] = []
    job_ooms: List[OomRecord] = []

    if args.sosreport_dir:
        if time_hours is not None:
            print(f"{C.YELLOW}Warning: -T (time filter) is ignored in offline mode.{C.RESET}",
                  file=sys.stderr)
        if not os.path.isdir(args.sosreport_dir):
            print(f"Error: Directory '{args.sosreport_dir}' does not exist.", file=sys.stderr)
            sys.exit(EXIT_ERROR)

        sos_roots = discover_sosreports(args.sosreport_dir)
        if not sos_roots:
            print(f"Error: No sosreport directories found under '{args.sosreport_dir}'.",
                  file=sys.stderr)
            print("Expected structure: <dir>/sos_commands/kernel/dmesg_-T", file=sys.stderr)
            sys.exit(EXIT_ERROR)

        print(f"Scanning {len(sos_roots)} sosreport(s) for AAP OOM kills and evictions...")
        for sos_root in sos_roots:
            print(f"  Checking node: {get_node_from_sosreport(sos_root)}")
            t, j = find_aap_ooms_offline(sos_root, args.namespace, time_hours)
            task_ooms.extend(t)
            job_ooms.extend(j)
    else:
        print("Error: Live mode is not yet supported. Use -d <directory> for offline/sosreport mode.",
              file=sys.stderr)
        sys.exit(EXIT_ERROR)

        import shutil
        if not shutil.which("oc"):
            print("Error: 'oc' command not found. Please install the OpenShift CLI.", file=sys.stderr)
            sys.exit(EXIT_ERROR)
        if not shutil.which("jq"):
            print("Error: 'jq' command not found.", file=sys.stderr)
            sys.exit(EXIT_ERROR)

        oc = OcClient()

        if not args.controller_url and args.api_token and args.namespace:
            host = oc.run("get", "route", "-n", args.namespace, "-o",
                          "jsonpath={.items[0].spec.host}")
            if host:
                args.controller_url = f"https://{host.strip()}"
                api = AapApiClient(args.controller_url, args.api_token, args.jobs_file)
                print(f"  Auto-discovered controller URL: {args.controller_url}")

        print("Scanning cluster for AAP OOMKilled/Evicted pods...")
        if args.namespace:
            print(f"  Namespace filter: {args.namespace}")
        if time_hours is not None:
            print(f"  Time filter: last {time_hours}h")

        with tempfile.TemporaryDirectory() as tmpdir:
            oc.tmpdir = tmpdir
            task_ooms, job_ooms = find_aap_ooms_live(oc, args.namespace, time_hours)
            print("Scanning worker node journals for historical OOM events...")
            ht, hj = find_aap_ooms_live_historical(oc, args.namespace, time_hours, task_ooms, job_ooms)
            task_ooms.extend(ht)
            job_ooms.extend(hj)

    if not task_ooms and not job_ooms:
        print(f"\n{C.GREEN}No AAP OOM kills or evictions found.{C.RESET}")
        sys.exit(EXIT_NO_OOMS)

    display_task_oom_timeline(task_ooms, args.verbose)

    corr = CorrelationResult()
    has_api = api.has_api
    if has_api and api.controller_url and api.api_token and not api.jobs_file:
        if not api.ping():
            print(f"\n{C.YELLOW}Warning: Cannot reach AAP API at {api.controller_url}. Skipping playbook correlation.{C.RESET}",
                  file=sys.stderr)
            has_api = False

    if has_api:
        print("\nCorrelating OOM events with AAP job data...")
        corr = correlate_task_ooms_with_jobs(task_ooms, api)
        enrich_job_pod_ooms(job_ooms, api)
        profile = build_memory_profile(job_ooms)
        display_frequency_analysis(task_ooms, corr)
        display_affected_jobs(task_ooms, corr)
        display_job_pod_summary(job_ooms, args.verbose)
        display_memory_profile(profile, corr)
        display_recommendations(task_ooms, job_ooms, corr)
    else:
        display_job_pod_summary(job_ooms, args.verbose)
        display_no_api_fallback(task_ooms, job_ooms, args.sosreport_dir, script_name)
        display_recommendations(task_ooms, job_ooms, corr)

    sys.exit(EXIT_OOMS_FOUND)


if __name__ == "__main__":
    main()
