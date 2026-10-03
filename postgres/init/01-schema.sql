-- Demo store schema. Safe to re-run: drops public objects first.
BEGIN;

DROP TABLE IF EXISTS reviews CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS regions CASCADE;

CREATE TABLE categories (
  id    SMALLINT PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE
);

CREATE TABLE products (
  id            INTEGER PRIMARY KEY,
  category_id   SMALLINT NOT NULL REFERENCES categories (id),
  name          TEXT NOT NULL,
  sku           TEXT NOT NULL UNIQUE,
  price_cents   INTEGER NOT NULL CHECK (price_cents > 0),
  in_stock      INTEGER NOT NULL CHECK (in_stock >= 0)
);

CREATE TABLE orders (
  id           INTEGER PRIMARY KEY,
  status       TEXT NOT NULL CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled')),
  ordered_at   TIMESTAMPTZ NOT NULL
);

CREATE TABLE order_items (
  order_id         INTEGER NOT NULL REFERENCES orders (id),
  product_id       INTEGER NOT NULL REFERENCES products (id),
  qty              INTEGER NOT NULL CHECK (qty > 0),
  unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents > 0),
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE reviews (
  id           INTEGER PRIMARY KEY,
  product_id   INTEGER NOT NULL REFERENCES products (id),
  rating       SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  body         TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_products_category ON products (category_id);
CREATE INDEX idx_order_items_product ON order_items (product_id);
CREATE INDEX idx_reviews_product ON reviews (product_id);

COMMIT;
