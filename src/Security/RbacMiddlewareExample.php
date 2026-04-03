<?php

declare(strict_types=1);

namespace App\Security;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;
use RuntimeException;

/**
 * Пример PSR-15 middleware, использующего RbacGuard.
 *
 * Ожидается, что в request-атрибуте `auth_user` лежит массив:
 * ['user_id' => int, 'is_active' => bool, 'roles' => string[]]
 */
final class RbacMiddlewareExample implements MiddlewareInterface
{
    public function __construct(
        private readonly RbacGuard $guard,
        private readonly string $resourceType,
        private readonly string $routeUserIdAttribute
    ) {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        /** @var array{user_id:int,is_active:bool,roles:string[]}|null $authUser */
        $authUser = $request->getAttribute('auth_user');

        if ($authUser === null) {
            throw new RuntimeException('Пользователь не аутентифицирован.');
        }

        $ownerUserId = (int) $request->getAttribute($this->routeUserIdAttribute);

        if ($this->resourceType === 'supplier') {
            $this->guard->assertCanViewSupplierData($authUser, $ownerUserId);
        }

        if ($this->resourceType === 'store') {
            $this->guard->assertCanViewStoreData($authUser, $ownerUserId);
        }

        return $handler->handle($request);
    }
}
