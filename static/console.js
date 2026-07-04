// Shared console page behaviors: theme toggle persistence, app filter chips,
// and the Cmd/Ctrl-K search shortcut.

// Set the app list filter chip and trigger the HTMX refresh via the hidden input
function setAppFilter(btn, value) {
	const input = document.getElementById('app-filter-value');
	if (!input) {
		return;
	}
	input.value = value;
	// The buttons live outside the htmx swap target, update the highlight
	// here. Join chips use btn-primary, stat blocks use a primary tint
	for (const sibling of btn.parentElement.children) {
		const active = sibling === btn;
		if (sibling.classList.contains('join-item')) {
			sibling.classList.toggle('btn-primary', active);
		} else {
			sibling.classList.toggle('bg-primary/5', active);
			for (const v of sibling.querySelectorAll('.stat-value')) {
				v.classList.toggle('text-primary', active);
			}
		}
	}
	input.dispatchEvent(new Event('change'));
}

// Reset the page search box, and filter chips back to "All" when the page
// has them (used from list empty states)
function clearAppFilter() {
	const search = document.getElementById('page-search');
	const filter = document.getElementById('app-filter-value');
	if (search) {
		search.value = '';
	}
	if (filter) {
		const first = filter.parentElement.querySelector('.join button, .stats button');
		if (first) {
			setAppFilter(first, first.dataset.filter || '');
		} else {
			filter.value = '';
			filter.dispatchEvent(new Event('change'));
		}
	} else if (search) {
		search.dispatchEvent(new Event('input'));
	}
	if (search) {
		search.focus();
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
			'<div class="alert alert-error text-sm shadow-lg">' +
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
		dialog.innerHTML =
			'<div class="modal-box max-w-md">' +
			'<h3 class="text-base font-semibold mb-2">Please confirm</h3>' +
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
		showNavProgress();
	});
	document.body.addEventListener('submit', () => {
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

	// Cmd/Ctrl-K focuses the search box; Escape clears it
	document.addEventListener('keydown', (event) => {
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
