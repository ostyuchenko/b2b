# Админка: журнал остатков и фильтры

Добавлен журнал движений остатков `inventory_ledger` и история цен `price_change_log`.

## Фильтры в админке

Для экрана журнала остатков используются фильтры:
- `product_id` (товар),
- `store_id` (точка),
- период (`date_from`, `date_to`),
- `operation_type` (`receipt`, `shipment`, `sale`, `payment_close`, `manual_adjustment`).

Готовый SQL для бэкенда находится в `api/admin_inventory_queries.sql`.

## Правило сервисного слоя

Любое изменение количественных остатков в `consignment_shipment_items` проводится через
`inventory_apply_operation(...)`.

Прямые обновления `qty_shipped`, `qty_on_consignment`, `qty_sold_unpaid`,
`qty_paid_and_closed` блокируются триггером `trg_consignment_items_require_service`.
