#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - read a single field from cores.json
 *
 * Usage: meta.uc <core> <dot.path>
 * Prints the raw string value (or JSON for non-string values).
 */
'use strict';

const fs = require('fs');

const core = ARGV[0];
const path = ARGV[1];

if (!core || !path)
	exit(1);

let all;

try {
	all = json(fs.readfile('/usr/share/gtools/cores.json'));
}
catch (e) {
	exit(1);
}

let value = all ? all[core] : null;

if (value == null)
	exit(1);

const parts = split(path, '.');

for (let i = 0; i < length(parts); i++) {
	value = value[parts[i]];

	if (value == null)
		exit(1);
}

if (type(value) == 'string')
	printf('%s\n', value);
else
	printf('%J\n', value);
