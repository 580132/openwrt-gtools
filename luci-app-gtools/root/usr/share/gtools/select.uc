#!/usr/bin/ucode
/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * gtools - select an upstream release asset for the current device
 *
 * Usage:
 *   select.uc <core> <channel> <variant> <allocator> <arch> <releases.json>
 *
 * Writes tab separated key/value lines to stdout. On failure it writes an
 * "error" line and exits non-zero.
 */
'use strict';

const fs = require('fs');

const core      = ARGV[0];
const channel   = ARGV[1] || 'auto';
const variant   = ARGV[2] || 'full';
const allocator = ARGV[3] || 'mimalloc';
const arch      = ARGV[4] || '';
const relFile   = ARGV[5] || '';

function fail(msg) {
	printf('error\t%s\n', msg);
	printf('checked\t%d\n', time());
	exit(1);
}

if (!core || !relFile)
	fail('参数不完整');

let all;

try {
	all = json(fs.readfile('/usr/share/gtools/cores.json'));
}
catch (e) {
	fail('无法读取 cores.json');
}

const meta = all ? all[core] : null;

if (!meta)
	fail('未知核心: ' + core);

const asset = meta.asset || {};
const archName = asset.arch ? asset.arch[arch] : null;

if (!archName)
	fail('当前架构 ' + (arch || '未知') + ' 不受支持');

let releases;

try {
	releases = json(fs.readfile(relFile));
}
catch (e) {
	fail('GitHub 返回的数据无法解析');
}

if (type(releases) != 'array')
	fail('GitHub 返回的数据格式异常');

if (channel != 'auto' && channel != 'stable' && channel != 'beta' && channel != 'debug')
	fail('未知更新通道: ' + channel);

const debugPrefix = asset.debug_prefix || 'debug.';
const wantDebug = (channel == 'debug');

function isDebug(release) {
	return substr(release.tag_name || '', 0, length(debugPrefix)) == debugPrefix;
}

let best = null;

for (let i = 0; i < length(releases); i++) {
	const release = releases[i];

	if (type(release) != 'object' || release.draft)
		continue;

	const tag = release.tag_name || '';

	if (wantDebug) {
		if (!isDebug(release))
			continue;
	}
	else {
		if (isDebug(release) || tag == 'debug')
			continue;

		if (channel == 'stable' && release.prerelease)
			continue;

		if (channel == 'beta' && !release.prerelease)
			continue;
	}

	if (best == null || (release.published_at || '') > (best.published_at || ''))
		best = release;
}

if (best == null) {
	if (channel == 'stable')
		fail('上游暂无稳定版');
	if (channel == 'beta')
		fail('上游暂无测试版');
	if (channel == 'debug')
		fail('上游暂无调试版');
	fail('上游暂无可用版本');
}

const tag = best.tag_name;
let version = tag;

if (substr(version, 0, 1) == 'v')
	version = substr(version, 1);

const variantSuffixes = asset.variants ? asset.variants[variant] : null;

if (!variantSuffixes)
	fail('未知变体: ' + variant);

const allocatorSuffixes = asset.allocators ? asset.allocators[allocator] : null;

if (!allocatorSuffixes)
	fail('未知分配器: ' + allocator);

const pattern = isDebug(best) ? (asset.debug_pattern || asset.pattern) : asset.pattern;
const assetInfo = {};

if (best.assets) {
	for (let i = 0; i < length(best.assets); i++) {
		const item = best.assets[i] || {};
		const aname = item.name || '';

		if (length(aname) && !assetInfo[aname])
			assetInfo[aname] = item;
	}
}

function hasAsset(name) {
	return !!assetInfo[name];
}

let assetName = null;

for (let i = 0; i < length(variantSuffixes) && assetName == null; i++) {
	for (let j = 0; j < length(allocatorSuffixes); j++) {
		let name = pattern;

		name = replace(name, '{tag}', tag);
		name = replace(name, '{version}', version);
		name = replace(name, '{arch}', archName);
		name = replace(name, '{libc}', asset.libc || 'musl');
		name = replace(name, '{alloc}', allocatorSuffixes[j]);
		name = replace(name, '{variant}', variantSuffixes[i]);

		if (hasAsset(name)) {
			assetName = name;
			break;
		}
	}
}

if (assetName == null)
	fail('上游发布中没有找到适用于 ' + arch + ' 的 ' + variant + ' 安装包');

let sha256 = '';
const chosen = assetInfo[assetName] || {};

if (chosen.digest && substr(chosen.digest, 0, 7) == 'sha256:')
	sha256 = substr(chosen.digest, 7);

const base = 'https://github.com/' + meta.repo + '/releases/download/' + tag + '/';
const hasSums = hasAsset('SHA256SUMS');

printf('tag\t%s\n', tag);
printf('version\t%s\n', version);
printf('asset\t%s\n', assetName);
printf('url\t%s\n', base + assetName);
printf('sha256\t%s\n', sha256);
printf('sums_url\t%s\n', hasSums ? base + 'SHA256SUMS' : '');
printf('archive\t%s\n', asset.archive || 'tar.gz');
printf('binary_name\t%s\n', asset.binary_name || '');
printf('binary\t%s\n', meta.binary || '');
printf('service\t%s\n', meta.service || '');
printf('repo\t%s\n', meta.repo || '');
printf('arch\t%s\n', arch);
printf('channel\t%s\n', channel);
printf('variant\t%s\n', variant);
printf('allocator\t%s\n', allocator);
printf('checked\t%d\n', time());
printf('published\t%s\n', best.published_at || '');
printf('prerelease\t%s\n', best.prerelease ? '1' : '0');
