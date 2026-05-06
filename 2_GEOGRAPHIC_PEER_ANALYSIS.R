/*=============================================================================
  PROGRAM:    esl_geographic_peer_FINAL.sas
PURPOSE:    Self-contained end-to-end ESL geographic-peer pricing comparison
using tract-overlap peer selection and cluster-bootstrap CIs.
Produces memo-ready basis-point and dollar-equivalent tables
for all-borrower and race-stratified differentials.

NO DEPENDENCIES on prior WORK datasets - runs from source HMDA dataset.

AUTHOR:     [Saurabh]
DATE:       2026-05-06

METHODOLOGY (locked-in design choices):
  - Peer universe: Credit Unions only
- Activity floor: peer must have >=100 originations in 2024
- Per-tract floor: peer needs >=1 loan in shared tract to qualify
- Overlap metric: ESL-weighted asymmetric (sum ESL vol in shared tracts /
                                             ESL total vol)
- Min overlap: 3% of ESL volume covered
- Top-N peers: 25 (binding only if many qualify)
- Aggregation: pooled equal-weighted across peers within tract
- Cell statistic: tract-level mean differential (ESL mean - pool mean)
- Inference: cluster bootstrap on tract, 1000 reps, percentile CIs
- Sample disclosure: results are descriptive, not inferential, given
small peer set

OUTPUTS:
  OUT.peers_selected            - the 3 peer CUs with overlap metrics
OUT.tract_cells               - tract-level differentials (ESL - pool)
OUT.pooled_diffs              - all-borrower pooled diffs with CIs
OUT.race_stratified_diffs     - by-race pooled diffs with CIs
OUT.memo_table                - bp + $-equivalent for memo
OUT.peer_diagnostics          - per-peer contribution to pool

=============================================================================*/
  
  /*-----------------------------------------------------------------------------
  SETUP
-----------------------------------------------------------------------------*/
  options nofmterr nomprint nomlogic nosymbolgen;

libname hmda24 "S:\Projects\OCFP_Fair_Lending\2024_NEW\data";
libname out    "S:\Projects\OCFP_Fair_Lending\2024_NEW\data\peer_geo";

%let SOURCE_DS         = hmda24.reg_combinations_origs6;
%let ESL_ID            = 26241;
%let MIN_PEER_ORIGS    = 100;
%let MIN_PEER_VOL_TR   = 1;
%let MIN_OVERLAP_SCORE = 0.03;
%let TOP_N_PEERS       = 25;
%let N_BOOT            = 1000;
%let SEED              = 20260506;

/*-----------------------------------------------------------------------------
  STEP 1: ESL ORIGINATIONS AND TRACT FOOTPRINT
-----------------------------------------------------------------------------*/
  data work.esl_origs;
set &SOURCE_DS.;
where join_number = &ESL_ID.
and action_taken = 1
and not missing(census_tract);
length tract_key $11;
tract_key = put(input(census_tract, ?? best12.), z11.);
if tract_key in ('00000000000','.') then delete;
run;

proc sql;
create table work.esl_tract_dist as
select tract_key,
count(*)         as esl_n_loans,
sum(loan_amount) as esl_vol
from work.esl_origs
group by tract_key;
quit;

proc sql noprint;
select sum(loan_amount) into :esl_total_vol trimmed
from work.esl_origs;
quit;

/*-----------------------------------------------------------------------------
  STEP 2: ELIGIBLE CU CANDIDATE POOL
ADJUST 'institution_type in ("CU","Credit Union")' to match your CU flag.
-----------------------------------------------------------------------------*/
  data work.cu_origs;
set &SOURCE_DS.;
where action_taken = 1
and join_number ne &ESL_ID.
and not missing(census_tract)
and not missing(join_number)
and institution_type in ("CU","Credit Union");   /* <-- VERIFY VAR/VALUES */
  length tract_key $11;
tract_key = put(input(census_tract, ?? best12.), z11.);
if tract_key in ('00000000000','.') then delete;
run;

proc sql;
create table work.cu_eligible as
select join_number,
count(*)         as peer_total_origs,
sum(loan_amount) as peer_total_vol
from work.cu_origs
group by join_number
having calculated peer_total_origs >= &MIN_PEER_ORIGS.;
quit;

proc sql;
create table work.cand_origs as
select a.*
  from work.cu_origs a
inner join work.cu_eligible b on a.join_number = b.join_number;
quit;

/*-----------------------------------------------------------------------------
  STEP 3: OVERLAP SCORING AND PEER SELECTION
-----------------------------------------------------------------------------*/
  proc sql;
create table work.peer_tract_pres as
select join_number, tract_key,
count(*)         as peer_n_loans,
sum(loan_amount) as peer_vol_tract
from work.cand_origs
group by join_number, tract_key
having calculated peer_n_loans >= &MIN_PEER_VOL_TR.;
quit;

proc sql;
create table work.peer_scored as
select p.join_number,
count(distinct p.tract_key) as n_shared_tracts,
sum(e.esl_vol)              as esl_vol_covered,
sum(p.peer_vol_tract)       as peer_vol_in_shared,
sum(p.peer_n_loans)         as peer_n_in_shared,
e.peer_total_origs,
e.peer_total_vol,
sum(e.esl_vol) / &esl_total_vol.            as overlap_score
format=percent8.2,
sum(p.peer_n_loans) / e.peer_total_origs    as peer_concentration
format=percent8.2
from work.peer_tract_pres p
inner join work.esl_tract_dist e on p.tract_key = e.tract_key
inner join work.cu_eligible    eu on p.join_number = eu.join_number
inner join work.cu_eligible    e  on p.join_number = e.join_number
group by p.join_number, e.peer_total_origs, e.peer_total_vol
order by overlap_score desc;
quit;

data out.peers_selected;
set work.peer_scored;
where overlap_score >= &MIN_OVERLAP_SCORE.;
rank_overlap = _N_;
if rank_overlap <= &TOP_N_PEERS.;
run;

proc print data=out.peers_selected noobs label;
title "Selected Peer CUs (geographic overlap >= &MIN_OVERLAP_SCORE)";
var rank_overlap join_number overlap_score n_shared_tracts
peer_total_origs peer_total_vol peer_concentration;
format peer_total_vol dollar18. peer_total_origs comma10.;
run;
title;

proc sql noprint;
select join_number into :peer_list separated by ','
from out.peers_selected;
select count(*) into :n_peers trimmed from out.peers_selected;
quit;

%put NOTE: Selected &n_peers peer CUs: &peer_list;

/*-----------------------------------------------------------------------------
  STEP 4: ANALYTICAL LOAN-LEVEL DATASET
-----------------------------------------------------------------------------*/
  proc sql;
create table work.shared_tracts as
select distinct e.tract_key
from work.esl_tract_dist e
inner join (
  select distinct tract_key from work.cu_origs
  where join_number in (&peer_list.)
) p on e.tract_key = p.tract_key;
quit;

proc sql;
create table work.analy_loans as
select a.*,
case when a.join_number = &ESL_ID. then "ESL"
else "PEER" end as role length=4
from (
  select * from work.esl_origs
  union all corr
  select * from work.cu_origs where join_number in (&peer_list.)
) a
inner join work.shared_tracts s on a.tract_key = s.tract_key;
quit;

/*-----------------------------------------------------------------------------
  STEP 5: TRACT-LEVEL MEANS AND DIFFERENTIALS (POOLED EQUAL-WEIGHTED)
-----------------------------------------------------------------------------*/
  proc sql;
/* ESL means per tract */
  create table work.esl_tract_means as
select tract_key, count(*) as esl_n,
mean(Interest_Rate_Min_PMMS_1) as esl_rate,
mean(Discount_Points_LA)       as esl_disc,
mean(Lender_Credits_LA)        as esl_cred,
mean(Loan_Cost_Prc_LA)         as esl_cost
from work.analy_loans where role = "ESL"
group by tract_key;

/* Per-peer-per-tract means */
  create table work.peer_tract_means as
select tract_key, join_number, count(*) as peer_n,
mean(Interest_Rate_Min_PMMS_1) as peer_rate,
mean(Discount_Points_LA)       as peer_disc,
mean(Lender_Credits_LA)        as peer_cred,
mean(Loan_Cost_Prc_LA)         as peer_cost
from work.analy_loans where role = "PEER"
group by tract_key, join_number;

/* Equal-weighted pool across peers within tract */
  create table work.pool_tract_means as
select tract_key,
count(distinct join_number) as n_peers_in_tract,
sum(peer_n)                 as pool_n_loans,
mean(peer_rate)             as pool_rate,
mean(peer_disc)             as pool_disc,
mean(peer_cred)             as pool_cred,
mean(peer_cost)             as pool_cost
from work.peer_tract_means
group by tract_key;

/* Tract-level differentials */
  create table out.tract_cells as
select e.tract_key, e.esl_n,
p.n_peers_in_tract, p.pool_n_loans,
e.esl_rate - p.pool_rate as diff_rate,
e.esl_disc - p.pool_disc as diff_disc,
e.esl_cred - p.pool_cred as diff_cred,
e.esl_cost - p.pool_cost as diff_cost
from work.esl_tract_means e
inner join work.pool_tract_means p on e.tract_key = p.tract_key;
quit;

/*-----------------------------------------------------------------------------
  STEP 6: BOOTSTRAP MACRO (REUSABLE FOR ALL + EACH RACE)
-----------------------------------------------------------------------------*/
  %macro bootstrap_diffs(in_ds=, out_ds=, label=);

proc sql noprint;
select count(*) into :n_in trimmed from &in_ds.;
quit;

%if &n_in = 0 %then %do;
data &out_ds.;
length stratum $30 outcome $40;
stratum = "&label."; outcome = "INSUFFICIENT DATA";
estimate=.; ci_lo=.; ci_hi=.; sig_95=0; n_tracts=0;
output;
run;
%return;
%end;

proc surveyselect data=&in_ds.
out=work._boot_samp
method=urs samprate=1 outhits
reps=&N_BOOT. seed=&SEED. noprint;
run;

proc sql;
create table work._boot_diffs as
select replicate,
mean(diff_rate) as boot_diff_rate,
mean(diff_disc) as boot_diff_disc,
mean(diff_cred) as boot_diff_cred,
mean(diff_cost) as boot_diff_cost
from work._boot_samp group by replicate;
quit;

proc univariate data=work._boot_diffs noprint;
var boot_diff_rate boot_diff_disc boot_diff_cred boot_diff_cost;
output out=work._boot_ci
pctlpts=2.5 97.5
pctlpre=rate_ disc_ cred_ cost_
pctlname=lo hi;
run;

proc sql;
create table work._point as
select count(*)        as n_tracts,
mean(diff_rate) as point_diff_rate,
mean(diff_disc) as point_diff_disc,
mean(diff_cred) as point_diff_cred,
mean(diff_cost) as point_diff_cost
from &in_ds.;
quit;

data &out_ds.;
if _N_=1 then set work._point;
set work._boot_ci;
length stratum $30 outcome $40;
stratum = "&label.";
array pt {4} point_diff_rate point_diff_disc point_diff_cred point_diff_cost;
array lo {4} rate_lo disc_lo cred_lo cost_lo;
array hi {4} rate_hi disc_hi cred_hi cost_hi;
array nm {4} $40 _temporary_
("Rate spread above PMMS"
  "Discount points (% of loan)"
  "Lender credits (% of loan)"
  "Total loan costs (% of loan)");
do i = 1 to 4;
outcome  = nm{i};
estimate = pt{i};
ci_lo    = lo{i};
ci_hi    = hi{i};
sig_95   = (ci_lo > 0) or (ci_hi < 0);
output;
end;
keep stratum outcome estimate ci_lo ci_hi sig_95 n_tracts;
run;

%mend;

/* All-borrower pooled diffs */
  %bootstrap_diffs(in_ds=out.tract_cells, out_ds=out.pooled_diffs,
                   label=All borrowers);

/*-----------------------------------------------------------------------------
  STEP 7: RACE-STRATIFIED DIFFERENTIALS
ADJUST race values if your dataset uses different coding.
-----------------------------------------------------------------------------*/
  %macro race_diff(label=, race_value=);
proc sql;
create table work.esl_means_&label as
select tract_key, count(*) as esl_n_race,
mean(Interest_Rate_Min_PMMS_1) as esl_rate,
mean(Discount_Points_LA)       as esl_disc,
mean(Lender_Credits_LA)        as esl_cred,
mean(Loan_Cost_Prc_LA)         as esl_cost
from work.analy_loans
where role = "ESL" and race = "&race_value"
group by tract_key
having calculated esl_n_race >= 1;

create table work.cells_&label as
select e.tract_key, e.esl_n_race,
e.esl_rate - p.pool_rate as diff_rate,
e.esl_disc - p.pool_disc as diff_disc,
e.esl_cred - p.pool_cred as diff_cred,
e.esl_cost - p.pool_cost as diff_cost
from work.esl_means_&label e
inner join work.pool_tract_means p on e.tract_key = p.tract_key;
quit;

%bootstrap_diffs(in_ds=work.cells_&label.,
                 out_ds=work.race_summary_&label.,
                 label=&label.);
%mend;

%race_diff(label=White,    race_value=WHITE);
%race_diff(label=Black,    race_value=BLACK);
%race_diff(label=Hispanic, race_value=HISP);

data out.race_stratified_diffs;
set work.race_summary_White
work.race_summary_Black
work.race_summary_Hispanic;
run;

/*-----------------------------------------------------------------------------
  STEP 8: MEMO-READY TABLE (BASIS POINTS + $ EQUIVALENTS)
-----------------------------------------------------------------------------*/
  proc sql noprint;
select mean(loan_amount) into :avg_loan_esl trimmed
from work.analy_loans where role = "ESL";
quit;

data out.memo_table;
set out.pooled_diffs out.race_stratified_diffs;
if outcome = "Rate spread above PMMS" then do;
bp_estimate = estimate * 100;
bp_ci_lo    = ci_lo * 100;
bp_ci_hi    = ci_hi * 100;
dollar_equiv = bp_estimate * &avg_loan_esl / 10000;
dollar_label = "Annual interest $ on avg loan";
end;
else do;
bp_estimate = estimate * 10000;
bp_ci_lo    = ci_lo * 10000;
bp_ci_hi    = ci_hi * 10000;
dollar_equiv = estimate * &avg_loan_esl;
dollar_label = "$ on avg loan (one-time)";
end;
keep stratum outcome bp_estimate bp_ci_lo bp_ci_hi sig_95
dollar_equiv dollar_label n_tracts;
run;

proc print data=out.memo_table noobs label;
title "MEMO-READY: Pricing differentials in basis points and $ equivalents";
title2 "Average ESL loan in shared tracts: $%sysfunc(putn(&avg_loan_esl, dollar12.0))";
title3 "Positive = ESL prices HIGHER than peer pool";
label stratum="Stratum" outcome="Outcome"
bp_estimate="Est (bp)" bp_ci_lo="CI lo" bp_ci_hi="CI hi"
sig_95="Sig" dollar_equiv="$ equiv" dollar_label="Interpretation"
n_tracts="N tracts";
format bp_estimate bp_ci_lo bp_ci_hi 10.1 dollar_equiv dollar12.2;
by stratum notsorted;
run;
title;

/*-----------------------------------------------------------------------------
  STEP 9: PER-PEER DIAGNOSTIC (where pooled diff comes from)
-----------------------------------------------------------------------------*/
  proc sql;
create table out.peer_diagnostics as
select pt.join_number,
count(distinct pt.tract_key)     as n_shared_w_esl,
sum(pt.peer_n)                   as total_peer_loans,
mean(em.esl_rate - pt.peer_rate) as avg_diff_rate,
mean(em.esl_cost - pt.peer_cost) as avg_diff_cost
from work.peer_tract_means pt
inner join work.esl_tract_means em on pt.tract_key = em.tract_key
group by pt.join_number;
quit;

proc print data=out.peer_diagnostics noobs label;
title "Per-peer breakdown of pooled differential";
format avg_diff_rate avg_diff_cost 10.6;
run;
title;

/*=============================================================================
  END
Final outputs in OUT library:
  peers_selected, tract_cells, pooled_diffs, race_stratified_diffs,
memo_table, peer_diagnostics
=============================================================================*/
  