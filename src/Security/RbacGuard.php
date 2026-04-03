<?php

declare(strict_types=1);

namespace App\Security;

use RuntimeException;

final class RbacGuard
{
    /**
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     */
    public function assertCanViewSupplierData(array $authUser, int $supplierUserId): void
    {
        $this->assertActive($authUser);

        if ($this->isAdmin($authUser)) {
            return;
        }

        if ($this->hasRole($authUser, 'supplier') && $authUser['user_id'] === $supplierUserId) {
            return;
        }

        throw new RuntimeException('Доступ к данным поставщика запрещен.');
    }

    /**
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     */
    public function assertCanViewStoreData(array $authUser, int $storeUserId): void
    {
        $this->assertActive($authUser);

        if ($this->isAdmin($authUser)) {
            return;
        }

        if ($this->hasRole($authUser, 'store') && $authUser['user_id'] === $storeUserId) {
            return;
        }

        throw new RuntimeException('Доступ к данным точки сбыта запрещен.');
    }

    /**
     * Возвращает SQL-условие для ограничения выборки поставок/цен.
     *
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     * @return array{condition:string,params:array<string,int>}
     */
    public function supplierScope(array $authUser): array
    {
        $this->assertActive($authUser);

        if ($this->isAdmin($authUser)) {
            return ['condition' => '1=1', 'params' => []];
        }

        if ($this->hasRole($authUser, 'supplier')) {
            return [
                'condition' => 'suppliers.user_id = :supplier_user_id',
                'params' => ['supplier_user_id' => $authUser['user_id']],
            ];
        }

        throw new RuntimeException('Недостаточно прав для просмотра поставок и цен.');
    }

    /**
     * Возвращает SQL-условие для ограничения выборки товаров/остатков/продаж.
     *
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     * @return array{condition:string,params:array<string,int>}
     */
    public function storeScope(array $authUser): array
    {
        $this->assertActive($authUser);

        if ($this->isAdmin($authUser)) {
            return ['condition' => '1=1', 'params' => []];
        }

        if ($this->hasRole($authUser, 'store')) {
            return [
                'condition' => 'stores.user_id = :store_user_id',
                'params' => ['store_user_id' => $authUser['user_id']],
            ];
        }

        throw new RuntimeException('Недостаточно прав для просмотра данных точки.');
    }

    /**
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     */
    private function isAdmin(array $authUser): bool
    {
        return $this->hasRole($authUser, 'admin');
    }

    /**
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     */
    private function hasRole(array $authUser, string $roleCode): bool
    {
        return in_array($roleCode, $authUser['roles'], true);
    }

    /**
     * @param array{user_id:int,is_active:bool,roles:string[]} $authUser
     */
    private function assertActive(array $authUser): void
    {
        if ($authUser['is_active'] === false) {
            throw new RuntimeException('Пользователь деактивирован.');
        }
    }
}
