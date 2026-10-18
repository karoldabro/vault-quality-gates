<?php

namespace Tests\Unit\Quality\IndicationChecks;

use PHPUnit\Framework\TestCase;
use RuntimeException;
use Tests\Quality\IndicationChecks\ParallelWorkersCappedCheck;

final class ParallelWorkersCappedCheckTest extends TestCase
{
    use BuildsFixtureRoot;

    private const FIXTURES = __DIR__.'/../../../Quality/IndicationChecks/Fixtures/ParallelWorkersCappedCheck';

    private const V2_HEADER = "id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy";

    public function test_flags_uncapped_parallel_scripts_and_unniced_gate_rows(): void
    {
        $this->assertSame([
            'composer.json scripts.test:parallel runs a parallel suite without --processes=N; paratest defaults to one worker per core.',
            'composer.json scripts.test:paratest runs a parallel suite without --processes=N; paratest defaults to one worker per core.',
            'quality/checks.tsv row phpstan-errors runs a CPU-bound tool without a nice -n prefix.',
        ], (new ParallelWorkersCappedCheck)->check(self::FIXTURES.'/bad', []));
    }

    public function test_passes_capped_scripts_niced_rows_and_non_cpu_rows(): void
    {
        $this->assertSame([], (new ParallelWorkersCappedCheck)->check(self::FIXTURES.'/good', []));
    }

    public function test_v2_driver_rows_through_a_niced_runner_or_reading_a_report_pass(): void
    {
        $root = $this->fixtureRoot(['composer.json' => '{}', 'quality/checks.tsv' => implode("\n", [
            self::V2_HEADER,
            "phpstan-new\tcommit\tdiff\tphpstan\trunner=quality/bin/in-tree.sh -- --memory-limit=1G\tdown\t0\trefuse\twhy",
            "insights-code\tpush\trepo\tphpinsights\trunner=quality/bin/in-server.sh metric=code\tup\t0.5\trefuse\twhy",
            "coverage\tpush\trepo\tphpunit\tmetric=coverage run=no\tup\t0.5\trefuse\twhy",
            "comment-density\tpush\trepo\tcloc\tpaths=app\tdown\t0.02\trefuse\twhy",
            "suppressions\tcommit\tdiff\tshell\t-- nice -n 15 vendor/bin/phpstan analyse\tdown\t0\trefuse\twhy",
            "old\t-\tabsent\t-\t-\t-\t-\t-\treplaced by phpstan-new",
        ])]);

        $this->assertSame([], (new ParallelWorkersCappedCheck)->check($root, []));
    }

    public function test_v2_rows_running_a_cpu_tool_without_nice_are_flagged(): void
    {
        $root = $this->fixtureRoot(['composer.json' => '{}', 'quality/checks.tsv' => implode("\n", [
            self::V2_HEADER,
            "phpstan-host\tcommit\tdiff\tphpstan\t-- --memory-limit=1G\tdown\t0\trefuse\twhy",
            "suite\tbaseline\tdiff\tphpunit\tmetric=failed runner=quality/bin/other.sh\tdown\t0\trefuse\twhy",
            "stan-shell\tcommit\tdiff\tshell\tparser=phpstan-all -- vendor/bin/phpstan analyse\tdown\t0\trefuse\twhy",
            "argv-runner\tpush\tdiff\tphpunit\tmetric=failed -- runner=quality/bin/in-tree.sh run=no nice -n 1\tdown\t0\trefuse\twhy",
        ])]);

        $this->assertSame([
            'quality/checks.tsv row phpstan-host runs a CPU-bound tool without a nice -n prefix.',
            'quality/checks.tsv row suite runs a CPU-bound tool without a nice -n prefix.',
            'quality/checks.tsv row stan-shell runs a CPU-bound tool without a nice -n prefix.',
            'quality/checks.tsv row argv-runner runs a CPU-bound tool without a nice -n prefix.',
        ], (new ParallelWorkersCappedCheck)->check($root, []));
    }

    public function test_throws_when_composer_json_is_missing(): void
    {
        $root = $this->fixtureRoot([]);

        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessage('Cannot read '.$root.'/composer.json');

        (new ParallelWorkersCappedCheck)->check($root, []);
    }

    public function test_throws_when_checks_tsv_is_missing(): void
    {
        $root = $this->fixtureRoot(['composer.json' => '{}']);

        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessage('Cannot read '.$root.'/quality/checks.tsv');

        (new ParallelWorkersCappedCheck)->check($root, []);
    }
}
