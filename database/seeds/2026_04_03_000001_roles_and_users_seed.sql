BEGIN;

INSERT INTO roles (code, name)
VALUES
    ('admin', 'Администратор'),
    ('supplier', 'Поставщик'),
    ('store', 'Точка сбыта')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name;

INSERT INTO users (login, password_hash, is_active)
VALUES
    ('admin', '$2y$12$oTxt9wE/CQ79940ZWSM1V.Z9RsHfW/LblI1RMTjJhx9kivz.sE2WO', TRUE),
    ('supplier_demo', '$2y$12$2dCFZ4nfaSDdAjKMyWqgtO1WOvpmmtFkv43ZMDH/eXt3L3Svv02Da', TRUE),
    ('store_demo', '$2y$12$qoBmHlsfMWMAAmhOMVeeWuiZ0cPOll8bzkJjTFLJNzeHlQGkIJoHO', TRUE)
ON CONFLICT (login) DO UPDATE SET
    password_hash = EXCLUDED.password_hash,
    is_active = EXCLUDED.is_active;

INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN roles r ON
    (u.login = 'admin' AND r.code = 'admin') OR
    (u.login = 'supplier_demo' AND r.code = 'supplier') OR
    (u.login = 'store_demo' AND r.code = 'store')
ON CONFLICT (user_id, role_id) DO NOTHING;

INSERT INTO suppliers (user_id, legal_name, inn, phone)
SELECT u.id, 'ООО Демо Поставщик', '7700000000', '+7-900-000-00-01'
FROM users u
WHERE u.login = 'supplier_demo'
ON CONFLICT (user_id) DO UPDATE SET
    legal_name = EXCLUDED.legal_name,
    inn = EXCLUDED.inn,
    phone = EXCLUDED.phone;

INSERT INTO stores (user_id, name, address)
SELECT u.id, 'Магазин Демо', 'г. Москва, ул. Тестовая, д. 1'
FROM users u
WHERE u.login = 'store_demo'
ON CONFLICT (user_id) DO UPDATE SET
    name = EXCLUDED.name,
    address = EXCLUDED.address;

COMMIT;
