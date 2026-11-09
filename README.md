# synthgen

Generate a rank-preserving **synthetic stand-in dataset** in Stata: a file that behaves like the source without containing any of its records, so an outside collaborator can write and test code against realistic data while the real records never leave the secure environment.

```stata
sysuse nlsw88, clear
synthgen wage grade tenure age hours, frame(synth) seed(20260730)
frame synth: summarize
```

## What it does

- **Empirical margins, exactly.** Every synthetic value is a value observed in the source, drawn with the source's frequencies — minimums, maximums, and category codes are always respected, and value/variable labels travel with the file.
- **Rank correlations preserved.** A Gaussian copula correlates normal scores on the source's complete cases and maps the joint draw back through each variable's empirical quantiles, so Spearman correlations survive.
- **Missingness re-imposed** per variable (independently; documented limitation).
- **Loud refusals, no overrides.** String variables are refused (encode categories first); numeric variables whose nonmissing values are all distinct are refused as ID-shaped — synthetic identifiers are a re-identification hazard, not a feature. The rule looks only at distinctness, so a continuous variable whose values happen to be all distinct (for example `price` in `sysuse auto`) is refused too; leave it out of the varlist.
- **A utility-and-safety receipt** on every run: worst standardized mean gap, worst pairwise rank-correlation gap, and the count of synthetic rows that exactly duplicate a real record — the number a data-sharing agreement's synthetic clause needs.

## Syntax and options

```stata
synthgen [varlist] [if] [in], [saving(filename[, replace]) frame(name) n(#) seed(#) noreport]
```

With no varlist, every numeric variable is used.

| Option | Meaning |
| ------ | ------- |
| `saving(filename[, replace])` | write the synthetic rows to a `.dta` file (quote a path with spaces) |
| `frame(name)` | copy the synthetic rows into a frame (not the current frame) |
| `n(#)` | number of synthetic rows; default (or `n(0)`) is the source size; negative is an error |
| `seed(#)` | random-number seed, for a reproducible draw |
| `noreport` | suppress the utility-and-safety receipt |

At least one of `saving()` and `frame()` is required.

## Stored results

| Result | Meaning |
| ------ | ------- |
| `r(n)` | synthetic rows generated |
| `r(k)` | variables synthesized |
| `r(src_n)` | source observations used |
| `r(cc_n)` | complete cases behind the correlation structure |
| `r(maxdmean)` | worst standardized mean gap |
| `r(maxdrho)` | worst pairwise rank-correlation gap |
| `r(dupes)` | synthetic rows duplicating a real record |

## Install

```stata
net install synthgen, from("https://raw.githubusercontent.com/ericabooth/synthgen-stata-public/main/") replace force
discard
which synthgen
help synthgen
```

## Requirements

Stata 16 or newer (frames). No Python or other external dependencies.

## Testing

`test_synthgen.do` is the package's battery (refusals, shape/range/label checks, utility tolerances, seed determinism, missing-share preservation, categorical snapping). Run it from the package folder:

```stata
do test_synthgen.do
```

## Changes

- **1.0.2 (2026-11-09):** value labels are carried through a temporary file,
  so no `synthgen_vl.do` is left in the temp folder and no `file ... saved`
  lines print. `frame()` naming the current frame is refused before any work
  (1.0.1 failed with r(110) after drawing). A negative `n()` is r(198). The
  default varlist no longer prints a `ds` listing. The README gains the
  options and stored-results tables, and the help and README say plainly that
  the ID-shaped rule also refuses all-distinct continuous variables.
- **1.0.1 (2026-11-09):** `saving()` accepts a path with spaces, quoted, with
  or without `, replace`; 1.0.0 stopped with r(198) ("invalid 'dir'") and
  wrote nothing. The filename and the `replace` suboption are checked before
  any rows are drawn: an existing file without `replace` is r(602), and any
  other suboption is r(198).

## Authors

Eric A. Booth, Sr Researcher, Texas 2036 (eric.a.booth@gmail.com)
Elizabeth Teas, Sr Research Scientist, Far Harbor, LLC

Issues and PRs welcome.
