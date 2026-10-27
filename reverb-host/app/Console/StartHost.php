<?php

namespace App\Console;

use Laravel\Reverb\Contracts\Logger;
use Laravel\Reverb\Loggers\CliLogger;
use Laravel\Reverb\Servers\Reverb\Console\Commands\StartServer;
use Laravel\Reverb\Servers\Reverb\Factory;
use Laravel\Reverb\Servers\Reverb\Http\Server;
use React\EventLoop\Loop;
use React\Socket\SocketServer;
use RuntimeException;
use Symfony\Component\Console\Attribute\AsCommand;

/**
 * Reverb's own reverb:start, listening on a Unix socket instead of a port (design D16). nginx, which runs as the
 * box user, passes the QA zone's WebSocket host to it, and the socket's folder is the box user's alone, so no QA
 * site can take Reverb's place, not even while it restarts. Its timers, signals and graceful stop are
 * reverb:start's.
 */
#[AsCommand(name: 'reverb-host:start')]
class StartHost extends StartServer
{
    protected $signature = 'reverb-host:start
                {--socket= : The Unix socket to listen on, when REVERB_HOST_SOCKET does not name it}
                {--debug : Print each message the server sends and receives}';

    protected $description = 'Run Reverb for every QA environment on the box, on a Unix socket';

    public function handle(): void
    {
        if ($this->option('debug')) {
            $this->laravel->instance(Logger::class, new CliLogger($this->output));
        }

        $config = $this->laravel['config']['reverb.servers.reverb'];
        $socket = $this->option('socket') ?: $config['socket'];
        if (! is_string($socket) || ! str_starts_with($socket, '/')) {
            throw new RuntimeException('reverb-host:start needs the absolute path of its socket (REVERB_HOST_SOCKET)');
        }

        // A socket left by a run that stopped short would refuse the new one; anything else in its place stays.
        if (@filetype($socket) === 'socket') {
            unlink($socket);
        }

        $loop = Loop::get();
        $server = new Server(
            new SocketServer("unix://{$socket}", [], $loop),
            Factory::makePusherRouter($config['path'] ?? ''),
            $config['max_request_size'] ?? 10_000,
            $loop
        );

        $this->ensureHorizontalScalability($loop);
        $this->ensureStaleConnectionsAreCleaned($loop);
        $this->ensureRestartCommandIsRespected($server, $loop, 'unix', $socket);
        $this->ensurePulseEventsAreCollected($loop, $config['pulse_ingest_interval'] ?? 15);
        $this->ensureTelescopeEntriesAreCollected($loop, $config['telescope_ingest_interval'] ?? 15);

        $this->components->info("Starting server on unix:{$socket}");

        $server->start();
    }
}
