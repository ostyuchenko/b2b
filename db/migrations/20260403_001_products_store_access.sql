-- 1) Products (SKU / артикул, название, базовые поля)
CREATE TABLE IF NOT EXISTS products (
    id                  BIGSERIAL PRIMARY KEY,
    sku                 VARCHAR(64) NOT NULL UNIQUE,
    name                TEXT NOT NULL,
    description         TEXT,
    unit                VARCHAR(32) NOT NULL DEFAULT 'pcs',
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2) Store-level assortment access and direct sale price
CREATE TABLE IF NOT EXISTS store_product_access (
    id                  BIGSERIAL PRIMARY KEY,
    store_id            BIGINT NOT NULL,
    product_id          BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    is_enabled          BOOLEAN NOT NULL DEFAULT FALSE,
    sale_price_uah      NUMERIC(12,2),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_store_product UNIQUE (store_id, product_id),
    CONSTRAINT chk_sale_price_non_negative CHECK (sale_price_uah IS NULL OR sale_price_uah >= 0)
);

-- Optional: dated sale-price history (if needed later)
CREATE TABLE IF NOT EXISTS store_product_sale_prices (
    id                  BIGSERIAL PRIMARY KEY,
    store_id            BIGINT NOT NULL,
    product_id          BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    sale_price_uah      NUMERIC(12,2) NOT NULL,
    effective_from      DATE NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_store_product_effective UNIQUE (store_id, product_id, effective_from),
    CONSTRAINT chk_store_sale_price_non_negative CHECK (sale_price_uah >= 0)
);

CREATE INDEX IF NOT EXISTS idx_spa_store_enabled ON store_product_access (store_id, is_enabled);
CREATE INDEX IF NOT EXISTS idx_spa_product_enabled ON store_product_access (product_id, is_enabled);
CREATE INDEX IF NOT EXISTS idx_store_sale_prices_effective ON store_product_sale_prices (store_id, product_id, effective_from DESC);
