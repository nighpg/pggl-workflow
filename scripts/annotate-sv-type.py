#!/usr/bin/env python3
"""Adds SVTYPE/SVLEN/SVSIM to a vg call VCF.

vg call writes REF and ALT as explicit sequences and never emits a symbolic
<INV> or <DUP>, so the kind of event a record describes is present but
unlabelled. The type is recovered from the sequences themselves:

  INV  the ALT matches the reverse complement of the REF and not the REF
  DUP  the inserted sequence is a copy of the reference next to it
  INS  the inserted sequence is unrelated to its flanks
  DEL  the ALT is shorter than the REF by at least min_length

This matters for more than tidiness. An inversion barely changes length -- on
NA18945 the median length difference of an inversion was 3 bp, and 86% of them
were under 50 bp -- so filtering the VCF on |ALT-REF| throws nearly all of them
away while keeping the 6 kb event they describe invisible. SVTYPE is what makes
them findable.

Comparisons are 31-mer set operations rather than alignment: an inversion
carries none of the reference's forward k-mers and nearly all of its reverse
complement's, which separates the two cases by an order of magnitude without
aligning anything. Every ALT allele is annotated, not only the called ones, so
the fields describe the site rather than this sample's genotype.

Usage: annotate-sv-type.py <in.vcf.gz> <ref.fa> <min_length> <out.vcf>
"""
import subprocess, sys, tempfile, os

K = 31
INV_MIN_JACCARD = 0.3      # below this the reverse-complement match is noise
INV_RATIO = 3.0            # and it has to beat the forward match by this much
DUP_MIN_CONTAINED = 0.8    # fraction of the insert's k-mers found in a flank
BALANCED = (0.7, 1.43)     # an inversion keeps its length; this is the slack

COMP = str.maketrans("ACGTNacgtn", "TGCANtgcan")


def rc(s):
    return s.translate(COMP)[::-1]


def kmers(s):
    s = s.upper()
    return {s[i:i + K] for i in range(len(s) - K + 1)} if len(s) >= K else set()


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def contained(a, b):
    return len(a & b) / len(a) if a else 0.0


def insert_of(ref, alt):
    """The sequence an ALT adds, with the flanks it shares with REF removed."""
    a, b = ref.upper(), alt.upper()
    p = 0
    while p < len(a) and p < len(b) and a[p] == b[p]:
        p += 1
    s = 0
    while s < len(a) - p and s < len(b) - p and a[len(a) - 1 - s] == b[len(b) - 1 - s]:
        s += 1
    return b[p:len(b) - s], p


def records(path):
    """Stream the VCF, yielding header lines as-is and data lines split."""
    p = subprocess.Popen(["bcftools", "view", path], stdout=subprocess.PIPE,
                         universal_newlines=True)
    for line in p.stdout:
        if line.startswith("#"):
            yield line, None
        else:
            yield line, line.rstrip("\n").split("\t")
    p.stdout.close()
    if p.wait() != 0:
        sys.exit(f"annotate-sv-type.py: bcftools view failed on {path}")


def main():
    vcf, ref, min_length, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

    lengths = {}
    with open(ref + ".fai") as fh:
        for line in fh:
            f = line.split("\t")
            lengths[f[0]] = int(f[1])

    # Pass 1: every insertion needs the reference on either side of it, the same
    # length as the insert, to see whether it is a copy of its neighbourhood.
    # They are collected and fetched in one samtools call; one call per record
    # would dominate the runtime.
    wanted = []
    for _, f in records(vcf):
        if f is None:
            continue
        chrom, pos, r = f[0], int(f[1]), f[3]
        for alt in f[4].split(","):
            if alt.startswith("<") or len(alt) - len(r) < min_length:
                continue
            seg, off = insert_of(r, alt)
            if len(seg) < K:
                continue
            anchor, L, n = pos + off, len(seg), lengths.get(chrom, 0)
            wanted.append((f"{chrom}:{max(1, anchor - L)}-{max(1, anchor - 1)}",
                           f"{chrom}:{min(n, anchor)}-{min(n, anchor + L - 1)}"))

    flanks = {}
    if wanted:
        with tempfile.NamedTemporaryFile("w", suffix=".regions", delete=False) as fh:
            regions = fh.name
            for up, down in wanted:
                fh.write(up + "\n" + down + "\n")
        try:
            fa = subprocess.run(["samtools", "faidx", "-r", regions, ref],
                                capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(regions)
        name, buf = None, []
        for line in fa.split("\n"):
            if line.startswith(">"):
                if name:
                    flanks[name] = "".join(buf)
                name, buf = line[1:].split()[0], []
            elif line:
                buf.append(line)
        if name:
            flanks[name] = "".join(buf)

    hdr = [
        '##INFO=<ID=SVTYPE,Number=A,Type=String,Description="Event each ALT '
        'describes, recovered from the sequences: INV (ALT matches the reverse '
        'complement of REF), DUP (inserted sequence is a copy of the adjacent '
        'reference), INS (inserted sequence unrelated to its flanks), DEL, or . '
        'when the allele is too small to classify">\n',
        '##INFO=<ID=SVLEN,Number=A,Type=Integer,Description="Bases gained '
        '(INS/DUP, positive) or lost (DEL, negative); for INV the length of the '
        'inverted segment, which is not the length difference">\n',
        '##INFO=<ID=SVSIM,Number=A,Type=Float,Description="The 31-mer similarity '
        'the SVTYPE rests on: reverse-complement Jaccard for INV, fraction of '
        'the insert found in the adjacent reference for DUP/INS, . otherwise">\n',
    ]

    with open(out, "w") as fh:
        it = iter(records(vcf))
        for line, f in it:
            if f is None:
                if line.startswith("#CHROM"):
                    fh.writelines(hdr)
                fh.write(line)
                continue
            chrom, pos, r = f[0], int(f[1]), f[3]
            types, lens, sims = [], [], []
            for alt in f[4].split(","):
                t, L, sim = ".", ".", "."
                if alt.startswith("<"):
                    pass
                else:
                    d = len(alt) - len(r)
                    ratio = len(alt) / len(r) if len(r) else 0
                    if (len(r) >= min_length and len(alt) >= min_length
                            and BALANCED[0] <= ratio <= BALANCED[1]):
                        fwd = jaccard(kmers(r), kmers(alt))
                        rev = jaccard(kmers(rc(r)), kmers(alt))
                        if rev > INV_MIN_JACCARD and rev > fwd * INV_RATIO:
                            t, L, sim = "INV", len(r), f"{rev:.3f}"
                    if t == "." and d >= min_length:
                        seg, off = insert_of(r, alt)
                        frac = 0.0
                        if len(seg) >= K:
                            anchor, n = pos + off, lengths.get(chrom, 0)
                            ks = kmers(seg)
                            for key in (f"{chrom}:{max(1, anchor - len(seg))}-{max(1, anchor - 1)}",
                                        f"{chrom}:{min(n, anchor)}-{min(n, anchor + len(seg) - 1)}"):
                                if key in flanks:
                                    frac = max(frac, contained(ks, kmers(flanks[key])))
                        t = "DUP" if frac >= DUP_MIN_CONTAINED else "INS"
                        L, sim = d, f"{frac:.3f}"
                    elif t == "." and d <= -min_length:
                        t, L = "DEL", d
                types.append(t)
                lens.append(str(L))
                sims.append(sim)
            add = f"SVTYPE={','.join(types)};SVLEN={','.join(lens)};SVSIM={','.join(sims)}"
            f[7] = add if f[7] in (".", "") else f[7] + ";" + add
            fh.write("\t".join(f) + "\n")


if __name__ == "__main__":
    main()
