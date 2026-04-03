-- Создать черновик инвойса для точки из продаж shipment-ов в статусе sold_not_paid.
-- Parameters:
-- :store_id (required)
-- :created_by (nullable)
SELECT create_invoice_for_store(:store_id, :created_by, NOW()) AS invoice_id;

-- Просмотр инвойса (шапка + строки) для экрана и экспорта.
-- Parameters:
-- :invoice_id (required)
SELECT
    i.id,
    i.invoice_number,
    i.status,
    i.issued_at,
    i.confirmed_at,
    i.store_id,
    st.name AS store_name,
    i.subtotal_amount,
    i.paid_amount,
    (i.subtotal_amount - i.paid_amount) AS due_amount,
    i.currency,
    ii.id AS invoice_item_id,
    ii.product_id,
    p.sku,
    p.name AS product_name,
    ii.unit_price,
    ii.qty_invoiced,
    ii.amount
FROM invoices i
JOIN stores st ON st.id = i.store_id
JOIN invoice_items ii ON ii.invoice_id = i.id
JOIN products p ON p.id = ii.product_id
WHERE i.id = :invoice_id
ORDER BY ii.id;

-- Подтверждение инвойса и создание оплаты (полной/частичной) с пропорциональным закрытием строк.
-- Parameters:
-- :invoice_id (required)
-- :amount_paid (required)
-- :payment_method (nullable)
-- :note (nullable)
-- :created_by (nullable)
SELECT confirm_invoice_payment(
    :invoice_id,
    :amount_paid,
    :payment_method,
    :note,
    :created_by,
    NOW()
) AS invoice_payment_id;

-- Реестр платежей по инвойсу.
-- Parameters:
-- :invoice_id (required)
SELECT
    ip.id,
    ip.payment_number,
    ip.amount_paid,
    ip.payment_method,
    ip.paid_at,
    ip.note
FROM invoice_payments ip
WHERE ip.invoice_id = :invoice_id
ORDER BY ip.paid_at DESC, ip.id DESC;

-- Журнал экспортов PDF/XLSX.
-- Parameters:
-- :invoice_id (required)
SELECT
    ie.id,
    ie.export_type,
    ie.file_path,
    ie.status,
    ie.exported_at,
    ie.exported_by
FROM invoice_exports ie
WHERE ie.invoice_id = :invoice_id
ORDER BY ie.exported_at DESC, ie.id DESC;

-- Журнал отправок инвойса.
-- Parameters:
-- :invoice_id (required)
SELECT
    isl.id,
    isl.channel,
    isl.recipient,
    isl.status,
    isl.provider_message_id,
    isl.error_message,
    isl.sent_at,
    isl.sent_by
FROM invoice_send_log isl
WHERE isl.invoice_id = :invoice_id
ORDER BY isl.sent_at DESC, isl.id DESC;
