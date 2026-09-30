-- 02_customer_features.sql
-- One row per customer. Everything the targeting logic is allowed to see.
--
-- Two windows are used throughout:
--   recent = the 90 days before as_of_date
--   prior  = the 90 days before that
-- Comparing the two is what turns a level into a direction.

CREATE OR REPLACE TABLE customer_features AS
WITH p AS (SELECT as_of_date FROM params),

holdings AS (
    SELECT
        customer_id,
        count(DISTINCT account_type)                                              AS product_count,
        max(account_type = 'savings')                                             AS has_savings,
        max(account_type = 'credit_card')                                         AS has_credit_card,
        max(account_type = 'loan')                                                AS has_loan,
        sum(CASE WHEN account_type = 'checking' THEN current_balance ELSE 0 END)  AS checking_balance,
        sum(CASE WHEN account_type = 'savings'  THEN current_balance ELSE 0 END)  AS savings_balance,
        sum(CASE WHEN current_balance > 0 THEN current_balance ELSE 0 END)        AS deposit_balance
    FROM accounts
    WHERE status = 'open'
    GROUP BY customer_id
),

activity AS (
    SELECT
        t.customer_id,
        max(t.txn_date)                                                            AS last_txn_date,

        count(*) FILTER (WHERE t.txn_date >  p.as_of_date - 90)                    AS txn_recent,
        count(*) FILTER (WHERE t.txn_date <= p.as_of_date - 90
                           AND t.txn_date >  p.as_of_date - 180)                   AS txn_prior,

        coalesce(sum(t.amount) FILTER (WHERE t.amount > 0
                           AND t.txn_date >  p.as_of_date - 90), 0)                AS inflow_recent,
        coalesce(sum(t.amount) FILTER (WHERE t.amount > 0
                           AND t.txn_date <= p.as_of_date - 90
                           AND t.txn_date >  p.as_of_date - 180), 0)               AS inflow_prior,

        coalesce(-sum(t.amount) FILTER (WHERE t.amount < 0
                           AND t.txn_date >  p.as_of_date - 90), 0)                AS outflow_recent,

        coalesce(sum(t.amount) FILTER (WHERE t.txn_date > p.as_of_date - 365), 0)  AS net_flow_12m,

        count(*) FILTER (WHERE t.channel IN ('mobile', 'online'))
            / nullif(count(*), 0)::DOUBLE                                          AS digital_share,

        count(*) FILTER (WHERE t.category = 'salary'
                           AND t.txn_date > p.as_of_date - 90)                     AS salary_credits_recent,

        count(*) FILTER (WHERE t.category = 'salary'
                           AND t.txn_date <= p.as_of_date - 90
                           AND t.txn_date >  p.as_of_date - 180)                   AS salary_credits_prior
    FROM transactions t
    CROSS JOIN p
    GROUP BY t.customer_id
)

SELECT
    c.customer_id,
    c.branch,
    c.joined_date,
    date_diff('month', c.joined_date, p.as_of_date)                                AS tenure_months,

    coalesce(h.product_count, 0)                                                   AS product_count,
    coalesce(h.has_savings, FALSE)                                                 AS has_savings,
    coalesce(h.has_credit_card, FALSE)                                             AS has_credit_card,
    coalesce(h.has_loan, FALSE)                                                    AS has_loan,
    coalesce(h.checking_balance, 0)                                                AS checking_balance,
    coalesce(h.savings_balance, 0)                                                 AS savings_balance,
    coalesce(h.deposit_balance, 0)                                                 AS deposit_balance,

    a.last_txn_date,
    coalesce(date_diff('day', a.last_txn_date, p.as_of_date), 9999)                AS days_since_last_txn,
    coalesce(a.txn_recent, 0)                                                      AS txn_recent,
    coalesce(a.txn_prior, 0)                                                       AS txn_prior,

    -- direction, not level: >1 accelerating, <1 cooling off
    round(coalesce(a.txn_recent, 0) / nullif(a.txn_prior, 0)::DOUBLE, 3)           AS activity_ratio,
    round(coalesce(a.inflow_recent, 0) / nullif(a.inflow_prior, 0)::DOUBLE, 3)     AS inflow_ratio,

    round(coalesce(a.inflow_recent, 0), 2)                                         AS inflow_recent,
    round(coalesce(a.inflow_prior, 0), 2)                                          AS inflow_prior,
    round(coalesce(a.outflow_recent, 0), 2)                                        AS outflow_recent,
    round(coalesce(a.net_flow_12m, 0), 2)                                          AS net_flow_12m,
    round(coalesce(a.digital_share, 0), 3)                                         AS digital_share,
    coalesce(a.salary_credits_recent, 0)                                           AS salary_credits_recent,
    coalesce(a.salary_credits_prior, 0)                                            AS salary_credits_prior,

    c.true_profile  -- held back for validation in 04, never used for targeting
FROM customers c
CROSS JOIN p
LEFT JOIN holdings h ON h.customer_id = c.customer_id
LEFT JOIN activity a ON a.customer_id = c.customer_id;

SELECT
    count(*)                              AS customers,
    round(avg(product_count), 2)          AS avg_products,
    round(avg(txn_recent), 1)             AS avg_txn_recent,
    round(avg(digital_share), 3)          AS avg_digital_share
FROM customer_features;
