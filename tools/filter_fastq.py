#!/usr/bin/env python3
"""Drop read pairs whose sequence length != quality length (vg 1.70 crashes on them).

R1 and R2 must be in lockstep (same read order, as produced by `samtools fastq -1/-2`).
Streaming; safe for multi-hundred-GB files.
Usage: filter_fastq.py fq1 fq2 out1 out2
"""
import sys

def gen_records(fh):
    while True:
        name = fh.readline()
        if name == b"":
            return
        seq = fh.readline()
        plus = fh.readline()
        qual = fh.readline()
        yield name, seq, plus, qual

def main():
    f1, f2, o1, o2 = sys.argv[1:5]
    kept = dropped = 0
    with open(f1, "rb") as a, open(f2, "rb") as b, open(o1, "wb") as w1, open(o2, "wb") as w2:
        ok = True
        for (n1, s1, p1, q1), (n2, s2, p2, q2) in zip(gen_records(a), gen_records(b)):
            ok = (s1.endswith(b"\n") and q1.endswith(b"\n")
                  and s2.endswith(b"\n") and q2.endswith(b"\n")
                  and len(s1.rstrip()) == len(q1.rstrip())
                  and len(s2.rstrip()) == len(q2.rstrip()))
            if ok:
                w1.write(n1 + s1 + p1 + q1)
                w2.write(n2 + s2 + p2 + q2)
                kept += 1
            else:
                dropped += 1
    print(f"kept={kept} dropped={dropped}", file=sys.stderr)
    return 0 if dropped == 0 or kept > 0 else 1

if __name__ == "__main__":
    sys.exit(main())