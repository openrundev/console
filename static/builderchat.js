// <builder-chat> - live chat pane for the app builder session workspace.
//
//   <builder-chat stream="/console/builder/events?id=X" session="X">
//     <div class="bc-transcript">…server-rendered transcript…</div>
//     <div class="bc-status"></div>
//   </builder-chat>
//
// Connects to the stream URL (plain-text response of JSON lines, one builder
// event per line) and appends to the server-rendered transcript: agent
// message chunks stream into one bubble, tool calls render as chips, and
// turn completion refreshes the preview iframe. Light DOM only (DaisyUI +
// HTMX compatibility, same rule as the other console components).
//
// The composer form (data-builder-composer) posts through HTMX with
// hx-swap="none"; this element appends the user's bubble optimistically on
// htmx:afterRequest and clears the textarea. When the stream ends (sandbox
// stopped), a status line is shown and no reconnect is attempted after the
// second failure - the page's HTMX refresh reflects the detached state.

(function () {
	'use strict';

	/* ---------- injected styles: message animations, typing indicator ---------- */

	function injectStyle() {
		if (document.getElementById('builder-chat-style')) return;
		const css =
			// compact chat: tighter bubbles, line height and row rhythm than
			// the daisyUI chat defaults (dense transcripts read better)
			'builder-chat .chat{padding-top:1px;padding-bottom:1px}' +
			'builder-chat .chat-bubble{padding:0.3rem 0.6rem;font-size:0.8125rem;line-height:1.4;min-height:0}' +
			// agent replies are multi-paragraph: tighter leading than the
			// short user messages, and paragraph gaps at reduced height
			'builder-chat .chat-bubble.bc-md{line-height:1.3}' +
			'builder-chat .chat-bubble pre{margin:0.25rem 0;line-height:1.45}' +
			'builder-chat .chat-bubble strong.block{margin-top:0.25rem}' +
			'@keyframes bcIn{from{opacity:0;transform:translateY(8px) scale(.98)}to{opacity:1;transform:none}}' +
			'@keyframes bcDot{0%,60%,100%{transform:translateY(0);opacity:.35}30%{transform:translateY(-4px);opacity:1}}' +
			'.bc-anim{animation:bcIn .25s ease-out both}' +
			'.bc-typing{display:inline-flex;align-items:center;gap:4px;padding:2px 4px}' +
			'.bc-typing span{width:6px;height:6px;border-radius:9999px;background:currentColor;opacity:.4;' +
			'animation:bcDot 1.2s infinite ease-in-out}' +
			'.bc-typing span:nth-child(2){animation-delay:.15s}' +
			'.bc-typing span:nth-child(3){animation-delay:.3s}' +
			'@keyframes bcPop{0%{transform:scale(1)}50%{transform:scale(1.35)}100%{transform:scale(1)}}' +
			'.bc-pop{animation:bcPop .25s ease-out}' +
			'@media (prefers-reduced-motion: reduce){.bc-anim{animation:none}.bc-typing span{animation:none;opacity:.6}' +
			'.bc-pop{animation:none}}';
		const style = document.createElement('style');
		style.id = 'builder-chat-style';
		style.textContent = css;
		document.head.appendChild(style);
	}

	/* ---------- minimal markdown rendering ---------- */
	// Safe subset for agent replies: all input is HTML-escaped first, then
	// fenced code blocks, inline code, bold, http(s) links, headings and
	// bullets are converted. Everything else stays literal text (the bubble
	// is whitespace-pre-wrap, so newlines render as-is)

	function esc(s) {
		// Quotes must be escaped too: inlineMd interpolates escaped text into
		// the link href attribute, where a raw " would break out of the value
		return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
	}

	function inlineMd(s) {
		// s is already escaped
		s = s.replace(/`([^`]+)`/g, '<code class="bg-base-300/60 px-1 rounded text-xs">$1</code>');
		s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
		s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g,
			'<a class="link" target="_blank" rel="noopener" href="$2">$1</a>');
		return s;
	}

	function mdRender(raw) {
		const parts = raw.split('```');
		let out = '';
		for (let i = 0; i < parts.length; i++) {
			if (i % 2 === 1) {
				// fenced code block; drop the language tag line
				let code = parts[i];
				const nl = code.indexOf('\n');
				if (nl >= 0) code = code.slice(nl + 1);
				else code = '';
				out += '<pre class="bg-base-300/40 rounded-box p-2 overflow-x-auto text-xs my-1"><code>' +
					esc(code.replace(/\n$/, '')) + '</code></pre>';
			} else {
				const lines = parts[i].split('\n');
				const rendered = [];
				for (let j = 0; j < lines.length; j++) {
					const line = lines[j];
					const heading = line.match(/^#{1,4}\s+(.*)$/);
					if (heading) {
						rendered.push('<strong class="block mt-1">' + inlineMd(esc(heading[1])) + '</strong>');
						continue;
					}
					const bullet = line.match(/^\s*[-*]\s+(.*)$/);
					if (bullet) {
						rendered.push('<span class="block pl-3">• ' + inlineMd(esc(bullet[1])) + '</span>');
						continue;
					}
					rendered.push(inlineMd(esc(line)));
				}
				out += rendered.join('\n');
			}
		}
		return out;
	}

	class BuilderChat extends HTMLElement {
		connectedCallback() {
			// During initial HTML parsing connectedCallback fires before the
			// element's children exist; defer init until they are parsed.
			// (HTMX swaps insert complete subtrees, where readyState is
			// already interactive/complete and the timeout path is enough)
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
			this.transcript = this.querySelector('.bc-transcript');
			this.statusEl = this.querySelector('.bc-status');
			this.streaming = this.querySelector('[data-bc-streaming] .chat-bubble');
			this.streamRaw = this.streaming ? this.streaming.textContent : '';
			this.pendingBreak = false;
			this.aborter = null;
			this.failures = 0;
			this.turnActive = this.hasAttribute('turn-active');
			if (this.turnActive) this.setStatus('The agent is working…');

			// Render markdown in the server-rendered agent bubbles (they are
			// plain escaped text from the template)
			this.querySelectorAll('.bc-md').forEach((bubble) => {
				bubble.innerHTML = mdRender(bubble.textContent);
			});

			// Optimistic user bubble + textarea clear on send
			const page = this.closest('main') || document;
			this.composer = page.querySelector('[data-builder-composer]');
			// Remember a server-disabled send button (missing permission /
			// stopped sandbox) so turn toggling never re-enables it
			const sendBtn = this.composer && this.composer.querySelector('button[type=submit]');
			this.sendLocked = !!(sendBtn && sendBtn.disabled);
			if (this.turnActive) this.setTurnActive(true);
			this.onAfterRequest = (e) => {
				if (!this.composer || !this.composer.contains(e.target)) return;
				if (e.target.matches('[data-builder-cancel]')) return;
				if (!e.detail.successful) return;
				// A rejected send (agent busy, session still starting) comes
				// back HTTP 200 with HX-Retarget and the rendered error block;
				// keep the text in the composer and skip the bubble, or the
				// chat would sit on a typing indicator that never resolves.
				// The swap is done here: htmx does not override the form's
				// hx-swap=none from the HX-Reswap header
				const errSlot = document.getElementById('bc-send-error');
				if (e.detail.xhr && e.detail.xhr.getResponseHeader('HX-Retarget')) {
					if (errSlot) errSlot.innerHTML = e.detail.xhr.responseText;
					return;
				}
				if (errSlot) errSlot.innerHTML = '';
				const area = this.composer.querySelector('textarea[name=message]');
				if (area && area.value.trim()) {
					this.appendBubble('chat-end chat-bubble-primary', area.value.trim());
					area.value = '';
					this.showTyping();
				}
			};
			document.body.addEventListener('htmx:afterRequest', this.onAfterRequest);

			// Publish dialog: destination radios toggle the app-name input
			// (glob destinations) vs the custom path input
			this.onPublishChange = (e) => {
				const radio = e.target.closest('[data-builder-publish] input[name=publish_choice]');
				if (!radio) return;
				const form = radio.closest('form');
				const custom = radio.value === '__custom__';
				const hasWildcard = !custom && radio.value.indexOf('*') >= 0;
				const suffix = form.querySelector('[data-publish-suffix]');
				const customField = form.querySelector('[data-publish-custom]');
				if (suffix) suffix.hidden = !hasWildcard;
				if (customField) customField.hidden = !custom;
			};
			document.body.addEventListener('change', this.onPublishChange);

			// Preview refresh on demand
			this.onRefreshClick = (e) => {
				const btn = e.target.closest('[data-builder-refresh]');
				if (btn) this.refreshPreview();
			};
			document.body.addEventListener('click', this.onRefreshClick);

			// Enter sends, Shift+Enter inserts a newline (chat convention)
			const area = this.composer && this.composer.querySelector('textarea[name=message]');
			if (area) {
				area.addEventListener('keydown', (e) => {
					if (e.key === 'Enter' && !e.shiftKey) {
						e.preventDefault();
						const btn = this.composer.querySelector('button[type=submit]');
						if (area.value.trim() && btn && !btn.disabled) this.composer.requestSubmit();
					}
				});
			}

			// Only stream when the session has a running sandbox. A detached
			// or published session has no live sandbox, so the event stream
			// would immediately return "no running sandbox" - the transcript
			// is already rendered and Resume re-establishes the stream
			if (this.hasAttribute('live')) {
				this.connect();
			} else {
				this.setStatus('Sandbox stopped - resume to continue');
			}
			this.scrollToEnd();
		}

		disconnectedCallback() {
			if (this.aborter) this.aborter.abort();
			document.body.removeEventListener('htmx:afterRequest', this.onAfterRequest);
			document.body.removeEventListener('click', this.onRefreshClick);
			document.body.removeEventListener('change', this.onPublishChange);
		}

		setStatus(text) {
			if (this.statusEl) this.statusEl.textContent = text || '';
		}

		setTurnActive(active) {
			const page = this.closest('main') || document;
			const cancel = page.querySelector('[data-builder-cancel]');
			if (cancel) cancel.classList.toggle('hidden', !active);
			if (this.sendLocked || !this.composer) return;
			const btn = this.composer.querySelector('button[type=submit]');
			if (btn) btn.disabled = active;
		}

		scrollToEnd() {
			if (this.transcript) this.transcript.scrollTop = this.transcript.scrollHeight;
		}

		appendBubble(cls, text) {
			this.hideTyping();
			this.lastTool = null;
			this.toolLine = null;
			const wrap = document.createElement('div');
			wrap.className = 'chat bc-anim ' + (cls.indexOf('chat-end') >= 0 ? 'chat-end' : 'chat-start');
			const bubble = document.createElement('div');
			bubble.className = 'chat-bubble whitespace-pre-wrap text-sm shadow-sm' +
				(cls.indexOf('chat-bubble-primary') >= 0 ? ' chat-bubble-primary' : ' bg-base-200 text-base-content');
			bubble.textContent = text;
			wrap.appendChild(bubble);
			this.transcript.appendChild(wrap);
			this.scrollToEnd();
			return bubble;
		}

		appendChip(text, cls) {
			this.hideTyping();
			this.lastTool = null;
			this.toolLine = null;
			const wrap = document.createElement('div');
			wrap.className = 'pl-1 bc-anim ' + cls;
			wrap.textContent = text;
			this.transcript.appendChild(wrap);
			this.scrollToEnd();
			if (this.turnActive) this.showTyping();
		}

		// Tool-call chips render the moment their event arrives (the user
		// watches what the agent is doing live). A run of tool calls shares
		// ONE line: repeats bump a ×N counter on the last chip, different
		// tools append a new chip to the same line; bubbles and errors end
		// the run
		appendToolChip(title) {
			this.hideTyping();
			if (this.lastTool && this.lastTool.label === title && this.lastTool.line.isConnected) {
				this.lastTool.count++;
				const badge = this.lastTool.badge;
				badge.textContent = '×' + this.lastTool.count;
				badge.setAttribute('data-tip', this.lastTool.count + ' ' + title + ' tool calls');
				badge.classList.remove('hidden', 'bc-pop');
				void badge.offsetWidth; // restart the pop animation
				badge.classList.add('bc-pop');
				this.scrollToEnd();
				if (this.turnActive) this.showTyping();
				return;
			}
			if (!this.toolLine || !this.toolLine.isConnected ||
				this.transcript.lastElementChild !== this.toolLine) {
				const line = document.createElement('div');
				line.className = 'pl-1 bc-anim flex items-center flex-wrap gap-x-2 gap-y-0.5 text-xs text-base-content/70';
				line.innerHTML =
					'<svg aria-hidden="true" class="w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none" ' +
					'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
					'<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 ' +
					'7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>';
				this.transcript.appendChild(line);
				this.toolLine = line;
			}
			const chip = document.createElement('span');
			chip.className = 'inline-flex items-center gap-1 font-mono bc-anim';
			const label = document.createElement('span');
			label.textContent = title;
			const badge = document.createElement('span');
			badge.className = 'badge badge-soft badge-primary badge-xs font-mono hidden tooltip tooltip-top';
			chip.append(label, badge);
			this.toolLine.appendChild(chip);
			this.lastTool = { label: title, line: this.toolLine, count: 1, badge: badge };
			this.scrollToEnd();
			if (this.turnActive) this.showTyping();
		}

		// Typing indicator: a small bouncing-dots bubble shown while the
		// agent works between visible outputs
		showTyping() {
			if (this.typingEl || this.streaming || !this.transcript) return;
			const wrap = document.createElement('div');
			wrap.className = 'chat chat-start bc-anim';
			wrap.setAttribute('data-bc-typing', '');
			wrap.innerHTML = '<div class="chat-bubble bg-base-200 text-base-content py-2">' +
				'<span class="bc-typing" role="status" aria-label="The agent is working">' +
				'<span></span><span></span><span></span></span></div>';
			this.transcript.appendChild(wrap);
			this.typingEl = wrap;
			this.scrollToEnd();
		}

		hideTyping() {
			if (this.typingEl) {
				this.typingEl.remove();
				this.typingEl = null;
			}
		}

		refreshPreview() {
			const frame = document.getElementById('builder-preview');
			if (frame) {
				// eslint-disable-next-line no-self-assign
				frame.src = frame.src;
			}
		}

		handleEvent(event) {
			switch (event.kind) {
				case 'agent_chunk':
					if (!this.streaming) {
						this.streaming = this.appendBubble('chat-start', '');
						this.streaming.classList.add('bc-md');
						this.streaming.closest('.chat').setAttribute('data-bc-streaming', '');
						this.streamRaw = '';
					}
					// separate message parts around tool calls (the server
					// inserts the same break in the durable transcript)
					if (this.pendingBreak && this.streamRaw && !this.streamRaw.endsWith('\n') &&
						!event.text.startsWith('\n')) {
						this.streamRaw += '\n\n';
					}
					this.pendingBreak = false;
					this.streamRaw += event.text;
					this.streaming.innerHTML = mdRender(this.streamRaw.replace(/^\s+/, ''));
					this.scrollToEnd();
					break;
				case 'thought_chunk':
					this.pendingBreak = true;
					this.setStatus('The agent is thinking…');
					break;
				case 'tool_call':
					this.pendingBreak = true;
					this.appendToolChip(event.title || event.tool_kind || 'tool call');
					this.setStatus('The agent is working…');
					break;
				case 'turn_started':
					this.turnActive = true;
					this.setTurnActive(true);
					this.setStatus('The agent is working…');
					this.showTyping();
					break;
				case 'turn_done':
					this.turnActive = false;
					this.setTurnActive(false);
					this.hideTyping();
					this.lastTool = null;
					this.toolLine = null;
					if (this.streaming) {
						this.streaming.closest('.chat').removeAttribute('data-bc-streaming');
						this.streaming = null;
						this.streamRaw = '';
					}
					this.setStatus('');
					this.refreshPreview();
					// pick up preview creation / status changes
					if (window.htmx) window.htmx.trigger('#session-content', 'builder-turn-done');
					break;
				case 'error':
					this.hideTyping();
					this.appendChip(event.text, 'text-error text-xs whitespace-pre-wrap');
					this.setStatus('');
					break;
				case 'status':
					if (event.status === 'building image') this.setStatus('Building the sandbox image (first run can take a few minutes)…');
					else if (event.status === 'starting sandbox') this.setStatus('Starting the agent sandbox…');
					else if (event.status === 'detached' || event.status === 'error') this.setStatus('Sandbox stopped');
					break;
			}
		}

		async connect() {
			if (this.aborter) this.aborter.abort();
			this.aborter = new AbortController();
			const url = this.getAttribute('stream');
			if (!url) return;
			try {
				const resp = await fetch(url, { signal: this.aborter.signal });
				if (!resp.ok || !resp.body) throw new Error('stream unavailable');
				this.failures = 0;
				const reader = resp.body.getReader();
				const decoder = new TextDecoder();
				let buf = '';
				for (;;) {
					const { done, value } = await reader.read();
					if (done) break;
					buf += decoder.decode(value, { stream: true });
					let idx;
					while ((idx = buf.indexOf('\n')) >= 0) {
						const line = buf.slice(0, idx).trim();
						buf = buf.slice(idx + 1);
						if (!line) continue;
						if (line.startsWith('error:')) {
							// The sandbox is gone (stopped/reaped between render
							// and connect). Show a clean resume hint, not the
							// raw "no running sandbox" error
							this.setStatus(/no running sandbox/.test(line)
								? 'Sandbox stopped - resume to continue'
								: line);
							return; // session not live; no reconnect
						}
						try {
							this.handleEvent(JSON.parse(line));
						} catch (e) { /* ignore malformed lines */ }
					}
				}
			} catch (e) {
				if (this.aborter.signal.aborted) return;
			}
			// Stream ended: sandbox stopped or transient hiccup. One quick
			// retry, then leave it to the page state
			this.failures++;
			if (this.failures <= 2 && document.contains(this)) {
				setTimeout(() => { if (document.contains(this)) this.connect(); }, 2000 * this.failures);
			} else {
				this.setStatus('Live updates disconnected - the sandbox may be stopped');
			}
		}
	}

	customElements.define('builder-chat', BuilderChat);
})();
