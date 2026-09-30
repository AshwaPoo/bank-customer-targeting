-- 04_target_list.sql
-- The deliverable: a ranked call list where every row carries a reason.
--
-- A list without reasons is useless to whoever has to make the call. The
-- reason code determines the script, and it also makes the list auditable:
-- anyone can ask why a customer is on it and get an answer from the data.

--------------------------------------------------------------------------------
-- Who is eligible to be contacted at all
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW contactable AS
SELECT *
FROM customer_segments
WHERE tenure_months >= 6        -- still in onboarding, leave them alone
  AND deposit_balance >= 500;   -- below this the call costs more than it returns

--------------------------------------------------------------------------------
-- Every reason a customer might qualify. One customer can match several.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW candidate_reasons AS

-- Money sitting in checking with nowhere to go
SELECT customer_id, 'IDLE_CASH' AS reason, 0.55 AS urgency,
       'High checking balance, no savings product' AS rationale
FROM contactable
WHERE checking_balance >= 15000
  AND NOT has_savings
  AND days_since_last_txn < 60

UNION ALL

-- Still here, but using us less every month
SELECT customer_id, 'ATTRITION_RISK', 1.00,
       'Activity down vs prior quarter on an active relationship'
FROM contactable
WHERE segment = 'Cooling'
  AND deposit_balance >= 5000

UNION ALL

-- Gone quiet, money still on deposit
SELECT customer_id, 'REACTIVATE', 0.70,
       'No transactions in 90+ days with balance still held'
FROM contactable
WHERE segment = 'Dormant'

UNION ALL

-- Growing relationship the bank has under-served
SELECT customer_id, 'CROSS_SELL', 0.45,
       'Rising activity or inflows on a single-product relationship'
FROM contactable
WHERE segment = 'Growing'
  AND product_count = 1

UNION ALL

-- The salary stopped landing here. Someone else is now the primary bank.
SELECT customer_id, 'SALARY_LOST', 0.95,
       'Recurring salary credits stopped this quarter'
FROM contactable
WHERE salary_credits_prior >= 2
  AND salary_credits_recent = 0
  AND deposit_balance >= 1000;

--------------------------------------------------------------------------------
-- Rank, deduplicate, and score
--
-- score = 60% relationship value + 40% urgency of the reason.
-- Value is capped so that one very large depositor does not own the top of
-- the list, and a customer is kept only once, under their most urgent reason.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE target_list AS
WITH scored AS (
    SELECT
        s.customer_id,
        s.branch,
        s.segment,
        s.deposit_balance,
        s.product_count,
        s.days_since_last_txn,
        s.activity_ratio,
        r.reason,
        r.rationale,
        r.urgency,
        round(
            100 * (
                0.60 * least(s.deposit_balance, 75000) / 75000.0
              + 0.40 * r.urgency
            ), 1) AS priority_score,
        s.true_profile
    FROM contactable s
    JOIN candidate_reasons r USING (customer_id)
)
SELECT * EXCLUDE (urgency)
FROM scored
QUALIFY row_number() OVER (
    PARTITION BY customer_id
    ORDER BY urgency DESC, deposit_balance DESC
) = 1;

--------------------------------------------------------------------------------
-- Output 1: the call list
--------------------------------------------------------------------------------
SELECT
    customer_id,
    branch,
    segment,
    reason,
    priority_score,
    deposit_balance,
    days_since_last_txn,
    rationale
FROM target_list
ORDER BY priority_score DESC
LIMIT 20;

--------------------------------------------------------------------------------
-- Output 2: what the list is made of
--------------------------------------------------------------------------------
SELECT
    reason,
    count(*)                             AS customers,
    round(sum(deposit_balance) / 1e6, 2) AS deposits_at_stake_m,
    round(avg(priority_score), 1)        AS avg_score
FROM target_list
GROUP BY reason
ORDER BY deposits_at_stake_m DESC;

--------------------------------------------------------------------------------
-- Output 3: validation
--
-- The generator assigned each customer a hidden profile that none of the
-- queries above can see. This is the only place it is read. If the reason
-- codes are meaningful, they should line up with it.
--------------------------------------------------------------------------------
SELECT
    reason,
    count(*)                                                        AS customers,
    round(100.0 * count(*) FILTER (WHERE true_profile = 'attriting') / count(*), 1) AS pct_attriting,
    round(100.0 * count(*) FILTER (WHERE true_profile = 'dormant')   / count(*), 1) AS pct_dormant,
    round(100.0 * count(*) FILTER (WHERE true_profile = 'growing')   / count(*), 1) AS pct_growing,
    round(100.0 * count(*) FILTER (WHERE true_profile = 'stable')    / count(*), 1) AS pct_stable
FROM target_list
GROUP BY reason
ORDER BY customers DESC;
