-- CloudForge schema + seed data. Runs once on first Postgres start (docker-entrypoint-initdb.d)
-- and via the Kubernetes init ConfigMap. Idempotent.
CREATE TABLE IF NOT EXISTS products (
    id           SERIAL PRIMARY KEY,
    sku          VARCHAR(64)  NOT NULL UNIQUE,
    name         VARCHAR(200) NOT NULL,
    description  TEXT         NOT NULL DEFAULT '',
    price_cents  INTEGER      NOT NULL CHECK (price_cents >= 0),
    stock        INTEGER      NOT NULL DEFAULT 0 CHECK (stock >= 0),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
    id              SERIAL PRIMARY KEY,
    product_id      INTEGER      NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity        INTEGER      NOT NULL CHECK (quantity > 0),
    total_cents     INTEGER      NOT NULL CHECK (total_cents >= 0),
    customer_email  VARCHAR(254) NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_orders_created_at ON orders (created_at DESC);
CREATE INDEX IF NOT EXISTS ix_orders_product_id ON orders (product_id);

INSERT INTO products (sku, name, description, price_cents, stock) VALUES
    ('CF-ANVIL',  'Cloud Anvil',     'Heavy-duty compute anvil',       4999, 25),
    ('CF-HAMMER', 'Forge Hammer',    'Precision deployment hammer',    2499, 50),
    ('CF-TONGS',  'Pod Tongs',       'Handle hot containers safely',   1299, 80),
    ('CF-BELLOW', 'Scaling Bellows', 'Pumps air into your autoscaler', 3599, 15)
ON CONFLICT (sku) DO NOTHING;
