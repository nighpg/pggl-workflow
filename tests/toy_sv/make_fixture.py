#!/usr/bin/env python3
"""Generate the SV toy fixture: a PanSN reference, a phased VCF carrying three
SVs, and paired FASTQs simulated from one SV haplotype plus one reference
haplotype (so every SV is heterozygous)."""
import gzip
import os
import random
import sys

OUT = sys.argv[1]
random.seed(20260919)

# --- reference -------------------------------------------------------------
def read_fasta(path):
    seqs, name, buf = {}, None, []
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith(">"):
            if name:
                seqs[name] = "".join(buf)
            name, buf = line[1:].split()[0], []
        else:
            buf.append(line)
    if name:
        seqs[name] = "".join(buf)
    return seqs

ref = read_fasta(os.path.join(OUT, "ref.fa"))
PREFIX = "GRCh38#0#"

with open(os.path.join(OUT, "ref.pansn.fa"), "w") as fh:
    for name, seq in ref.items():
        fh.write(">%s%s\n" % (PREFIX, name))
        for i in range(0, len(seq), 60):
            fh.write(seq[i:i + 60] + "\n")

# --- SVs (1-based POS, VCF convention: REF/ALT share the anchor base) ------
def rand_seq(n):
    return "".join(random.choice("ACGT") for _ in range(n))

INS_SEQ = rand_seq(150)
SVS = [
    # (contig, POS, kind, length)
    ("chr20", 1000, "DEL", 200),
    ("chr20", 1800, "INS", 150),
    ("chrX", 800, "DEL", 120),
]

records = []
for contig, pos, kind, length in SVS:
    anchor = ref[contig][pos - 1]
    if kind == "DEL":
        r = ref[contig][pos - 1: pos - 1 + length + 1]
        a = anchor
    else:
        r = anchor
        a = anchor + INS_SEQ
    records.append((contig, pos, kind, length, r, a))

vcf = os.path.join(OUT, "sv.vcf")
with open(vcf, "w") as fh:
    fh.write("##fileformat=VCFv4.2\n")
    for name, seq in ref.items():
        fh.write("##contig=<ID=%s%s,length=%d>\n" % (PREFIX, name, len(seq)))
    fh.write('##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">\n')
    fh.write("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tTOYSV\n")
    for contig, pos, kind, length, r, a in records:
        fh.write("%s%s\t%d\t%s_%s_%d\t%s\t%s\t60\t.\t.\tGT\t1|0\n"
                 % (PREFIX, contig, pos, kind, contig, pos, r, a))

# --- haplotypes ------------------------------------------------------------
# hap1 carries every SV, hap2 is the reference; edits are applied right to left
# so earlier coordinates stay valid.
hap1 = dict(ref)
for contig, pos, kind, length, r, a in sorted(records, key=lambda x: -x[1]):
    s = hap1[contig]
    hap1[contig] = s[:pos - 1] + a + s[pos - 1 + len(r):]
hap2 = dict(ref)

# --- paired-end simulation -------------------------------------------------
READ_LEN, INSERT, PAIRS_PER_HAP = 150, 400, 900
COMP = str.maketrans("ACGTN", "TGCAN")


def revcomp(s):
    return s.translate(COMP)[::-1]


def simulate(hap, n, tag):
    total = sum(len(s) for s in hap.values())
    out = []
    for contig, seq in hap.items():
        share = max(1, int(round(n * len(seq) / total)))
        for _ in range(share):
            if len(seq) <= INSERT:
                continue
            start = random.randint(0, len(seq) - INSERT)
            frag = seq[start:start + INSERT]
            out.append((tag + "_%d" % len(out), frag[:READ_LEN],
                        revcomp(frag[-READ_LEN:])))
    return out


reads = simulate(hap1, PAIRS_PER_HAP, "h1") + simulate(hap2, PAIRS_PER_HAP, "h2")
random.shuffle(reads)

half = len(reads) // 2
for lane, chunk in (("L1", reads[:half]), ("L2", reads[half:])):
    with open(os.path.join(OUT, "%s_R1.fastq" % lane), "w") as f1, \
         open(os.path.join(OUT, "%s_R2.fastq" % lane), "w") as f2:
        for name, r1, r2 in chunk:
            f1.write("@%s_%s\n%s\n+\n%s\n" % (lane, name, r1, "I" * len(r1)))
            f2.write("@%s_%s\n%s\n+\n%s\n" % (lane, name, r2, "I" * len(r2)))

print("SVs: %s" % ", ".join("%s:%d %s%d" % (c, p, k, l)
                            for c, p, k, l, _, _ in records))
print("read pairs: %d (L1=%d, L2=%d)" % (len(reads), half, len(reads) - half))
