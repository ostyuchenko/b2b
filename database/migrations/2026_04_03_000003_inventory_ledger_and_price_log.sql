BEGIN;

CREATE TABLE IF NOT EXISTS inventory_ledger (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    store_id BIGINT REFERENCES stores(id) ON DELETE SET NULL,
    supplier_id BIGINT REFERENCES suppliers(id) ON DELETE SET NULL,
    operation_type VARCHAR(32) NOT NULL,
    qty_delta NUMERIC(14,3) NOT NULL,
    balance_after NUMERIC(14,3) NOT NULL,
    ref_type VARCHAR(64),
    ref_id BIGINT,
    created_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_inventory_ledger_operation_type
        CHECK (operation_type IN ('receipt', 'shipment', 'sale', 'payment_close', 'manual_adjustment'))
);

CREATE INDEX IF NOT EXISTS idx_inventory_ledger_product_created_at
    ON inventory_ledger (product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_store_created_at
    ON inventory_ledger (store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_operation_created_at
    ON inventory_ledger (operation_type, created_at DESC);

CREATE TABLE IF NOT EXISTS price_change_log (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    store_id BIGINT REFERENCES stores(id) ON DELETE SET NULL,
    supplier_id BIGINT REFERENCES suppliers(id) ON DELETE SET NULL,
    old_price NUMERIC(14,4),
    new_price NUMERIC(14,4) NOT NULL,
    currency VARCHAR(3) NOT NULL DEFAULT 'UAH',
    source_table VARCHAR(64) NOT NULL,
    source_id BIGINT,
    changed_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_price_change_log_currency CHECK (currency IN ('UAH', 'USD')),
    CONSTRAINT chk_price_change_log_non_negative_old CHECK (old_price IS NULL OR old_price >= 0),
    CONSTRAINT chk_price_change_log_non_negative_new CHECK (new_price >= 0)
);

CREATE INDEX IF NOT EXISTS idx_price_change_log_product_changed_at
    ON price_change_log (product_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_change_log_store_changed_at
    ON price_change_log (store_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_change_log_supplier_changed_at
    ON price_change_log (supplier_id, changed_at DESC);

CREATE OR REPLACE FUNCTION assert_inventory_service_context()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (
        NEW.qty_shipped IS DISTINCT FROM OLD.qty_shipped
        OR NEW.qty_on_consignment IS DISTINCT FROM OLD.qty_on_consignment
        OR NEW.qty_sold_unpaid IS DISTINCT FROM OLD.qty_sold_unpaid
        OR NEW.qty_paid_and_closed IS DISTINCT FROM OLD.qty_paid_and_closed
    )
    AND COALESCE(current_setting('app.inventory_service', true), 'off') <> 'on' THEN
        RAISE EXCEPTION
            'Direct stock updates are forbidden. Use inventory service function inventory_apply_operation().';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_consignment_items_require_service ON consignment_shipment_items;
CREATE TRIGGER trg_consignment_items_require_service
BEFORE UPDATE ON consignment_shipment_items
FOR EACH ROW
EXECUTE FUNCTION assert_inventory_service_context();

CREATE OR REPLACE FUNCTION inventory_apply_operation(
    p_consignment_shipment_item_id BIGINT,
    p_operation_type VARCHAR(32),
    p_qty NUMERIC(14,3),
    p_ref_type VARCHAR(64),
    p_ref_id BIGINT,
    p_created_by BIGINT DEFAULT NULL
)
RETURNS NUMERIC(14,3)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item consignment_shipment_items%ROWTYPE;
    v_qty NUMERIC(14,3);
    v_ledger_delta NUMERIC(14,3);
BEGIN
    IF p_operation_type NOT IN ('receipt', 'shipment', 'sale', 'payment_close', 'manual_adjustment') THEN
        RAISE EXCEPTION 'Unsupported inventory operation type: %', p_operation_type;
    END IF;

    IF p_qty IS NULL THEN
        RAISE EXCEPTION 'Quantity cannot be NULL';
    END IF;

    v_qty := p_qty;

    SELECT *
    INTO v_item
    FROM consignment_shipment_items
    WHERE id = p_consignment_shipment_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'consignment_shipment_item_id % not found', p_consignment_shipment_item_id;
    END IF;

    PERFORM set_config('app.inventory_service', 'on', true);

    CASE p_operation_type
        WHEN 'receipt', 'shipment' THEN
            IF v_qty <= 0 THEN
                RAISE EXCEPTION '% operation requires positive qty, got %', p_operation_type, v_qty;
            END IF;

            UPDATE consignment_shipment_items
            SET qty_shipped = qty_shipped + v_qty,
                qty_on_consignment = qty_on_consignment + v_qty,
                updated_at = NOW()
            WHERE id = p_consignment_shipment_item_id;

            v_ledger_delta := v_qty;

        WHEN 'sale' THEN
            IF v_qty <= 0 THEN
                RAISE EXCEPTION 'sale operation requires positive qty, got %', v_qty;
            END IF;

            IF v_qty > v_item.qty_on_consignment THEN
                RAISE EXCEPTION
                    'Cannot sell %.3f units: only %.3f currently on consignment for item %',
                    v_qty, v_item.qty_on_consignment, p_consignment_shipment_item_id;
            END IF;

            UPDATE consignment_shipment_items
            SET qty_on_consignment = qty_on_consignment - v_qty,
                qty_sold_unpaid = qty_sold_unpaid + v_qty,
                updated_at = NOW()
            WHERE id = p_consignment_shipment_item_id;

            v_ledger_delta := -v_qty;

        WHEN 'payment_close' THEN
            IF v_qty <= 0 THEN
                RAISE EXCEPTION 'payment_close operation requires positive qty, got %', v_qty;
            END IF;

            IF v_qty > v_item.qty_sold_unpaid THEN
                RAISE EXCEPTION
                    'Cannot register payment for %.3f units: only %.3f sold but unpaid for item %',
                    v_qty, v_item.qty_sold_unpaid, p_consignment_shipment_item_id;
            END IF;

            UPDATE consignment_shipment_items
            SET qty_sold_unpaid = qty_sold_unpaid - v_qty,
                qty_paid_and_closed = qty_paid_and_closed + v_qty,
                updated_at = NOW()
            WHERE id = p_consignment_shipment_item_id;

            v_ledger_delta := 0;

        WHEN 'manual_adjustment' THEN
            IF v_qty = 0 THEN
                RAISE EXCEPTION 'manual_adjustment operation requires non-zero qty';
            END IF;

            IF v_item.qty_on_consignment + v_qty < 0 THEN
                RAISE EXCEPTION
                    'Cannot apply adjustment %.3f: resulting on-consignment balance would be negative (%.3f)',
                    v_qty, v_item.qty_on_consignment + v_qty;
            END IF;

            UPDATE consignment_shipment_items
            SET qty_shipped = qty_shipped + v_qty,
                qty_on_consignment = qty_on_consignment + v_qty,
                updated_at = NOW()
            WHERE id = p_consignment_shipment_item_id;

            v_ledger_delta := v_qty;
    END CASE;

    SELECT *
    INTO v_item
    FROM consignment_shipment_items
    WHERE id = p_consignment_shipment_item_id;

    INSERT INTO inventory_ledger (
        product_id,
        store_id,
        supplier_id,
        operation_type,
        qty_delta,
        balance_after,
        ref_type,
        ref_id,
        created_by,
        created_at
    )
    SELECT
        csi.product_id,
        cs.store_id,
        cs.supplier_id,
        p_operation_type,
        v_ledger_delta,
        v_item.qty_on_consignment,
        p_ref_type,
        p_ref_id,
        p_created_by,
        NOW()
    FROM consignment_shipment_items csi
    JOIN consignment_shipments cs ON cs.id = csi.consignment_shipment_id
    WHERE csi.id = p_consignment_shipment_item_id;

    PERFORM refresh_consignment_shipment_status(v_item.consignment_shipment_id);

    RETURN v_item.qty_on_consignment;
END;
$$;

CREATE OR REPLACE FUNCTION trg_sales_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM inventory_apply_operation(
        NEW.consignment_shipment_item_id,
        'sale',
        NEW.qty,
        'sales',
        NEW.id,
        NULL
    );

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_payments_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM inventory_apply_operation(
        NEW.consignment_shipment_item_id,
        'payment_close',
        NEW.qty_paid,
        'payments',
        NEW.id,
        NULL
    );

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_consignment_item_receipt_ledger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.qty_on_consignment > 0 THEN
        INSERT INTO inventory_ledger (
            product_id,
            store_id,
            supplier_id,
            operation_type,
            qty_delta,
            balance_after,
            ref_type,
            ref_id,
            created_at
        )
        SELECT
            NEW.product_id,
            cs.store_id,
            cs.supplier_id,
            'receipt',
            NEW.qty_on_consignment,
            NEW.qty_on_consignment,
            'consignment_shipment_item',
            NEW.id,
            NOW()
        FROM consignment_shipments cs
        WHERE cs.id = NEW.consignment_shipment_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_consignment_item_receipt_ledger ON consignment_shipment_items;
CREATE TRIGGER trg_consignment_item_receipt_ledger
AFTER INSERT ON consignment_shipment_items
FOR EACH ROW
EXECUTE FUNCTION trg_consignment_item_receipt_ledger();

CREATE OR REPLACE FUNCTION trg_log_store_price_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.sale_price_uah IS DISTINCT FROM OLD.sale_price_uah THEN
        IF NEW.sale_price_uah IS NOT NULL THEN
            INSERT INTO price_change_log (
                product_id,
                store_id,
                old_price,
                new_price,
                currency,
                source_table,
                source_id,
                changed_at
            )
            VALUES (
                NEW.product_id,
                NEW.store_id,
                CASE WHEN TG_OP = 'UPDATE' THEN OLD.sale_price_uah ELSE NULL END,
                NEW.sale_price_uah,
                'UAH',
                'store_product_access',
                NEW.id,
                NOW()
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DO $$
BEGIN
    IF to_regclass('store_product_access') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_log_store_price_change ON store_product_access;
        CREATE TRIGGER trg_log_store_price_change
        AFTER INSERT OR UPDATE OF sale_price_uah ON store_product_access
        FOR EACH ROW
        EXECUTE FUNCTION trg_log_store_price_change();
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trg_log_supplier_price_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.purchase_price_uah IS DISTINCT FROM OLD.purchase_price_uah THEN
        INSERT INTO price_change_log (
            product_id,
            supplier_id,
            old_price,
            new_price,
            currency,
            source_table,
            source_id,
            changed_at
        )
        VALUES (
            NEW.product_id,
            NEW.supplier_id,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.purchase_price_uah ELSE NULL END,
            NEW.purchase_price_uah,
            'UAH',
            'supplier_product_prices',
            NEW.id,
            NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

DO $$
BEGIN
    IF to_regclass('supplier_product_prices') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_log_supplier_price_change ON supplier_product_prices;
        CREATE TRIGGER trg_log_supplier_price_change
        AFTER INSERT OR UPDATE OF purchase_price_uah ON supplier_product_prices
        FOR EACH ROW
        EXECUTE FUNCTION trg_log_supplier_price_change();
    END IF;
END;
$$;

COMMIT;
