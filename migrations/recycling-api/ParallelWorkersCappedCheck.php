<?php

namespace Tests\Quality\IndicationChecks;

use RuntimeException;

/**
 * Flags a composer.json script that runs `--parallel` or paratest without a numeric `--processes=N` / `-p N`, and
 * a quality/checks.tsv row that runs a CPU-bound tool (phpstan, phpinsights, phpunit, paratest, infection,
 * artisan test) without a `nice -n` prefix.
 *
 * A v1 row (header `id scope kind command ...`) is judged on its command cell. A v2 row (header
 * `id on kind driver args ...`) is judged on its driver and args: a shell row on the command after ` -- `, a
 * driver row by its runner, because quality/bin/in-tree.sh and quality/bin/in-server.sh start every tool with
 * `nice -n 15`. A driver row with `run=no` reads a report and runs nothing.
 *
 * Indication: ~/vault/givore/indications/api/test-runs-must-cap-parallel-workers.md
 */
final class ParallelWorkersCappedCheck implements IndicationCheck
{
    private const CPU_TOOL = '/phpstan|phpinsights|phpunit|paratest|infection|artisan test/';

    private const NICED_RUNNERS = ['quality/bin/in-tree.sh', 'quality/bin/in-server.sh'];

    public function check(string $root, array $gitFacts): array
    {
        $violations = [];

        $path = $root.'/composer.json';
        $json = is_file($path) ? json_decode((string) file_get_contents($path), true) : null;
        if (! is_array($json)) {
            throw new RuntimeException('Cannot read '.$path);
        }
        foreach ($json['scripts'] ?? [] as $key => $value) {
            foreach ((array) $value as $command) {
                $command = (string) $command;
                $parallel = str_contains($command, '--parallel') || str_contains($command, 'paratest');
                $capped = (bool) preg_match('/--processes=\d|(?<![\w-])-p\s*\d/', $command);
                if ($parallel && ! $capped) {
                    $violations[] = 'composer.json scripts.'.$key.' runs a parallel suite without --processes=N; paratest defaults to one worker per core.';
                    break;
                }
            }
        }

        $path = $root.'/quality/checks.tsv';
        $rows = is_file($path) ? file($path, FILE_IGNORE_NEW_LINES) : false;
        if ($rows === false) {
            throw new RuntimeException('Cannot read '.$path);
        }
        $v2 = isset($rows[0]) && str_starts_with($rows[0], "id\ton\t");
        foreach ($rows as $row) {
            if (trim($row) === '' || str_starts_with($row, '#') || str_starts_with($row, "id\t")) {
                continue;
            }
            $cells = explode("\t", $row);
            $uncapped = $v2 ? $this->uncappedV2($cells[3] ?? '', $cells[4] ?? '') : $this->uncapped($cells[3] ?? '');
            if ($uncapped) {
                $violations[] = 'quality/checks.tsv row '.$cells[0].' runs a CPU-bound tool without a nice -n prefix.';
            }
        }

        return $violations;
    }

    private function uncapped(string $command): bool
    {
        return preg_match(self::CPU_TOOL, $command) === 1 && ! str_contains($command, 'nice -n');
    }

    private function uncappedV2(string $driver, string $args): bool
    {
        if ($driver === 'shell') {
            $command = str_contains($args, ' -- ') ? substr($args, strpos($args, ' -- ') + 4) : (str_starts_with($args, '-- ') ? substr($args, 3) : '');

            return $this->uncapped($command);
        }
        // The engine reads keys only before the first ` -- `; what follows is the tool's own argv.
        $keys = str_starts_with($args, '-- ') ? '' : explode(' -- ', $args, 2)[0];
        if (preg_match(self::CPU_TOOL, $driver.' '.$args) !== 1 || preg_match('/(^| )run=no( |$)/', $keys) === 1) {
            return false;
        }
        foreach (self::NICED_RUNNERS as $runner) {
            if (preg_match('#(^| )runner='.preg_quote($runner, '#').'( |$)#', $keys) === 1) {
                return false;
            }
        }

        return true;
    }
}
