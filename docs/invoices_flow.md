# Инвойсы: формирование, подтверждение, экспорт и журнал отправок

## Что добавлено

- Таблицы:
  - `invoices`, `invoice_items`, `invoice_item_sales`
  - `invoice_payments`, `invoice_payment_items`
  - `invoice_exports`, `invoice_send_log`
  - `global_inventory_stock`, `global_inventory_ledger`
- Функции:
  - `next_invoice_number()` — номер по маске `INV-YYYYMM-####`
  - `create_invoice_for_store()` — собрать все `sales` по точке из shipment-ов `sold_not_paid`
  - `confirm_invoice_payment()` — подтверждение/частичная оплата инвойса
  - `global_inventory_apply_writeoff()` — списание глобального остатка по оплаченной части

## Бизнес-логика

### 1) Кнопка «Сформировать инвойс»

В UI для точки выполняется `create_invoice_for_store(store_id, created_by)`:

- берутся только продажи (`sales`) по отгрузкам точки (`consignment_shipments.store_id`),
- учитываются только отгрузки со статусом `sold_not_paid`,
- исключаются уже аллоцированные в другие инвойсы части продаж,
- строки инвойса агрегируются по `consignment_shipment_item_id + product_id + unit_price`,
- считаются `qty_invoiced` и `amount`.

### 2) Нумерация документа

`next_invoice_number()` формирует номер вида:

- `INV-202604-0001`
- `INV-202604-0002`

Счётчик инкрементируется внутри месяца (`YYYYMM`).

### 3) Подтверждение и оплата

`confirm_invoice_payment(invoice_id, amount_paid, ...)`:

- переводит `draft` в `confirmed` (при первом платеже),
- создаёт запись в `invoice_payments`,
- пропорционально распределяет оплату по открытым строкам в `invoice_payment_items`,
- создаёт агрегированные записи в `payments` (что закрывает `qty_sold_unpaid` через существующий триггер),
- списывает глобальный остаток по оплаченному количеству (`global_inventory_apply_writeoff`),
- обновляет статусы инвойса: `confirmed` / `partially_paid` / `paid`.

### 4) Экспорт PDF/Excel и журнал отправок

- Экспорт хранится в `invoice_exports` (`export_type = pdf|xlsx`, путь к файлу, статус).
- Отправки фиксируются в `invoice_send_log` (канал, получатель, статус, ошибка/ID провайдера).

## Готовые SQL-запросы

См. `api/invoice_queries.sql`:

- формирование инвойса,
- получение данных для PDF/Excel,
- подтверждение оплаты,
- журнал экспортов,
- журнал отправок.
