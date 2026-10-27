<?php

namespace App\Reverb;

use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Log;
use Laravel\Reverb\Application;
use Laravel\Reverb\Contracts\ApplicationProvider;
use Laravel\Reverb\Exceptions\InvalidApplication;

/**
 * Reverb's apps, read from a JSON file on every lookup (design D16), so the gate adds and removes a QA
 * environment's app without a restart:
 *
 *   {"apps": [{"app_id": "shop-qa-12", "key": "shop-qa-12", "secret": "…", "allowed_origins": [...], …}]}
 *
 * The gate replaces the file whole, renaming a new one into place, so a lookup sees the old apps or the new
 * ones, never half of either. A missing file holds no apps, and so does one that cannot be read or parsed: the
 * error is logged once, and every connection is refused until the file is right again. An entry without a plain
 * id, key and secret is left out, and a setting it leaves out takes Reverb's default.
 */
class FileApplicationProvider implements ApplicationProvider
{
    private ?string $lastError = null;

    public function __construct(private readonly string $path)
    {
    }

    /**
     * @return Collection<int, Application>
     */
    public function all(): Collection
    {
        return collect($this->apps())->map(fn (array $app) => $this->application($app))->values();
    }

    public function findById(string $id): Application
    {
        return $this->find('app_id', $id);
    }

    public function findByKey(string $key): Application
    {
        return $this->find('key', $key);
    }

    private function find(string $field, string $value): Application
    {
        foreach ($this->apps() as $app) {
            if ($app[$field] === $value) {
                return $this->application($app);
            }
        }

        throw new InvalidApplication;
    }

    /**
     * @return list<array<string, mixed>>
     */
    private function apps(): array
    {
        if (! file_exists($this->path)) {
            return $this->read([]);
        }

        $json = @file_get_contents($this->path);
        if (! is_string($json)) {
            return $this->broken('cannot be read');
        }

        $data = json_decode($json, true);
        if (! is_array($data) || ! is_array($data['apps'] ?? null) || ! array_is_list($data['apps'])) {
            return $this->broken('is not {"apps": [...]} in JSON');
        }

        return $this->read(array_values(array_filter($data['apps'], fn (mixed $app) => $this->plain($app))));
    }

    private function plain(mixed $app): bool
    {
        if (! is_array($app)) {
            return false;
        }

        foreach (['app_id', 'key', 'secret'] as $field) {
            if (! is_string($app[$field] ?? null) || ! preg_match('/\A[A-Za-z0-9._-]{1,128}\z/', $app[$field])) {
                return false;
            }
        }

        return true;
    }

    /**
     * @param  array<string, mixed>  $app
     */
    private function application(array $app): Application
    {
        return new Application(
            $app['app_id'],
            $app['key'],
            $app['secret'],
            $this->positive($app, 'ping_interval', 60),
            $this->positive($app, 'activity_timeout', 30),
            array_values(array_filter((array) ($app['allowed_origins'] ?? []), 'is_string')),
            $this->positive($app, 'max_message_size', 10_000),
            is_int($app['max_connections'] ?? null) ? $app['max_connections'] : null,
            is_string($app['accept_client_events_from'] ?? null) ? $app['accept_client_events_from'] : 'members',
            is_array($app['rate_limiting'] ?? null) ? $app['rate_limiting'] : null,
            is_array($app['options'] ?? null) ? $app['options'] : [],
        );
    }

    /**
     * @param  array<string, mixed>  $app
     */
    private function positive(array $app, string $field, int $default): int
    {
        return is_int($app[$field] ?? null) && $app[$field] > 0 ? $app[$field] : $default;
    }

    /**
     * @param  list<array<string, mixed>>  $apps
     * @return list<array<string, mixed>>
     */
    private function read(array $apps): array
    {
        $this->lastError = null;

        return $apps;
    }

    /**
     * @return list<array<string, mixed>>
     */
    private function broken(string $why): array
    {
        if ($this->lastError !== $why) {
            $this->lastError = $why;
            Log::error("reverb-host: no apps, since {$this->path} {$why}");
        }

        return [];
    }
}
