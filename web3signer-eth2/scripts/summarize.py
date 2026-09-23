#!/usr/bin/env python3
"""Summarise memleak-test.sh result directories as Markdown.

Usage: ./scripts/summarize.py RESULTS_DIR [RESULTS_DIR ...]

For every run it prints a per-cycle table (live heap from the class histogram, anon RSS after
GC, peak anon RSS, page cache, CPU during signing / reload windows and per cycle, reload
duration and, for MODE=sign, the k6 cycle results) followed by a trend line: the
least-squares slope of live heap and anon RSS across cycles 2..N (the first loaded cycle is
warm-up). A leak shows as a slope that stays clearly positive run after run; a healthy run
plateaus. With several directories a side-by-side comparison of the steady-state numbers is
appended.
"""
import csv
import json
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

MIB = 1024 * 1024


def read_tsv(path):
    if not path.exists():
        return []
    with path.open() as f:
        return list(csv.DictReader(f, delimiter="\t"))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def slope(points):
    """Least-squares slope of (x, y) points, or None with fewer than two points."""
    points = [(x, y) for x, y in points if y is not None]
    if len(points) < 2:
        return None
    n = len(points)
    mean_x = sum(x for x, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    var_x = sum((x - mean_x) ** 2 for x, _ in points)
    return sum((x - mean_x) * (y - mean_y) for x, y in points) / var_x if var_x else None


def log_events(outdir, reference_epoch):
    """(epoch_seconds, message) for every run.log line, anchored on the resources.tsv date."""
    lines = (outdir / "run.log").read_text().splitlines()
    day = datetime.fromtimestamp(reference_epoch or time.time()).date()
    events, previous = [], None
    for line in lines:
        match = re.match(r"\[(\d\d):(\d\d):(\d\d)\] (.*)", line)
        if not match:
            continue
        hh, mm, ss, message = match.groups()
        stamp = datetime.combine(day, datetime.min.time()) + timedelta(hours=int(hh), minutes=int(mm), seconds=int(ss))
        if previous and stamp < previous:  # crossed midnight
            day += timedelta(days=1)
            stamp += timedelta(days=1)
        previous = stamp
        events.append((stamp.timestamp(), message))
    return events


def live_heap_bytes(outdir, cycle, fallback):
    """Live heap from `jcmd GC.class_histogram` (it runs a full GC itself), else the metrics value.

    The metrics value is read after `GC.run`, but in MODE=sign-reload the load keeps allocating
    until the scrape, so the histogram total is the reliable live-set figure.
    """
    path = outdir / f"cycle-{cycle}.histogram"
    if path.exists():
        for line in reversed(path.read_text().splitlines()):
            match = re.match(r"Total\s+\d+\s+(\d+)", line)
            if match:
                return float(match.group(1))
    return fallback


def k6_summary(path):
    if not path.exists():
        return None
    metrics = json.loads(path.read_text())["metrics"]

    def value(name, field="count"):
        metric = metrics.get(name) or {}
        return metric.get(field)

    failed = sum(1 for m in metrics.values() for v in (m.get("thresholds") or {}).values() if v is True)
    return {
        "signatures": value("signatures"),
        "errors": value("sign_errors"),
        "refused": value("slashing_expected_refusal"),
        "unexpected_refusals": value("slashing_unexpected_refusal"),
        "missing_refusals": value("slashing_missing_refusal"),
        "unknown_keys": value("unknown_key"),
        "missed_slots": value("missed_slots"),
        "att_p50": value("latency_attestation", "med"),
        "att_p99": value("latency_attestation", "p(99)"),
        "block_p99": value("latency_block", "p(99)"),
        "rate": value("http_reqs", "rate"),
        "failed_thresholds": failed,
    }


def fmt(value, pattern="{:.1f}"):
    return "-" if value is None else pattern.format(value)


def summarise(outdir):
    outdir = Path(outdir)
    header = (outdir / "run.log").read_text().splitlines()
    image = next((re.search(r"image=(\S+)", l).group(1) for l in header if "image=" in l), "?")
    mode = next((re.search(r"mode=(\S+)", l).group(1) for l in header if "mode=" in l), "?")
    resources = read_tsv(outdir / "resources.tsv")
    first_epoch = number(resources[0]["epoch_s"]) if resources else None
    events = log_events(outdir, first_epoch)
    captures = {int(re.search(r"cycle=(\d+) ", m).group(1)): t for t, m in events if re.match(r"cycle=\d+ expected_total", m)}
    rows = read_tsv(outdir / "summary.tsv")

    samples = [(number(s["epoch_s"]), number(s["usage_usec"]), number(s["anon"])) for s in resources]
    samples = [s for s in samples if s[0] is not None and s[1] is not None]

    def cpu_at(moment):
        before = [s for s in samples if s[0] <= moment]
        after = [s for s in samples if s[0] >= moment]
        if not before or not after:
            return None
        (t0, c0, _), (t1, c1, _) = before[-1], after[0]
        return c0 if t1 == t0 else c0 + (c1 - c0) * (moment - t0) / (t1 - t0)

    def cores_between(start, end):
        a, b = cpu_at(start), cpu_at(end)
        return (b - a) / 1e6 / (end - start) if a is not None and b is not None and end > start else None

    # Signing windows logged by memleak-test.sh (MODE=sign / sign-reload).
    windows = {}
    for moment, message in events:
        match = re.match(r"cycle (\d+): (?:k6 signing load — duration=(\d+)s|signing for (\d+)s)", message)
        if match:
            windows[int(match.group(1))] = (moment, float(match.group(2) or match.group(3)))
    reloads_done = [moment for moment, message in events if message.startswith("reload finished")]

    table, previous = [], None
    for row in rows:
        cycle = int(row["cycle"])
        cpu = number(row.get("cpu_usage_usec"))
        cycle_cores = None
        if previous and cpu is not None and previous[1] is not None and cycle in captures and previous[0] in captures:
            elapsed = captures[cycle] - captures[previous[0]]
            cycle_cores = (cpu - previous[1]) / 1e6 / elapsed if elapsed > 0 else None
        previous = (cycle, cpu)
        load_cores = reload_cores = None
        if cycle in windows:
            start, seconds = windows[cycle]
            load_cores = cores_between(start + 3, start + seconds - 3)
            if mode == "sign-reload":
                done = next((moment for moment in reloads_done if moment > start + seconds), None)
                reload_cores = cores_between(start + seconds, done) if done else None
        low, high = captures.get(cycle - 1), captures.get(cycle)
        peak = max(
            (s[2] for s in samples if low is not None and high is not None and low < s[0] <= high and s[2] is not None),
            default=None,
        )
        table.append(
            {
                "cycle": cycle,
                "keys": row["expected_total"],
                "heap": (live_heap_bytes(outdir, cycle, number(row["heap_used_bytes"])) or 0) / MIB or None,
                "rss": number(row.get("rss_anon_bytes")) / MIB if number(row.get("rss_anon_bytes")) else None,
                "peak": peak / MIB if peak else None,
                "cache": number(row.get("page_cache_bytes")) / MIB if number(row.get("page_cache_bytes")) else None,
                "load_cores": load_cores,
                "reload_cores": reload_cores,
                "cycle_cores": cycle_cores,
                "reload": row.get("reload_secs"),
                "k6": k6_summary(outdir / f"cycle-{cycle}.k6.json"),
            }
        )

    print(f"### {outdir.name}\n")
    print(f"image `{image}`, mode `{mode}`, {len(table) - 1} cycles\n")
    has_k6 = any(r["k6"] for r in table)
    has_load = any(r["load_cores"] is not None for r in table)
    has_reload_cpu = any(r["reload_cores"] is not None for r in table)
    columns = ["cycle", "keys", "live heap MiB", "anon RSS after GC MiB", "peak anon RSS MiB", "page cache MiB"]
    columns += ["CPU cores (signing)"] if has_load else []
    columns += ["CPU cores (rotate + reload)"] if has_reload_cpu else []
    columns += ["CPU cores (cycle)", "reload s"]
    if has_k6:
        columns += ["signed", "att p50/p99 ms", "errors", "412 refused / unexpected / missing", "missed slots"]
    print("| " + " | ".join(columns) + " |")
    print("|" + "---|" * len(columns))
    for r in table:
        cells = [str(r["cycle"]), r["keys"], fmt(r["heap"]), fmt(r["rss"], "{:.0f}"), fmt(r["peak"], "{:.0f}"), fmt(r["cache"], "{:.0f}")]
        cells += [fmt(r["load_cores"], "{:.2f}")] if has_load else []
        cells += [fmt(r["reload_cores"], "{:.2f}")] if has_reload_cpu else []
        cells += [fmt(r["cycle_cores"], "{:.2f}"), r["reload"] or "-"]
        if has_k6:
            k = r["k6"] or {}
            cells += [
                fmt(k.get("signatures"), "{:.0f}"),
                f"{fmt(k.get('att_p50'))}/{fmt(k.get('att_p99'))}",
                fmt(k.get("errors"), "{:.0f}"),
                f"{fmt(k.get('refused'), '{:.0f}')} / {fmt(k.get('unexpected_refusals'), '{:.0f}')} / {fmt(k.get('missing_refusals'), '{:.0f}')}",
                fmt(k.get("missed_slots"), "{:.0f}"),
            ]
        print("| " + " | ".join(cells) + " |")

    loaded = [r for r in table if r["cycle"] >= 1]
    # The first loaded cycle includes JIT and heap warm-up; leave it out of the trend when possible.
    trend = [r for r in loaded if r["cycle"] >= 2] if len(loaded) >= 4 else loaded
    heap_slope = slope([(r["cycle"], r["heap"]) for r in trend])
    rss_slope = slope([(r["cycle"], r["rss"]) for r in trend])
    peak_anon = max((number(s["anon"]) or 0 for s in resources), default=0) / MIB
    peak_current = max((number(s["memory_current"]) or 0 for s in resources), default=0) / MIB
    loop_start = captures.get(0)
    loop_samples = [s for s in resources if loop_start and number(s["epoch_s"]) >= loop_start]
    avg_cores = None
    if len(loop_samples) >= 2:
        first, last = loop_samples[0], loop_samples[-1]
        wall = number(last["epoch_s"]) - number(first["epoch_s"])
        avg_cores = (number(last["usage_usec"]) - number(first["usage_usec"])) / 1e6 / wall if wall > 0 else None
    print(
        f"\nTrend over cycles {trend[0]['cycle'] if trend else '-'}..{trend[-1]['cycle'] if trend else '-'}: live heap {fmt(heap_slope, '{:+.2f}')} MiB/cycle, "
        f"anon RSS {fmt(rss_slope, '{:+.1f}')} MiB/cycle. Peak anon RSS {peak_anon:.0f} MiB, "
        f"peak cgroup memory {peak_current:.0f} MiB, average CPU after cycle 0 {fmt(avg_cores, '{:.2f}')} cores."
    )
    whole = k6_summary(outdir / "k6-sign-reload.json")
    if whole:
        print(
            f"\nk6 over the whole run: {fmt(whole['signatures'], '{:.0f}')} signatures at {fmt(whole['rate'])} req/s, "
            f"attestation p50/p99 {fmt(whole['att_p50'])}/{fmt(whole['att_p99'])} ms, errors {fmt(whole['errors'], '{:.0f}')}, "
            f"refused (412) {fmt(whole['refused'], '{:.0f}')}, unexpected 412 {fmt(whole['unexpected_refusals'], '{:.0f}')}, "
            f"missing 412 {fmt(whole['missing_refusals'], '{:.0f}')}, unknown keys (404) {fmt(whole['unknown_keys'], '{:.0f}')}, "
            f"missed slots {fmt(whole['missed_slots'], '{:.0f}')}, failed thresholds {whole['failed_thresholds']}."
        )
    print()
    steady = [r["load_cores"] for r in loaded if r["cycle"] >= 2 and r["load_cores"] is not None]
    return {
        "name": outdir.name,
        "image": image,
        "heap": loaded[-1]["heap"] if loaded else None,
        "rss": loaded[-1]["rss"] if loaded else None,
        "heap_slope": heap_slope,
        "rss_slope": rss_slope,
        "peak_anon": peak_anon,
        "avg_cores": avg_cores,
        "signing_cores": sum(steady) / len(steady) if steady else None,
    }


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    results = [summarise(d) for d in argv]
    if len(results) > 1:
        print("### Comparison\n")
        print(
            "| run | image | live heap (last) MiB | live heap slope MiB/cycle | anon RSS (last) MiB | RSS slope MiB/cycle "
            "| peak anon MiB | signing CPU cores (cycles 2..N) | avg CPU cores |"
        )
        print("|---|---|---|---|---|---|---|---|---|")
        for r in results:
            print(
                f"| {r['name']} | `{r['image']}` | {fmt(r['heap'])} | {fmt(r['heap_slope'], '{:+.2f}')} | {fmt(r['rss'], '{:.0f}')} | "
                f"{fmt(r['rss_slope'], '{:+.1f}')} | {r['peak_anon']:.0f} | {fmt(r['signing_cores'], '{:.2f}')} | {fmt(r['avg_cores'], '{:.2f}')} |"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
