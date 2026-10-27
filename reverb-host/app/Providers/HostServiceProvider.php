<?php

namespace App\Providers;

use App\Reverb\FileApplicationProvider;
use App\Reverb\HostServer;
use Illuminate\Support\ServiceProvider;
use Laravel\Reverb\ApplicationManager;
use Laravel\Reverb\Contracts\Logger;
use Laravel\Reverb\Loggers\StandardLogger;
use Laravel\Reverb\Protocols\Pusher\Server;
use RuntimeException;

/**
 * Gives Reverb the file driver config/reverb.php names (design D16), the Pusher server a shared host needs, and a
 * logger that reaches the journal.
 */
class HostServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->bind(Server::class, HostServer::class);
    }

    public function boot(): void
    {
        // Reverb logs nothing unless told to. Its errors go to stderr, and so to the journal; the unit's LOG_LEVEL
        // (error) keeps out its info lines, which hold whole messages.
        $this->app->instance(Logger::class, new StandardLogger);

        $this->app->make(ApplicationManager::class)->extend('file', function ($app) {
            $path = $app['config']['reverb.apps.file'];
            if (! is_string($path) || ! str_starts_with($path, '/')) {
                throw new RuntimeException('reverb-host needs the absolute path of its apps file (REVERB_HOST_APPS)');
            }

            return new FileApplicationProvider($path);
        });
    }
}
