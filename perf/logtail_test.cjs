// Correctness tests for the <log-tail> parsing core (static/logtail.js).
// Run: node perf/logtail_test.cjs
'use strict';

const assert = require('assert');
const core = require('./load_core.cjs');

const { STYLE_DEFAULT, styleBits } = core;
const { BOLD, DIM, ITALIC, UNDERLINE } = styleBits;

function lines(...chunks) {
	const p = core.createParser();
	const out = [];
	for (const c of chunks) out.push(...p.feed(c));
	out.push(...p.end());
	return out;
}

// Plain lines pass through as strings (fast path)
assert.deepStrictEqual(lines('a\nb\nc\n'), ['a', 'b', 'c']);
assert.deepStrictEqual(lines('no trailing newline'), ['no trailing newline']);
assert.deepStrictEqual(lines('tab\tkeeps\n'), ['tab\tkeeps']);
assert.deepStrictEqual(lines('', 'sp', 'lit\nacross\nfe', 'eds\n'), ['split', 'across', 'feeds']);

// Empty lines survive
assert.deepStrictEqual(lines('a\n\nb\n'), ['a', '', 'b']);

// CRLF is stripped, interior \r overwrites (progress bars)
assert.deepStrictEqual(lines('dos line\r\n'), ['dos line']);
assert.deepStrictEqual(lines('progress 10%\rprogress 100%\n'), ['progress 100%']);
assert.deepStrictEqual(lines('a\rb\rc\r\n'), ['c']);

// Backspace deletes the previous char (slow path)
assert.deepStrictEqual(lines('abcd\b\bZ\n'), ['abZ']);

// Other C0 controls and DEL are stripped
assert.deepStrictEqual(lines('a\x00b\x07c\x7fd\n'), ['abcd']);

// Basic SGR colors produce segments [style, text, ...]
const red = lines('\x1b[31mred\x1b[0m plain\n')[0];
assert.strictEqual(Array.isArray(red), true);
assert.deepStrictEqual(red, [(STYLE_DEFAULT & ~31) | 1, 'red', STYLE_DEFAULT, ' plain']);

// Bold + bright fg, and 256-color palette entries 0-15 map to base colors
const boldBright = lines('\x1b[1;92mok\x1b[m\n')[0];
assert.deepStrictEqual(boldBright, [((STYLE_DEFAULT & ~31) | 10) | BOLD, 'ok']);
const c256 = lines('\x1b[38;5;9mnine\x1b[0m\n')[0];
assert.deepStrictEqual(c256, [(STYLE_DEFAULT & ~31) | 9, 'nine']);

// dim/italic/underline set and clear
const styled = lines('\x1b[2;3;4mx\x1b[22;23;24my\n')[0];
assert.deepStrictEqual(styled, [STYLE_DEFAULT | DIM | ITALIC | UNDERLINE, 'x', STYLE_DEFAULT, 'y']);

// Style persists across lines until reset, like a terminal
const persisted = lines('\x1b[33mwarn start\nstill warn\x1b[0m\ndone\n');
assert.deepStrictEqual(persisted[0], [(STYLE_DEFAULT & ~31) | 3, 'warn start']);
assert.deepStrictEqual(persisted[1], [(STYLE_DEFAULT & ~31) | 3, 'still warn']);
assert.strictEqual(persisted[2], 'done');

// Unsupported sequences are stripped: truecolor, 256-color > 15, cursor
// movement, OSC titles, other escapes
assert.deepStrictEqual(lines('\x1b[38;2;10;20;30mtc\x1b[0m\n'), ['tc']);
assert.deepStrictEqual(lines('\x1b[38;5;200mhi\x1b[0m\n'), ['hi']);
assert.deepStrictEqual(lines('a\x1b[2Kb\x1b[1;5Hc\n'), ['abc']);
assert.deepStrictEqual(lines('\x1b]0;win title\x07after\n'), ['after']);
assert.deepStrictEqual(lines('\x1b]8;;http://x\x1b\\link\n'), ['link']);
assert.deepStrictEqual(lines('esc\x1b(Bpair\n'), ['escpair']);

// Background colors
const bg = lines('\x1b[41mbg\x1b[49m fg\x1b[0m\n')[0];
assert.deepStrictEqual(bg, [(STYLE_DEFAULT & ~(31 << 5)) | (1 << 5), 'bg', STYLE_DEFAULT, ' fg']);

// Very long lines are truncated to bound memory
const long = lines('x'.repeat(20000) + '\n')[0];
assert.ok(long.length < 17000, 'long line truncated');

// Escape sequence split across feed chunks is held with the partial line
assert.deepStrictEqual(lines('\x1b[3', '1mr\x1b[0m\n'), [[(STYLE_DEFAULT & ~31) | 1, 'r']]);

// Ring buffer keeps only the newest cap entries
const ring = core.createRingBuffer(3);
for (let i = 0; i < 10; i++) ring.push(i);
assert.deepStrictEqual(ring.toArray(), [7, 8, 9]);
assert.strictEqual(ring.size, 3);

console.log('logtail_test: all assertions passed');
