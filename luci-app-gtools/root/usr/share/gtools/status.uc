#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - collect the current status of every registered core
 *
 * Prints one JSON document on stdout. This script only reads state, it never
 * changes anything.
 */
'use strict';

const fs = require('fs');
const uci = require('uci');

const RUN_DIR = '/tmp/gtools';
const DATA_DIR = '/usr/share/gtools';
const BACKUP_ROOT = '/usr/share/gtools/backups';

function readfile(path) {
	try {
		return fs.readfile(path) || '';
	}
	catch (e) {
		return '';
	}
}

function read_tsv(path) {
	const result = {};
	const lines = split(readfile(path), '\n');

	for (let i = 0; i < length(lines); i++) {
		const line = lines[i];

		if (!length(line))
			continue;

		const pos = index(line, '\t');

		if (pos < 0)
			continue;

		result[substr(line, 0, pos)] = substr(line, pos + 1);
	}

	return result;
}

/*
 * fs.popen() only accepts a command string. Passing an array makes it return
 * null on some ucode builds, which would silently leave every field empty.
 */
function shquote(arg) {
	arg = '' + arg;

	let safe = length(arg) > 0;

	for (let i = 0; i < length(arg); i++) {
		const ch = substr(arg, i, 1);

		if (index('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-', ch) < 0) {
			safe = false;
			break;
		}
	}

	if (safe)
		return arg;

	let out = "'";

	for (let i = 0; i < length(arg); i++) {
		const ch = substr(arg, i, 1);

		if (ch == "'")
			out += "'\\''";
		else
			out += ch;
	}

	return out + "'";
}

function run(argv) {
	const parts = [];

	for (let i = 0; i < length(argv); i++)
		push(parts, shquote(argv[i]));

	let proc = fs.popen(join(' ', parts) + ' 2>/dev/null');

	if (!proc)
		return '';

	const out = proc.read('all') || '';

	proc.close();

	return out;
}

/*
 * `timeout` is not part of every ImmortalWrt image (busybox may omit the
 * applet), so only wrap the command when the binary is actually available.
 */
const has_timeout = !!(fs.stat('/usr/bin/timeout') || fs.stat('/bin/timeout') ||
	fs.stat('/sbin/timeout') || fs.stat('/usr/sbin/timeout'));

function run_version(bin) {
	return has_timeout
		? run([ 'timeout', '10', bin, '--version' ])
		: run([ bin, '--version' ]);
}

function first_line(s) {
	const pos = index(s, '\n');

	return pos < 0 ? s : substr(s, 0, pos);
}

function normalize_arch(arch) {
	arch = trim(arch || '');

	if (arch == 'amd64')
		return 'x86_64';
	if (arch == 'arm64')
		return 'aarch64';
	if (arch == 'armv7l')
		return 'armv7';

	return arch;
}

function is_true(value) {
	return value == '1' || value == 'true' || value == 'yes' || value == 'on';
}

const ctx = uci.cursor();

function cfg_conf(conf, section, option, fallback) {
	const value = ctx.get(conf, section, option);

	return (value == null) ? fallback : value;
}

function cfg(section, option, fallback) {
	return cfg_conf('gtools', section, option, fallback);
}

function cfg_nonempty(section, option, fallback) {
	const value = cfg(section, option, '');

	return length(value) ? value : fallback;
}

const arch = normalize_arch(first_line(run([ 'uname', '-m' ])));
const kernel = trim(first_line(run([ 'uname', '-r' ])));

const job = {
	state: trim(readfile(RUN_DIR + '/job.state')) || 'idle',
	action: trim(readfile(RUN_DIR + '/job.action')),
	pid: +trim(readfile(RUN_DIR + '/job.pid')) || 0,
	started: +trim(readfile(RUN_DIR + '/job.started')) || 0,
	finished: +trim(readfile(RUN_DIR + '/job.finished')) || 0,
	message: trim(readfile(RUN_DIR + '/job.message'))
};

if (job.state == 'running') {
	if (job.pid && !fs.stat('/proc/' + job.pid)) {
		job.state = 'fail';
		job.message = '后台任务意外退出';
	}
	else if (!job.pid && job.started && (time() - job.started) > 15) {
		job.state = 'fail';
		job.message = '后台任务未能启动';
	}
}

const settings = {
	download_proxy: cfg('main', 'download_proxy', ''),
	api_proxy: cfg('main', 'api_proxy', ''),
	has_token: length(cfg('main', 'api_token', '')) > 0,
	keep_backups: +cfg('main', 'keep_backups', '3') || 3,
	auto_rollback: is_true(cfg_nonempty('main', 'auto_rollback', '1')),
	verify_sha256: is_true(cfg_nonempty('main', 'verify_sha256', '1')),
	auto_check: is_true(cfg_nonempty('main', 'auto_check', '1'))
};

let registry = {};

try {
	registry = json(fs.readfile(DATA_DIR + '/cores.json')) || {};
}
catch (e) {
	registry = {};
}

const ids = keys(registry);
const cores = [];

for (let n = 0; n < length(ids); n++) {
	const id = ids[n];
	const meta = registry[id] || {};
	const asset = meta.asset || {};
	const defaults = meta.defaults || {};
	const binary = meta.binary || '';
	const binary_name = asset.binary_name || '';

	let binary_exists = false;
	let binary_size = 0;
	let installed = '';
	let installed_raw = '';
	const binary_stat = binary ? fs.stat(binary) : null;

	if (binary_stat) {
		binary_exists = true;
		binary_size = binary_stat.size || 0;

		const raw = run_version(binary);

		installed_raw = trim(first_line(raw));

		const parts = split(trim(installed_raw), ' ');

		installed = parts[length(parts) - 1] || '';

		if (substr(installed, 0, 1) == 'v')
			installed = substr(installed, 1);
	}

	const service = meta.service || '';
	const service_exists = service ? !!fs.stat('/etc/init.d/' + service) : false;
	const service_running = service
		? length(trim(run([ 'pidof', binary_name || service ]))) > 0
		: false;
	const service_enabled = meta.service_config
		? is_true(cfg_conf(meta.service_config, meta.service_section || 'config',
		                   meta.service_enabled || 'enabled', '0'))
		: false;

	const channel = cfg_nonempty(id, 'channel', defaults.channel || 'auto');
	const variant = cfg_nonempty(id, 'variant', defaults.variant || 'full');
	const allocator = cfg_nonempty(id, 'allocator', defaults.allocator || 'mimalloc');
	const enabled = is_true(cfg_nonempty(id, 'enabled',
		defaults.enabled === false ? '0' : '1'));

	const latest = read_tsv(RUN_DIR + '/latest.' + id + '.tsv');
	const latest_version = latest.version || '';
	const latest_checked = +latest.checked || 0;
	const latest_error = latest.error || '';
	const latest_stale = !!latest_version &&
		(latest.channel != channel || latest.variant != variant ||
		 latest.allocator != allocator || latest.arch != arch ||
		 latest.binary != binary);

	let update_available = false;

	if (latest_version) {
		if (!binary_exists)
			update_available = true;
		else if (installed != latest_version)
			update_available = true;
	}

	const backups = [];
	const backup_dir = BACKUP_ROOT + '/' + id;
	const entries = fs.lsdir(backup_dir);

	if (entries) {
		for (let i = 0; i < length(entries); i++) {
			const name = entries[i];
			const parts = split(name, '@');

			if (length(parts) != 3)
				continue;

			const st = fs.stat(backup_dir + '/' + name);

			push(backups, {
				file: name,
				version: parts[1],
				size: st ? (st.size || 0) : 0,
				mtime: +parts[2] || 0
			});
		}
	}

	sort(backups, function(a, b) { return b.mtime - a.mtime; });

	const channels = meta.channels || [ 'auto', 'stable', 'beta', 'debug' ];
	const variants = keys(asset.variants || {});
	const allocators = keys(asset.allocators || {});
	const supported = !!(asset.arch && asset.arch[arch]);

	push(cores, {
		id: id,
		title: meta.title || id,
		description: meta.description || '',
		repo: meta.repo || '',
		binary: binary,
		binary_exists: binary_exists,
		binary_size: binary_size,
		installed: installed,
		installed_raw: installed_raw,
		service: service,
		service_exists: service_exists,
		service_running: service_running,
		service_enabled: service_enabled,
		enabled: enabled,
		channel: channel,
		variant: variant,
		allocator: allocator,
		channels: channels,
		variants: variants,
		allocators: allocators,
		supported: supported,
		arch_name: supported ? asset.arch[arch] : '',
		latest: latest_version,
		latest_tag: latest.tag || '',
		latest_asset: latest.asset || '',
		latest_url: latest.url || '',
		latest_checked: latest_checked,
		latest_error: latest_error,
		latest_stale: latest_stale,
		update_available: update_available,
		backups: backups
	});
}

printf('%J\n', {
	time: time(),
	arch: arch,
	kernel: kernel,
	job: job,
	settings: settings,
	cores: cores
});

