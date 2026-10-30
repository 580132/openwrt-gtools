#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - turn a GitHub "expanded_assets" page into a releases.json subset
 *
 * Usage:
 *   assets.uc <expanded_assets.html> <tag> <published> <prerelease 0|1>
 *
 * Prints a JSON array with a single release object, shaped like the payload
 * of the GitHub REST API, so select.uc can consume it unchanged.
 */
'use strict';

const fs = require('fs');

const file      = ARGV[0] || '';
const tag       = ARGV[1] || '';
const published = ARGV[2] || '';
const prerelease = ARGV[3] == '1';

if (!length(tag))
	exit(1);

const html = fs.readfile(file) || '';

if (!length(html))
	exit(1);

const prefix = '/releases/download/' + tag + '/';
const parts = split(html, prefix);
const assets = [];
const seen = {};

for (let i = 1; i < length(parts); i++) {
	const m = match(parts[i], /^([^"]+)/);

	if (!m)
		continue;

	const name = m[1];

	if (seen[name])
		continue;

	seen[name] = true;
	push(assets, { name: name });
}

if (!length(assets))
	exit(1);

printf('%J\n', [ {
	tag_name: tag,
	published_at: published,
	prerelease: prerelease,
	draft: false,
	assets: assets
} ]);
