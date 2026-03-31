-- -----------------------------------------------------------------------------
-- Nested Queries & Join-Based Queries (To be used in the App)
-- -----------------------------------------------------------------------------

USE walmart_sales;

-- 10. Nested Query: Departments with highest sales in last month
-- (Assuming 'last month' means the max month available in the dataset for this example)
SELECT dept_id, dept_name 
FROM Departments 
WHERE dept_id IN (
    SELECT dept_id 
    FROM Sales 
    WHERE MONTH(sale_date) = (SELECT MAX(MONTH(sale_date)) FROM Sales)
      AND YEAR(sale_date) = (SELECT MAX(YEAR(sale_date)) FROM Sales)
    GROUP BY dept_id
    HAVING SUM(weekly_sales) > (
        SELECT AVG(total_sales) 
        FROM (SELECT SUM(weekly_sales) AS total_sales, dept_id FROM Sales GROUP BY dept_id) as dept_avgs
    )
);

-- 11. Nested Query: Stores with declining weekly sales trend 
-- (Comparing previous week vs current week for a specific store/dept combination)
SELECT DISTINCT store_id
FROM Stores
WHERE store_id IN (
    SELECT s1.store_id
    FROM Sales s1
    JOIN Sales s2 ON s1.store_id = s2.store_id 
                  AND s1.dept_id = s2.dept_id 
                  AND s1.sale_date = DATE_ADD(s2.sale_date, INTERVAL 7 DAY)
    WHERE s1.weekly_sales < s2.weekly_sales
);

-- 12. Nested Query: Sales contribution by each department per store
SELECT 
    store_id,
    dept_id,
    SUM(weekly_sales) AS dept_sales,
    (SUM(weekly_sales) / (SELECT SUM(weekly_sales) FROM Sales s2 WHERE s2.store_id = s1.store_id) * 100) AS contribution_percentage
FROM Sales s1
GROUP BY store_id, dept_id;


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
