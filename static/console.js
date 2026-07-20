// SPDX-License-Identifier: Apache-2.0
// Shared console page behaviors: theme toggle persistence, app filter chips,
// the nav drawer toggle, the Cmd/Ctrl-K search shortcut, and the
// <secret-input> / kv-table form components.

// ---- <secret-input> ----------------------------------------------------
// A value input with a "store as secret" button: the typed value (or a
// picked file) is POSTed to the console's /secrets/store endpoint, which
// encrypts it into the db secrets provider; the input is then replaced with
// the returned {{secret ...}} template reference. Light DOM (no shadow root)
// so daisyui styles, native form participation and htmx all work. The
// element renders purely from its attributes:
//
//   name        form field name of the inner input (posts with the form)
//   value       current value; a {{secret ...}} ref renders the locked state
//   prefix      secret name prefix for generated names (context specific)
//   endpoint    the store URL, "<app path>/secrets/store"
//   input-id    id for the inner input (label for= target)
//   placeholder inner input placeholder
//   masked      render the value input as type=password until stored
//   small       compact sizing, for inline forms (input-sm/btn-sm)
//   file        offer a file picker; the file content is stored base64
//   can-create  present when the user holds secret:create; else lock disabled
//   can-delete  present when the user holds secret:delete; unlocking a
//               stored field then offers deleting the secret from the db
//   error       inline error message (set by the store fragment on failure)
//   description recorded as the secret description on store
//
// The store response fragment is a fresh <secret-input> tag which upgrades
// and re-renders on insertion. This script loads in <head> before the body
// is parsed, so elements upgrade during parsing and there is no flash of
// un-upgraded content on page loads.

function looksLikeSecretRef(value) {
	const trimmed = (value || '').trim();
	return trimmed.startsWith('{{') && /^\{\{\s*secret(_from)?\s/.test(trimmed);
}

// Extracts provider/name from a {{secret "name"}} or
// {{secret_from "provider" "name"}} reference; null when it does not match
// (hand-written refs stay untouched, only clear-not-delete is offered)
function parseSecretRef(value) {
	const trimmed = (value || '').trim();
	let m = /^\{\{\s*secret\s+"([^"]+)"\s*\}\}$/.exec(trimmed);
	if (m) {
		return { provider: '', name: m[1] };
	}
	m = /^\{\{\s*secret_from\s+"([^"]+)"\s+"([^"]+)"\s*\}\}$/.exec(trimmed);
	if (m) {
		return { provider: m[1], name: m[2] };
	}
	return null;
}

class SecretInput extends HTMLElement {
	connectedCallback() {
		this.render();
	}

	get value() {
		const input = this.querySelector('input[data-role="value"]');
		return input ? input.value : this.getAttribute('value') || '';
	}

	render() {
		const name = this.getAttribute('name') || '';
		const value = this.getAttribute('value') || '';
		const stored = looksLikeSecretRef(value);
		const canCreate = this.hasAttribute('can-create');
		const masked = this.hasAttribute('masked') && !stored;
		const inputId = this.getAttribute('input-id');
		const error = this.getAttribute('error');

		this.replaceChildren();
		const join = document.createElement('div');
		join.className = 'join w-full';

		const input = document.createElement('input');
		input.type = masked ? 'password' : 'text';
		input.name = name;
		input.value = value;
		input.autocomplete = 'off';
		input.spellcheck = false;
		input.dataset.role = 'value';
		input.className = this.hasAttribute('small')
			? 'input input-sm w-full font-mono text-xs join-item'
			: 'input w-full font-mono text-sm join-item';
		if (inputId) {
			// A page label targets the input via for=; otherwise give the
			// input an accessible name itself
			input.id = inputId;
		} else {
			// "params_value" -> "params value", "value" -> "value"
			const base = name.replace(/_?value$/, '');
			input.setAttribute('aria-label', base ? base + ' value' : 'value');
		}
		if (this.getAttribute('placeholder')) {
			input.placeholder = this.getAttribute('placeholder');
		}
		if (stored) {
			input.readOnly = true;
			input.classList.add('bg-base-200', 'tooltip', 'tooltip-top');
			input.setAttribute('data-tip', 'Stored secret reference');
		}
		join.appendChild(input);

		if (stored) {
			join.appendChild(this.makeButton('secret-unlock',
				this.hasAttribute('can-delete')
					? 'Stored as a secret - click to replace or delete it'
					: 'Stored as a secret - click to clear and enter a new value',
				false, () => this.unlockClicked()));
		} else {
			if (this.hasAttribute('file')) {
				const fileInput = document.createElement('input');
				fileInput.type = 'file';
				fileInput.hidden = true;
				fileInput.addEventListener('change', () => this.fileChosen(fileInput));
				this.appendChild(fileInput);
				join.appendChild(this.makeButton('secret-file',
					canCreate ? 'Store a file as a secret' : 'requires secret:create',
					!canCreate, () => fileInput.click()));
			}
			const lock = this.makeButton('secret-lock',
				canCreate ? 'Encrypt and store as a secret' : 'requires secret:create',
				!canCreate, canCreate ? () => this.lockClicked() : null);
			if (canCreate) {
				// hx- attributes only on the enabled button: a disabled
				// button with hx-disabled-elt matches the in-flight spinner
				// CSS and would show a permanent spinner. The request fires
				// on the custom event (not click): the click first opens the
				// description dialog, which triggers the event on confirm
				lock.setAttribute('hx-post', this.getAttribute('endpoint') || '');
				lock.setAttribute('hx-trigger', 'secret-store');
				lock.setAttribute('hx-target', 'closest secret-input');
				lock.setAttribute('hx-swap', 'outerHTML');
				// The button sits inside the page form; without this htmx
				// would post the entire enclosing form to the store
				// endpoint. The actual parameters are injected in
				// htmx:configRequest
				lock.setAttribute('hx-params', 'none');
				lock.setAttribute('hx-disabled-elt', 'this');
			}
			join.appendChild(lock);
		}
		this.insertBefore(join, this.firstChild);

		if (error) {
			const line = document.createElement('p');
			line.className = 'text-xs text-error mt-1';
			line.textContent = error;
			this.appendChild(line);
		}

		if (!this.dataset.wired) {
			this.dataset.wired = 'true';
			this.addEventListener('htmx:configRequest', (event) => this.configRequest(event));
		}

		// Wire the hx- attributes of the freshly rendered buttons. Needed on
		// every render, not just insertion: an error/undo re-render creates a
		// new lock button which htmx has not seen. Also covers kv-table row
		// clones (htmx only auto-processes its own swaps). During the initial
		// page parse htmx is already loaded (both scripts are in <head>), and
		// re-processing already initialized nodes is safe
		if (window.htmx) {
			window.htmx.process(this);
		}
	}

	makeButton(icon, tip, disabled, onClick) {
		const btn = document.createElement('button');
		btn.type = 'button';
		// daisy tooltip like the rest of the console; left, over the input,
		// which always has room (the button is the right end of the join)
		btn.className = this.hasAttribute('small')
			? 'btn btn-sm btn-square join-item tooltip tooltip-left'
			: 'btn btn-square join-item tooltip tooltip-left';
		btn.setAttribute('data-tip', tip);
		btn.setAttribute('aria-label', tip);
		btn.disabled = disabled;
		btn.innerHTML = SecretInput.icons[icon];
		if (onClick) {
			btn.addEventListener('click', onClick);
		}
		return btn;
	}

	lockClicked() {
		// Prompt for an optional secret description before storing. An
		// invalid value skips the dialog and fires the request anyway, so
		// configRequest renders its usual inline error. Cancel leaves the
		// field exactly as it was
		const fire = () => {
			const lock = this.querySelector('button[hx-post]');
			if (lock && window.htmx) {
				window.htmx.trigger(lock, 'secret-store');
			}
		};
		if (!this.pendingFile) {
			const value = this.value.trim();
			if (!value || looksLikeSecretRef(value)) {
				fire();
				return;
			}
		}
		showSecretDescriptionDialog(this.getAttribute('description') || '',
			this.getAttribute('prefix') || '',
			(store) => {
				this.pendingStore = store;
				fire();
			},
			() => {
				this.pendingFile = null;
			});
	}

	unlockClicked() {
		// With secret:delete held, unlocking offers deleting the stored
		// secret from the database; otherwise (or for a hand-written ref the
		// component cannot parse) the field is just cleared, keeping the secret
		const ref = parseSecretRef(this.value);
		if (!ref || !this.hasAttribute('can-delete')) {
			this.makeEditable();
			return;
		}
		showSecretUnlockDialog(ref.name,
			() => this.makeEditable(),
			() => this.deleteSecret(ref));
	}

	deleteSecret(ref) {
		// POST to the delete endpoint; the response fragment replaces this
		// element (empty editable field on success, locked state + error
		// message on failure). configRequest injects the parameters
		this.deleteParams = ref;
		// The element sits inside the page form: without this htmx would post
		// the whole form, whose fields (e.g. "name") would collide
		this.setAttribute('hx-params', 'none');
		if (window.htmx) {
			window.htmx.ajax('POST',
				(this.getAttribute('endpoint') || '').replace(/\/store$/, '/delete'),
				{ source: this, target: this, swap: 'outerHTML' });
		}
	}

	makeEditable() {
		// Clearing the reference does not delete the stored secret; the field
		// just goes back to accepting a plain value
		this.removeAttribute('value');
		this.removeAttribute('error');
		this.render();
		const input = this.querySelector('input[data-role="value"]');
		if (input) {
			input.focus();
		}
	}

	fileChosen(fileInput) {
		const file = fileInput.files && fileInput.files[0];
		if (!file) {
			return;
		}
		if (file.size > 1024 * 1024) {
			this.showError('file is larger than the 1MB secret size limit');
			return;
		}
		const reader = new FileReader();
		reader.onload = () => {
			// readAsDataURL result is "data:<mime>;base64,<data>"
			this.pendingFile = {
				b64: String(reader.result).split(',', 2)[1] || '',
				name: file.name,
			};
			this.lockClicked();
		};
		reader.onerror = () => this.showError('could not read the file');
		reader.readAsDataURL(file);
	}

	showError(message) {
		this.setAttribute('error', message);
		this.render();
	}

	configRequest(event) {
		const params = event.detail.parameters;
		const set = (key, val) => {
			if (typeof params.set === 'function') {
				params.set(key, val);
			} else {
				params[key] = val;
			}
		};
		const del = this.deleteParams;
		if (del) {
			// Delete request (deleteSecret): name/provider parsed from the
			// reference; the ref itself re-renders the locked state on failure
			this.deleteParams = null;
			set('name', del.name);
			set('provider', del.provider || '');
			set('ref', this.getAttribute('value') || '');
			this.echoRenderAttrs(set);
			return;
		}
		const file = this.pendingFile;
		this.pendingFile = null;
		if (!file) {
			const value = this.value.trim();
			if (!value) {
				event.preventDefault();
				this.showError('enter a value to store as a secret');
				return;
			}
			if (looksLikeSecretRef(value)) {
				event.preventDefault();
				this.showError('the value is already a secret reference');
				return;
			}
			set('value', value);
		} else {
			set('value_b64', file.b64);
			set('source_file', file.name);
		}
		this.echoRenderAttrs(set);
		const store = this.pendingStore;
		if (store) {
			this.pendingStore = null;
			// Dialog values win over the preset attributes echoed above. The
			// store_* keys drive only this store; the element's own prefix
			// attribute is untouched for later stores
			set('description', store.description);
			if (store.key) {
				set('store_key', store.key);
			} else if (store.prefix) {
				set('store_prefix', store.prefix);
			}
		}
	}

	// Echo the rendering attributes so the response fragment can reproduce
	// this element
	echoRenderAttrs(set) {
		set('field', this.getAttribute('name') || '');
		set('prefix', this.getAttribute('prefix') || '');
		for (const attr of ['input-id', 'placeholder', 'description']) {
			if (this.getAttribute(attr)) {
				set(attr.replace('-', '_'), this.getAttribute(attr));
			}
		}
		for (const flag of ['masked', 'file', 'small']) {
			if (this.hasAttribute(flag)) {
				set(flag, 'true');
			}
		}
	}
}
SecretInput.icons = {
	// heroicons mini: lock-closed, lock-open, paper-clip (MIT)
	'secret-lock':
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="size-4" aria-hidden="true">' +
		'<path fill-rule="evenodd" d="M10 1a4.5 4.5 0 0 0-4.5 4.5V9H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-.5V5.5A4.5 4.5 0 0 0 10 1Zm3 8V5.5a3 3 0 1 0-6 0V9h6Z" clip-rule="evenodd"/></svg>',
	'secret-unlock':
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="size-4 text-success" aria-hidden="true">' +
		'<path d="M14.5 1A4.5 4.5 0 0 0 10 5.5V9H3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-1.5V5.5a3 3 0 1 1 6 0v2.75a.75.75 0 0 0 1.5 0V5.5A4.5 4.5 0 0 0 14.5 1Z"/></svg>',
	'secret-file':
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="size-4" aria-hidden="true">' +
		'<path fill-rule="evenodd" d="M15.621 4.379a3 3 0 0 0-4.242 0l-7 7a3 3 0 0 0 4.241 4.243h.001l.497-.5a.75.75 0 0 1 1.064 1.057l-.498.501-.002.002a4.5 4.5 0 0 1-6.364-6.364l7-7a4.5 4.5 0 0 1 6.368 6.36l-3.455 3.553A2.625 2.625 0 1 1 9.52 9.52l3.45-3.451a.75.75 0 1 1 1.061 1.06l-3.45 3.451a1.125 1.125 0 0 0 1.587 1.595l3.454-3.553a3 3 0 0 0 0-4.242Z" clip-rule="evenodd"/></svg>',
};
customElements.define('secret-input', SecretInput);

// Three-way dialog shown when unlocking a stored secret-input with
// secret:delete held: keep the stored secret (the field is just cleared) or
// also delete it from the database. Cancel/Escape leaves the field locked.
function showSecretUnlockDialog(name, onKeep, onDelete) {
	let dialog = document.getElementById('secret-unlock-dialog');
	if (!dialog) {
		dialog = document.createElement('dialog');
		dialog.id = 'secret-unlock-dialog';
		dialog.className = 'modal';
		dialog.setAttribute('aria-labelledby', 'secret-unlock-title');
		dialog.setAttribute('aria-describedby', 'secret-unlock-text');
		dialog.innerHTML =
			'<div class="modal-box max-w-md">' +
			'<h3 id="secret-unlock-title" class="text-base font-semibold mb-2">Stop using this secret?</h3>' +
			'<p id="secret-unlock-text" class="text-sm text-base-content/70 break-words"></p>' +
			'<div class="modal-action mt-5">' +
			'<button id="secret-unlock-cancel" class="btn btn-ghost btn-sm">Cancel</button>' +
			'<button id="secret-unlock-keep" class="btn btn-sm btn-primary">Keep secret</button>' +
			'<button id="secret-unlock-delete" class="btn btn-sm btn-error">Delete secret</button>' +
			'</div></div>' +
			'<form method="dialog" class="modal-backdrop"><button>close</button></form>';
		document.body.appendChild(dialog);
		const run = (which) => {
			const actions = dialog.pendingActions;
			dialog.pendingActions = null;
			dialog.close();
			if (actions && actions[which]) {
				actions[which]();
			}
		};
		dialog.querySelector('#secret-unlock-cancel').addEventListener('click', () => dialog.close());
		dialog.querySelector('#secret-unlock-keep').addEventListener('click', () => run('keep'));
		dialog.querySelector('#secret-unlock-delete').addEventListener('click', () => run('delete'));
		dialog.addEventListener('close', () => {
			dialog.pendingActions = null;
		});
	}

	dialog.querySelector('#secret-unlock-text').innerText =
		'The field goes back to accepting a plain value. Should the stored secret "' +
		name + '" also be deleted from the database? Deleting can break other ' +
		'apps or settings that still reference this secret.';
	dialog.pendingActions = { keep: onKeep, delete: onDelete };
	dialog.showModal();
	// Focus Cancel so Enter does not trigger an action by accident
	dialog.querySelector('#secret-unlock-cancel').focus();
}

// Dialog shown when the lock button is clicked: how the secret is named
// (a generated name from an editable prefix - the default - or an exact
// name typed by the user) plus an optional description recorded on the
// secret. Store proceeds; Cancel/Escape/backdrop leaves the field untouched
function showSecretDescriptionDialog(initialDesc, prefix, onStore, onCancel) {
	let dialog = document.getElementById('secret-desc-dialog');
	if (!dialog) {
		dialog = document.createElement('dialog');
		dialog.id = 'secret-desc-dialog';
		dialog.className = 'modal';
		dialog.setAttribute('aria-labelledby', 'secret-desc-title');
		dialog.innerHTML =
			'<div class="modal-box max-w-md">' +
			'<h3 id="secret-desc-title" class="text-base font-semibold mb-2">Store as a secret</h3>' +
			'<p class="text-sm text-base-content/70 mb-3">The value is encrypted into the secret store ' +
			'and the field keeps a reference to it.</p>' +
			'<fieldset class="mb-3">' +
			'<legend class="block text-sm font-medium mb-1">Secret name</legend>' +
			'<label class="flex items-center gap-2 text-sm cursor-pointer mb-1">' +
			'<input type="radio" name="secret-desc-mode" id="secret-desc-mode-prefix" class="radio radio-xs radio-primary" checked />' +
			'Generated, from a name prefix</label>' +
			'<div class="flex items-center gap-2 mb-2 pl-6">' +
			'<input id="secret-desc-prefix" type="text" autocomplete="off" spellcheck="false" ' +
			'aria-label="secret name prefix" class="input input-sm w-full font-mono text-xs" />' +
			'<span class="text-xs text-base-content/70 whitespace-nowrap">+ random suffix</span></div>' +
			'<label class="flex items-center gap-2 text-sm cursor-pointer mb-1">' +
			'<input type="radio" name="secret-desc-mode" id="secret-desc-mode-key" class="radio radio-xs radio-primary" />' +
			'Exact name</label>' +
			'<div class="pl-6">' +
			'<input id="secret-desc-key" type="text" autocomplete="off" spellcheck="false" disabled ' +
			'placeholder="my_secret_name" aria-label="exact secret name" class="input input-sm w-full font-mono text-xs" /></div>' +
			'<p id="secret-desc-error" class="text-xs text-error mt-1" hidden></p>' +
			'</fieldset>' +
			'<label class="block text-sm font-medium mb-1" for="secret-desc-input">Description (optional)</label>' +
			'<input id="secret-desc-input" type="text" autocomplete="off" ' +
			'placeholder="what this secret is for" class="input w-full text-sm" />' +
			'<div class="modal-action mt-5">' +
			'<button id="secret-desc-cancel" class="btn btn-ghost btn-sm">Cancel</button>' +
			'<button id="secret-desc-store" class="btn btn-sm btn-primary">Store secret</button>' +
			'</div></div>' +
			'<form method="dialog" class="modal-backdrop"><button>close</button></form>';
		document.body.appendChild(dialog);
		const input = dialog.querySelector('#secret-desc-input');
		const prefixRadio = dialog.querySelector('#secret-desc-mode-prefix');
		const keyRadio = dialog.querySelector('#secret-desc-mode-key');
		const prefixInput = dialog.querySelector('#secret-desc-prefix');
		const keyInput = dialog.querySelector('#secret-desc-key');
		const errorLine = dialog.querySelector('#secret-desc-error');
		const syncMode = () => {
			prefixInput.disabled = keyRadio.checked;
			keyInput.disabled = prefixRadio.checked;
			errorLine.hidden = true;
		};
		prefixRadio.addEventListener('change', syncMode);
		keyRadio.addEventListener('change', syncMode);
		const store = () => {
			const exact = keyRadio.checked;
			const prefixVal = prefixInput.value.trim();
			const keyVal = keyInput.value.trim();
			if (exact ? !keyVal : !prefixVal) {
				errorLine.textContent = exact ? 'enter the secret name' : 'enter a name prefix';
				errorLine.hidden = false;
				(exact ? keyInput : prefixInput).focus();
				return;
			}
			const actions = dialog.pendingActions;
			dialog.pendingActions = null;
			dialog.close();
			if (actions && actions.store) {
				actions.store({
					description: input.value.trim(),
					prefix: exact ? '' : prefixVal,
					key: exact ? keyVal : '',
				});
			}
		};
		dialog.querySelector('#secret-desc-store').addEventListener('click', store);
		dialog.querySelector('#secret-desc-cancel').addEventListener('click', () => dialog.close());
		for (const el of [input, prefixInput, keyInput]) {
			el.addEventListener('keydown', (event) => {
				if (event.key === 'Enter') {
					event.preventDefault();
					store();
				}
			});
		}
		// Fires on every close path (cancel button, Escape, backdrop); the
		// store path clears pendingActions first so this is cancel-only
		dialog.addEventListener('close', () => {
			const actions = dialog.pendingActions;
			dialog.pendingActions = null;
			if (actions && actions.cancel) {
				actions.cancel();
			}
		});
	}

	dialog.querySelector('#secret-desc-input').value = initialDesc || '';
	dialog.querySelector('#secret-desc-prefix').value = prefix || '';
	dialog.querySelector('#secret-desc-key').value = '';
	dialog.querySelector('#secret-desc-mode-prefix').checked = true;
	dialog.querySelector('#secret-desc-mode-key').checked = false;
	dialog.querySelector('#secret-desc-prefix').disabled = false;
	dialog.querySelector('#secret-desc-key').disabled = true;
	dialog.querySelector('#secret-desc-error').hidden = true;
	dialog.pendingActions = { store: onStore, cancel: onCancel };
	dialog.showModal();
	dialog.querySelector('#secret-desc-input').focus();
}

// ---- kv-table row helpers ----------------------------------------------
// The kv_table template renders KEY=value rows (value is a <secret-input>)
// plus a <template> holding an empty row. Rows added from the template
// self-initialize: the secret-input upgrade happens on insertion

function addKvRow(btn) {
	const table = btn.closest('.kv-table');
	const template = table.querySelector('template');
	const row = template.content.firstElementChild.cloneNode(true);
	template.before(row);
	const key = row.querySelector('input');
	if (key) {
		key.focus();
	}
}

function removeKvRow(btn) {
	const table = btn.closest('.kv-table');
	const row = btn.closest('.kv-row');
	// Keep one row so the table never collapses to just the Add button
	if (table.querySelectorAll('.kv-row').length <= 1) {
		const key = row.querySelector('input');
		const secret = row.querySelector('secret-input');
		if (key) {
			key.value = '';
		}
		if (secret) {
			secret.removeAttribute('value');
			secret.removeAttribute('error');
			secret.render();
		}
		return;
	}
	row.remove();
}

// ---- binding-table row helpers ------------------------------------------
// The app form's service bindings section renders <select name=bindings>
// rows plus a <template> holding an empty row. Unlike the kv table, zero
// rows is a valid state (most apps have no bindings), so removing the last
// row removes it outright

function addBindingRow(btn) {
	const table = btn.closest('.binding-table');
	const template = table.querySelector('template');
	const row = template.content.firstElementChild.cloneNode(true);
	template.before(row);
	const select = row.querySelector('select');
	if (select) {
		select.focus();
	}
}

function removeBindingRow(btn) {
	btn.closest('.binding-row').remove();
}

// ---- boosted form submit indicator ---------------------------------------
// The full-page operation forms are hx-boosted: while the request is in
// flight htmx adds .htmx-request to the form (its submit buttons disable,
// see accessibility.css) and #page-progress shows via hx-indicator. The
// clicked submit button additionally gets the inline spinner: mark it from
// the submit event's submitter, since CSS cannot tell which of a form's
// buttons was clicked (e.g. Validate vs Create app)

document.addEventListener('htmx:beforeRequest', (event) => {
	const submitter = event.detail.requestConfig?.triggeringEvent?.submitter;
	if (submitter && submitter.matches('button[type=submit]')) {
		submitter.classList.add('btn-inflight');
	}
});

document.addEventListener('htmx:afterRequest', () => {
	// The boost body swap usually replaces the form; clean up for the
	// responses that leave the page in place (e.g. a network failure)
	for (const btn of document.querySelectorAll('.btn-inflight')) {
		btn.classList.remove('btn-inflight');
	}
});

// Close any open <details class="dropdown"> when clicking outside it
// (native details elements stay open otherwise). Capture phase so a click
// that opens one dropdown still closes the others
document.addEventListener('click', (event) => {
	for (const details of document.querySelectorAll('details.dropdown[open]')) {
		if (!details.contains(event.target)) {
			details.removeAttribute('open');
		}
	}
});

// Open/close the nav drawer from the hamburger button. The daisyui drawer is
// driven by the hidden #nav-drawer checkbox; the button keeps aria-expanded
// in sync (also when the overlay click closes the drawer)
function toggleNavDrawer(btn) {
	const drawer = document.getElementById('nav-drawer');
	if (!drawer) {
		return;
	}
	drawer.checked = !drawer.checked;
	btn.setAttribute('aria-expanded', drawer.checked ? 'true' : 'false');
	if (drawer.checked) {
		const nav = document.getElementById('main-nav');
		if (nav) {
			nav.focus();
		}
	}
}

// Show an error toast for failed API calls; replaces the previous message
// and auto-dismisses
function showApiError(message) {
	let toast = document.getElementById('api-error-toast');
	if (!toast) {
		toast = document.createElement('div');
		toast.id = 'api-error-toast';
		toast.className = 'toast toast-top toast-center z-50';
		toast.innerHTML =
			'<div role="alert" class="alert alert-error text-sm shadow-lg">' +
			'<span>✕</span><span id="api-error-text" class="break-all"></span>' +
			'<button class="btn btn-xs btn-ghost" ' +
			'onclick="this.closest(\'#api-error-toast\').remove()">Dismiss</button>' +
			'</div>';
		document.body.appendChild(toast);
	}
	document.getElementById('api-error-text').innerText = message;
	clearTimeout(showApiError.timer);
	showApiError.timer = setTimeout(() => toast.remove(), 8000);
}

// Styled replacement for the native hx-confirm dialog. The confirm button
// picks up a destructive style when the question starts with Delete/Remove
function showConfirmDialog(question, onConfirm) {
	let dialog = document.getElementById('confirm-dialog');
	if (!dialog) {
		dialog = document.createElement('dialog');
		dialog.id = 'confirm-dialog';
		dialog.className = 'modal';
		dialog.setAttribute('aria-labelledby', 'confirm-dialog-title');
		dialog.setAttribute('aria-describedby', 'confirm-dialog-text');
		dialog.innerHTML =
			'<div class="modal-box max-w-md">' +
			'<h3 id="confirm-dialog-title" class="text-base font-semibold mb-2">Please confirm</h3>' +
			'<p id="confirm-dialog-text" class="text-sm text-base-content/70 break-words"></p>' +
			'<div class="modal-action mt-5">' +
			'<button id="confirm-dialog-cancel" class="btn btn-ghost btn-sm">Cancel</button>' +
			'<button id="confirm-dialog-ok" class="btn btn-sm"></button>' +
			'</div></div>' +
			'<form method="dialog" class="modal-backdrop"><button>close</button></form>';
		document.body.appendChild(dialog);
		dialog.querySelector('#confirm-dialog-cancel').addEventListener('click', () => dialog.close());
		dialog.querySelector('#confirm-dialog-ok').addEventListener('click', () => {
			const confirm = dialog.pendingConfirm;
			dialog.pendingConfirm = null;
			dialog.close();
			if (confirm) {
				confirm();
			}
		});
		dialog.addEventListener('close', () => {
			dialog.pendingConfirm = null;
		});
	}

	dialog.querySelector('#confirm-dialog-text').innerText = question;
	const okButton = dialog.querySelector('#confirm-dialog-ok');
	const destructive = /^(delete|remove)/i.exec(question);
	okButton.innerText = destructive ? destructive[0] : 'Confirm';
	okButton.className =
		'btn btn-sm transition-transform duration-150 active:scale-95 ' +
		(destructive ? 'btn-error' : 'btn-primary');

	dialog.pendingConfirm = onConfirm;
	dialog.showModal();
	// Focus Cancel so Enter does not trigger the action by accident
	dialog.querySelector('#confirm-dialog-cancel').focus();
}

// Show the top progress bar while navigating to the next page. Hidden again
// on pageshow, which also covers back/forward cache restores
function showNavProgress() {
	const bar = document.getElementById('nav-progress');
	if (bar) {
		bar.classList.add('active');
	}
}

window.addEventListener('pageshow', () => {
	const bar = document.getElementById('nav-progress');
	if (bar) {
		bar.classList.remove('active');
	}
});

document.addEventListener('DOMContentLoaded', () => {
	// Navigation feedback for regular link clicks and form submits
	document.body.addEventListener('click', (event) => {
		const link = event.target.closest('a[href]');
		if (
			!link ||
			link.target === '_blank' ||
			link.origin !== location.origin ||
			link.getAttribute('href').startsWith('#') ||
			link.hasAttribute('hx-get') ||
			link.classList.contains('btn-disabled') ||
			event.metaKey ||
			event.ctrlKey ||
			event.shiftKey ||
			event.altKey
		) {
			return;
		}
		// Current-page links do not need a document teardown/repaint. This is
		// especially noticeable on the sidebar logo when Apps is already open.
		if (link.href === location.href) {
			event.preventDefault();
			return;
		}
		showNavProgress();
	});
	document.body.addEventListener('submit', (event) => {
		// HTMX-managed forms swap in place without navigating, so the
		// navigation progress bar would never clear for them; they have
		// their own hx-indicator
		const form = event.target;
		if (form && form.matches && form.matches('[hx-post], [hx-get], [hx-put], [hx-patch], [hx-delete]')) {
			return;
		}
		showNavProgress();
	});

	// Generic error handling for all HTMX API calls
	document.body.addEventListener('htmx:sendError', () => {
		showApiError('API call failed: server is not reachable');
	});
	document.body.addEventListener('htmx:responseError', (event) => {
		const detail = event.detail.xhr.responseText || event.detail.xhr.statusText;
		showApiError('API call failed: ' + detail);
	});

	// Render hx-confirm questions in a styled dialog instead of the native
	// browser confirm
	document.body.addEventListener('htmx:confirm', (event) => {
		if (!event.detail.question) {
			return; // element has no hx-confirm set
		}
		event.preventDefault();
		showConfirmDialog(event.detail.question, () => {
			event.detail.issueRequest(true); // true skips asking again
		});
	});
	// Persist the user's theme choice. The toggle's initial state is set by
	// an inline script next to it in the sidebar, before first paint, so the
	// swap animation does not play on page load
	const toggle = document.getElementById('theme-toggle');
	if (toggle) {
		toggle.addEventListener('change', (event) => {
			const theme = event.target.checked ? 'light' : 'dark';
			document.documentElement.setAttribute('data-theme', 'openrun-' + theme);
			localStorage.setItem('theme', theme);
		});
	}

	// Keep the hamburger's aria-expanded in sync when the drawer is closed
	// by the overlay click instead of the button
	const drawer = document.getElementById('nav-drawer');
	if (drawer) {
		drawer.addEventListener('change', () => {
			for (const btn of document.querySelectorAll('[aria-controls="main-nav"]')) {
				btn.setAttribute('aria-expanded', drawer.checked ? 'true' : 'false');
			}
		});
	}

	// Cmd/Ctrl-K focuses the search box; Escape clears it (or closes the
	// nav drawer when it is open)
	document.addEventListener('keydown', (event) => {
		if (event.key == 'Escape') {
			const drawer = document.getElementById('nav-drawer');
			if (drawer && drawer.checked) {
				drawer.checked = false;
				drawer.dispatchEvent(new Event('change'));
				const btn = document.querySelector('[aria-controls="main-nav"]');
				if (btn) {
					btn.focus();
				}
				return;
			}
		}
		const search = document.getElementById('page-search');
		if (!search) {
			return;
		}
		if ((event.metaKey || event.ctrlKey) && event.key == 'k') {
			event.preventDefault();
			search.focus();
			search.select();
		} else if (
			event.key == 'Escape' &&
			document.activeElement == search &&
			search.value != ''
		) {
			search.value = '';
			search.dispatchEvent(new Event('input'));
		}
	});
});
