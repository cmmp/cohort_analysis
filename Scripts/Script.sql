/* ********************
 * 
 * Setup 
 * 
 * ********************
*/
select count(*) from legislators l ;

select count(*) from legislators_terms;

select id_bioguide, min(term_start) as first_term from legislators_terms group by 1;

create view date_dim as select generate_series::date as date from generate_series('1770-12-31', '2020-12-31', interval '1 year');	

select * from date_dim;

select dia from (select date_part('day', date) as dia from date_dim) a where dia != 31; 

/* ********************
 * 
 * Retention Curve
 * 
 * ********************
*/

select date_part('year', age(b.term_start, a.first_term)) as period,
	count(distinct a.id_bioguide) as cohort_retained
	from
	(
		select id_bioguide, min(term_start) as first_term
		from legislators_terms
		group by 1
	) a
	join legislators_terms b on a.id_bioguide = b.id_bioguide
	group by 1;
	
select period,
	first_value(cohort_retained) over (order by period) as cohort_size,
	cohort_retained,
	cast(cohort_retained as float) / first_value(cohort_retained) over (order by period) as pct_retained
	from
	(
		select date_part('year', age(b.term_start, a.first_term)) as period,
			count(distinct a.id_bioguide) as cohort_retained
			from
			(
				select id_bioguide, min(term_start) as first_term
					from legislators_terms group by 1
			) a
			join legislators_terms b on a.id_bioguide = b.id_bioguide
				group by 1
	) aa;


select a.id_bioguide, a.first_term,
	b.term_start, b.term_end,
	c.date,	
	date_part('year', age(c.date, a.first_term)) as period
	from
	( -- finding the first time a legislator started their term
		select id_bioguide, min(term_start) as first_term
		from legislators_terms
		group by 1
	) a
	join legislators_terms b on a.id_bioguide = b.id_bioguide
	left join date_dim c on c.date between b.term_start and b.term_end;
	
-- calculate cohort retained for each period:

select coalesce(date_part('year', age(c.date, a.first_term)), 0) as period,
	count(distinct a.id_bioguide) as cohort_retained from
	(
		select id_bioguide, min(term_start) as first_term from legislators_terms group by 1
	) a
	join legislators_terms b on a.id_bioguide = b.id_bioguide 
	left join date_dim c on c.date between b.term_start and b.term_end group by 1;

-- next step is to calculate cohort_size and pct_retained using the first_value window function:

select period,
	first_value(cohort_retained) over (order by period) as cohort_size,
	cohort_retained,
	cohort_retained * 1.0 / first_value(cohort_retained) over (order by period) as pct_retained
	from
	(
		select coalesce (date_part('year', age(c.date, a.first_term)), 0) as period,
		count(distinct a.id_bioguide) as cohort_retained
		from
		(
			select id_bioguide, min(term_start) as first_term from legislators_terms group by 1
		) a
		join legislators_terms b on a.id_bioguide = b.id_bioguide
		left join date_dim c on c.date between b.term_start and b.term_end
		group by 1
	) aa;

/* ********************
 * 
 * Cohorts
 * 
 * ********************
*/

-- first add the year of the first_term to the query that finds the period and cohort_retained:

select date_part('year', a.first_term) as first_year, 
	coalesce(date_part('year', age(c.date, a.first_term)),0) as period,
	count(distinct a.id_bioguide) as cohort_retained
	from
		(
			select id_bioguide, min(term_start) as first_term from legislators_terms group by 1
		) a
	join legislators_terms b on a.id_bioguide = b.id_bioguide
	left join date_dim c on c.date between b.term_start and b.term_end 
	group by 1, 2;

-- Now we calculate the cohorts, partitioned by first_year

select first_year, period,
	first_value(cohort_retained) over (partition by first_year order by period) as cohort_size,
	cohort_retained,
	cohort_retained * 1.0 /	first_value(cohort_retained) over (partition by first_year order by period) as pct_retained
	from
	(
		select date_part('year', a.first_term) as first_year, 	
		coalesce(date_part('year', age(c.date, a.first_term)),0) as period,
		count(distinct a.id_bioguide) as cohort_retained
		from
		(
			select id_bioguide, min(term_start) as first_term from legislators_terms group by 1
		) a
		join legislators_terms b on a.id_bioguide = b.id_bioguide
		left join date_dim c on c.date between b.term_start and b.term_end 
		group by 1, 2
	) aa;

-- cohorts by the first state legislators represented:

-- extract the first state the legislator served under, along with the first_term date:
select distinct id_bioguide,
	min(term_start) over (partition by id_bioguide) as first_term,
	first_value(state) over (partition by id_bioguide order by term_start) as first_state
	from legislators_terms;

-- plug it in and create the cohorts by state:

select first_state, period,
	first_value(cohort_retained) over (partition by first_state order by period) as cohort_size,
	cohort_retained,
	cohort_retained * 1.0 /	first_value(cohort_retained) over (partition by first_state order by period) as pct_retained
	from
	(
		select a.first_state,		 	
		coalesce(date_part('year', age(c.date, a.first_term)),0) as period,
		count(distinct a.id_bioguide) as cohort_retained
		from
		(
			select distinct id_bioguide,
				min(term_start) over (partition by id_bioguide) as first_term,
				first_value(state) over (partition by id_bioguide order by term_start) as first_state
				from legislators_terms
		) a
		join legislators_terms b on a.id_bioguide = b.id_bioguide
		left join date_dim c on c.date between b.term_start and b.term_end 
		group by 1, 2
	) aa;


/* ********************
 * 
 * Survival Analysis
 * 
 * ********************
*/

-- We'll look at the share of legislators who survived in office for a decade
-- or more after their first term started. Since we don't need specific dates
-- of each term, we just calculate the first and last term start dates:

select id_bioguide,
	min(term_start) as first_term,
	max(term_start) as last_term
	from legislators_terms group by 1;

-- next we find the century of the min term_start and calculate the tenure
-- as the number of years between the min and max term_starts found with the
-- age function:

select id_bioguide,
	date_part('century', min(term_start)) as first_century,
	min(term_start) as first_term,
	max(term_start) as last_term,
	date_part('year', age(max(term_start), min(term_start))) as tenure 
	from legislators_terms group by 1;

-- finally, we calculate the cohort_size with a count of all legislators,
-- including the number who survived for at least 10 years. The percent
-- who survived is found by dividing these two values:
select first_century,
	count(distinct id_bioguide) as cohort_size,
	count(distinct case when tenure >= 10 then id_bioguide end) as survived_10,
	count(distinct case when tenure >= 10 then id_bioguide end) * 1.0 / 
		count(distinct id_bioguide) as pct_survived_10
	from 
	(
		select id_bioguide,
			date_part('century', min(term_start)) as first_century,
			min(term_start) as first_term,
			max(term_start) as last_term,
			date_part('year', age(max(term_start), min(term_start))) as tenure 
			from legislators_terms group by 1
	) a group by 1;









