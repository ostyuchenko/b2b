#!/usr/bin/env php
<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use PhpOffice\PhpSpreadsheet\IOFactory;
use PhpOffice\PhpSpreadsheet\Worksheet\Worksheet;

final class ReconciliationImporter
{
    private PDO $pdo;

    /** @var array<int, string> */
    private array $errors = [];

    private int $createdProducts = 0;
    private int $updatedProducts = 0;

    public function __construct(PDO $pdo)
    {
        $this->pdo = $pdo;
    }

    /**
     * @param array<string, mixed> $options
     */
    public function import(array $options): void
    {
        $files = [
            'internal' => (string) $options['internal-file'],
            'external' => (string) $options['external-file'],
        ];

        $effectiveDate = (string) ($options['effective-date'] ?? date('Y-m-d'));
        $supplierId = (int) $options['supplier-id'];

        $this->pdo->beginTransaction();

        try {
            foreach ($files as $sourceType => $filePath) {
                $rows = $this->readRows($filePath, $sourceType);
                $seenSkus = [];

                foreach ($rows as $rowNumber => $row) {
                    $sku = trim((string) ($row['sku'] ?? ''));
                    $name = trim((string) ($row['name'] ?? ''));
                    $qty = $this->toNullableFloat($row['qty'] ?? null);
                    $priceUsd = $this->toNullableFloat($row['price_usd'] ?? null);
                    $priceUah = $this->toNullableFloat($row['price_uah'] ?? null);
                    $fxRate = $this->toNullableFloat($row['fx_rate'] ?? null);

                    if ($sku === '') {
                        $this->errors[] = sprintf('[%s][row:%d] Пропущен SKU.', $sourceType, $rowNumber);
                        continue;
                    }

                    if (isset($seenSkus[$sku])) {
                        $this->errors[] = sprintf('[%s][row:%d] Дубликат SKU "%s".', $sourceType, $rowNumber, $sku);
                        continue;
                    }
                    $seenSkus[$sku] = true;

                    if ($name === '' || $qty === null || $priceUsd === null || $priceUah === null || $fxRate === null) {
                        $this->errors[] = sprintf('[%s][row:%d] Пустые обязательные поля для SKU "%s".', $sourceType, $rowNumber, $sku);
                        continue;
                    }

                    $productId = $this->upsertProduct($sku, $name);
                    $this->upsertInitialStock($productId, $sourceType, $qty, basename($filePath));
                    $this->upsertSupplierPrice($productId, $supplierId, $priceUsd, $priceUah, $fxRate, $effectiveDate);
                }
            }

            $this->pdo->commit();
        } catch (Throwable $e) {
            $this->pdo->rollBack();
            throw $e;
        }

        $this->printReport();
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function readRows(string $filePath, string $sourceType): array
    {
        if (!is_file($filePath)) {
            throw new RuntimeException(sprintf('Файл не найден: %s', $filePath));
        }

        $spreadsheet = IOFactory::load($filePath);
        $sheet = $spreadsheet->getSheet(0);

        [$headerRow, $mapping] = $this->detectHeader($sheet);

        $rows = [];
        $lastRow = $sheet->getHighestDataRow();
        for ($row = $headerRow + 1; $row <= $lastRow; $row++) {
            $item = [];
            $empty = true;
            foreach ($mapping as $column => $field) {
                $value = $sheet->getCell($column . $row)->getValue();
                if ($value !== null && trim((string) $value) !== '') {
                    $empty = false;
                }
                $item[$field] = $value;
            }

            if ($empty) {
                continue;
            }

            $rows[$row] = $item;
        }

        if ($rows === []) {
            $this->errors[] = sprintf('[%s] Не найдено строк данных в файле %s.', $sourceType, $filePath);
        }

        return $rows;
    }

    /**
     * @return array{0:int,1:array<string,string>}
     */
    private function detectHeader(Worksheet $sheet): array
    {
        $required = [
            'sku' => ['артикул'],
            'name' => ['товари', 'товар', 'наименование'],
            'qty' => ['кількість', 'количество'],
            'price_usd' => ['цiна usd', 'ціна usd', 'цена usd'],
            'price_uah' => ['цiна uah', 'ціна uah', 'цена uah'],
            'fx_rate' => ['курс'],
        ];

        $maxHeaderScanRows = min(25, $sheet->getHighestDataRow());
        $maxColumns = \PhpOffice\PhpSpreadsheet\Cell\Coordinate::columnIndexFromString($sheet->getHighestDataColumn());

        for ($row = 1; $row <= $maxHeaderScanRows; $row++) {
            $columnToHeader = [];
            for ($col = 1; $col <= $maxColumns; $col++) {
                $columnName = \PhpOffice\PhpSpreadsheet\Cell\Coordinate::stringFromColumnIndex($col);
                $value = $sheet->getCell($columnName . $row)->getValue();
                $norm = $this->normalizeHeader((string) $value);
                if ($norm !== '') {
                    $columnToHeader[$columnName] = $norm;
                }
            }

            $mapping = [];
            foreach ($required as $field => $variants) {
                foreach ($columnToHeader as $columnName => $header) {
                    if (in_array($header, $variants, true)) {
                        $mapping[$columnName] = $field;
                        break;
                    }
                }
            }

            if (count(array_unique($mapping)) === count($required)) {
                return [$row, $mapping];
            }
        }

        throw new RuntimeException('Не удалось найти строку заголовков с нужными колонками.');
    }

    private function normalizeHeader(string $value): string
    {
        $value = mb_strtolower(trim($value));
        $value = preg_replace('/\s+/', ' ', $value);

        return (string) $value;
    }

    private function toNullableFloat(mixed $value): ?float
    {
        if ($value === null) {
            return null;
        }

        $value = trim((string) $value);
        if ($value === '') {
            return null;
        }

        $value = str_replace(' ', '', $value);
        $value = str_replace(',', '.', $value);

        if (!is_numeric($value)) {
            return null;
        }

        return (float) $value;
    }

    private function upsertProduct(string $sku, string $name): int
    {
        $stmt = $this->pdo->prepare('SELECT id, name FROM products WHERE sku = :sku');
        $stmt->execute(['sku' => $sku]);
        $existing = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($existing === false) {
            $insert = $this->pdo->prepare(
                'INSERT INTO products (sku, name, created_at, updated_at) VALUES (:sku, :name, NOW(), NOW()) RETURNING id'
            );
            $insert->execute(['sku' => $sku, 'name' => $name]);
            $this->createdProducts++;

            return (int) $insert->fetchColumn();
        }

        $productId = (int) $existing['id'];
        if ((string) $existing['name'] !== $name) {
            $update = $this->pdo->prepare('UPDATE products SET name = :name, updated_at = NOW() WHERE id = :id');
            $update->execute(['name' => $name, 'id' => $productId]);
            $this->updatedProducts++;
        }

        return $productId;
    }

    private function upsertInitialStock(int $productId, string $sourceType, float $qty, string $importFile): void
    {
        $stmt = $this->pdo->prepare(
            'INSERT INTO product_initial_stocks (product_id, source_type, qty, import_file, imported_at)
             VALUES (:product_id, :source_type, :qty, :import_file, NOW())
             ON CONFLICT (product_id, source_type)
             DO UPDATE SET qty = EXCLUDED.qty, import_file = EXCLUDED.import_file, imported_at = NOW()'
        );

        $stmt->execute([
            'product_id' => $productId,
            'source_type' => $sourceType,
            'qty' => $qty,
            'import_file' => $importFile,
        ]);
    }

    private function upsertSupplierPrice(
        int $productId,
        int $supplierId,
        float $priceUsd,
        float $priceUah,
        float $fxRate,
        string $effectiveDate
    ): void {
        $stmt = $this->pdo->prepare(
            'INSERT INTO supplier_product_prices (
                supplier_id,
                product_id,
                purchase_price_usd,
                purchase_price_uah,
                fx_rate,
                effective_from,
                created_at
            ) VALUES (
                :supplier_id,
                :product_id,
                :purchase_price_usd,
                :purchase_price_uah,
                :fx_rate,
                :effective_from,
                NOW()
            )
            ON CONFLICT (supplier_id, product_id, effective_from)
            DO UPDATE SET
                purchase_price_usd = EXCLUDED.purchase_price_usd,
                purchase_price_uah = EXCLUDED.purchase_price_uah,
                fx_rate = EXCLUDED.fx_rate'
        );

        $stmt->execute([
            'supplier_id' => $supplierId,
            'product_id' => $productId,
            'purchase_price_usd' => $priceUsd,
            'purchase_price_uah' => $priceUah,
            'fx_rate' => $fxRate,
            'effective_from' => $effectiveDate,
        ]);
    }

    private function printReport(): void
    {
        echo "\n=== Отчёт импорта ===\n";
        echo 'Создано товаров: ' . $this->createdProducts . "\n";
        echo 'Обновлено товаров: ' . $this->updatedProducts . "\n";
        echo 'Ошибок: ' . count($this->errors) . "\n";

        if ($this->errors !== []) {
            echo "\n--- Ошибки/предупреждения ---\n";
            foreach ($this->errors as $error) {
                echo '- ' . $error . "\n";
            }
        }
    }
}

$options = getopt('', [
    'dsn:',
    'db-user:',
    'db-pass::',
    'supplier-id:',
    'internal-file::',
    'external-file::',
    'effective-date::',
]);

$required = ['dsn', 'db-user', 'supplier-id'];
foreach ($required as $key) {
    if (!isset($options[$key]) || trim((string) $options[$key]) === '') {
        fwrite(STDERR, "Не указан обязательный параметр --{$key}\n");
        exit(1);
    }
}

$defaultInternal = __DIR__ . '/../База сверки - внутренняя.xlsx';
$defaultExternal = __DIR__ . '/../База сверки внешняя.xlsx';
$options['internal-file'] = $options['internal-file'] ?? $defaultInternal;
$options['external-file'] = $options['external-file'] ?? $defaultExternal;

try {
    $pdo = new PDO(
        (string) $options['dsn'],
        (string) $options['db-user'],
        (string) ($options['db-pass'] ?? ''),
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]
    );

    (new ReconciliationImporter($pdo))->import($options);
} catch (Throwable $e) {
    fwrite(STDERR, 'Ошибка импорта: ' . $e->getMessage() . "\n");
    exit(1);
}
