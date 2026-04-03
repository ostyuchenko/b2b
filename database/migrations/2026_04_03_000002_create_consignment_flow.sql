BEGIN;

CREATE TABLE IF NOT EXISTS consignment_shipments (
    id BIGSERIAL PRIMARY KEY,
    supplier_id BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    store_id BIGINT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    shipment_number VARCHAR(64) NOT NULL UNIQUE,
    shipped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(32) NOT NULL DEFAULT 'shipped',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_consignment_shipment_status
        CHECK (status IN ('shipped', 'partly_sold', 'sold_not_paid', 'paid'))
);

CREATE TABLE IF NOT EXISTS consignment_shipment_items (
    id BIGSERIAL PRIMARY KEY,
    consignment_shipment_id BIGINT NOT NULL REFERENCES consignment_shipments(id) ON DELETE CASCADE,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    qty_shipped NUMERIC(14,3) NOT NULL,
    qty_on_consignment NUMERIC(14,3) NOT NULL,
    qty_sold_unpaid NUMERIC(14,3) NOT NULL DEFAULT 0,
    qty_paid_and_closed NUMERIC(14,3) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_consignment_item UNIQUE (consignment_shipment_id, product_id),
    CONSTRAINT chk_qty_shipped_positive CHECK (qty_shipped > 0),
    CONSTRAINT chk_qty_on_consignment_non_negative CHECK (qty_on_consignment >= 0),
    CONSTRAINT chk_qty_sold_unpaid_non_negative CHECK (qty_sold_unpaid >= 0),
    CONSTRAINT chk_qty_paid_and_closed_non_negative CHECK (qty_paid_and_closed >= 0),
    CONSTRAINT chk_qty_balance_consistent
        CHECK (qty_shipped = qty_on_consignment + qty_sold_unpaid + qty_paid_and_closed)
);

CREATE TABLE IF NOT EXISTS sales (
    id BIGSERIAL PRIMARY KEY,
    consignment_shipment_item_id BIGINT NOT NULL REFERENCES consignment_shipment_items(id) ON DELETE RESTRICT,
    qty NUMERIC(14,3) NOT NULL,
    sold_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    unit_price NUMERIC(14,2),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_sale_qty_positive CHECK (qty > 0),
    CONSTRAINT chk_sale_unit_price_non_negative CHECK (unit_price IS NULL OR unit_price >= 0)
);

CREATE TABLE IF NOT EXISTS payments (
    id BIGSERIAL PRIMARY KEY,
    consignment_shipment_item_id BIGINT NOT NULL REFERENCES consignment_shipment_items(id) ON DELETE RESTRICT,
    qty_paid NUMERIC(14,3) NOT NULL,
    amount_paid NUMERIC(14,2),
    paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_payment_qty_positive CHECK (qty_paid > 0),
    CONSTRAINT chk_payment_amount_non_negative CHECK (amount_paid IS NULL OR amount_paid >= 0)
);

CREATE INDEX IF NOT EXISTS idx_consignment_shipments_store_status
    ON consignment_shipments (store_id, status);
CREATE INDEX IF NOT EXISTS idx_consignment_items_shipment
    ON consignment_shipment_items (consignment_shipment_id);
CREATE INDEX IF NOT EXISTS idx_sales_item_sold_at
    ON sales (consignment_shipment_item_id, sold_at DESC);
CREATE INDEX IF NOT EXISTS idx_payments_item_paid_at
    ON payments (consignment_shipment_item_id, paid_at DESC);

CREATE OR REPLACE FUNCTION refresh_consignment_shipment_status(p_shipment_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_shipped NUMERIC(14,3);
    v_total_on_consignment NUMERIC(14,3);
    v_total_sold_unpaid NUMERIC(14,3);
    v_total_paid NUMERIC(14,3);
    v_new_status VARCHAR(32);
BEGIN
    SELECT
        COALESCE(SUM(i.qty_shipped), 0),
        COALESCE(SUM(i.qty_on_consignment), 0),
        COALESCE(SUM(i.qty_sold_unpaid), 0),
        COALESCE(SUM(i.qty_paid_and_closed), 0)
    INTO v_total_shipped, v_total_on_consignment, v_total_sold_unpaid, v_total_paid
    FROM consignment_shipment_items i
    WHERE i.consignment_shipment_id = p_shipment_id;

    IF v_total_shipped = 0 OR v_total_on_consignment = v_total_shipped THEN
        v_new_status := 'shipped';
    ELSIF v_total_on_consignment > 0 THEN
        v_new_status := 'partly_sold';
    ELSIF v_total_sold_unpaid > 0 THEN
        v_new_status := 'sold_not_paid';
    ELSE
        v_new_status := 'paid';
    END IF;

    UPDATE consignment_shipments
    SET status = v_new_status,
        updated_at = NOW()
    WHERE id = p_shipment_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_consignment_item_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.qty_on_consignment IS NULL THEN
        NEW.qty_on_consignment := NEW.qty_shipped;
    END IF;

    IF NEW.qty_sold_unpaid IS NULL THEN
        NEW.qty_sold_unpaid := 0;
    END IF;

    IF NEW.qty_paid_and_closed IS NULL THEN
        NEW.qty_paid_and_closed := 0;
    END IF;

    NEW.updated_at := NOW();

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_consignment_item_defaults
BEFORE INSERT OR UPDATE ON consignment_shipment_items
FOR EACH ROW
EXECUTE FUNCTION trg_consignment_item_defaults();

CREATE OR REPLACE FUNCTION trg_sales_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_available NUMERIC(14,3);
    v_shipment_id BIGINT;
BEGIN
    SELECT qty_on_consignment, consignment_shipment_id
    INTO v_available, v_shipment_id
    FROM consignment_shipment_items
    WHERE id = NEW.consignment_shipment_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'consignment_shipment_item_id % not found', NEW.consignment_shipment_item_id;
    END IF;

    IF NEW.qty > v_available THEN
        RAISE EXCEPTION
            'Cannot sell %.3f units: only %.3f currently on consignment for item %',
            NEW.qty, v_available, NEW.consignment_shipment_item_id;
    END IF;

    UPDATE consignment_shipment_items
    SET qty_on_consignment = qty_on_consignment - NEW.qty,
        qty_sold_unpaid = qty_sold_unpaid + NEW.qty,
        updated_at = NOW()
    WHERE id = NEW.consignment_shipment_item_id;

    PERFORM refresh_consignment_shipment_status(v_shipment_id);

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_sales_forbid_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Sales records are immutable. Create compensating records instead.';
END;
$$;

CREATE TRIGGER trg_sales_apply
BEFORE INSERT ON sales
FOR EACH ROW
EXECUTE FUNCTION trg_sales_apply();

CREATE TRIGGER trg_sales_forbid_update_delete
BEFORE UPDATE OR DELETE ON sales
FOR EACH ROW
EXECUTE FUNCTION trg_sales_forbid_change();

CREATE OR REPLACE FUNCTION trg_payments_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_unpaid NUMERIC(14,3);
    v_shipment_id BIGINT;
BEGIN
    SELECT qty_sold_unpaid, consignment_shipment_id
    INTO v_unpaid, v_shipment_id
    FROM consignment_shipment_items
    WHERE id = NEW.consignment_shipment_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'consignment_shipment_item_id % not found', NEW.consignment_shipment_item_id;
    END IF;

    IF NEW.qty_paid > v_unpaid THEN
        RAISE EXCEPTION
            'Cannot register payment for %.3f units: only %.3f sold but unpaid for item %',
            NEW.qty_paid, v_unpaid, NEW.consignment_shipment_item_id;
    END IF;

    UPDATE consignment_shipment_items
    SET qty_sold_unpaid = qty_sold_unpaid - NEW.qty_paid,
        qty_paid_and_closed = qty_paid_and_closed + NEW.qty_paid,
        updated_at = NOW()
    WHERE id = NEW.consignment_shipment_item_id;

    PERFORM refresh_consignment_shipment_status(v_shipment_id);

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_payments_forbid_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Payment records are immutable. Create compensating records instead.';
END;
$$;

CREATE TRIGGER trg_payments_apply
BEFORE INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payments_apply();

CREATE TRIGGER trg_payments_forbid_update_delete
BEFORE UPDATE OR DELETE ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payments_forbid_change();

CREATE OR REPLACE FUNCTION trg_refresh_status_on_item_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_shipment_id BIGINT;
BEGIN
    v_shipment_id := COALESCE(NEW.consignment_shipment_id, OLD.consignment_shipment_id);
    PERFORM refresh_consignment_shipment_status(v_shipment_id);
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_refresh_status_on_item_change
AFTER INSERT OR UPDATE OR DELETE ON consignment_shipment_items
FOR EACH ROW
EXECUTE FUNCTION trg_refresh_status_on_item_change();

COMMIT;
