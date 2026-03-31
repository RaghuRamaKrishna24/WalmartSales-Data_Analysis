-- Walmart Sales Data Analysis - Database Schema & Setup
-- Modified for PostgreSQL (Detected from app.py)

-- -----------------------------------------------------------------------------
-- 1. Tables Creation
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS Stores (
    store_id INT PRIMARY KEY,
    store_type VARCHAR(50),
    location VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS Departments (
    dept_id INT PRIMARY KEY,
    dept_name VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS Sales (
    sale_id SERIAL PRIMARY KEY,
    store_id INT REFERENCES Stores(store_id),
    dept_id INT REFERENCES Departments(dept_id),
    sale_date DATE,
    weekly_sales FLOAT,
    holiday_flag BOOLEAN
);

-- Auxiliary table for logging high sales (Trigger #1)
CREATE TABLE IF NOT EXISTS High_Sales_Log (
    log_id SERIAL PRIMARY KEY,
    sale_id INT,
    weekly_sales FLOAT,
    log_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- 2. Sample Data Insertion
-- -----------------------------------------------------------------------------

INSERT INTO Stores (store_id, store_type, location) VALUES
(1, 'A', 'Dallas'),
(2, 'B', 'Austin')
ON CONFLICT (store_id) DO NOTHING;

INSERT INTO Departments (dept_id, dept_name) VALUES
(101, 'Grocery'),
(102, 'Electronics')
ON CONFLICT (dept_id) DO NOTHING;

INSERT INTO Sales (sale_id, store_id, dept_id, sale_date, weekly_sales, holiday_flag) VALUES
(1, 1, 101, '2023-08-01', 12500.50, FALSE),
(2, 1, 102, '2023-08-08', 10000.75, TRUE),
(3, 2, 101, '2023-08-01', 11300.00, FALSE)
ON CONFLICT (sale_id) DO NOTHING;

-- Reset sequence for Sales since we hardcoded IDs
SELECT setval('sales_sale_id_seq', (SELECT MAX(sale_id) FROM Sales));

-- -----------------------------------------------------------------------------
-- 3. Triggers & Trigger Functions
-- -----------------------------------------------------------------------------

-- Trigger 1: Log high-sales events
CREATE OR REPLACE FUNCTION log_high_sales_func()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weekly_sales > 15000 THEN
        INSERT INTO High_Sales_Log (sale_id, weekly_sales) 
        VALUES (NEW.sale_id, NEW.weekly_sales);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_log_high_sales ON Sales;
CREATE TRIGGER trg_log_high_sales
AFTER INSERT ON Sales
FOR EACH ROW EXECUTE FUNCTION log_high_sales_func();


-- Trigger 2: Validate non-negative sales input
CREATE OR REPLACE FUNCTION prevent_negative_sales_func()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weekly_sales < 0 THEN
        RAISE EXCEPTION 'Error: Weekly sales cannot be negative';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_negative_sales ON Sales;
CREATE TRIGGER trg_prevent_negative_sales
BEFORE INSERT ON Sales
FOR EACH ROW EXECUTE FUNCTION prevent_negative_sales_func();


-- Trigger 3: Flag holiday sales
CREATE OR REPLACE FUNCTION flag_holiday_sales_func()
RETURNS TRIGGER AS $$
BEGIN
    -- Just a simple example: If month is Dec and week includes 25th, or month is July and week includes 4th
    IF (EXTRACT(MONTH FROM NEW.sale_date) = 12 AND EXTRACT(DAY FROM NEW.sale_date) BETWEEN 20 AND 31) OR 
       (EXTRACT(MONTH FROM NEW.sale_date) = 7 AND EXTRACT(DAY FROM NEW.sale_date) BETWEEN 1 AND 7) THEN
        NEW.holiday_flag := TRUE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_flag_holiday_sales ON Sales;
CREATE TRIGGER trg_flag_holiday_sales
BEFORE INSERT ON Sales
FOR EACH ROW EXECUTE FUNCTION flag_holiday_sales_func();

-- -----------------------------------------------------------------------------
-- 4. Stored Procedures / Functions
-- -----------------------------------------------------------------------------

-- Procedure 4: Calculate total sales by store and date range
CREATE OR REPLACE FUNCTION GetTotalSalesByStoreAndDate(p_store_id INT, p_start DATE, p_end DATE)
RETURNS TABLE (store_id INT, total_sales FLOAT) AS $$
BEGIN
    RETURN QUERY 
    SELECT s.store_id, CAST(SUM(s.weekly_sales) AS FLOAT) AS total_sales
    FROM Sales s
    WHERE s.store_id = p_store_id AND s.sale_date BETWEEN p_start AND p_end
    GROUP BY s.store_id;
END;
$$ LANGUAGE plpgsql;

-- Procedure 5: Insert new department sales data (Procedure because it just inserts and returns void)
CREATE OR REPLACE PROCEDURE InsertDeptSales(
    p_store_id INT, 
    p_dept_id INT, 
    p_sale_date DATE, 
    p_weekly_sales FLOAT, 
    p_holiday_flag BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO Sales (store_id, dept_id, sale_date, weekly_sales, holiday_flag)
    VALUES (p_store_id, p_dept_id, p_sale_date, p_weekly_sales, p_holiday_flag);
END;
$$;

-- Procedure 6: Predict sales for next week based on trends (Simple 4-week average)
CREATE OR REPLACE FUNCTION PredictSalesNextWeek(p_store_id INT, p_dept_id INT)
RETURNS TABLE (store_id INT, dept_id INT, predicted_next_week_sales FLOAT) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        recent_sales.store_id, 
        recent_sales.dept_id, 
        CAST(AVG(recent_sales.weekly_sales) AS FLOAT) AS predicted_next_week_sales
    FROM (
        SELECT s.store_id, s.dept_id, s.weekly_sales
        FROM Sales s
        WHERE s.store_id = p_store_id AND s.dept_id = p_dept_id
        ORDER BY s.sale_date DESC
        LIMIT 4
    ) AS recent_sales
    GROUP BY recent_sales.store_id, recent_sales.dept_id;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 5. Views
-- -----------------------------------------------------------------------------

-- View 7: Monthly sales per store
CREATE OR REPLACE VIEW View_MonthlySalesPerStore AS
SELECT 
    s.store_id,
    st.store_type,
    st.location,
    EXTRACT(YEAR FROM s.sale_date) AS sales_year,
    EXTRACT(MONTH FROM s.sale_date) AS sales_month,
    SUM(s.weekly_sales) AS total_monthly_sales
FROM Sales s
JOIN Stores st ON s.store_id = st.store_id
GROUP BY s.store_id, st.store_type, st.location, sales_year, sales_month;

-- View 8: Top performing departments (overall)
CREATE OR REPLACE VIEW View_TopPerformingDepartments AS
SELECT 
    d.dept_id,
    d.dept_name,
    SUM(s.weekly_sales) AS total_sales
FROM Sales s
JOIN Departments d ON s.dept_id = d.dept_id
GROUP BY d.dept_id, d.dept_name
ORDER BY total_sales DESC;

-- View 9: Holiday vs non-holiday sales comparison
CREATE OR REPLACE VIEW View_HolidayVsNonHolidaySales AS
SELECT 
    holiday_flag,
    COUNT(sale_id) AS total_weeks,
    SUM(weekly_sales) AS total_sales,
    AVG(weekly_sales) AS average_weekly_sales
FROM Sales
GROUP BY holiday_flag;

-- -----------------------------------------------------------------------------
-- 6. Nested Queries & Join-Based Queries
-- -----------------------------------------------------------------------------

-- 10. Nested Query: Departments with highest sales in last month
SELECT dept_id, dept_name 
FROM Departments 
WHERE dept_id IN (
    SELECT dept_id 
    FROM Sales 
    WHERE EXTRACT(MONTH FROM sale_date) = (SELECT MAX(EXTRACT(MONTH FROM sale_date)) FROM Sales)
      AND EXTRACT(YEAR FROM sale_date) = (SELECT MAX(EXTRACT(YEAR FROM sale_date)) FROM Sales)
    GROUP BY dept_id
    HAVING SUM(weekly_sales) > (
        SELECT AVG(total_sales) 
        FROM (SELECT SUM(weekly_sales) AS total_sales, dept_id FROM Sales GROUP BY dept_id) as dept_avgs
    )
);

-- 11. Nested Query: Stores with declining weekly sales trend 
SELECT DISTINCT store_id
FROM Stores
WHERE store_id IN (
    SELECT s1.store_id
    FROM Sales s1
    JOIN Sales s2 ON s1.store_id = s2.store_id 
                  AND s1.dept_id = s2.dept_id 
                  AND s1.sale_date = s2.sale_date + INTERVAL '7 days'
    WHERE s1.weekly_sales < s2.weekly_sales
);

-- 12. Nested Query: Sales contribution by each department per store
SELECT 
    s1.store_id,
    s1.dept_id,
    SUM(s1.weekly_sales) AS dept_sales,
    (SUM(s1.weekly_sales) / (SELECT SUM(s2.weekly_sales) FROM Sales s2 WHERE s2.store_id = s1.store_id) * 100) AS contribution_percentage
FROM Sales s1
GROUP BY s1.store_id, s1.dept_id;

-- 13. Join-Based Query: Store-wise department sales summary
SELECT 
    st.store_id, 
    st.location,
    d.dept_name,
    SUM(s.weekly_sales) AS total_sales
FROM Sales s
JOIN Stores st ON s.store_id = st.store_id
JOIN Departments d ON s.dept_id = d.dept_id
GROUP BY st.store_id, st.location, d.dept_name
ORDER BY st.store_id, total_sales DESC;

-- 14. Join-Based Query: Weekly sales and department details
SELECT 
    s.sale_date,
    st.location AS store_location,
    d.dept_name,
    s.weekly_sales,
    s.holiday_flag
FROM Sales s
JOIN Stores st ON s.store_id = st.store_id
JOIN Departments d ON s.dept_id = d.dept_id
ORDER BY s.sale_date DESC;

-- 15. Join-Based Query: Comparison of sales during holidays vs regular weeks (By Store)
SELECT 
    st.store_id,
    st.location,
    s.holiday_flag,
    SUM(s.weekly_sales) AS total_sales,
    AVG(s.weekly_sales) AS avg_weekly_sales
FROM Sales s
JOIN Stores st ON s.store_id = st.store_id
GROUP BY st.store_id, st.location, s.holiday_flag
ORDER BY st.store_id, s.holiday_flag;
