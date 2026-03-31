from flask import Flask, render_template, jsonify, request
import psycopg2
from psycopg2.extras import RealDictCursor, execute_values
import pandas as pd
import os

app = Flask(__name__)

DB_HOST = "localhost"
DB_NAME = "walmart sales"
DB_USER = "postgres"
DB_PASS = "raghuramm24"
DB_PORT = "5432"

CSV_FILE_PATH = "walmart_sales.csv" 

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS, port=DB_PORT
    )

def init_db_schema():
    print("Initializing Database Schema...")
    conn = get_db_connection()
    conn.autocommit = True
    cur = conn.cursor()
    
    schema = """
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

    CREATE TABLE IF NOT EXISTS High_Sales_Log (
        log_id SERIAL PRIMARY KEY,
        sale_id INT,
        weekly_sales FLOAT,
        log_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE OR REPLACE FUNCTION log_high_sales_func() RETURNS TRIGGER AS $$
    BEGIN
        IF NEW.weekly_sales > 15000 THEN
            INSERT INTO High_Sales_Log (sale_id, weekly_sales) VALUES (NEW.sale_id, NEW.weekly_sales);
        END IF;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trg_log_high_sales ON Sales;
    CREATE TRIGGER trg_log_high_sales AFTER INSERT ON Sales FOR EACH ROW EXECUTE FUNCTION log_high_sales_func();

    CREATE OR REPLACE FUNCTION prevent_negative_sales_func() RETURNS TRIGGER AS $$
    BEGIN
        IF NEW.weekly_sales < 0 THEN
            RAISE EXCEPTION 'Error: Weekly sales cannot be negative';
        END IF;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trg_prevent_negative_sales ON Sales;
    CREATE TRIGGER trg_prevent_negative_sales BEFORE INSERT ON Sales FOR EACH ROW EXECUTE FUNCTION prevent_negative_sales_func();

    CREATE OR REPLACE FUNCTION GetTotalSalesByStoreAndDate(p_store_id INT, p_start DATE, p_end DATE)
    RETURNS TABLE (store_id INT, total_sales FLOAT) AS $$
    BEGIN
        RETURN QUERY SELECT s.store_id, CAST(SUM(s.weekly_sales) AS FLOAT) FROM Sales s WHERE s.store_id = p_store_id AND s.sale_date BETWEEN p_start AND p_end GROUP BY s.store_id;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION PredictSalesNextWeek(p_store_id INT, p_dept_id INT)
    RETURNS TABLE (store_id INT, dept_id INT, predicted_next_week_sales FLOAT) AS $$
    BEGIN
        RETURN QUERY SELECT recent_sales.store_id, recent_sales.dept_id, CAST(AVG(recent_sales.weekly_sales) AS FLOAT) 
        FROM (SELECT s.store_id, s.dept_id, s.weekly_sales FROM Sales s WHERE s.store_id = p_store_id AND s.dept_id = p_dept_id ORDER BY s.sale_date DESC LIMIT 4) AS recent_sales
        GROUP BY recent_sales.store_id, recent_sales.dept_id;
    END;
    $$ LANGUAGE plpgsql;

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

    CREATE OR REPLACE VIEW View_MonthlySalesPerStore AS
    SELECT s.store_id, st.store_type, st.location, EXTRACT(YEAR FROM s.sale_date) AS sales_year, EXTRACT(MONTH FROM s.sale_date) AS sales_month, SUM(s.weekly_sales) AS total_monthly_sales
    FROM Sales s JOIN Stores st ON s.store_id = st.store_id GROUP BY s.store_id, st.store_type, st.location, sales_year, sales_month;

    CREATE OR REPLACE VIEW View_TopPerformingDepartments AS
    SELECT d.dept_id, d.dept_name, SUM(s.weekly_sales) AS total_sales
    FROM Sales s JOIN Departments d ON s.dept_id = d.dept_id GROUP BY d.dept_id, d.dept_name ORDER BY total_sales DESC;

    CREATE OR REPLACE VIEW View_HolidayVsNonHolidaySales AS
    SELECT holiday_flag, COUNT(sale_id) AS total_weeks, SUM(weekly_sales) AS total_sales, AVG(weekly_sales) AS average_weekly_sales
    FROM Sales GROUP BY holiday_flag;
    """
    try:
        cur.execute(schema)
        print("Schema created/verified successfully.")
    except Exception as e:
        print(f"Notice during schema init: {e}")
    
    cur.close()
    conn.close()

def load_data_from_csv():
    init_db_schema()
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("SELECT COUNT(*) FROM Sales;")
        count = cur.fetchone()[0]
        
        if count > 3:
            print(f"Application Ready! Found {count} sales records in database.")
            cur.close()
            conn.close()
            return
            
        print("Database has only sample rows. Emptying it and checking for CSV file...")
        cur.execute("TRUNCATE TABLE Sales, Departments, Stores CASCADE;")
        conn.commit()
        
        if not os.path.exists(CSV_FILE_PATH):
            print(f"Cannot find '{CSV_FILE_PATH}'. Please put your dataset in the same folder to auto-load.")
            cur.close()
            conn.close()
            return

        print("Reading CSV file with pandas...")
        df = pd.read_csv(CSV_FILE_PATH)
        df['Date'] = pd.to_datetime(df['Date'], format='mixed').dt.strftime('%Y-%m-%d')

        print("Loading Stores...")
        store_col = 'Store_Number' if 'Store_Number' in df.columns else 'Store'
        unique_stores = df[store_col].unique()
        store_records = [(int(sid), f"Type A", f"Location") for sid in unique_stores]
        execute_values(cur, "INSERT INTO Stores (store_id, store_type, location) VALUES %s ON CONFLICT (store_id) DO NOTHING", store_records)

        print("Loading Departments...")
        dept_col = 'Dept' if 'Dept' in df.columns else None
        if dept_col:
            unique_depts = df[dept_col].unique()
            dept_records = [(int(did), f"Department {did}") for did in unique_depts]
        else:
            dept_records = [(1, "General Dept")]
        
        execute_values(cur, "INSERT INTO Departments (dept_id, dept_name) VALUES %s ON CONFLICT (dept_id) DO NOTHING", dept_records)

        print("Loading Sales Data (This might take a minute)...")
        sales_records = []
        for _, r in df.iterrows():
            store_id = int(r[store_col])
            dept_id = int(r[dept_col]) if dept_col else 1
            sales = float(str(r['Weekly_Sales']).replace(',', '').replace('"', '').strip())
            
            if 'Holiday_Flag' in df.columns:
                holiday = bool(r['Holiday_Flag'] == 1)
            else:
                holiday = bool(r.get('IsHoliday', False))
                
            sales_records.append((store_id, dept_id, r['Date'], sales, holiday))
            
        execute_values(cur, "INSERT INTO Sales (store_id, dept_id, sale_date, weekly_sales, holiday_flag) VALUES %s ON CONFLICT DO NOTHING", sales_records)

        conn.commit()
        print(f"Successfully loaded {len(sales_records)} sales records into PostgreSQL!")
        cur.close()
        conn.close()
    except Exception as e:
        print(f"Database error during startup check/load: {e}")

@app.route('/')
def home(): return render_template('index.html')

@app.route('/api/views/monthly_sales')
def view_monthly_sales():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT * FROM View_MonthlySalesPerStore ORDER BY sales_year DESC, sales_month DESC;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(rows)

@app.route('/api/views/top_departments')
def view_top_departmens():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT * FROM View_TopPerformingDepartments LIMIT 5;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(rows)

@app.route('/api/views/holiday_impact')
def view_holiday_impact():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT * FROM View_HolidayVsNonHolidaySales;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(rows)

@app.route('/api/procedures/predict_sales')
def proc_predict_sales():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT * FROM PredictSalesNextWeek(1, 101);")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(rows)

@app.route('/api/sales', methods=['POST'])
def add_sale():
    data = request.json
    store_id = int(data.get('store_id', 1))
    dept_id = int(data.get('dept_id', 1))
    sale_date = data.get('sale_date')
    weekly_sales = float(data.get('weekly_sales', 0))
    holiday_flag = bool(data.get('holiday_flag', False))

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        # First ensure Store and Dept exist, otherwise FK constraint fails
        cur.execute("INSERT INTO Stores (store_id, store_type, location) VALUES (%s, 'Unknown', 'Unknown') ON CONFLICT DO NOTHING;", (store_id,))
        cur.execute("INSERT INTO Departments (dept_id, dept_name) VALUES (%s, 'Unknown') ON CONFLICT DO NOTHING;", (dept_id,))
        
        # Now insert the sale using the Stored Procedure Call equivalent (or just direct INSERT since we modified to standard INSERT in python)
        cur.execute(
            "CALL InsertDeptSales(%s::INT, %s::INT, %s::DATE, %s::FLOAT, %s::BOOLEAN);",
            (store_id, dept_id, sale_date, weekly_sales, holiday_flag)
        )
        conn.commit()
        success = True
        msg = "Sale record inserted successfully!"
    except Exception as e:
        conn.rollback()
        success = False
        msg = str(e)
    finally:
        cur.close()
        conn.close()
    
    return jsonify({"success": success, "message": msg})

@app.route('/data')
def get_data():
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT sale_date, weekly_sales FROM Sales ORDER BY sale_date;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    
    dates = [row['sale_date'].strftime('%Y-%m-%d') if row['sale_date'] else None for row in rows]
    sales = [row['weekly_sales'] for row in rows]
    
    return jsonify({"dates": dates, "sales": sales})

if __name__ == '__main__':
    load_data_from_csv()
    app.run(debug=True)