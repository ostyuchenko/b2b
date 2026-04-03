-- 5) API-level filtering: return only enabled products for requested store.
-- Example query for /api/stores/:storeId/catalog endpoint.
SELECT
    p.id,
    p.sku,
    p.name,
    spa.sale_price_uah
FROM products p
JOIN store_product_access spa
    ON spa.product_id = p.id
WHERE spa.store_id = :store_id
  AND spa.is_enabled = TRUE
  AND p.is_active = TRUE
ORDER BY p.name ASC;
