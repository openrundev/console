// Loads the parsing core from static/logtail.js for Node tests. The file is
// a classic browser script (an app static asset, not a module), so it is
// evaluated with a CommonJS-style module shim rather than require()d - the
// nearest package.json declares "type": "module" which would break require.
'use strict';

const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'static', 'logtail.js'), 'utf8');
const mod = { exports: {} };
new Function('module', 'exports', src)(mod, mod.exports);
module.exports = mod.exports;
