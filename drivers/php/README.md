# `maludb/client` — PHP driver for MaluDB

PHP 8.2+ client for the maludb_core extension. Mirrors the
[Python](../python/README.md) and [Node.js](../nodejs/README.md)
drivers in shape and method names.

Status: **alpha**. v0.1.0 covers the headline read/write surface;
streaming, pool retrieval, and the workflow-extraction helpers land
in later versions.

## Requirements

| | |
|---|---|
| PHP | >= 8.2 |
| Extensions | `ext-pdo`, `ext-pdo_pgsql`, `ext-json` |
| PostgreSQL | maludb_core 0.41.0+ installed in the target DB |

On Ubuntu 24.04, install PHP, the PostgreSQL PDO driver, the PostgreSQL
client, and `unzip` so Composer can extract package archives:

```bash
sudo apt install php-cli php-pgsql postgresql-client unzip
```

Composer is needed for the autoload + dev deps:

```bash
# If composer isn't installed, install it system-wide:
curl -sS https://getcomposer.org/installer -o composer-setup.php
php composer-setup.php
sudo mv composer.phar /usr/local/bin/composer
rm composer-setup.php
composer --version
```

If you do not have sudo access, install Composer for your user instead:

```bash
mkdir -p "$HOME/.local/bin"
curl -sS https://getcomposer.org/installer | php -- --install-dir="$HOME/.local/bin" --filename=composer
"$HOME/.local/bin/composer" --version
```

If the user-local `composer` command is not found in a new shell, add
`$HOME/.local/bin` to your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
. ~/.profile
```

## Install

Install the published package from Packagist:

```bash
cd /path/to/your/php-project
composer require maludb/client:^0.1
```

No path-repository override is needed for normal application use.

If your web document root is a subdirectory of the Composer project, require
the autoloader relative to that layout. For example, if Composer was run in
`/var/www` and the script is `/var/www/html/index.php`, use
`require __DIR__ . '/../vendor/autoload.php';`.

Use this source tree only when developing the driver itself or running its
examples and tests:

```bash
git clone https://github.com/maludb/maludb-core.git
cd maludb-core/drivers/php
composer install
```

## Database setup

Create a database and user on the PostgreSQL/MaluDB server:

```bash
sudo -u postgres createuser --pwprompt zozocal
sudo -u postgres createdb -O zozocal zozocal
sudo -u postgres psql -d zozocal -c 'CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;'
```

Allow the client host in the server's `pg_hba.conf`. For example, to allow
client `192.168.100.157` to connect as user `zozocal` to database `zozocal`:

```conf
host    zozocal     zozocal     192.168.100.157/32     scram-sha-256
```

Reload PostgreSQL after editing `pg_hba.conf`:

```bash
sudo systemctl reload postgresql
```

Verify the connection from the client before testing PHP:

```bash
PGPASSWORD='your_password' psql \
  -h 192.168.100.163 \
  -p 5432 \
  -U zozocal \
  -d zozocal \
  -c 'select current_user, current_database();'
```

## Quickstart

```php
<?php
declare(strict_types=1);

require __DIR__ . '/vendor/autoload.php';

use MaluDB\Client;

// Use a PDO PostgreSQL DSN and pass credentials separately. This avoids
// URL-encoding surprises when passwords contain special characters.
$client = Client::fromDsn(
    'pgsql:host=192.168.100.163;port=5432;dbname=zozocal;sslmode=disable',
    'zozocal',
    'your_password',
);

$sp = $client->registerSourcePackage(
    sourceType: 'log',
    contentText: 'oncall: 14:22Z api-gateway 5xx burst',
    originJsonb: ['uri' => 'log://oncall/2026-05-13'],
);

$c1 = $client->registerClaim(
    subject: 'api_gateway',
    verb: 'observed',
    objectValue: '5xx_burst',
    statementText: 'Initial 5xx surge at 14:22Z',
    sourcePackageId: $sp,
);

foreach ($client->retrieve('api_gateway', null, null, null, null, null, 10) as $hit) {
    echo "$hit->objectType {$hit->objectId} {$hit->rank}\n";
}
```

For a local PostgreSQL server using the default Unix socket, the DSN can be:

```php
$client = Client::fromDsn(
    'pgsql:host=/var/run/postgresql;dbname=zozocal',
    'zozocal',
    'your_password',
);
```

## Troubleshooting web 500s

If a browser only shows HTTP 500, check the web server error log first:

```bash
sudo tail -n 100 /var/log/apache2/error.log
```

For temporary debugging, add this at the top of the PHP script:

```php
ini_set('display_errors', '1');
ini_set('display_startup_errors', '1');
error_reporting(E_ALL);
```

A missing autoloader means Composer was run in a different directory than the
script expects. Use an absolute `__DIR__`-based path, such as:

```php
require __DIR__ . '/../vendor/autoload.php';
```

If `psql` connects but PHP still fails authentication, test PDO directly with
the same DSN, user, and password:

```php
<?php
ini_set('display_errors', '1');
error_reporting(E_ALL);

$pdo = new PDO(
    'pgsql:host=192.168.100.163;port=5432;dbname=zozocal;sslmode=disable',
    'zozocal',
    'your_password',
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);

echo $pdo->query('select current_user')->fetchColumn() . PHP_EOL;
```

## Available methods

| Group | Methods |
|---|---|
| Ingest | `registerSourcePackage`, `registerClaim`, `registerFact`, `registerMemory`, `registerEpisode` |
| Retrieve | `textSearch`, `retrieve`, `replayEpisode` |
| Pool | `createPool`, `poolAddObservation`, `poolPromoteToClaim` |
| Skill | `registerSkill`, `addSkillState`, `addSkillTransition`, `beginSkillExecution`, `stepSkillExecution`, `abortSkillExecution` |
| Node | `registerLocalNode`, `nodeSubmit`, `nodeAccept`, `nodeReject`, `revokeLocalNode` |
| Misc | `version()`, `raw` (the underlying `PDO` instance) |

## Exception hierarchy

```
MaluDBError
├── MaluDBNotFound                       (P0002 / 02000)
├── MaluDBInvalidParameter               (22023 / 22P02)
├── MaluDBObjectNotInPrerequisiteState   (55000)
├── MaluDBCheckViolation                 (23514)
└── MaluDBPermissionDenied               (42501)
```

`catch (MaluDBNotFound $e) { … }`. All classes live in
`MaluDB\Exceptions\`.

## Running tests

```bash
cd drivers/php
composer install
MALUDB_TEST_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
    vendor/bin/phpunit
```
