"""Load the four in-scope Olist tables from data/Raw/*.csv into MySQL.

Creates the database `olist` and four tables with join-key columns typed
VARCHAR(32) (all ID values verified to be exactly 32 chars) plus indexes on
every join column, so sql/delivery_analysis.sql runs without full-table-scan
joins. (The first load used pandas to_sql defaults, which produced unindexed
TEXT columns and caused query timeouts; this script avoids that.)

Connection settings come from environment variables — no credentials are
hardcoded:

    MYSQL_HOST     default 127.0.0.1
    MYSQL_PORT     default 3307
    MYSQL_USER     default root
    MYSQL_PASSWORD default '' (empty; set if your local MySQL requires one)

The database name stays `olist` because sql/delivery_analysis.sql issues
`USE olist`.

Date columns are TEXT in the CSVs with format 'YYYY-MM-DD HH:MM:SS'.
The format is verified against every non-null value before conversion,
then loaded as DATETIME so delivery-delay arithmetic is unambiguous.

Usage (after placing the four Olist CSVs in data/Raw/):
    python data/load_mysql.py
"""
import os
from pathlib import Path

import pandas as pd
import pymysql
from sqlalchemy import create_engine
from urllib.parse import quote_plus

# CSVs live next to this script in data/Raw/ — path is repo-relative, not machine-specific
BASE = Path(__file__).resolve().parent / 'Raw'
HOST = os.environ.get('MYSQL_HOST', '127.0.0.1')
PORT = int(os.environ.get('MYSQL_PORT', '3307'))
USER = os.environ.get('MYSQL_USER', 'root')
PASSWORD = os.environ.get('MYSQL_PASSWORD', '')
DB = 'olist'

DDL = """
CREATE DATABASE IF NOT EXISTS olist CHARACTER SET utf8mb4;
USE olist;

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  order_id                      VARCHAR(32) NOT NULL,
  customer_id                   VARCHAR(32),
  order_status                  VARCHAR(32),
  order_purchase_timestamp      DATETIME,
  order_approved_at             DATETIME,
  order_delivered_carrier_date  DATETIME,
  order_delivered_customer_date DATETIME,
  order_estimated_delivery_date DATETIME,
  PRIMARY KEY (order_id),
  KEY idx_orders_status (order_status)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS order_items;
CREATE TABLE order_items (
  order_id            VARCHAR(32) NOT NULL,
  order_item_id       INT,
  product_id          VARCHAR(32),
  seller_id           VARCHAR(32) NOT NULL,
  shipping_limit_date DATETIME,
  price               DOUBLE,
  freight_value       DOUBLE,
  KEY idx_items_order (order_id),
  KEY idx_items_seller (seller_id)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS sellers;
CREATE TABLE sellers (
  seller_id             VARCHAR(32) NOT NULL,
  seller_zip_code_prefix INT,
  seller_city           VARCHAR(64),
  seller_state          VARCHAR(2),
  PRIMARY KEY (seller_id)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS order_reviews;
CREATE TABLE order_reviews (
  review_id               VARCHAR(32),
  order_id                VARCHAR(32) NOT NULL,
  review_score            INT,
  review_comment_title    TEXT,
  review_comment_message  TEXT,
  review_creation_date    DATETIME,
  review_answer_timestamp DATETIME,
  KEY idx_reviews_order (order_id)
) ENGINE=InnoDB;
"""

DATE_COLS = {
    'orders': ['order_purchase_timestamp', 'order_approved_at',
               'order_delivered_carrier_date', 'order_delivered_customer_date',
               'order_estimated_delivery_date'],
    'order_items': ['shipping_limit_date'],
    'order_reviews': ['review_creation_date', 'review_answer_timestamp'],
}
FILES = {'orders': 'olist_orders_dataset.csv',
         'order_items': 'olist_order_items_dataset.csv',
         'sellers': 'olist_sellers_dataset.csv',
         'order_reviews': 'olist_order_reviews_dataset.csv'}


def read_one(table):
    df = pd.read_csv(BASE / FILES[table])
    for c in DATE_COLS.get(table, []):
        parsed = pd.to_datetime(df[c], format='%Y-%m-%d %H:%M:%S', errors='coerce')
        bad = df[c].notna() & parsed.isna()
        assert bad.sum() == 0, f'unparseable {c}: {df.loc[bad, c].head().tolist()}'
        df[c] = parsed
    return df


conn = pymysql.connect(host=HOST, port=PORT, user=USER, password=PASSWORD,
                       autocommit=True)
with conn.cursor() as cur:
    for stmt in DDL.strip().split(';'):
        if stmt.strip():
            cur.execute(stmt)
conn.close()

engine_url = (f'mysql+pymysql://{quote_plus(USER)}:{quote_plus(PASSWORD)}'
              f'@{HOST}:{PORT}/{DB}?charset=utf8mb4')
engine = create_engine(engine_url)
for table in FILES:
    df = read_one(table)
    df.to_sql(table, engine, if_exists='append', index=False)
    print(f'{table}: {len(df)} rows loaded')

with engine.connect() as cn:
    for table in FILES:
        n = cn.exec_driver_sql(f'SELECT COUNT(*) FROM {table}').scalar()
        print(f'{table} count in db: {n}')
print('load complete')
