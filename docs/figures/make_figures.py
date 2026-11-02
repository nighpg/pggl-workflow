#!/usr/bin/env python3
"""Draw the figures of docs/BENCHMARK-HG002.md from the values in its tables.

Usage: python3 docs/figures/make_figures.py   (writes docs/figures/*.svg)

The numbers are copied from the tables of BENCHMARK-HG002.md; change them in
both places together.
"""
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

OUT = os.path.dirname(os.path.abspath(__file__))
ACCENT = "#1f6fd1"   # the workflow (setup C)
GREY = "#9aa0a6"     # comparisons
DARK = "#5f6368"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10, "axes.spines.top": False,
    "axes.spines.right": False, "axes.edgecolor": "#bdc1c6", "axes.labelcolor": "#3c4043",
    "xtick.color": "#3c4043", "ytick.color": "#3c4043", "svg.fonttype": "none",
})


def save(fig, name):
    fig.savefig(os.path.join(OUT, name), bbox_inches="tight")
    plt.close(fig)


# 1. F1 by region, GIAB v5.0q: HC -> L -> C
regions = ["Not difficult", "Low mappability\nor segdup", "Segmental\nduplications",
           "Tandem repeats and\nhomopolymers", "MHC", "chrX outside PAR", "chrY outside PAR"]
f1 = {
    "SNP": {"HC": [0.9975, 0.8778, 0.8274, 0.9401, 0.9593, 0.9856, 0.8303],
            "L": [0.9995, 0.9291, 0.8987, 0.9564, 0.9917, 0.9880, 0.8413],
            "C": [0.9996, 0.9715, 0.9509, 0.9539, 0.9944, 0.9946, 0.9447]},
    "INDEL": {"HC": [0.9935, 0.7790, 0.7819, 0.8832, 0.9103, 0.9379, 0.7664],
              "L": [0.9968, 0.8674, 0.8655, 0.9471, 0.9632, 0.9651, 0.8305],
              "C": [0.9969, 0.9078, 0.9131, 0.9465, 0.9509, 0.9686, 0.9018]},
}
fig, axes = plt.subplots(1, 2, figsize=(10, 4.6), sharey=True)
ys = list(range(len(regions)))[::-1]
for ax, kind in zip(axes, ("SNP", "INDEL")):
    d = f1[kind]
    for y, a, b, c in zip(ys, d["HC"], d["L"], d["C"]):
        ax.plot([min(a, b, c), max(a, b, c)], [y, y], color="#dadce0", lw=2, zorder=1)
    ax.scatter(d["HC"], ys, s=46, facecolors="white", edgecolors=GREY, lw=1.6, zorder=2,
               label="BWA + HaplotypeCaller")
    ax.scatter(d["L"], ys, s=46, color=GREY, zorder=2, label="BWA + DeepVariant (L)")
    ax.scatter(d["C"], ys, s=60, color=ACCENT, zorder=3, label="Workflow (C)")
    ax.set_title(kind, loc="left", fontweight="bold")
    ax.set_xlim(0.75, 1.0)
    ax.set_xlabel("F1")
    ax.grid(axis="x", color="#eceff1", lw=0.8)
    ax.set_axisbelow(True)
axes[0].set_yticks(ys)
axes[0].set_yticklabels(regions)
handles, labels = axes[1].get_legend_handles_labels()
fig.legend(handles, labels, loc="lower center", ncol=3, frameon=False, fontsize=9,
           bbox_to_anchor=(0.55, -0.07))
fig.subplots_adjust(top=0.84)
fig.suptitle("The graph gains most where reads map ambiguously: segdup SNP F1 0.83 → 0.95",
             x=0.01, y=0.99, ha="left", fontsize=12, fontweight="bold")
fig.text(0.01, 0.925, "F1 by region, HG002 against GIAB v5.0q (stratifications v3.6)",
         color=DARK, fontsize=9.5)
save(fig, "small-variant-f1-by-region.svg")

# 2. Errors (FN + FP), GIAB v5.0q
setups = ["BWA + HaplotypeCaller", "BWA + DeepVariant (L)", "Full graph (A)", "Workflow (C)"]
errors = {"SNP": [112758, 63633, 45375, 43079], "INDEL": [155624, 73546, 73203, 73749]}
fig, axes = plt.subplots(1, 2, figsize=(10, 2.9), sharey=True)
for ax, kind in zip(axes, ("SNP", "INDEL")):
    vals = errors[kind]
    colors = [GREY, GREY, GREY, ACCENT]
    ys = list(range(len(setups)))[::-1]
    ax.barh(ys, [v / 1000 for v in vals], color=colors, height=0.6)
    for y, v in zip(ys, vals):
        ax.text(v / 1000 + 2, y, f"{v / 1000:.1f}k", va="center", fontsize=9, color="#3c4043")
    ax.set_title(f"{kind} errors (FN + FP)", loc="left", fontweight="bold")
    ax.set_xlabel("thousands")
    ax.set_xlim(0, 175)
axes[0].set_yticks(list(range(len(setups)))[::-1])
axes[0].set_yticklabels(setups)
fig.subplots_adjust(top=0.74)
fig.suptitle("Against HaplotypeCaller the workflow makes 62% fewer SNP and 53% fewer INDEL errors",
             x=0.01, y=0.99, ha="left", fontsize=12, fontweight="bold")
fig.text(0.01, 0.88, "HG002 against GIAB v5.0q; lower is better", color=DARK, fontsize=9.5)
save(fig, "small-variant-errors.svg")

# 3. SV precision and recall, position-and-length rule
fig, ax = plt.subplots(figsize=(6.4, 5.2))
for f in (0.4, 0.6, 0.8, 0.9):
    # the F1 = f curve, precision as a function of recall, kept inside the view
    r = [x / 400 for x in range(1, 401) if x / 400 > f / (2 - f) + 1e-9]
    pts = [(a, f * a / (2 * a - f)) for a in r]
    pts = [(a, b) for a, b in pts if 0.5 <= b <= 1.0]
    ax.plot([a for a, _ in pts], [b for _, b in pts], color="#e8eaed", lw=1, zorder=0)
    a, b = pts[-1]
    ax.text(min(a, 0.99), b + 0.007, f"F1 {f}", color="#9aa0a6", fontsize=8,
            ha="right" if a > 0.95 else "center")
points = [  # (label, recall, precision, colour, marker, label offset)
    ("Manta (HaplotypeCaller pipeline)\ngenome-wide", 0.171, 0.917, GREY, "o", (-0.15, -0.075)),
    ("Graph (C), genome-wide", 0.626, 0.767, ACCENT, "o", (0.02, -0.045)),
    ("Manta, outside repeats", 0.247, 0.948, GREY, "s", (0.02, 0.025)),
    (".nonrep (C), outside repeats", 0.857, 0.974, ACCENT, "s", (-0.33, 0.03)),
]
for label, r, p, c, m, (dx, dy) in points:
    ax.scatter([r], [p], s=70, color=c, marker=m, zorder=3)
    ax.annotate(label, (r, p), (r + dx, p + dy), fontsize=8.5, color="#3c4043")
ax.annotate("", (0.626, 0.767), (0.171, 0.917), arrowprops=dict(arrowstyle="->", color="#bdc1c6"))
ax.annotate("", (0.857, 0.974), (0.247, 0.948), arrowprops=dict(arrowstyle="->", color="#bdc1c6"))
ax.set_xlim(0, 1.0)
ax.set_ylim(0.5, 1.02)
ax.set_xlabel("Recall")
ax.set_ylabel("Precision")
fig.subplots_adjust(top=0.82)
fig.suptitle("The graph recovers 3.7x as many SVs as Manta;\noutside repeats .nonrep also beats it on precision",
             x=0.01, y=0.99, ha="left", fontsize=11.5, fontweight="bold")
fig.text(0.01, 0.875, "HG002 SVs ≥ 50 bp against GIAB v5.0q, matched by position and length "
         "(truvari --pctseq 0)", color=DARK, fontsize=8.5)
save(fig, "sv-precision-recall.svg")

# 4. SV F1 by type and size, full graph (A) vs personalized graph (C)
sizes = ["50–99 bp", "100–299 bp", "300–999 bp", "1–5 kb", "≥ 5 kb"]
sv = {"DEL": {"A": [0.650, 0.660, 0.806, 0.819, 0.838], "C": [0.716, 0.751, 0.863, 0.887, 0.902]},
      "INS": {"A": [0.635, 0.649, 0.748, 0.750, 0.735], "C": [0.662, 0.710, 0.789, 0.806, 0.793]}}
fig, axes = plt.subplots(1, 2, figsize=(10, 3.6), sharey=True)
x = list(range(len(sizes)))
for ax, kind in zip(axes, ("DEL", "INS")):
    ax.plot(x, sv[kind]["A"], "o-", color=GREY, lw=1.8, label="Full graph (A)")
    ax.plot(x, sv[kind]["C"], "o-", color=ACCENT, lw=2.2, label="Personalized graph (C)")
    for xi, v in zip(x, sv[kind]["C"]):
        ax.text(xi, v + 0.018, f"{v:.2f}", ha="center", fontsize=8.5, color=ACCENT)
    ax.set_title(kind, loc="left", fontweight="bold")
    ax.set_xticks(x)
    ax.set_xticklabels(sizes, fontsize=8.5)
    ax.set_ylim(0.5, 1.0)
    ax.grid(axis="y", color="#eceff1", lw=0.8)
    ax.set_axisbelow(True)
axes[0].set_ylabel("F1")
axes[1].legend(loc="lower right", frameon=False, fontsize=9)
fig.suptitle("Sampling the sample's haplotypes raises SV F1 at every type and size",
             x=0.01, ha="left", fontsize=12, fontweight="bold", y=1.03)
fig.text(0.01, 0.94, "HG002 SVs against GIAB v5.0q, truvari bench --refine", color=DARK, fontsize=9.5)
save(fig, "sv-f1-by-size.svg")
print("wrote", ", ".join(sorted(f for f in os.listdir(OUT) if f.endswith(".svg"))))
