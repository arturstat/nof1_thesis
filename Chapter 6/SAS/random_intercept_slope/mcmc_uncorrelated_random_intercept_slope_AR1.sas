/*
Written by Artur Araujo

artur.stat@gmail.com
aamarinhodearaujo1@sheffield.ac.uk

November 2019
*/

* Options for macro debugging ;
*options symbolgen mprint mlogic;
*option nosymbolgen nomprint nomlogic;

* Log current folder ;
%xlog(cd);

* Determine path to script ;
%let ScriptDir=%sysfunc(
	tranwrd(
		%sysget(SAS_EXECFILEPATH),
		%sysget(SAS_EXECFILENAME),
	)
);

* Set current folder ;
x cd "&ScriptDir";

* Log current folder ;
%xlog(cd);

* Include data ;
%include '..\data_normal.sas';

/* SAS program G.6 */

title "Uncorrelated random intercept and slope";
title2 "AR1 stochastic process";
title3 "Bayesian inference";

* define dataset names here ;
%let datain=WORK.gaba_placebo; * input dataset ;
%let datatemp=WORK.gaba_placebo_temp; * temporary dataset ;
%let datadummy=WORK.dummy; * dummy dataset ;
%let dataout=WORK.outURISAR1; * output dataset ;

* define variable names here ;
%let Subject=id; * subject variable ;
%let Treatment=Treatment; * treatment variable ;
%let Period=Period; * period variable ;
%let Outcome=Pain; * outcome variable ;
%let ref=Placebo; * reference treatment ;
%let seed=3141593; * random seed for simulation ;

* Determine and count unique treatments ;
proc sql noprint;
	select distinct &Treatment
			into :Treatment1 - :Treatment999999999
	from &datain
	where &Outcome is not null;
	%let TreatmentNumber = &SqlObs; * number of treatments ;
quit;

%macro findRef;
	%if &Treatment1 ne &ref %then %do;
		%local t f;
		%let t = 1;
		%do %until (&t eq &TreatmentNumber or &&Treatment&t eq &ref);
			%let t=%eval(&t+1);
		%end;
		%let f=&Treatment1;
		%let Treatment1=&ref;
		%let Treatment&t=&f;
	%end;
%mend findRef;

* Set first treatment to reference treatment ;
%findRef

%macro dataTemp;
	%local t;
	proc sql;
		create table &datatemp as
		select 	&Subject,
				case
				%do t = 1 %to &TreatmentNumber %by 1;
					when &Treatment eq "&&Treatment&t" then &t
				%end;
				end as &Treatment,
				&Period,
				&Outcome
		from &datain
		where &Outcome is not null
		order by &Subject, &Period;
	quit;
%mend dataTemp;

* Convert treatment variable to numeric,
and remove missing observations;
%dataTemp

* Determine and count unique subjects,
and number of observations ;
proc sql noprint;
	select	distinct &Subject
			into :Subject1 - :Subject999999999
	from &datatemp;
	%let SubjectNumber = &SqlObs; * number of subjects ;
	select count(&Outcome) into :size1 - :size999999999
	from &datatemp
	group by &Subject; * number of observations per subject ;
	select count(*) into :nobs /* total number of observations */
	from &datatemp;
quit;

* Create dummy dataset ;
data &datadummy;
run;

%macro mcmcArray;
	%local s;
	%do s = 1 %to &SubjectNumber %by 1;
		array Y_&&Subject&s..[&&size&s];
		array MU_&&Subject&s..[&&size&s];
		array COV_&&Subject&s..[&&size&s,&&size&s];
	%end;	
	array treat[&nobs] / nosymbols;
	array data[&nobs] / nosymbols;
	begincnst;
		rc = read_array("&datatemp", treat, "&Treatment");
		rc = read_array("&datatemp", data, "&Outcome");
	endcnst;
%mend mcmcArray;

%macro mcmcParms;
	%local s t;
	parms intercept
	%do t = 2 %to &TreatmentNumber %by 1;
		pte_&&Treatment&t
	%end;
	;
	parms var_&Subject
	%do t = 2 %to &TreatmentNumber %by 1;
		var_&&Treatment&t
	%end;
	;
	parms var_residual rho;
	parms
	%do s = 1 %to &SubjectNumber %by 1;
		bi_&&Subject&s
		%do t = 2 %to &TreatmentNumber %by 1;
			ite_&&Subject&s.._&&Treatment&t
		%end;
	%end;
	;
%mend mcmcParms;

%macro mcmcPrior;
	%local s t;
	beginnodata;
		prior intercept pte_: ~ normal(mean=0, var=1e7);
		prior var_: ~ igamma(0.01, scale=0.01);
		prior bi_: ~ normal(mean=intercept, var=var_&Subject);
		%do t = 2 %to &TreatmentNumber %by 1;
			prior
			%do s = 1 %to &SubjectNumber %by 1;
				ite_&&Subject&s.._&&Treatment&t
			%end;
			~ normal(mean=pte_&&Treatment&t, var=var_&&Treatment&t);
		%end;
		prior rho ~ uniform(left=-1, right=1);
	endnodata;
%mend mcmcPrior;

%macro mcmcLogLike;
	%local s t;
	index = 1;
	llike = 0;
	%do s = 1 %to &SubjectNumber %by 1;
		do i = 1 to &&size&s by 1;
			Y_&&Subject&s..[i] = data[index];
			MU_&&Subject&s..[i] = bi_&&Subject&s
			%do t = 2 %to &TreatmentNumber %by 1;
				+ ite_&&Subject&s.._&&Treatment&t*(treat[index] eq &t)
			%end;
			;
			COV_&&Subject&s..[i,i] = var_residual;
			do j = i+1 to &&size&s by 1;
				COV_&&Subject&s..[i,j] = var_residual*rho**abs(i-j);
				COV_&&Subject&s..[j,i] = COV_&&Subject&s..[i,j];
			end;
			index = index + 1;
		end;
		llike = llike + lpdfmvn(Y_&&Subject&s, MU_&&Subject&s, COV_&&Subject&s);
	%end;
	model general(llike);
%mend mcmcLogLike;

* Fit linear mixed-effects model ;
proc mcmc
		data=&datadummy
		outpost=&dataout
		nbi=2000 /* number of burn-in iterations */
		nmc=100000 /* number of mcmc iterations */
		ntu=2000 /* number of turning iterations */
		seed=&seed /* random seed for simulation */
		thin=1 /* thinning rate */
		jointmodel; /* specify joint log-likelihood */
	%mcmcArray
	
	%mcmcParms
	
	%mcmcPrior
	
	%mcmcLogLike
run;

* Delete datasets from system ;
proc sql;
	drop table &datatemp, &datadummy, &dataout;
quit;

%symdel datain datatemp datadummy dataout;
%symdel Subject Treatment Period Outcome ref seed nobs;

%macro deleteVariables;
	%local i;
	%do i = 1 %to &SubjectNumber %by 1;
		%symdel Subject&i size&i;
	%end;
	%do i = 1 %to &TreatmentNumber %by 1;
		%symdel Treatment&i;
	%end;
	%symdel SubjectNumber TreatmentNumber;
%mend deleteVariables;

* Delete macro variables from system ;
%deleteVariables

* Delete macros from WORK.Sasmacr ;
proc catalog cat=WORK.Sasmacr;
	delete findRef dataTemp mcmcArray
		mcmcParms mcmcPrior mcmcLogLike
		deleteVariables / et=macro;
quit;

title; * clear all titles ;