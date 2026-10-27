<?php

namespace App\Providers;

use App\Reverb\FileApplicationProvider;
use Illuminate\Support\ServiceProvider;
use Laravel\Reverb\ApplicationManager;
use RuntimeException;

/**
 * Gives Reverb's application manager the file driver that config/reverb.php names (design D16).
 */
class HostServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        $this->app->make(ApplicationManager::class)->extend('file', function ($app) {
            $path = $app['config']['reverb.apps.file'];
            if (! is_string($path) || ! str_starts_with($path, '/')) {
                throw new RuntimeException('reverb-host needs the absolute path of its apps file (REVERB_HOST_APPS)');
            }

            return new FileApplicationProvider($path);
        });
    }
}
