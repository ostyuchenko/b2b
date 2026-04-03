BEGIN;

CREATE TABLE IF NOT EXISTS product_initial_stocks (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    source_type VARCHAR(16) NOT NULL,
    qty NUMERIC(14,3) NOT NULL,
    imported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    import_file VARCHAR(255),
    CONSTRAINT uq_product_initial_stocks UNIQUE (product_id, source_type),
    CONSTRAINT chk_product_initial_stock_source_type CHECK (source_type IN ('internal', 'external')),
    CONSTRAINT chk_product_initial_stock_qty_non_negative CHECK (qty >= 0)
);

CREATE INDEX IF NOT EXISTS idx_product_initial_stocks_product_id
    ON product_initial_stocks (product_id);

COMMIT;
