# Импорт базы сверки из Excel

Добавлена CLI-команда `scripts/import_reconciliation.php` для загрузки двух Excel-файлов:

- `База сверки - внутренняя.xlsx`;
- `База сверки внешняя.xlsx`.

## Зависимости

```bash
composer install
```

Используется библиотека `phpoffice/phpspreadsheet`.

## Маппинг колонок

- `Артикул` -> `products.sku`
- `Товари` -> `products.name`
- `Кількість` -> `product_initial_stocks.qty` (стартовые остатки)
- `Цiна USD` -> `supplier_product_prices.purchase_price_usd`
- `Цiна UAH` -> `supplier_product_prices.purchase_price_uah`
- `Курс` -> `supplier_product_prices.fx_rate`

## Запуск

```bash
php scripts/import_reconciliation.php \
  --dsn="pgsql:host=127.0.0.1;port=5432;dbname=b2b" \
  --db-user="postgres" \
  --db-pass="postgres" \
  --supplier-id=1 \
  --effective-date="2026-04-03"
```

Пути к файлам можно переопределить:

- `--internal-file=/path/to/internal.xlsx`
- `--external-file=/path/to/external.xlsx`

## Логирование ошибок при импорте

Во время обработки строк логируются:

- строки с отсутствующим SKU;
- строки с дубликатами SKU в пределах файла;
- строки с пустыми обязательными значениями.

## Отчёт

После импорта команда печатает:

- сколько товаров создано;
- сколько товаров обновлено;
- сколько ошибок найдено.
