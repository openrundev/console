// CPU / memory benchmark for the <log-tail> parsing core.
// Run: node perf/logtail_bench.cjs   (add --expose-gc for exact memory deltas)
//
// Feeds synthetic log streams through the parser in network-sized chunks and
// reports throughput plus retained memory with the 5000-line ring buffer.
// Exits non-zero if a workload falls below its budget, so this can run in CI.
'use strict';

const core = require('./load_core.cjs');

const CHUNK = 16 * 1024; // typical network read size
const MAX_LINES = 5000; // element default line cap

// ---- workload generators ----

function plainLines(count) {
	const out = [];
	for (let i = 0; i < count; i++) {
		out.push(`2026-07-05T10:12:${String(i % 60).padStart(2, '0')}.123Z INFO request handled path=/api/items/${i} status=200 dur=${i % 97}ms bytes=${1000 + (i % 4096)}`);
	}
	return out.join('\n') + '\n';
}

function ansiLines(count) {
	const levels = ['\x1b[32mINFO \x1b[0m', '\x1b[33mWARN \x1b[0m', '\x1b[1;31mERROR\x1b[0m', '\x1b[2mDEBUG\x1b[0m'];
	const out = [];
	for (let i = 0; i < count; i++) {
		out.push(`\x1b[90m2026-07-05T10:12:00Z\x1b[0m ${levels[i % 4]} \x1b[36mworker-${i % 8}\x1b[0m handled job ${i} in \x1b[35m${i % 300}ms\x1b[0m`);
	}
	return out.join('\n') + '\n';
}

function progressLines(count) {
	// \r-overwritten progress updates ending in a final line, like docker pulls
	const out = [];
	for (let i = 0; i < count; i++) {
		let s = '';
		for (let p = 0; p <= 100; p += 25) s += `Downloading layer ${i}: ${p}%\r`;
		out.push(s + `Downloading layer ${i}: done`);
	}
	return out.join('\n') + '\n';
}

// ---- harness ----

function feedChunked(parser, ring, text) {
	let lines = 0;
	for (let off = 0; off < text.length; off += CHUNK) {
		const parsed = parser.feed(text.slice(off, off + CHUNK));
		lines += parsed.length;
		for (let i = 0; i < parsed.length; i++) ring.push(parsed[i]);
	}
	const rest = parser.end();
	lines += rest.length;
	for (let i = 0; i < rest.length; i++) ring.push(rest[i]);
	return lines;
}

function bench(name, text, minMBps) {
	// warm up the JIT, then measure
	feedChunked(core.createParser(), core.createRingBuffer(MAX_LINES), text.slice(0, 1 << 20));

	const ring = core.createRingBuffer(MAX_LINES);
	const parser = core.createParser();
	const start = process.hrtime.bigint();
	const lines = feedChunked(parser, ring, text);
	const secs = Number(process.hrtime.bigint() - start) / 1e9;

	const mb = text.length / (1024 * 1024);
	const mbps = mb / secs;
	const ok = mbps >= minMBps;
	console.log(
		`${name.padEnd(22)} ${mb.toFixed(1).padStart(7)} MB  ${(lines / 1e6).toFixed(2)} M lines  ` +
		`${(secs * 1000).toFixed(0).padStart(5)} ms  ${mbps.toFixed(0).padStart(5)} MB/s  ` +
		`${(lines / secs / 1e6).toFixed(1)} M lines/s  [budget ${minMBps} MB/s] ${ok ? 'PASS' : 'FAIL'}`,
	);
	return ok;
}

function benchMemory() {
	// Retained memory must stay bounded by the ring buffer, not stream size:
	// stream 2M lines (~250 MB) through a 5000-line ring and measure growth
	const ring = core.createRingBuffer(MAX_LINES);
	const parser = core.createParser();
	const piece = plainLines(10000);

	if (global.gc) global.gc();
	const before = process.memoryUsage().heapUsed;
	let lines = 0;
	for (let i = 0; i < 200; i++) {
		lines += feedChunked(parser, ring, piece);
	}
	if (global.gc) global.gc();
	const grewMB = (process.memoryUsage().heapUsed - before) / (1024 * 1024);

	// Without --expose-gc the reading includes floating garbage; the bound
	// is generous but still catches an unbounded buffer (would be 100s of MB)
	const ok = grewMB < 64;
	console.log(
		`memory (ring ${MAX_LINES})   ${(lines / 1e6).toFixed(1)} M lines streamed, ` +
		`retained heap growth ${grewMB.toFixed(1)} MB ` +
		`${global.gc ? '(gc forced)' : '(run with --expose-gc for exact)'} [budget 64 MB] ${ok ? 'PASS' : 'FAIL'}`,
	);
	return ok;
}

console.log(`node ${process.version}, chunk ${CHUNK / 1024} KB, ring ${MAX_LINES} lines\n`);
let ok = true;
ok = bench('plain logs', plainLines(2_000_000), 300) && ok;
ok = bench('ansi colored logs', ansiLines(1_000_000), 60) && ok;
ok = bench('\\r progress updates', progressLines(200_000), 60) && ok;
ok = benchMemory() && ok;
process.exit(ok ? 0 : 1);
