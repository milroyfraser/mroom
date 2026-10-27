<?php

use App\Console\StartHost;
use App\Providers\HostServiceProvider;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;

// A console-only Laravel app: no routes, no HTTP kernel, no database. Its one command runs Reverb for every
// QA environment on the box (design D16).
return Application::configure(basePath: dirname(__DIR__))
    ->withProviders([HostServiceProvider::class])
    ->withCommands([StartHost::class])
    ->withExceptions(function (Exceptions $exceptions): void {
        //
    })
    ->create();
