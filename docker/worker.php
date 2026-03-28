<?php
/**
 * FrankenPHP Worker Mode Bootstrap
 *
 * 此文件在 FrankenPHP worker 模式下运行：
 * - Laravel 应用只启动一次（冷启动）
 * - 后续请求复用已启动的进程，极大降低延迟
 *
 * @see https://frankenphp.dev/docs/worker/
 */

// 引导 Laravel
require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/../bootstrap/app.php';

$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);

// FrankenPHP worker 循环
while ($request = \FrankenPHP\getRequest()) {
    // 使用 Symfony 请求适配器（FrankenPHP 已提供）
    $symfonyRequest = \Symfony\Bridge\PsrHttpMessage\Factory\HttpFoundationFactory::createRequest($request);

    $illuminateRequest = \Illuminate\Http\Request::createFromBase($symfonyRequest);

    // 处理请求
    $response = $kernel->handle($illuminateRequest);
    $response->send();
    $kernel->terminate($illuminateRequest, $response);
}
