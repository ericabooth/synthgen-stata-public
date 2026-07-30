*==============================================================================*
* test_synthgen.do -- battery for synthgen v1.0.0
* Run:  stata-mp -b do test_synthgen.do ["/path/to/pkg"]
* Judge the run by the log: no r(NNN) errors, no "assertion is false".
*==============================================================================*
clear all
set more off

* locate the package (arg > pkgroot global > findfile)
if `"`1'"' != "" global pkgroot `"`1'"'
if `"$pkgroot"' == "" {
    capture findfile synthgen.ado
    if !_rc {
        local fp `"`r(fn)'"'
        local s = max(strrpos(`"`fp'"', "/"), strrpos(`"`fp'"', "\"))
        if `s' > 1 global pkgroot = substr(`"`fp'"', 1, `s' - 1)
    }
}
if `"$pkgroot"' == "" {
    di as err "test_synthgen: cannot locate synthgen.ado."
    exit 601
}
confirm file "$pkgroot/synthgen.ado"
adopath ++ "$pkgroot"
discard

*--- (1) refusal: no destination stated ---------------------------------------*
sysuse nlsw88, clear
capture noisily synthgen wage grade tenure
assert _rc == 198
di as res "TEST 1 OK: destination refusal (rc 198)"

*--- (2) refusal: ID-shaped variable, no override -----------------------------*
capture noisily synthgen idcode wage, frame(bad) seed(1)
assert _rc == 459
capture confirm frame bad
assert _rc != 0
di as res "TEST 2 OK: ID-shaped refusal (rc 459), no partial product"

*--- (3) refusal: string variable (syntax-level) ------------------------------*
sysuse auto, clear
capture noisily synthgen make price, frame(bad2) seed(1)
assert _rc == 109
di as res "TEST 3 OK: string refusal (rc 109)"

*--- (4) basic run: shape, bounds, labels -------------------------------------*
sysuse nlsw88, clear
synthgen wage grade tenure age hours, frame(s1) seed(20260730)
* capture the receipt NOW: any later summarize/count overwrites r()
local rc_n        = r(n)
local rc_k        = r(k)
local rc_maxdmean = r(maxdmean)
local rc_maxdrho  = r(maxdrho)
assert `rc_n' == 2246
assert `rc_k' == 5
frame s1 {
    assert _N == 2246
    confirm variable wage grade tenure age hours
}
* empirical-quantile mapping cannot leave the observed range
quietly summarize wage
local lo = r(min)
local hi = r(max)
frame s1 {
    quietly summarize wage
    assert r(min) >= `lo' & r(max) <= `hi'
}
* labels carried across
frame s1 {
    local L : variable label wage
    assert `"`L'"' != ""
}
di as res "TEST 4 OK: shape, range, labels"

*--- (5) utility: means and rank correlations preserved -----------------------*
assert `rc_maxdmean' < 0.10
assert `rc_maxdrho'  < 0.15
di as res "TEST 5 OK: maxdmean=" %5.3f `rc_maxdmean' " maxdrho=" %5.3f `rc_maxdrho'

*--- (6) determinism under seed ----------------------------------------------*
synthgen wage grade tenure age hours, frame(s2) seed(20260730)
frame s1: quietly summarize wage
local m1 = r(mean)
frame s2: quietly summarize wage
assert reldif(`m1', r(mean)) < 1e-12
di as res "TEST 6 OK: identical draw under the same seed"

*--- (7) missingness re-imposed ----------------------------------------------*
* nlsw88 union is missing for ~16% of rows
quietly count if missing(union)
local srcmiss = r(N)/_N
synthgen union wage grade, frame(s3) seed(7)
frame s3 {
    quietly count if missing(union)
    local synmiss = r(N)/_N
}
assert abs(`synmiss' - `srcmiss') < 0.05
di as res "TEST 7 OK: missing share preserved (" %5.3f `srcmiss' " vs " %5.3f `synmiss' ")"

*--- (8) n() and saving() -----------------------------------------------------*
tempfile out
synthgen wage grade, n(500) saving("`out'") seed(11) noreport
assert r(n) == 500
preserve
use "`out'", clear
assert _N == 500
confirm variable wage grade
restore
di as res "TEST 8 OK: n() and saving()"

*--- (9) receipt scalars present ---------------------------------------------*
synthgen wage grade tenure, frame(s4) seed(3)
local rc_dupes = r(dupes)
local rc_srcn  = r(src_n)
local rc_ccn   = r(cc_n)
assert `rc_dupes' >= 0 & `rc_dupes' < .
assert `rc_srcn' == 2244 | `rc_srcn' == 2246
assert `rc_ccn' > 0 & `rc_ccn' <= `rc_srcn'
di as res "TEST 9 OK: receipt returns (dupes=`rc_dupes')"

*--- (10) categorical variables: values snap to observed categories -----------*
synthgen race married collgrad industry, frame(s5) seed(5)
frame s5 {
    quietly levelsof race, local(rl)
    foreach x of local rl {
        assert inlist(`x', 1, 2, 3)
    }
}
di as res "TEST 10 OK: categorical margins stay on observed values"

di as res _n "ALL TESTS PASSED: synthgen battery complete"
