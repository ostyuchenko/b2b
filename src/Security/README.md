# RBAC guard

`RbacGuard` реализует правила доступа:

- `admin` видит всё;
- `supplier` видит только свои поставки/цены (`suppliers.user_id = auth_user.user_id`);
- `store` видит только свои товары/остатки/продажи (`stores.user_id = auth_user.user_id`).

## Пример использования

```php
$guard = new RbacGuard();
$scope = $guard->supplierScope($authUser);

$sql = "
    SELECT s.*
    FROM supplies s
    JOIN suppliers ON suppliers.id = s.supplier_id
    WHERE {$scope['condition']}
";

$stmt = $pdo->prepare($sql);
$stmt->execute($scope['params']);
```

`RbacMiddlewareExample` показывает, как подвесить проверку на HTTP-слой (PSR-15).
