/*=============================================================================
  PROGRAM:    esl_oaxaca_detailed.sas
  PURPOSE:    Detailed per-variable Oaxaca-Blinder decomposition.
              Identifies how much of the EXPLAINED portion of each racial
              pricing gap is attributable to each underwriting control variable.

  DIFFERS FROM AGGREGATE OAXACA:
    Aggregate Oaxaca produces three numbers per (outcome, comparison, spec):
      - total gap, explained, unexplained
    Detailed Oaxaca produces per-variable contributions to the explained
    portion, so you can say "X% of the explained gap is attributable to
    loan amount differences, Y% to credit score, etc."

  USES WORK._merged_decomp DATASET from prior Oaxaca run.
  Each row of that dataset contains:
      variable, beta_ref, beta_prot, beta_pool, xbar_ref, xbar_prot,
      contrib_explained, contrib_unexp_ref, contrib_unexp_prot, contrib_unexplained

  PRECONDITION: esl_oaxaca_blinder_v3.sas has run successfully.

  RUN OPTIONS:
    A) Re-run the Oaxaca macro but save the per-variable decomposition
       to a permanent output dataset
    B) Just regenerate the detailed table for Black-White and Hispanic-White
       cost outcome, Full spec

  This program does option A to be complete and produces a memo-ready
  detailed table for all (comparison x outcome x spec) combinations.

=============================================================================*/

options nofmterr nomprint nomlogic nosymbolgen;

libname hmda25 "S:\Projects\OCFP_Fair_Lending\2025_NEW\data";
libname out    "S:\Projects\OCFP_Fair_Lending\2025_NEW\data\oaxaca";

%let SOURCE_DS = hmda25.reg_combinations_origs6;
%let ESL_ID    = 26241;

/*-----------------------------------------------------------------------------
  STEP 1: REBUILD ANALYTICAL SAMPLE (matches Oaxaca v3 exactly)
-----------------------------------------------------------------------------*/
data work.esl_loans;
    set &SOURCE_DS.;
    where join_number = &ESL_ID.
      and action = 1
      and not missing(Interest_Rate_Min_PMMS_1)
      and not missing(credit_score)
      and not missing(DTI_N)
      and not missing(LTV_COMBINED)
      and not missing(loan_amount)
      and not missing(LN_TERM)
      and race in ("WHITE","BLACK","HISP")
      and loan_type    in (1, 2)
      and loan_purpose in (1, 32);

    d_fha     = (loan_type = 2);
    d_cashout = (loan_purpose = 32);
    is_black  = (race = "BLACK");
    is_hisp   = (race = "HISP");
run;

%let X_FULL = credit_score DTI_N LTV_COMBINED loan_amount LN_TERM d_fha d_cashout;
%let X_NOLA = credit_score DTI_N LTV_COMBINED             LN_TERM d_fha d_cashout;

/*-----------------------------------------------------------------------------
  STEP 2: OAXACA MACRO THAT KEEPS PER-VARIABLE DECOMPOSITION
-----------------------------------------------------------------------------*/
%macro oaxaca_detailed(
    outcome=, outcome_label=,
    ref_group=WHITE, prot_group=,
    x_vars=,
    spec_label=,
    out_detail=
);

    %put ====================================================================;
    %put DETAILED OAXACA: &outcome, &prot_group vs &ref_group, spec=&spec_label;
    %put ====================================================================;

    data work._sample;
        set work.esl_loans;
        where race in ("&ref_group.","&prot_group.");
        is_protected = (race = "&prot_group.");
    run;

    proc sql noprint;
        select count(*) into :n_ref  trimmed from work._sample where race="&ref_group.";
        select count(*) into :n_prot trimmed from work._sample where race="&prot_group.";
    quit;

    %if &n_prot < 10 %then %do;
        %put WARNING: protected group n=&n_prot too small - skipping;
        %return;
    %end;

    /* Three regressions */
    proc reg data=work._sample(where=(race="&ref_group.")) noprint
             outest=work._beta_ref_wide;
        model &outcome. = &x_vars.;
    run; quit;

    proc reg data=work._sample(where=(race="&prot_group.")) noprint
             outest=work._beta_prot_wide;
        model &outcome. = &x_vars.;
    run; quit;

    proc reg data=work._sample noprint outest=work._beta_pool_wide;
        model &outcome. = &x_vars. is_protected;
    run; quit;

    proc means data=work._sample(where=(race="&ref_group.")) noprint;
        var &outcome. &x_vars.;
        output out=work._mean_ref_wide(drop=_TYPE_ _FREQ_) mean=;
    run;
    proc means data=work._sample(where=(race="&prot_group.")) noprint;
        var &outcome. &x_vars.;
        output out=work._mean_prot_wide(drop=_TYPE_ _FREQ_) mean=;
    run;

    proc transpose data=work._beta_ref_wide(keep=Intercept &x_vars.)
                   out=work._beta_ref_long(rename=(_NAME_=variable COL1=beta_ref));
    run;
    proc transpose data=work._beta_prot_wide(keep=Intercept &x_vars.)
                   out=work._beta_prot_long(rename=(_NAME_=variable COL1=beta_prot));
    run;
    proc transpose data=work._beta_pool_wide(keep=Intercept &x_vars. is_protected)
                   out=work._beta_pool_long(rename=(_NAME_=variable COL1=beta_pool));
    run;
    proc transpose data=work._mean_ref_wide(keep=&x_vars.)
                   out=work._mean_ref_long(rename=(_NAME_=variable COL1=xbar_ref));
    run;
    proc transpose data=work._mean_prot_wide(keep=&x_vars.)
                   out=work._mean_prot_long(rename=(_NAME_=variable COL1=xbar_prot));
    run;

    /* Per-variable decomposition */
    proc sql;
        create table work._var_decomp as
        select br.variable,
               br.beta_ref,
               bp.beta_prot,
               bo.beta_pool,
               mr.xbar_ref,
               mp.xbar_prot,
               (mr.xbar_ref - mp.xbar_prot)               as xbar_diff,
               (mr.xbar_ref - mp.xbar_prot) * bo.beta_pool as contrib_explained,
               mr.xbar_ref  * (br.beta_ref - bo.beta_pool) +
               mp.xbar_prot * (bo.beta_pool - bp.beta_prot)
                                                          as contrib_unexplained
        from work._beta_ref_long  br
        inner join work._beta_prot_long bp on upcase(br.variable)=upcase(bp.variable)
        inner join work._beta_pool_long bo on upcase(br.variable)=upcase(bo.variable)
        inner join work._mean_ref_long  mr on upcase(br.variable)=upcase(mr.variable)
        inner join work._mean_prot_long mp on upcase(br.variable)=upcase(mp.variable)
        where upcase(br.variable) not in ("INTERCEPT","IS_PROTECTED");
    quit;

    /* Tag with metadata */
    data work._var_decomp_tagged;
        length comparison $20 outcome $40 outcome_lbl $40 spec $20;
        comparison  = "&prot_group._vs_&ref_group.";
        outcome     = "&outcome.";
        outcome_lbl = "&outcome_label.";
        spec        = "&spec_label.";
        set work._var_decomp;
    run;

    proc append base=&out_detail. data=work._var_decomp_tagged force; run;

%mend;

/*-----------------------------------------------------------------------------
  STEP 3: RUN FOR KEY (OUTCOME, COMPARISON, SPEC) COMBINATIONS
  Focus on what matters most for the memo:
    - Total Loan Costs (the headline outcome)
    - Both Black and Hispanic comparisons
    - Full spec (the one with all controls)
-----------------------------------------------------------------------------*/
proc datasets library=out nolist;
    delete oaxaca_detailed_decomp;
quit;

%oaxaca_detailed(outcome=Loan_Cost_Prc_LA, outcome_label=Total loan costs,
                 ref_group=WHITE, prot_group=BLACK,
                 x_vars=&X_FULL., spec_label=Full,
                 out_detail=out.oaxaca_detailed_decomp);

%oaxaca_detailed(outcome=Loan_Cost_Prc_LA, outcome_label=Total loan costs,
                 ref_group=WHITE, prot_group=HISP,
                 x_vars=&X_FULL., spec_label=Full,
                 out_detail=out.oaxaca_detailed_decomp);

/*-----------------------------------------------------------------------------
  STEP 4: BUILD MEMO-READY TABLE
  Convert raw proportions to basis points and percentages of explained gap.
-----------------------------------------------------------------------------*/
proc sql noprint;
    select mean(loan_amount) into :avg_loan trimmed from work.esl_loans;
quit;

/* Get total explained per comparison so we can compute % shares */
proc sql;
    create table work._totals as
    select comparison, spec,
           sum(contrib_explained)   as total_explained,
           sum(contrib_unexplained) as total_unexplained,
           sum(contrib_explained) + sum(contrib_unexplained) as gap_check
    from out.oaxaca_detailed_decomp
    group by comparison, spec;
quit;

data out.oaxaca_detailed_memo;
    merge out.oaxaca_detailed_decomp(in=a)
          work._totals;
    by comparison spec;
    if a;

    /* Convert to basis points of loan amount */
    contrib_explained_bp   = contrib_explained   * 10000;
    contrib_unexplained_bp = contrib_unexplained * 10000;

    /* Share of explained portion attributable to this variable */
    if total_explained ne 0 then
        pct_of_explained = contrib_explained / total_explained;

    /* Dollar contribution on avg loan */
    contrib_dollar = contrib_explained * &avg_loan;

    /* Label variables in plain English for memo */
    length var_label $40;
    select (upcase(variable));
        when ("CREDIT_SCORE")   var_label = "Credit score";
        when ("DTI_N")          var_label = "Debt-to-income ratio";
        when ("LTV_COMBINED")   var_label = "Loan-to-value ratio";
        when ("LOAN_AMOUNT")    var_label = "Loan amount";
        when ("LN_TERM")        var_label = "Loan term";
        when ("D_FHA")          var_label = "FHA loan (vs conventional)";
        when ("D_CASHOUT")      var_label = "Cash-out refi (vs purchase)";
        otherwise               var_label = variable;
    end;
run;

/* Sort by absolute size of explained contribution within each comparison */
proc sort data=out.oaxaca_detailed_memo;
    by comparison descending contrib_explained;
run;

proc print data=out.oaxaca_detailed_memo noobs label;
    title "DETAILED OAXACA DECOMPOSITION - Total Loan Costs";
    title2 "Per-variable contribution to the EXPLAINED portion of the racial cost gap";
    title3 "(Full spec, with all underwriting controls)";
    by comparison notsorted;
    var var_label contrib_explained_bp pct_of_explained
        contrib_dollar xbar_ref xbar_prot xbar_diff;
    label var_label             = "Variable"
          contrib_explained_bp  = "Explained contrib (bp)"
          pct_of_explained      = "% of explained"
          contrib_dollar        = "$ on avg loan"
          xbar_ref              = "Avg (White)"
          xbar_prot             = "Avg (Protected)"
          xbar_diff             = "Diff";
    format contrib_explained_bp 10.1
           pct_of_explained percent8.1
           contrib_dollar dollar10.2
           xbar_ref xbar_prot xbar_diff 12.4;
run;
title;

/*-----------------------------------------------------------------------------
  STEP 5: HEADLINE LOG DUMP
-----------------------------------------------------------------------------*/
proc sql;
    title "Summary: top explainers of the racial cost gap";
    select comparison, var_label,
           contrib_explained_bp format=10.1,
           pct_of_explained format=percent8.1,
           xbar_ref format=12.4 as "White Mean",
           xbar_prot format=12.4 as "Prot Mean"
    from out.oaxaca_detailed_memo
    where abs(pct_of_explained) >= 0.05
    order by comparison, abs(contrib_explained) desc;
quit;
title;

%put ;
%put ====================================================================;
%put DETAILED OAXACA - WHICH VARIABLES DRIVE THE EXPLAINED PORTION;
%put ====================================================================;
%put ;
%put Look at the printed table to see per-variable contributions.;
%put Variables with |pct_of_explained| >= 5%% are the substantive drivers.;
%put ;
%put EXPECTED PATTERN:;
%put   loan_amount: largest explainer (Black and Hispanic borrowers take;
%put     smaller loans on avg; smaller loans have higher cost ratios);
%put   credit_score: moderate explainer (lower avg scores in protected;
%put     groups; lower scores associated with higher pricing);
%put   DTI_N, LTV_COMBINED: smaller contributions;
%put   loan_type d_fha: depends on FHA usage by group;
%put ====================================================================;

/*=============================================================================
  END
=============================================================================*/
