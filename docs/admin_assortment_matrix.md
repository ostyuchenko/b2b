# Экран админа: «Матрица ассортимента»

## Что должно делать

4) На экране для выбранной точки (`store_id`) администратор может:
- включать/выключать товар (`is_enabled`),
- задавать цену реализации (`sale_price_uah`).

## Минимальный UX

- Фильтр по точке продаж.
- Таблица товаров: SKU, Название, Статус (вкл/выкл), Цена реализации, Дата обновления.
- Массовое действие: включить/выключить выбранные.
- Быстрое редактирование цены в строке.
- Сохранение батчем.

## Рекомендуемые API для экрана

### Получить матрицу точки
`GET /api/admin/stores/{storeId}/assortment-matrix?search=&page=&limit=`

Ответ (пример):
```json
{
  "items": [
    {
      "product_id": 101,
      "sku": "ABC-001",
      "name": "Товар 1",
      "is_enabled": true,
      "sale_price_uah": 199.00,
      "updated_at": "2026-04-03T10:00:00Z"
    }
  ],
  "total": 1
}
```

### Массово обновить доступ/цену
`PUT /api/admin/stores/{storeId}/assortment-matrix`

Тело:
```json
{
  "items": [
    { "product_id": 101, "is_enabled": true, "sale_price_uah": 199.00 },
    { "product_id": 102, "is_enabled": false, "sale_price_uah": null }
  ]
}
```

## SQL для обновления батчем (пример)

```sql
INSERT INTO store_product_access (store_id, product_id, is_enabled, sale_price_uah, updated_at)
VALUES (:store_id, :product_id, :is_enabled, :sale_price_uah, NOW())
ON CONFLICT (store_id, product_id)
DO UPDATE SET
    is_enabled = EXCLUDED.is_enabled,
    sale_price_uah = EXCLUDED.sale_price_uah,
    updated_at = NOW();
```
