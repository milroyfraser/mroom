<?php

namespace App\Reverb;

use Exception;
use Laravel\Reverb\Contracts\Connection;
use Laravel\Reverb\Protocols\Pusher\Server;

/**
 * Reverb's Pusher server, with two changes a host that many apps share needs (design D16):
 *
 * - Before each message, the channel manager is set to the sender's app. Reverb 1.12.0 looks a client event's
 *   channel up in whichever app the manager served last, so with more than one app a valid whisper is refused at
 *   random (fixed upstream after 1.12.0, in laravel/reverb#418).
 * - A socket refused for its origin or for the app's connection limit is closed. Reverb only sends the error, and
 *   the socket could still subscribe; pusher-js closes itself, but nothing makes a script do so.
 */
class HostServer extends Server
{
    public function open(Connection $connection): void
    {
        try {
            $this->ensureWithinConnectionLimit($connection);
            $this->verifyOrigin($connection);
        } catch (Exception $e) {
            $this->error($connection, $e);
            $connection->disconnect();

            return;
        }

        parent::open($connection);
    }

    public function message(Connection $from, string $message): void
    {
        $this->channels->for($from->app());

        parent::message($from, $message);
    }
}
