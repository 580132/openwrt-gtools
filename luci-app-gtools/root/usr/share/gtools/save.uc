#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - apply the settings submitted by the LuCI page
 *
 * Usage:
 *   save.uc '<json>'
 *
 * The JSON document maps section names to option/value pairs, e.g.:
 *   { "main": { "keep_backups": "3" }, "honk": { "channel": "beta" } }
 *
 * Writing the configuration here instead of using LuCI's uci JS module keeps
 * the page independent from the global "unsaved changes" workflow, which
 * otherwise reports "There are no changes to apply".
 */
'use strict';

const uci = require('uci');

const raw = ARGV[0] || '';

if (!length(raw))
	exit(1);

let data;

try {
	data = json(raw);
}
catch (e) {
	exit(1);
}

if (type(data) != 'object')
	exit(1);

const MAIN_OPTS = {
	download_proxy: 'string',
	api_proxy: 'string',
	api_token: 'string',
	keep_backups: 'keep',
	verify_sha256: 'bool',
	auto_rollback: 'bool',
	auto_check: 'bool'
};

const CORE_OPTS = {
	enabled: 'bool',
	channel: 'channel',
	variant: 'variant',
	allocator: 'allocator'
};

function has_control_chars(s) {
	for (let i = 0; i < length(s); i++) {
		const c = ord(substr(s, i, 1));

		if (c < 32 || c == 127)
			return true;
	}

	return false;
}

function valid_value(kind, value) {
	if (type(value) != 'string')
		return false;

	switch (kind) {
	case 'bool':
		return value == '0' || value == '1';

	case 'keep':
		if (!match(value, /^[0-9]+$/))
			return false;

		return +value >= 1 && +value <= 10;

	case 'channel':
		return value == 'auto' || value == 'stable' ||
		       value == 'beta' || value == 'debug';

	case 'variant':
		return value == 'full' || value == 'clash-api' ||
		       value == 'native-api';

	case 'allocator':
		return value == 'mimalloc' || value == 'stock';

	default:
		return !has_control_chars(value) && length(value) <= 2048;
	}
}

const ctx = uci.cursor();
let changed = 0;

for (let section in data) {
	const opts = data[section];
	const kinds = (section == 'main') ? MAIN_OPTS : CORE_OPTS;

	if (type(opts) != 'object')
		continue;

	if (section != 'main' && !match(section, /^[a-z0-9_]+$/))
		continue;

	for (let opt in opts) {
		if (!kinds[opt])
			continue;

		const value = opts[opt];

		if (!valid_value(kinds[opt], value))
			continue;

		ctx.set('gtools', section, opt, value);
		changed++;
	}
}

if (changed) {
	if (!ctx.commit('gtools')) {
		printf('无法保存配置\n');
		exit(1);
	}
}

printf('%d\n', changed);
