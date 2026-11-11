#!/usr/bin/env python3
"""Check that every file a graph preset names exists, before a run is submitted.

  check-inputs.py PRESET [--data-root DIR]

PRESET is a graph preset (examples/graphs/<name>.json). Its relative paths are
looked up the way apply-graph.py does: under the data root (--data-root, else
$PGGL_DATA), then in this checkout. Prints one line per file and exits 1 when
any is missing, with what to run for the ones that can be fetched.
"""
import argparse, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("apply_graph", os.path.join(HERE, "apply-graph.py"))
apply_graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply_graph)


def files(v, name=""):
    """Yield (name, File path) for every File in the preset."""
    if isinstance(v, dict):
        if v.get("class") == "File":
            yield name, v["path"]
        else:
            for k, x in v.items():
                yield from files(x, f"{name}.{k}" if name else k)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("preset")
    ap.add_argument("--data-root", default=os.environ.get("PGGL_DATA"),
                    help="directory the preset's relative paths are under (default: $PGGL_DATA)")
    a = ap.parse_args()
    preset = apply_graph.resolve(apply_graph.load(a.preset), a.data_root)
    missing = []
    print(f"{a.preset} (data root: {a.data_root or 'none'})")
    for name, path in files(preset):
        ok = os.path.exists(path)
        print(f"  {'OK     ' if ok else 'MISSING'} {name}: {path}")
        if not ok:
            missing.append((name, path))
    if not missing:
        return
    print(f"\n{len(missing)} file(s) missing.", file=sys.stderr)
    if any(os.path.basename(os.path.dirname(p)) == "interval_files" for _, p in missing):
        print("  The repeat BED is not in the repo: run scripts/fetch-giab-repeat-bed.sh "
              "(it writes to the checkout's interval_files/), or copy the file there "
              "from another host.", file=sys.stderr)
    if any(os.path.basename(os.path.dirname(p)) != "interval_files" for _, p in missing):
        print("  Graph files come from the graph release: check --data-root / $PGGL_DATA "
              "points at the directory that holds the release folders.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
