-- Admin inventory ledger filters for product/store/period/operation type.
-- Parameters:
-- :product_id (nullable)
-- :store_id (nullable)
-- :date_from (nullable, timestamptz)
-- :date_to (nullable, timestamptz)
-- :operation_type (nullable)
SELECT
    il.id,
    il.created_at,
    il.operation_type,
    il.product_id,
    p.name AS product_name,
    il.store_id,
    st.name AS store_name,
    il.supplier_id,
    s.legal_name AS supplier_name,
    il.qty_delta,
    il.balance_after,
    il.ref_type,
    il.ref_id,
    il.created_by
FROM inventory_ledger il
JOIN products p ON p.id = il.product_id
LEFT JOIN stores st ON st.id = il.store_id
LEFT JOIN suppliers s ON s.id = il.supplier_id
WHERE (:product_id IS NULL OR il.product_id = :product_id)
  AND (:store_id IS NULL OR il.store_id = :store_id)
  AND (:operation_type IS NULL OR il.operation_type = :operation_type)
  AND (:date_from IS NULL OR il.created_at >= :date_from)
  AND (:date_to IS NULL OR il.created_at < :date_to)
ORDER BY il.created_at DESC, il.id DESC;

-- Price history view with optional filters by product, store, supplier, period.
-- Parameters:
-- :product_id (nullable)
-- :store_id (nullable)
-- :supplier_id (nullable)
-- :date_from (nullable, timestamptz)
-- :date_to (nullable, timestamptz)
SELECT
    pcl.id,
    pcl.changed_at,
    pcl.product_id,
    p.name AS product_name,
    pcl.store_id,
    st.name AS store_name,
    pcl.supplier_id,
    s.legal_name AS supplier_name,
    pcl.old_price,
    pcl.new_price,
    pcl.currency,
    pcl.source_table,
    pcl.source_id,
    pcl.changed_by
FROM price_change_log pcl
JOIN products p ON p.id = pcl.product_id
LEFT JOIN stores st ON st.id = pcl.store_id
LEFT JOIN suppliers s ON s.id = pcl.supplier_id
WHERE (:product_id IS NULL OR pcl.product_id = :product_id)
  AND (:store_id IS NULL OR pcl.store_id = :store_id)
  AND (:supplier_id IS NULL OR pcl.supplier_id = :supplier_id)
  AND (:date_from IS NULL OR pcl.changed_at >= :date_from)
  AND (:date_to IS NULL OR pcl.changed_at < :date_to)
ORDER BY pcl.changed_at DESC, pcl.id DESC;
