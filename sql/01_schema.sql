-- 01_schema.sql
-- Builds a synthetic retail banking dataset: customers, accounts, transactions.
--
-- Every customer is assigned a hidden behavior profile by the generator.
-- Nothing downstream is allowed to read that column. It exists only so the
-- targeting logic can be checked against a known answer at the end.
--
-- Run: duckdb bank.duckdb < sql/01_schema.sql

SELECT setseed(0.42);

-- As-of date for the whole project. Every window is measured back from here.
CREATE OR REPLACE TABLE params AS SELECT DATE '2026-09-30' AS as_of_date;

--------------------------------------------------------------------------------
-- customers
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customers AS
SELECT
    100000 + i AS customer_id,
    DATE '2015-01-01' + to_days(CAST(random() * 3800 AS INT)) AS joined_date,
    1955 + CAST(random() * 50 AS INT) AS birth_year,
    ['Downtown', 'Riverside', 'North Park', 'Airport', 'Online only'][1 + CAST(random() * 5 AS INT)] AS branch,
    -- hidden ground truth, never referenced by the targeting queries
    CASE
        WHEN random() < 0.10 THEN 'dormant'
        WHEN random() < 0.28 THEN 'attriting'
        WHEN random() < 0.45 THEN 'growing'
        ELSE 'stable'
    END AS true_profile
FROM range(1, 2001) t(i);

--------------------------------------------------------------------------------
-- accounts
-- Everyone holds a checking account. Other products are held by a subset.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE accounts AS
WITH raw AS (
    SELECT
        customer_id,
        'checking' AS account_type,
        joined_date AS opened_date,
        round(
            CASE true_profile
                WHEN 'growing'   THEN 3000 + random() * 38000
                WHEN 'attriting' THEN  200 + random() *  4000
                WHEN 'dormant'   THEN  100 + random() *  9000
                ELSE                  800 + random() * 22000
            END, 2) AS current_balance
    FROM customers

    UNION ALL
    SELECT
        customer_id,
        'savings',
        joined_date + to_days(CAST(random() * 500 AS INT)),
        round(1000 + random() * 70000, 2)
    FROM customers
    WHERE random() < 0.38

    UNION ALL
    SELECT
        customer_id,
        'credit_card',
        joined_date + to_days(CAST(random() * 900 AS INT)),
        round(-1 * random() * 6000, 2)
    FROM customers
    WHERE random() < 0.31

    UNION ALL
    SELECT
        customer_id,
        'loan',
        joined_date + to_days(CAST(random() * 1200 AS INT)),
        round(-1 * (5000 + random() * 90000), 2)
    FROM customers
    WHERE random() < 0.14
)
SELECT
    row_number() OVER (ORDER BY customer_id, account_type) AS account_id,
    customer_id,
    account_type,
    opened_date,
    current_balance,
    'open' AS status
FROM raw;

--------------------------------------------------------------------------------
-- transactions
-- 18 months of checking activity. Volume and recency vary by hidden profile:
--   dormant   nothing in the last ~4 months
--   attriting activity thins out as the window approaches today
--   growing   activity and inflows build over the window
--   stable    flat
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE transactions AS
WITH gen AS (
    SELECT
        a.account_id,
        c.customer_id,
        c.true_profile,
        d.day_offset,
        (SELECT as_of_date FROM params) - to_days(CAST(d.day_offset AS INT)) AS txn_date,
        random() AS r_keep,
        random() AS r_kind,
        random() AS r_amt,
        random() AS r_chan
    FROM customers c
    JOIN accounts a
      ON a.customer_id = c.customer_id
     AND a.account_type = 'checking'
    CROSS JOIN range(0, 540) d(day_offset)
),
kept AS (
    SELECT *
    FROM gen
    WHERE r_keep <
        CASE
            WHEN true_profile = 'dormant'   AND day_offset < 130 THEN 0.002
            WHEN true_profile = 'dormant'                        THEN 0.22
            WHEN true_profile = 'attriting'                      THEN 0.32 * (0.25 + day_offset / 540.0)
            WHEN true_profile = 'growing'                        THEN 0.18 * (1.45 - day_offset / 540.0)
            ELSE 0.26
        END
)
SELECT
    row_number() OVER (ORDER BY txn_date, account_id) AS txn_id,
    account_id,
    customer_id,
    txn_date,
    CASE
        WHEN r_kind < 0.18 THEN 'salary'
        WHEN r_kind < 0.28 THEN 'transfer_in'
        WHEN r_kind < 0.62 THEN 'card_purchase'
        WHEN r_kind < 0.80 THEN 'bill_pay'
        WHEN r_kind < 0.95 THEN 'atm_withdrawal'
        ELSE 'fee'
    END AS category,
    -- inflows positive, outflows negative
    round(
        CASE
            WHEN r_kind < 0.18 THEN  1800 + r_amt * 4200
            WHEN r_kind < 0.28 THEN   100 + r_amt * 2500
            WHEN r_kind < 0.62 THEN -(10 + r_amt *  380)
            WHEN r_kind < 0.80 THEN -(40 + r_amt *  600)
            WHEN r_kind < 0.95 THEN -(20 + r_amt *  300)
            ELSE -(3 + r_amt * 32)
        END, 2) AS amount,
    CASE
        WHEN r_chan < 0.46 THEN 'mobile'
        WHEN r_chan < 0.68 THEN 'online'
        WHEN r_chan < 0.84 THEN 'card'
        WHEN r_chan < 0.94 THEN 'atm'
        ELSE 'branch'
    END AS channel
FROM kept;

--------------------------------------------------------------------------------
-- sanity checks
--------------------------------------------------------------------------------
SELECT 'customers' AS tbl, count(*) AS rows FROM customers
UNION ALL SELECT 'accounts', count(*) FROM accounts
UNION ALL SELECT 'transactions', count(*) FROM transactions;
