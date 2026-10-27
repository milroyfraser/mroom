<?php

// Reverb for every QA environment on the box (design D16). It listens on a Unix socket, which nginx passes the
// QA zone's WebSocket host to, and reads its apps from a file the gate writes, on every lookup, so an app comes
// and goes without a restart. The systemd unit sets both paths.
return [

    'default' => 'reverb',

    'servers' => [
        'reverb' => [
            'socket' => env('REVERB_HOST_SOCKET'),
            'path' => '',
            'max_request_size' => 10_000,
            'options' => [],
            'scaling' => [
                'enabled' => false,
            ],
            'pulse_ingest_interval' => 15,
            'telescope_ingest_interval' => 15,
        ],
    ],

    'apps' => [
        'provider' => 'file',
        'file' => env('REVERB_HOST_APPS'),
        'apps' => [],
    ],

];
