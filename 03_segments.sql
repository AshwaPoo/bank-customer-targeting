-- 03_segments.sql
-- Assigns every customer to exactly one behavioral segment.
--
-- The rules are ordered, and the order is the design. A customer who has gone
-- quiet for four months is dormant even if their balance is large, because
-- recency dominates: you cannot cross-sell someone who is not there.
--
-- Thresholds are stated once here rather than repeated downstream.

CREATE OR REPLACE TABLE segment_thresholds AS
SELECT
    6      AS new_customer_months,
    90     AS dormant_days,
    0.75   AS cooling_activity_ratio,
    5      AS min_prior_txns_for_trend,
    1.15   AS growing_activity_ratio,
    1.25   AS growing_inflow_ratio;

CREATE OR REPLACE TABLE customer_segments AS
SELECT
    f.*,
    CASE
        WHEN f.tenure_months < t.new_customer_months
            THEN 'New'

        WHEN f.days_since_last_txn >= t.dormant_days
            THEN 'Dormant'

        WHEN f.activity_ratio < t.cooling_activity_ratio
             AND f.txn_prior >= t.min_prior_txns_for_trend
            THEN 'Cooling'

        WHEN f.activity_ratio >= t.growing_activity_ratio
             OR f.inflow_ratio >= t.growing_inflow_ratio
            THEN 'Growing'

        ELSE 'Stable'
    END AS segment
FROM customer_features f
CROSS JOIN segment_thresholds t;

-- Segment sizes and what each one is worth
SELECT
    segment,
    count(*)                                   AS customers,
    round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
    round(avg(deposit_balance), 0)             AS avg_deposits,
    round(sum(deposit_balance) / 1e6, 2)       AS total_deposits_m,
    round(avg(product_count), 2)               AS avg_products,
    round(avg(days_since_last_txn), 0)         AS avg_days_since_txn
FROM customer_segments
GROUP BY segment
ORDER BY total_deposits_m DESC;
