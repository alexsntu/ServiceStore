<?php
/**
 * Сбор цен для калькуляторов iRepair Store.
 *
 * Берёт цены напрямую из CS-Cart (те же, что видит покупатель на витрине:
 * с учётом акций каталога) и пишет один JSON-файл, который читают калькуляторы.
 *
 * Запуск (от пользователя www-root):
 *   /opt/php83/bin/php build_prices.php            — собрать и записать файл
 *   /opt/php83/bin/php build_prices.php --dry-run  — только показать сводку
 */

if (php_sapi_name() !== 'cli') {
    exit(1);
}

$dry_run = in_array('--dry-run', $argv, true);

$root = '/var/www/www-root/data/www/irepair-store.ru';
$out_file = $root . '/calc/prices.json';

define('AREA', 'C');
$_SERVER['REQUEST_METHOD'] = 'GET';
$_SERVER['HTTP_HOST'] = 'irepair-store.ru';
$_SERVER['HTTPS'] = 'on';

require $root . '/init.php';

$lang = 'ru';
$started = microtime(true);

list($products) = fn_get_products([
    'extend' => ['description'],
    'sort_by' => 'product',
], 0, $lang);

fn_gather_additional_products_data($products, [
    'get_icon' => false,
    'get_detailed' => false,
    'get_options' => false,
    'get_discounts' => true,
    'get_features' => false,
]);

$slugs = db_get_hash_single_array(
    "SELECT object_id, name FROM ?:seo_names WHERE type = 'p' AND lang_code = ?s AND object_id IN (?n)",
    ['object_id', 'name'],
    $lang,
    array_keys($products ?: [0 => 0])
);

$items = [];
$without_price = 0;
foreach ($products as $product) {
    $id = (int) $product['product_id'];
    if (empty($slugs[$id])) {
        continue;
    }
    $price = (int) round((float) $product['price']);
    $list_price = (int) round((float) $product['list_price']);

    $item = ['id' => $id, 'code' => (string) $product['product_code']];
    if ($price > 0) {
        $item['price'] = $price;
        if ($list_price > $price) {
            $item['list_price'] = $list_price;
        }
    } else {
        // товар без цены («Свяжитесь с нами насчёт цены»)
        $item['price'] = null;
        $without_price++;
    }
    $items[$slugs[$id]] = $item;
}
ksort($items);

$result = [
    'updated_at' => date('c'),
    'updated_ts' => time(),
    'count' => count($items),
    'products' => $items,
];

$summary = sprintf(
    "товаров: %d, без цены: %d, время: %.1f с, память: %d МБ\n",
    count($items),
    $without_price,
    microtime(true) - $started,
    memory_get_peak_usage(true) / 1048576
);

if ($dry_run) {
    echo $summary;
    $sample = array_slice($items, 0, 5, true);
    echo json_encode($sample, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
    exit(0);
}

// пустой результат — признак сбоя: старый файл не затираем
if (count($items) === 0) {
    fwrite(STDERR, "нет товаров, файл не обновлён\n");
    exit(2);
}

if (!is_dir(dirname($out_file))) {
    mkdir(dirname($out_file), 0755, true);
}
$tmp = $out_file . '.tmp';
if (file_put_contents($tmp, json_encode($result, JSON_UNESCAPED_UNICODE)) === false || !rename($tmp, $out_file)) {
    fwrite(STDERR, "не удалось записать $out_file\n");
    exit(3);
}
chmod($out_file, 0644);
echo $summary;
