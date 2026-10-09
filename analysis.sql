-- Customer Profitability & Payment Risk Analysis (SQL Server)
-- Data is simulated. Reporting date: 30 Sep 2026.

USE CustomerFinance;
GO

-- 1. Find duplicate invoices
SELECT invoice_id, COUNT(*) AS times_repeated
FROM invoices
GROUP BY invoice_id
HAVING COUNT(*) > 1;
GO

-- 2. Remove duplicates into a clean copy
SELECT *
INTO invoices_clean
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY invoice_date) AS rn
    FROM invoices
) AS t
WHERE rn = 1;
GO
ALTER TABLE invoices_clean DROP COLUMN rn;
GO

-- 3. Clean customers: standardise segment, fill blank cities
SELECT
    customer_id,
    customer_name,
    CASE LOWER(LTRIM(RTRIM(segment)))
        WHEN 'corporate' THEN 'Corporate'
        WHEN 'retail'    THEN 'Retail'
        WHEN 'sme'       THEN 'SME'
        ELSE 'Unknown'
    END AS segment,
    CASE WHEN city IS NULL OR LTRIM(RTRIM(city)) = ''
         THEN 'Unknown' ELSE LTRIM(RTRIM(city)) END AS city,
    signup_date,
    credit_terms_days
INTO customers_clean
FROM customers;
GO

-- 4. One row per invoice: profit, paid amount, last payment date
SELECT
    i.invoice_id, i.customer_id, i.invoice_date, i.due_date,
    i.gross_amount, i.discount_amount,
    i.gross_amount - i.discount_amount AS invoice_net,
    ISNULL(r.return_amount, 0) AS return_amount,
    i.cogs, i.delivery_cost,
    i.gross_amount - i.discount_amount - ISNULL(r.return_amount, 0)
        - i.cogs - i.delivery_cost AS profit,
    ISNULL(p.amount_paid, 0) AS amount_paid,
    p.last_payment_date
INTO invoice_summary
FROM invoices_clean i
LEFT JOIN (
    SELECT invoice_id, SUM(amount_paid) AS amount_paid, MAX(payment_date) AS last_payment_date
    FROM payments GROUP BY invoice_id
) p ON p.invoice_id = i.invoice_id
LEFT JOIN (
    SELECT invoice_id, SUM(return_amount) AS return_amount
    FROM returns GROUP BY invoice_id
) r ON r.invoice_id = i.invoice_id;
GO

-- 5. One row per customer
SELECT
    c.customer_id, c.customer_name, c.segment, c.city, c.credit_terms_days,
    COUNT(*) AS invoices,
    SUM(s.gross_amount) AS gross_revenue,
    SUM(s.discount_amount) AS total_discount,
    SUM(s.invoice_net) AS net_revenue,
    SUM(s.return_amount) AS total_returns,
    SUM(s.profit) AS total_profit,
    ROUND(SUM(s.profit) * 100.0 / NULLIF(SUM(s.invoice_net), 0), 1) AS profit_margin_pct,
    SUM(s.invoice_net - s.amount_paid) AS outstanding,
    SUM(CASE WHEN s.due_date < '2026-09-30'
             THEN s.invoice_net - s.amount_paid ELSE 0 END) AS overdue_amount,
    AVG(CASE WHEN s.last_payment_date IS NOT NULL
             THEN 1.0 * DATEDIFF(day, s.due_date, s.last_payment_date) END) AS avg_days_late
INTO customer_summary
FROM invoice_summary s
JOIN customers_clean c ON c.customer_id = s.customer_id
GROUP BY c.customer_id, c.customer_name, c.segment, c.city, c.credit_terms_days;
GO

-- 6. Top customers by revenue: how much profit did they really make?
SELECT TOP 10
    customer_name, segment, net_revenue, total_discount, total_profit,
    profit_margin_pct, overdue_amount, ROUND(avg_days_late, 0) AS avg_days_late
FROM customer_summary
ORDER BY net_revenue DESC;
GO

-- 7. Receivables aging as of 30 Sep 2026
SELECT
    bucket,
    COUNT(*) AS unpaid_invoices,
    ROUND(SUM(outstanding), 0) AS amount_owed
FROM (
    SELECT
        invoice_net - amount_paid AS outstanding,
        CASE
            WHEN DATEDIFF(day, due_date, '2026-09-30') <= 0  THEN '0 Not yet due'
            WHEN DATEDIFF(day, due_date, '2026-09-30') <= 30 THEN '1 Overdue 1-30 days'
            WHEN DATEDIFF(day, due_date, '2026-09-30') <= 60 THEN '2 Overdue 31-60 days'
            WHEN DATEDIFF(day, due_date, '2026-09-30') <= 90 THEN '3 Overdue 61-90 days'
            ELSE '4 Overdue 90+ days'
        END AS bucket
    FROM invoice_summary
    WHERE invoice_net - amount_paid > 0
) x
GROUP BY bucket
ORDER BY bucket;
GO
