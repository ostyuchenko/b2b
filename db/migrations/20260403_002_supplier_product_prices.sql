-- 3) Supplier purchase prices and FX snapshot per effective date
CREATE TABLE IF NOT EXISTS supplier_product_prices (
    id                  BIGSERIAL PRIMARY KEY,
    supplier_id         BIGINT NOT NULL,
    product_id          BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    purchase_price_usd  NUMERIC(12,4) NOT NULL,
    purchase_price_uah  NUMERIC(12,4) NOT NULL,
    fx_rate             NUMERIC(12,6) NOT NULL,
    effective_from      DATE NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_supplier_product_effective UNIQUE (supplier_id, product_id, effective_from),
    CONSTRAINT chk_purchase_usd_non_negative CHECK (purchase_price_usd >= 0),
    CONSTRAINT chk_purchase_uah_non_negative CHECK (purchase_price_uah >= 0),
    CONSTRAINT chk_fx_rate_positive CHECK (fx_rate > 0)
);

CREATE INDEX IF NOT EXISTS idx_spp_supplier_product_effective
    ON supplier_product_prices (supplier_id, product_id, effective_from DESC);

CREATE INDEX IF NOT EXISTS idx_spp_product_effective
    ON supplier_product_prices (product_id, effective_from DESC);
