#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - list candidate releases from the GitHub releases.atom feed
 *
 * Usage:
 *   feed.uc <core> <channel> <atom.xml>
 *
 * Prints tab separated lines, newest first:
 *   <tag>	<published>	<prerelease 0|1>
 *
 * The atom feed is served from the regular github.com host, so it is not
 * subject to the 60 requests/hour limit of the REST API. It is used as a
 * fallback when the API is unavailable or rate limited.
 */
'use strict';

const fs = require('fs');

const core    = ARGV[0];
const channel = ARGV[1] || 'auto';
const file    = ARGV[2] || '';

let debugPrefix = 'debug.';

try {
	const all = json(fs.readfile('/usr/share/gtools/cores.json')) || {};
	const meta = all[core] || {};
	const asset = meta.asset || {};

	if (asset.debug_prefix)
		debugPrefix = asset.debug_prefix;
}
catch (e) {
	/* keep the default prefix */
}

const xml = fs.readfile(file) || '';

if (!length(xml))
	exit(1);

function entry_tag(chunk) {
	let m = match(chunk, /\/releases\/tag\/([^"<]+)/);

	if (m)
		return m[1];

	m = match(chunk, /Repository\/[0-9]+\/([^<]+)/);

	if (m)
		return m[1];

	m = match(chunk, /<title>([^<]*)<\/title>/);

	return m ? m[1] : null;
}

/* The atom feed carries no prerelease flag, guess it from the tag name. */
function is_prerelease(tag) {
	const lower = lc(tag);

	if (index(lower, '-') >= 0)
		return true;

	return match(lower, /\.(alpha|beta|rc|preview)\./) != null;
}

const entries = split(xml, '<entry>');
const seen = {};

/* entries[0] is the <feed> preamble, not a release. */
for (let i = 1; i < length(entries); i++) {
	const chunk = entries[i];
	const tag = entry_tag(chunk);

	if (!tag || seen[tag])
		continue;

	/* Guard against titles with spaces leaking through the fallback. */
	if (!match(tag, /^[A-Za-z0-9._+-]+$/))
		continue;

	seen[tag] = true;

	if (channel == 'debug') {
		if (substr(tag, 0, length(debugPrefix)) != debugPrefix)
			continue;
	}
	else {
		if (substr(tag, 0, length(debugPrefix)) == debugPrefix)
			continue;

		/* Rolling debug build, never a normal release. */
		if (tag == 'debug')
			continue;

		const pre = is_prerelease(tag);

		if (channel == 'stable' && pre)
			continue;

		if (channel == 'beta' && !pre)
			continue;
	}

	const m = match(chunk, /<updated>([^<]+)<\/updated>/);

	printf('%s\t%s\t%d\n', tag, m ? m[1] : '', is_prerelease(tag) ? 1 : 0);
}
