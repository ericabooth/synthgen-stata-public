*! synthgen - generate a rank-preserving synthetic stand-in dataset
*! v1.0.0 30jul2026 Eric A. Booth, Sr Researcher, Texas 2036 <eric.a.booth@gmail.com>
*!                  Elizabeth Teas, Sr Research Scientist, Far Harbor, LLC <elizabeth@farharbor.com>
*!
*! Gaussian-copula engine with empirical margins: each synthetic variable
*! reproduces its source variable's observed distribution exactly (every
*! synthetic value is an observed value), and the rank (Spearman)
*! correlations between variables are preserved through a joint normal
*! draw.  Refuses ID-shaped and string variables loudly, with no override.
*! Returns a utility-and-safety receipt: worst standardized mean gap,
*! worst rank-correlation gap, and the count of synthetic rows that
*! duplicate a real record.

program define synthgen, rclass
    version 16
    syntax [varlist(numeric default=none)] [if] [in], ///
        [ SAVing(string) FRame(name) N(integer 0) SEed(integer 0) ///
          noREPort ]

    * ----- what to synthesize --------------------------------------------
    if "`varlist'" == "" {
        ds, has(type numeric)
        local varlist `r(varlist)'
    }
    if "`varlist'" == "" {
        di as err "synthgen: no numeric variables to synthesize."
        exit 102
    }
    if "`saving'" == "" & "`frame'" == "" {
        di as err "synthgen: state where the synthetic rows land:" ///
            " saving(filename) and/or frame(name)."
        exit 198
    }

    marksample touse, novarlist
    quietly count if `touse'
    local srcN = r(N)
    if `srcN' < 10 {
        di as err "synthgen: only `srcN' usable observations; need at least 10."
        exit 2001
    }
    if `n' <= 0 local n = `srcN'
    if `seed' > 0 set seed `seed'
    local K : word count `varlist'

    * ----- ID-shaped refusal ---------------------------------------------
    * A variable whose nonmissing values are all distinct is an identifier
    * in numeric clothing; synthesizing it manufactures fake people with
    * real-looking keys.  Refuse loudly, no override.
    foreach v of local varlist {
        quietly {
            tempvar tag
            egen `tag' = tag(`v') if `touse' & !missing(`v')
            count if `tag' == 1
            local ndist = r(N)
            count if `touse' & !missing(`v')
            local nnm = r(N)
            drop `tag'
        }
        if `ndist' == `nnm' & `nnm' > 10 {
            di as err "synthgen: {bf:`v'} looks like an identifier" ///
                " (all `nnm' nonmissing values are distinct)." ///
                _n "  Drop it from the varlist; synthetic IDs are a" ///
                " re-identification hazard, not a feature.  No override."
            exit 459
        }
    }

    * ----- complete-case check for the correlation structure -------------
    tempvar cc
    quietly egen `cc' = rownonmiss(`varlist') if `touse'
    quietly count if `cc' == `K'
    local ccN = r(N)
    if `ccN' < 10 & `K' > 1 {
        di as err "synthgen: only `ccN' complete cases across the" ///
            " `K' variables; too few to estimate their correlation."
        exit 2001
    }

    * ----- engine (Mata): copula draw + empirical-quantile mapping -------
    tempname RES MISSRATE
    mata: _synthgen_engine("`varlist'", "`touse'", "`cc'", `K', `n', "`RES'", "`MISSRATE'")

    * ----- land the rows --------------------------------------------------
    tempname landing
    frame create `landing'
    frame `landing' {
        quietly set obs `n'
        local j = 0
        foreach v of local varlist {
            local ++j
            quietly gen double `v' = .
        }
        mata: st_store(., tokens("`varlist'"), st_matrix("`RES'"))
        * re-impose each source variable's missing share, independently
        local j = 0
        foreach v of local varlist {
            local ++j
            local mr = `MISSRATE'[1, `j']
            if `mr' > 0 {
                quietly replace `v' = . if runiform() < `mr'
            }
        }
        quietly compress
    }

    * carry labels across so the stand-in reads like the source
    local j = 0
    foreach v of local varlist {
        local vlab : variable label `v'
        local vall : value label `v'
        frame `landing' {
            if `"`vlab'"' != "" label variable `v' `"`vlab'"'
        }
        if "`vall'" != "" {
            label save `vall' using "`c(tmpdir)'/synthgen_vl.do", replace
            frame `landing': quietly do "`c(tmpdir)'/synthgen_vl.do"
            frame `landing': label values `v' `vall'
        }
    }
    frame `landing': label data "SYNTHETIC stand-in (synthgen); no real records"

    * ----- utility-and-safety receipt ------------------------------------
    tempname D
    mata: _synthgen_receipt("`varlist'", "`touse'", "`landing'", `K', "`D'")
    local maxdmean = `D'[1,1]
    local maxdrho  = `D'[1,2]

    * exact-duplicate check: does any synthetic row equal a real row?
    tempvar dupe
    tempname realf
    local dupes 0
    frame put `varlist' if `touse', into(`realf')
    frame `realf': quietly duplicates drop
    frame `landing' {
        quietly frlink m:1 `varlist', frame(`realf') generate(_sg_lnk)
        quietly count if !missing(_sg_lnk)
        local dupes = r(N)
        quietly drop _sg_lnk
    }
    frame drop `realf'

    if "`report'" != "noreport" {
        di as txt _n "synthgen: `n' synthetic rows from `srcN' source rows," ///
            " `K' variables (complete cases for structure: `ccN')"
        di as txt "  worst standardized mean gap:      " as res %6.3f `maxdmean'
        di as txt "  worst rank-correlation gap:       " as res %6.3f `maxdrho'
        di as txt "  synthetic rows duplicating a real record: " as res `dupes'
        if `dupes' > 0 {
            di as txt "  (a duplicate is not automatically a leak on coarse" ///
                " variables, but it is the first thing to check)"
        }
    }

    * ----- write the products --------------------------------------------
    if "`frame'" != "" {
        capture frame drop `frame'
        frame copy `landing' `frame'
        di as txt `"  synthetic rows in frame {bf:`frame'}"'
    }
    if `"`saving'"' != "" {
        frame `landing': save `saving'
    }
    frame drop `landing'

    return scalar n        = `n'
    return scalar k        = `K'
    return scalar src_n    = `srcN'
    return scalar cc_n     = `ccN'
    return scalar maxdmean = `maxdmean'
    return scalar maxdrho  = `maxdrho'
    return scalar dupes    = `dupes'
end

version 16
mata:
void _synthgen_engine(string scalar vlist, string scalar touse,
                      string scalar cc, real scalar K, real scalar n,
                      string scalar RES, string scalar MISSRATE)
{
    string rowvector vars
    real matrix X, Z, R, L, out
    real colvector x, z, u, idx, srt
    real scalar j, N, i, lambda
    real rowvector missrate

    vars = tokens(vlist)
    X = st_data(., vars, touse)
    N = rows(X)
    missrate = J(1, K, 0)

    // normal scores per column (nonmissing), for the correlation structure
    Z = J(N, K, .)
    for (j = 1; j <= K; j++) {
        x = X[., j]
        missrate[j] = sum(x :== .) / N
        srt = selectindex(x :!= .)
        z = J(N, 1, .)
        if (rows(srt) > 0) {
            real colvector xv, rk
            xv = x[srt]
            rk = _synthgen_ranks(xv)
            z[srt] = invnormal((rk :- 0.5) :/ rows(xv))
        }
        Z[., j] = z
    }

    // correlation of normal scores on complete cases, ridge to PD
    real colvector ccidx
    ccidx = selectindex(rowmissing(Z) :== 0)
    if (K == 1) {
        R = I(1)
        L = I(1)
    }
    else {
        R = correlation(Z[ccidx, .])
        // blend toward the identity until the matrix is safely PD
        lambda = 0
        while (min(symeigenvalues(_synthgen_blend(R, lambda))) < 1e-8) {
            lambda = (lambda == 0 ? 1e-6 : lambda * 10)
            if (lambda >= 1) break
        }
        R = _synthgen_blend(R, min((lambda, 1)))
        L = cholesky(R)
    }

    // joint normal draw -> uniforms -> empirical quantiles of each margin
    real matrix draw
    draw = rnormal(n, K, 0, 1)
    if (K > 1) draw = draw * L'
    out = J(n, K, .)
    for (j = 1; j <= K; j++) {
        real colvector src, uu
        src = sort(select(X[., j], X[., j] :!= .), 1)
        if (rows(src) == 0) continue
        uu = normal(draw[., j])
        idx = ceil(uu :* rows(src))
        idx = rowmax((idx, J(n, 1, 1)))
        idx = rowmin((idx, J(n, 1, rows(src))))
        out[., j] = src[idx]
    }

    st_matrix(RES, out)
    st_matrix(MISSRATE, missrate)
}

real colvector _synthgen_ranks(real colvector x)
{
    // average ranks (ties share their mean rank)
    real colvector ord, rk
    real scalar i, j0, j1
    ord = order(x, 1)
    rk = J(rows(x), 1, .)
    i = 1
    while (i <= rows(x)) {
        j0 = i
        j1 = i
        while (j1 < rows(x)) {
            if (x[ord[j1 + 1]] == x[ord[j0]]) j1++
            else break
        }
        rk[ord[|j0 \ j1|]] = J(j1 - j0 + 1, 1, (j0 + j1) / 2)
        i = j1 + 1
    }
    return(rk)
}

real matrix _synthgen_blend(real matrix R, real scalar lambda)
{
    return((1 - lambda) * R + lambda * I(rows(R)))
}

void _synthgen_receipt(string scalar vlist, string scalar touse,
                       string scalar landing, real scalar K,
                       string scalar D)
{
    string rowvector vars
    real matrix XS, XT, ZS, ZT, RS, RT
    real scalar j, dmean, drho
    real colvector s, t

    vars = tokens(vlist)
    XS = st_data(., vars, touse)
    string scalar cur
    cur = st_framecurrent()
    st_framecurrent(landing)
    XT = st_data(., vars)
    st_framecurrent(cur)

    dmean = 0
    ZS = J(rows(XS), K, .)
    ZT = J(rows(XT), K, .)
    for (j = 1; j <= K; j++) {
        s = select(XS[., j], XS[., j] :!= .)
        t = select(XT[., j], XT[., j] :!= .)
        if (rows(s) > 1 & rows(t) > 0) {
            real scalar gap
            gap = abs(mean(t) - mean(s)) / sqrt(variance(s))
            if (gap > dmean) dmean = gap
        }
        // normal scores for rank-correlation comparison
        real colvector is, it
        is = selectindex(XS[., j] :!= .)
        it = selectindex(XT[., j] :!= .)
        if (rows(is) > 0) ZS[is, j] = invnormal((_synthgen_ranks(XS[is, j]) :- 0.5) :/ rows(is))
        if (rows(it) > 0) ZT[it, j] = invnormal((_synthgen_ranks(XT[it, j]) :- 0.5) :/ rows(it))
    }
    drho = 0
    if (K > 1) {
        RS = correlation(ZS[selectindex(rowmissing(ZS) :== 0), .])
        RT = correlation(ZT[selectindex(rowmissing(ZT) :== 0), .])
        drho = max(abs(RS - RT))
    }
    st_matrix(D, (dmean, drho))
}
end
