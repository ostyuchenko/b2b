BEGIN;

CREATE TABLE IF NOT EXISTS invoices (
    id BIGSERIAL PRIMARY KEY,
    store_id BIGINT NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
    invoice_number VARCHAR(32) NOT NULL UNIQUE,
    period_month DATE NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'draft',
    subtotal_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    paid_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency VARCHAR(3) NOT NULL DEFAULT 'UAH',
    issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    confirmed_at TIMESTAMPTZ,
    created_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    confirmed_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_invoice_status CHECK (status IN ('draft', 'confirmed', 'partially_paid', 'paid', 'cancelled')),
    CONSTRAINT chk_invoice_subtotal_non_negative CHECK (subtotal_amount >= 0),
    CONSTRAINT chk_invoice_paid_non_negative CHECK (paid_amount >= 0),
    CONSTRAINT chk_invoice_currency CHECK (currency IN ('UAH', 'USD'))
);

CREATE TABLE IF NOT EXISTS invoice_items (
    id BIGSERIAL PRIMARY KEY,
    invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    consignment_shipment_item_id BIGINT NOT NULL REFERENCES consignment_shipment_items(id) ON DELETE RESTRICT,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    unit_price NUMERIC(14,2) NOT NULL,
    qty_invoiced NUMERIC(14,3) NOT NULL,
    amount NUMERIC(14,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_invoice_item_price_non_negative CHECK (unit_price >= 0),
    CONSTRAINT chk_invoice_item_qty_positive CHECK (qty_invoiced > 0),
    CONSTRAINT chk_invoice_item_amount_non_negative CHECK (amount >= 0),
    CONSTRAINT uq_invoice_item_unique_line UNIQUE (invoice_id, consignment_shipment_item_id, unit_price)
);

CREATE TABLE IF NOT EXISTS invoice_item_sales (
    id BIGSERIAL PRIMARY KEY,
    invoice_item_id BIGINT NOT NULL REFERENCES invoice_items(id) ON DELETE CASCADE,
    sale_id BIGINT NOT NULL REFERENCES sales(id) ON DELETE RESTRICT,
    qty_allocated NUMERIC(14,3) NOT NULL,
    amount_allocated NUMERIC(14,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_invoice_item_sales_qty_positive CHECK (qty_allocated > 0),
    CONSTRAINT chk_invoice_item_sales_amount_non_negative CHECK (amount_allocated >= 0),
    CONSTRAINT uq_invoice_item_sale UNIQUE (invoice_item_id, sale_id)
);

CREATE TABLE IF NOT EXISTS invoice_payments (
    id BIGSERIAL PRIMARY KEY,
    invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    payment_number VARCHAR(64) NOT NULL,
    amount_paid NUMERIC(14,2) NOT NULL,
    paid_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payment_method VARCHAR(32),
    note TEXT,
    created_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_invoice_payment_amount_positive CHECK (amount_paid > 0),
    CONSTRAINT uq_invoice_payment_number UNIQUE (payment_number)
);

CREATE TABLE IF NOT EXISTS invoice_payment_items (
    id BIGSERIAL PRIMARY KEY,
    invoice_payment_id BIGINT NOT NULL REFERENCES invoice_payments(id) ON DELETE CASCADE,
    invoice_item_id BIGINT NOT NULL REFERENCES invoice_items(id) ON DELETE CASCADE,
    qty_paid NUMERIC(14,3) NOT NULL,
    amount_paid NUMERIC(14,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_invoice_payment_item_qty_positive CHECK (qty_paid > 0),
    CONSTRAINT chk_invoice_payment_item_amount_positive CHECK (amount_paid > 0),
    CONSTRAINT uq_invoice_payment_item UNIQUE (invoice_payment_id, invoice_item_id)
);

CREATE TABLE IF NOT EXISTS invoice_exports (
    id BIGSERIAL PRIMARY KEY,
    invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    export_type VARCHAR(16) NOT NULL,
    file_path TEXT NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'ready',
    exported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    exported_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT chk_invoice_export_type CHECK (export_type IN ('pdf', 'xlsx')),
    CONSTRAINT chk_invoice_export_status CHECK (status IN ('ready', 'failed'))
);

CREATE TABLE IF NOT EXISTS invoice_send_log (
    id BIGSERIAL PRIMARY KEY,
    invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    channel VARCHAR(32) NOT NULL,
    recipient TEXT NOT NULL,
    status VARCHAR(16) NOT NULL,
    provider_message_id VARCHAR(128),
    error_message TEXT,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT chk_invoice_send_status CHECK (status IN ('queued', 'sent', 'failed'))
);

CREATE TABLE IF NOT EXISTS global_inventory_stock (
    product_id BIGINT PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
    qty_available NUMERIC(14,3) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_global_inventory_non_negative CHECK (qty_available >= 0)
);

CREATE TABLE IF NOT EXISTS global_inventory_ledger (
    id BIGSERIAL PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    operation_type VARCHAR(32) NOT NULL,
    qty_delta NUMERIC(14,3) NOT NULL,
    balance_after NUMERIC(14,3) NOT NULL,
    ref_type VARCHAR(64),
    ref_id BIGINT,
    created_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_global_inventory_ledger_operation_type CHECK (operation_type IN ('receipt', 'invoice_payment_writeoff', 'manual_adjustment'))
);

CREATE INDEX IF NOT EXISTS idx_invoices_store_status_created_at
    ON invoices (store_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice
    ON invoice_items (invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoice_item_sales_sale
    ON invoice_item_sales (sale_id);
CREATE INDEX IF NOT EXISTS idx_invoice_payments_invoice_paid_at
    ON invoice_payments (invoice_id, paid_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoice_exports_invoice_type
    ON invoice_exports (invoice_id, export_type, exported_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoice_send_log_invoice_sent_at
    ON invoice_send_log (invoice_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_global_inventory_ledger_product_created_at
    ON global_inventory_ledger (product_id, created_at DESC);

CREATE OR REPLACE FUNCTION set_updated_at_now()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoices_set_updated_at ON invoices;
CREATE TRIGGER trg_invoices_set_updated_at
BEFORE UPDATE ON invoices
FOR EACH ROW
EXECUTE FUNCTION set_updated_at_now();

CREATE OR REPLACE FUNCTION next_invoice_number(p_issued_at TIMESTAMPTZ DEFAULT NOW())
RETURNS VARCHAR(32)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prefix TEXT;
    v_max_seq INTEGER;
BEGIN
    v_prefix := 'INV-' || TO_CHAR(p_issued_at, 'YYYYMM') || '-';

    SELECT COALESCE(MAX(SUBSTRING(invoice_number FROM '([0-9]{4})$')::INTEGER), 0)
    INTO v_max_seq
    FROM invoices
    WHERE invoice_number LIKE v_prefix || '%';

    RETURN v_prefix || LPAD((v_max_seq + 1)::TEXT, 4, '0');
END;
$$;

CREATE OR REPLACE FUNCTION refresh_invoice_totals(p_invoice_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_subtotal NUMERIC(14,2);
    v_paid NUMERIC(14,2);
    v_status VARCHAR(32);
BEGIN
    SELECT COALESCE(SUM(ii.amount), 0)
    INTO v_subtotal
    FROM invoice_items ii
    WHERE ii.invoice_id = p_invoice_id;

    SELECT COALESCE(SUM(ip.amount_paid), 0)
    INTO v_paid
    FROM invoice_payments ip
    WHERE ip.invoice_id = p_invoice_id;

    SELECT status INTO v_status
    FROM invoices
    WHERE id = p_invoice_id
    FOR UPDATE;

    IF v_status IN ('cancelled', 'draft') THEN
        UPDATE invoices
        SET subtotal_amount = v_subtotal,
            paid_amount = v_paid
        WHERE id = p_invoice_id;
        RETURN;
    END IF;

    UPDATE invoices
    SET subtotal_amount = v_subtotal,
        paid_amount = v_paid,
        status = CASE
            WHEN v_subtotal = 0 THEN status
            WHEN v_paid = 0 THEN 'confirmed'
            WHEN v_paid < v_subtotal THEN 'partially_paid'
            ELSE 'paid'
        END
    WHERE id = p_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION global_inventory_apply_writeoff(
    p_product_id BIGINT,
    p_qty NUMERIC(14,3),
    p_ref_type VARCHAR(64),
    p_ref_id BIGINT,
    p_created_by BIGINT DEFAULT NULL
)
RETURNS NUMERIC(14,3)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(14,3);
BEGIN
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'Global inventory writeoff qty must be positive, got %', p_qty;
    END IF;

    INSERT INTO global_inventory_stock (product_id, qty_available)
    VALUES (p_product_id, 0)
    ON CONFLICT (product_id) DO NOTHING;

    SELECT qty_available
    INTO v_balance
    FROM global_inventory_stock
    WHERE product_id = p_product_id
    FOR UPDATE;

    IF v_balance < p_qty THEN
        RAISE EXCEPTION 'Insufficient global stock for product %: required %.3f, available %.3f', p_product_id, p_qty, v_balance;
    END IF;

    UPDATE global_inventory_stock
    SET qty_available = qty_available - p_qty,
        updated_at = NOW()
    WHERE product_id = p_product_id
    RETURNING qty_available INTO v_balance;

    INSERT INTO global_inventory_ledger (
        product_id,
        operation_type,
        qty_delta,
        balance_after,
        ref_type,
        ref_id,
        created_by,
        created_at
    )
    VALUES (
        p_product_id,
        'invoice_payment_writeoff',
        -p_qty,
        v_balance,
        p_ref_type,
        p_ref_id,
        p_created_by,
        NOW()
    );

    RETURN v_balance;
END;
$$;

CREATE OR REPLACE FUNCTION create_invoice_for_store(
    p_store_id BIGINT,
    p_created_by BIGINT DEFAULT NULL,
    p_issued_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_invoice_id BIGINT;
BEGIN
    INSERT INTO invoices (
        store_id,
        invoice_number,
        period_month,
        status,
        created_by,
        issued_at
    )
    VALUES (
        p_store_id,
        next_invoice_number(p_issued_at),
        DATE_TRUNC('month', p_issued_at)::DATE,
        'draft',
        p_created_by,
        p_issued_at
    )
    RETURNING id INTO v_invoice_id;

    WITH sales_pool AS (
        SELECT
            s.id AS sale_id,
            s.consignment_shipment_item_id,
            csi.product_id,
            COALESCE(s.unit_price, 0)::NUMERIC(14,2) AS unit_price,
            (s.qty - COALESCE(SUM(iis.qty_allocated), 0))::NUMERIC(14,3) AS qty_open
        FROM sales s
        JOIN consignment_shipment_items csi ON csi.id = s.consignment_shipment_item_id
        JOIN consignment_shipments cs ON cs.id = csi.consignment_shipment_id
        LEFT JOIN invoice_item_sales iis ON iis.sale_id = s.id
        WHERE cs.store_id = p_store_id
          AND cs.status = 'sold_not_paid'
        GROUP BY s.id, s.consignment_shipment_item_id, csi.product_id, s.unit_price, s.qty
        HAVING (s.qty - COALESCE(SUM(iis.qty_allocated), 0)) > 0
    ),
    grouped AS (
        SELECT
            consignment_shipment_item_id,
            product_id,
            unit_price,
            SUM(qty_open)::NUMERIC(14,3) AS qty_invoiced,
            ROUND(SUM(qty_open * unit_price)::NUMERIC, 2)::NUMERIC(14,2) AS amount
        FROM sales_pool
        GROUP BY consignment_shipment_item_id, product_id, unit_price
    ),
    inserted_items AS (
        INSERT INTO invoice_items (
            invoice_id,
            consignment_shipment_item_id,
            product_id,
            unit_price,
            qty_invoiced,
            amount
        )
        SELECT
            v_invoice_id,
            g.consignment_shipment_item_id,
            g.product_id,
            g.unit_price,
            g.qty_invoiced,
            g.amount
        FROM grouped g
        RETURNING id, consignment_shipment_item_id, unit_price
    )
    INSERT INTO invoice_item_sales (
        invoice_item_id,
        sale_id,
        qty_allocated,
        amount_allocated
    )
    SELECT
        ii.id,
        sp.sale_id,
        sp.qty_open,
        ROUND((sp.qty_open * sp.unit_price)::NUMERIC, 2)::NUMERIC(14,2)
    FROM sales_pool sp
    JOIN inserted_items ii
      ON ii.consignment_shipment_item_id = sp.consignment_shipment_item_id
     AND ii.unit_price = sp.unit_price;

    PERFORM refresh_invoice_totals(v_invoice_id);

    IF NOT EXISTS (SELECT 1 FROM invoice_items WHERE invoice_id = v_invoice_id) THEN
        RAISE EXCEPTION 'No sold_not_paid sales were found for store %', p_store_id;
    END IF;

    RETURN v_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION confirm_invoice_payment(
    p_invoice_id BIGINT,
    p_amount_paid NUMERIC(14,2),
    p_payment_method VARCHAR(32) DEFAULT NULL,
    p_note TEXT DEFAULT NULL,
    p_created_by BIGINT DEFAULT NULL,
    p_paid_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_invoice invoices%ROWTYPE;
    v_remaining NUMERIC(14,2);
    v_payment_id BIGINT;
    v_payment_number VARCHAR(64);
BEGIN
    IF p_amount_paid <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, got %', p_amount_paid;
    END IF;

    SELECT *
    INTO v_invoice
    FROM invoices
    WHERE id = p_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % not found', p_invoice_id;
    END IF;

    IF v_invoice.status NOT IN ('confirmed', 'partially_paid', 'draft') THEN
        RAISE EXCEPTION 'Invoice % in status % cannot accept payment', p_invoice_id, v_invoice.status;
    END IF;

    IF v_invoice.status = 'draft' THEN
        UPDATE invoices
        SET status = 'confirmed',
            confirmed_at = p_paid_at,
            confirmed_by = p_created_by
        WHERE id = p_invoice_id;
    END IF;

    PERFORM refresh_invoice_totals(p_invoice_id);

    SELECT subtotal_amount - paid_amount
    INTO v_remaining
    FROM invoices
    WHERE id = p_invoice_id;

    IF p_amount_paid > v_remaining THEN
        RAISE EXCEPTION 'Payment %.2f exceeds remaining invoice balance %.2f', p_amount_paid, v_remaining;
    END IF;

    v_payment_number := 'PAY-' || TO_CHAR(p_paid_at, 'YYYYMMDD') || '-' || LPAD(p_invoice_id::TEXT, 8, '0') || '-' || LPAD((COALESCE((SELECT COUNT(*) FROM invoice_payments WHERE invoice_id = p_invoice_id), 0) + 1)::TEXT, 3, '0');

    INSERT INTO invoice_payments (
        invoice_id,
        payment_number,
        amount_paid,
        paid_at,
        payment_method,
        note,
        created_by
    )
    VALUES (
        p_invoice_id,
        v_payment_number,
        p_amount_paid,
        p_paid_at,
        p_payment_method,
        p_note,
        p_created_by
    )
    RETURNING id INTO v_payment_id;

    WITH remaining_lines AS (
        SELECT
            ii.id AS invoice_item_id,
            ii.consignment_shipment_item_id,
            ii.product_id,
            ii.unit_price,
            ii.qty_invoiced,
            (ii.amount - COALESCE(SUM(ipi.amount_paid), 0))::NUMERIC(14,2) AS amount_open,
            (ii.qty_invoiced - COALESCE(SUM(ipi.qty_paid), 0))::NUMERIC(14,3) AS qty_open
        FROM invoice_items ii
        LEFT JOIN invoice_payment_items ipi ON ipi.invoice_item_id = ii.id
        WHERE ii.invoice_id = p_invoice_id
        GROUP BY ii.id
        HAVING (ii.amount - COALESCE(SUM(ipi.amount_paid), 0)) > 0
    ),
    weighted AS (
        SELECT
            rl.*,
            CASE WHEN (SELECT SUM(amount_open) FROM remaining_lines) = 0
                THEN 0
                ELSE (rl.amount_open / (SELECT SUM(amount_open) FROM remaining_lines))
            END AS ratio
        FROM remaining_lines rl
    ),
    base_allocation AS (
        SELECT
            w.invoice_item_id,
            w.consignment_shipment_item_id,
            w.product_id,
            LEAST(w.amount_open, ROUND((p_amount_paid * w.ratio)::NUMERIC, 2)::NUMERIC(14,2)) AS amount_allocated,
            LEAST(w.qty_open, ROUND((w.qty_open * w.ratio)::NUMERIC, 3)::NUMERIC(14,3)) AS qty_allocated
        FROM weighted w
    ),
    fixed_amounts AS (
        SELECT
            ba.invoice_item_id,
            ba.consignment_shipment_item_id,
            ba.product_id,
            ba.qty_allocated,
            CASE
                WHEN ROW_NUMBER() OVER (ORDER BY ba.invoice_item_id DESC) = 1
                THEN (p_amount_paid - COALESCE(SUM(ba.amount_allocated) OVER (ORDER BY ba.invoice_item_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))::NUMERIC(14,2)
                ELSE ba.amount_allocated
            END AS amount_allocated
        FROM base_allocation ba
    ),
    fixed_allocations AS (
        SELECT
            f.invoice_item_id,
            f.consignment_shipment_item_id,
            f.product_id,
            CASE
                WHEN ROW_NUMBER() OVER (ORDER BY f.invoice_item_id DESC) = 1
                THEN (
                    SELECT rl.qty_open
                    FROM remaining_lines rl
                    WHERE rl.invoice_item_id = f.invoice_item_id
                ) - COALESCE(SUM(f.qty_allocated) OVER (ORDER BY f.invoice_item_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                ELSE f.qty_allocated
            END::NUMERIC(14,3) AS qty_paid,
            f.amount_allocated
        FROM fixed_amounts f
        WHERE f.amount_allocated > 0
    )
    INSERT INTO invoice_payment_items (
        invoice_payment_id,
        invoice_item_id,
        qty_paid,
        amount_paid
    )
    SELECT
        v_payment_id,
        fa.invoice_item_id,
        LEAST(fa.qty_paid, (
            SELECT (ii.qty_invoiced - COALESCE(SUM(ipi.qty_paid), 0))::NUMERIC(14,3)
            FROM invoice_items ii
            LEFT JOIN invoice_payment_items ipi ON ipi.invoice_item_id = ii.id
            WHERE ii.id = fa.invoice_item_id
            GROUP BY ii.qty_invoiced
        )),
        fa.amount_allocated
    FROM fixed_allocations fa;

    INSERT INTO payments (
        consignment_shipment_item_id,
        qty_paid,
        amount_paid,
        paid_at,
        note
    )
    SELECT
        ii.consignment_shipment_item_id,
        SUM(ipi.qty_paid)::NUMERIC(14,3),
        SUM(ipi.amount_paid)::NUMERIC(14,2),
        p_paid_at,
        CONCAT('Invoice ', v_invoice.invoice_number, ', payment ', v_payment_number)
    FROM invoice_payment_items ipi
    JOIN invoice_items ii ON ii.id = ipi.invoice_item_id
    WHERE ipi.invoice_payment_id = v_payment_id
    GROUP BY ii.consignment_shipment_item_id;

    PERFORM global_inventory_apply_writeoff(
        src.product_id,
        src.qty_paid,
        'invoice_payment',
        v_payment_id,
        p_created_by
    )
    FROM (
        SELECT ii.product_id, SUM(ipi.qty_paid)::NUMERIC(14,3) AS qty_paid
        FROM invoice_payment_items ipi
        JOIN invoice_items ii ON ii.id = ipi.invoice_item_id
        WHERE ipi.invoice_payment_id = v_payment_id
        GROUP BY ii.product_id
    ) src;

    PERFORM refresh_invoice_totals(p_invoice_id);

    RETURN v_payment_id;
END;
$$;

COMMIT;
