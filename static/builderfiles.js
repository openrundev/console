// <builder-files> - read-only workspace file explorer + viewer for the
// builder session page.
//
//   <builder-files endpoint="/console/builder/file?id=X">
//     <nav class="bf-tree">…server-rendered file rows with [data-bf-file]…</nav>
//     <div class="bf-viewer">
//       <div class="bf-name"></div>
//       <div class="bf-body"><div class="bf-gutter"></div><pre class="bf-code"><code></code></pre></div>
//     </div>
//   </builder-files>
//
// Clicking a file row fetches the raw content from the endpoint and renders
// it with highlight.js (vendored, static/vendor/highlight.min.js) plus a
// line-number gutter. The highlight theme is defined here on top of the
// daisyUI theme variables, so it follows the light/dark theme automatically.
// Light DOM only, same rule as the other console components.

(function () {
	'use strict';

	function injectStyle() {
		if (document.getElementById('builder-files-style')) return;
		const css =
			'builder-files{display:flex}' +
			// file tree: native CSS resize, browser-rendered corner grip
			'builder-files .bf-tree{width:13rem;min-width:7rem;max-width:22rem;' +
			'resize:horizontal;overflow:auto;border-inline-end:1px solid var(--color-base-300)}' +
			// tab panels: the hidden attribute must win over utility display classes
			'[data-bf-panel][hidden]{display:none!important}' +
			// resizable agent/preview split (xl+): the chat pane width comes
			// from a root-level variable so it survives HTMX partial swaps
			'@media (min-width:1280px){' +
			'.builder-split{display:flex;gap:0}' +
			'.builder-split>.bs-chat{width:var(--builder-split,40%);flex:none;min-width:300px;max-width:72%}' +
			'.builder-split>.bs-divider{display:flex;align-items:center;justify-content:center;' +
			'width:16px;flex:none;cursor:col-resize;touch-action:none}' +
			'.builder-split>.bs-preview{flex:1;min-width:0}' +
			'}' +
			'.bs-divider::before{content:"";width:4px;height:44px;border-radius:9999px;' +
			'background:color-mix(in oklab,var(--color-base-content) 22%,transparent);transition:background .15s}' +
			'.bs-divider:hover::before,.bs-divider:focus-visible::before,.bs-divider.bs-active::before{' +
			'background:var(--color-primary)}' +
			// the iframe would swallow pointermove events mid-drag
			'.builder-split.bs-dragging iframe{pointer-events:none}' +
			// layout: shared scroll container, gutter sticky left
			'.bf-body{display:flex;overflow:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;' +
			'font-size:12px;line-height:1.6}' +
			'.bf-gutter{position:sticky;left:0;flex:none;padding:8px 10px 8px 14px;text-align:right;user-select:none;' +
			'color:color-mix(in oklab,var(--color-base-content) 35%,transparent);' +
			'background:color-mix(in oklab,var(--color-base-200) 80%,var(--color-base-100));' +
			'border-right:1px solid var(--color-base-300);white-space:pre}' +
			'.bf-code{flex:1;margin:0;padding:8px 14px;white-space:pre;tab-size:4}' +
			'.bf-code code{background:transparent;padding:0}' +
			// highlight theme on the daisyui variables: readable in both themes
			'.bf-code .hljs-comment,.bf-code .hljs-quote{color:color-mix(in oklab,var(--color-base-content) 45%,transparent);font-style:italic}' +
			'.bf-code .hljs-keyword,.bf-code .hljs-selector-tag,.bf-code .hljs-meta{color:var(--color-secondary);font-weight:600}' +
			'.bf-code .hljs-string,.bf-code .hljs-regexp,.bf-code .hljs-addition{color:var(--color-success)}' +
			'.bf-code .hljs-number,.bf-code .hljs-literal,.bf-code .hljs-symbol{color:var(--color-accent)}' +
			'.bf-code .hljs-title,.bf-code .hljs-name,.bf-code .hljs-section{color:var(--color-primary)}' +
			'.bf-code .hljs-attr,.bf-code .hljs-attribute,.bf-code .hljs-variable,.bf-code .hljs-template-variable{color:var(--color-info)}' +
			'.bf-code .hljs-built_in,.bf-code .hljs-type,.bf-code .hljs-class{color:var(--color-warning)}' +
			'.bf-code .hljs-deletion{color:var(--color-error)}' +
			'.bf-code .hljs-emphasis{font-style:italic}.bf-code .hljs-strong{font-weight:700}' +
			// active file row
			'[data-bf-file].bf-active{background:color-mix(in oklab,var(--color-primary) 12%,transparent);' +
			'color:var(--color-primary)}';
		const style = document.createElement('style');
		style.id = 'builder-files-style';
		style.textContent = css;
		document.head.appendChild(style);
	}

	// Language by file extension; only languages in the vendored common
	// build. Unknown extensions render as plain text
	const LANGUAGES = {
		py: 'python', star: 'python', js: 'javascript', mjs: 'javascript', ts: 'typescript',
		html: 'xml', htm: 'xml', xml: 'xml', svg: 'xml', css: 'css', scss: 'scss',
		json: 'json', md: 'markdown', sh: 'bash', bash: 'bash', sql: 'sql',
		go: 'go', java: 'java', rb: 'ruby', rs: 'rust', c: 'c', h: 'c', cpp: 'cpp',
		yaml: 'yaml', yml: 'yaml', toml: 'ini', ini: 'ini', txt: 'plaintext',
	};

	function languageFor(path) {
		const name = path.split('/').pop();
		if (name === 'Dockerfile') return 'bash';
		const ext = name.indexOf('.') >= 0 ? name.split('.').pop().toLowerCase() : '';
		// app.go.html and friends are Go templates; xml is the closest fit
		if (name.endsWith('.go.html')) return 'xml';
		return LANGUAGES[ext] || 'plaintext';
	}

	class BuilderFiles extends HTMLElement {
		connectedCallback() {
			if (document.readyState === 'loading') {
				document.addEventListener('DOMContentLoaded', () => this.init(), { once: true });
			} else {
				setTimeout(() => this.init(), 0);
			}
		}

		init() {
			if (!this.isConnected || this.initialized) return;
			this.initialized = true;
			injectStyle();
			this.nameEl = this.querySelector('.bf-name');
			this.gutter = this.querySelector('.bf-gutter');
			this.code = this.querySelector('.bf-code code');

			this.addEventListener('click', (e) => {
				const row = e.target.closest('[data-bf-file]');
				if (row) {
					e.preventDefault();
					this.open(row);
				}
			});

			// Open the first file (app.star when present) so the tab is
			// never empty
			const rows = this.querySelectorAll('[data-bf-file]');
			let first = null;
			rows.forEach((row) => {
				if (!first) first = row;
				if (row.getAttribute('data-bf-file') === 'app.star') first = row;
			});
			if (first) this.open(first);
		}

		async open(row) {
			const path = row.getAttribute('data-bf-file');
			this.querySelectorAll('[data-bf-file].bf-active').forEach((el) => el.classList.remove('bf-active'));
			row.classList.add('bf-active');
			if (this.nameEl) this.nameEl.textContent = path;
			this.renderText('Loading…', 'plaintext');
			try {
				const resp = await fetch(this.getAttribute('endpoint') + '&path=' + encodeURIComponent(path));
				const text = await resp.text();
				if (!resp.ok || text.startsWith('error: ')) {
					this.renderText(text || 'error loading file', 'plaintext');
					return;
				}
				this.renderText(text, languageFor(path));
			} catch (e) {
				this.renderText('error loading file: ' + e, 'plaintext');
			}
		}

		renderText(text, language) {
			if (!this.code) return;
			const lineCount = text === '' ? 1 : text.split('\n').length;
			let numbers = '';
			for (let i = 1; i <= lineCount; i++) numbers += i + '\n';
			if (this.gutter) this.gutter.textContent = numbers;
			if (window.hljs && language !== 'plaintext') {
				try {
					this.code.innerHTML = window.hljs.highlight(text, { language: language, ignoreIllegals: true }).value;
					return;
				} catch (e) { /* fall through to plain text */ }
			}
			this.code.textContent = text;
		}
	}

	customElements.define('builder-files', BuilderFiles);

	/* ---------- agent/preview pane resizing ---------- */
	// The split lives in a root-level CSS variable (survives HTMX swaps of
	// the session content) and persists across visits in localStorage

	const SPLIT_KEY = 'builder-split';
	const stored = localStorage.getItem(SPLIT_KEY);
	if (stored) document.documentElement.style.setProperty('--builder-split', stored);

	function setSplit(pct, persist) {
		const clamped = Math.max(25, Math.min(72, pct));
		const value = clamped.toFixed(1) + '%';
		document.documentElement.style.setProperty('--builder-split', value);
		if (persist) {
			try { localStorage.setItem(SPLIT_KEY, value); } catch (e) { /* private mode */ }
		}
		return clamped;
	}

	function currentSplit() {
		const raw = getComputedStyle(document.documentElement).getPropertyValue('--builder-split');
		const parsed = parseFloat(raw);
		return isNaN(parsed) ? 40 : parsed;
	}

	document.addEventListener('pointerdown', (e) => {
		const divider = e.target.closest('[data-bc-splitter]');
		if (!divider) return;
		const container = divider.closest('.builder-split');
		if (!container) return;
		e.preventDefault();
		divider.setPointerCapture(e.pointerId);
		container.classList.add('bs-dragging');
		divider.classList.add('bs-active');
		const rect = container.getBoundingClientRect();
		const onMove = (ev) => {
			setSplit(((ev.clientX - rect.left) / rect.width) * 100, false);
		};
		const onUp = () => {
			divider.removeEventListener('pointermove', onMove);
			container.classList.remove('bs-dragging');
			divider.classList.remove('bs-active');
			setSplit(currentSplit(), true);
		};
		divider.addEventListener('pointermove', onMove);
		divider.addEventListener('pointerup', onUp, { once: true });
		divider.addEventListener('pointercancel', onUp, { once: true });
	});

	document.addEventListener('keydown', (e) => {
		if (!e.target.closest || !e.target.closest('[data-bc-splitter]')) return;
		if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
		e.preventDefault();
		setSplit(currentSplit() + (e.key === 'ArrowLeft' ? -2 : 2), true);
	});

	// Preview / Files tab switching on the session page. Document-level
	// delegation so HTMX partial re-renders keep working
	document.addEventListener('click', (e) => {
		const tab = e.target.closest('[data-bf-tab]');
		if (!tab) return;
		const root = tab.closest('[data-bf-tabs]');
		if (!root) return;
		const target = tab.getAttribute('data-bf-tab');
		root.querySelectorAll('[data-bf-tab]').forEach((btn) => {
			const active = btn === tab;
			btn.classList.toggle('tab-active', active);
			btn.setAttribute('aria-selected', active ? 'true' : 'false');
		});
		root.querySelectorAll('[data-bf-panel]').forEach((panel) => {
			panel.hidden = panel.getAttribute('data-bf-panel') !== target;
		});
	});
})();
