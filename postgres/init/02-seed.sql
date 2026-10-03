-- Test rows for the demo store. Re-run after 01-schema.sql.
BEGIN;

INSERT INTO categories (id, name) VALUES
  (1, 'Laptops'),
  (2, 'Monitors'),
  (3, 'Accessories'),
  (4, 'Software');

INSERT INTO products (id, category_id, name, sku, price_cents, in_stock) VALUES
  (1, 1, '14-inch Ultrabook', 'LAP-14-U', 129900, 12),
  (2, 1, '16-inch Workstation', 'LAP-16-W', 219900, 5),
  (3, 2, '27-inch 4K Monitor', 'MON-27-4K', 54900, 20),
  (4, 2, '24-inch Office Monitor', 'MON-24-OF', 22900, 35),
  (5, 3, 'Mechanical Keyboard', 'ACC-KB-M', 14900, 40),
  (6, 3, 'USB-C Dock', 'ACC-DOCK', 18900, 18),
  (7, 4, 'Office Suite License', 'SFT-OFF-1', 9900, 999),
  (8, 4, 'Endpoint Protection', 'SFT-EPP-1', 5900, 999);

INSERT INTO orders (id, status, ordered_at) VALUES
  (1001, 'paid', '2025-02-02T10:12:00Z'),
  (1002, 'shipped', '2025-03-11T15:40:00Z'),
  (1003, 'pending', '2025-06-19T09:05:00Z'),
  (1004, 'paid', '2025-08-01T12:22:00Z'),
  (1005, 'cancelled', '2025-08-21T17:50:00Z'),
  (1006, 'shipped', '2026-01-14T08:33:00Z');

INSERT INTO order_items (order_id, product_id, qty, unit_price_cents) VALUES
  (1001, 1, 1, 129900),
  (1001, 5, 1, 14900),
  (1002, 3, 2, 54900),
  (1003, 2, 1, 219900),
  (1003, 6, 1, 18900),
  (1004, 7, 10, 9900),
  (1005, 4, 3, 22900),
  (1006, 8, 25, 5900),
  (1006, 5, 2, 14900);

INSERT INTO reviews (id, product_id, rating, body, created_at) VALUES
  (1, 1, 5, 'Light and fast. Battery lasts a full workday.', '2025-02-20T18:00:00Z'),
  (2, 3, 4, 'Sharp 4K panel. Stand is a bit wobbly.', '2025-03-28T09:10:00Z'),
  (3, 2, 5, 'Handles local models without thermal throttling.', '2025-07-01T21:45:00Z'),
  (4, 7, 3, 'Fine for docs. Installer needed two retries.', '2025-08-10T07:30:00Z'),
  (5, 5, 4, 'Tactile keys. Layout took a day to get used to.', '2026-01-20T16:05:00Z');

COMMIT;
