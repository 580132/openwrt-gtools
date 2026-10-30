/* SPDX-License-Identifier: GPL-3.0-or-later */
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var SCRIPT = '/usr/share/gtools/gtools.sh';
var LOG_PATH = '/tmp/gtools/job.log';

var css = [
	'.gtools-toolbar { display: flex; align-items: center; gap: .75em; flex-wrap: wrap; margin-bottom: .75em; }',
	'.gtools-status td { vertical-align: top; }',
	'.gtools-status th { white-space: nowrap; }',
	'.gtools-status { width: 100%; }',
	'.gtools-table-wrap { overflow-x: auto; }',
	'.gtools-sub { color: #777; font-size: 90%; margin-top: 2px; }',
	'.gtools-mono { font-family: monospace; word-break: break-all; }',
	'.gtools-error { color: #a94442; }',
	'.gtools-badge { display: inline-block; padding: 1px 6px; border-radius: 3px; font-size: 88%; background: #eee; color: #444; }',
	'.gtools-badge-ok { background: #dff0d8; color: #3c763d; }',
	'.gtools-badge-new { background: #d9edf7; color: #31708f; }',
	'.gtools-badge-warn { background: #fcf8e3; color: #8a6d3b; }',
	'.gtools-badge-err { background: #f2dede; color: #a94442; }',
	'.gtools-badge-muted { background: #eee; color: #777; }',
	'.gtools-actions { display: flex; gap: 4px; flex-wrap: wrap; }',
	'.gtools-actions .btn { white-space: nowrap; }',
	'.gtools-job { margin-top: .75em; }',
	'.gtools-job-running { padding: .6em .8em; border-left: 3px solid #31708f; background: #f4f8fa; }',
	'.gtools-log { max-height: 320px; overflow: auto; background: #1b1b1b; color: #ddd; padding: 8px; font-size: 12px; white-space: pre-wrap; word-break: break-all; }',
	'.gtools-settings .cbi-section { margin-top: 1em; }',
	'.gtools-page-actions { margin: 1em 0; }',
	'@media (max-width: 700px) { .gtools-actions { flex-direction: column; } }'
].join('\n');

function compact(items) {
	var out = [];

	for (var i = 0; i < items.length; i++)
		if (items[i] != null && items[i] !== '')
			out.push(items[i]);

	return out;
}

function badge(text, kind) {
	return E('span', { 'class': 'gtools-badge gtools-badge-' + kind }, text);
}

function labelRow(title, description, input) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, compact([
			input,
			description ? E('div', { 'class': 'cbi-value-description' }, description) : null
		]))
	]);
}

function fmtTime(ts) {
	if (!ts)
		return _('从未');

	var date = new Date(ts * 1000);

	if (isNaN(date.getTime()))
		return _('未知');

	return date.toLocaleString();
}

function fmtSize(bytes) {
	var value = Number(bytes) || 0;

	if (value <= 0)
		return '—';

	var units = [ 'B', 'KiB', 'MiB', 'GiB' ];
	var unit = 0;

	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit++;
	}

	return (unit ? value.toFixed(1) : String(Math.round(value))) + ' ' + units[unit];
}

function execStatus() {
	return fs.exec(SCRIPT, [ 'status' ]).then(function(res) {
		if (res.code != 0)
			throw new Error((res.stderr || res.stdout || '').trim() || _('无法读取状态'));

		try {
			return JSON.parse(res.stdout || '{}');
		}
		catch (e) {
			throw new Error(_('状态数据解析失败'));
		}
	});
}

function readLog() {
	return fs.read(LOG_PATH).catch(function() {
		return '';
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			execStatus().catch(function(err) {
				return { error: err.message || String(err) };
			}),
			readLog()
		]);
	},

	render: function(data) {
		var self = this;

		this.status = data[0] || {};
		this.logText = data[1] || '';
		this.lastJobState = this.status.job ? this.status.job.state : 'idle';
		this.autoCheckDone = false;
		this.form = { cores: {} };

		/* Let the shared page action bar reach the current view instance. */
		window._gtoolsView = this;

		var root = E('div', { 'class': 'cbi-map' }, [
			E('style', { 'type': 'text/css' }, [ css ]),
			E('h2', _('GTools 核心更新')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从上游 GitHub Releases 获取并安装最新核心，支持 SHA256 校验、自动备份和回滚。'))
		]);

		if (this.status.error) {
			root.appendChild(this.renderError(this.status.error));
		}
		else {
			root.appendChild(this.renderStatus());
			root.appendChild(this.renderSettings());
			root.appendChild(this.renderLog());

			this.updateStatus(this.status);
			this.updateLog(this.logText);

			window.setTimeout(function() { self.maybeAutoCheck(); }, 600);
			this.bindPageActions();
		}

		poll.add(function() { return self.refresh(); }, 5);

		return root;
	},

	renderError: function(message) {
		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'alert-message danger' }, [
				E('h4', _('无法读取 GTools 状态')),
				E('p', message),
				E('p', _('请确认 luci-app-gtools 已正确安装，然后刷新页面。'))
			])
		]);
	},

	renderStatus: function() {
		var self = this;
		var body = E('tbody', {});
		var job = E('div', { 'class': 'gtools-job' });
		var checked = E('span', { 'class': 'gtools-sub' }, '');

		var checkBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': function() { self.checkUpdates(false); }
		}, _('检查更新'));

		this.nodes = {
			body: body,
			job: job,
			checked: checked,
			checkBtn: checkBtn
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', [ _('核心状态'), ' ', checked ]),
			E('div', { 'class': 'cbi-section-node' }, [
				E('div', { 'class': 'gtools-toolbar' }, [
					checkBtn,
					E('span', { 'class': 'gtools-sub' },
						_('架构：%s　内核：%s　GTools：%s').format(
							this.status.arch || '?',
							this.status.kernel || '?',
							this.status.version || '?'))
				]),
				E('div', { 'class': 'gtools-table-wrap' }, [
					E('table', { 'class': 'table gtools-status' }, [
						E('thead', [
							E('tr', [
								E('th', _('核心')),
								E('th', _('已安装')),
								E('th', _('上游最新')),
								E('th', _('服务')),
								E('th', _('操作'))
							])
						]),
						body
					])
				]),
				job
			])
		]);
	},

	renderCoreRow: function(core) {
		var self = this;
		var running = this.jobRunning();

		var installed = core.binary_exists
			? (core.installed || _('未知'))
			: _('未安装');

		var stateBadge;

		if (!core.supported)
			stateBadge = badge(_('不支持的架构'), 'err');
		else if (core.latest_error)
			stateBadge = badge(_('检查失败'), 'err');
		else if (core.latest_stale)
			stateBadge = badge(_('需重新检查'), 'warn');
		else if (!core.binary_exists)
			stateBadge = badge(_('未安装'), 'warn');
		else if (!core.latest)
			stateBadge = badge(_('未检查'), 'muted');
		else if (core.update_available)
			stateBadge = badge(_('可升级'), 'new');
		else
			stateBadge = badge(_('已是最新'), 'ok');

		var service;

		if (!core.service_exists)
			service = badge(_('未安装'), 'muted');
		else if (core.service_running)
			service = badge(_('运行中'), 'ok');
		else if (core.service_enabled)
			service = badge(_('已启用，未运行'), 'warn');
		else
			service = badge(_('未启用'), 'muted');

		var upgradeBtn = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': function() { self.confirmUpgrade(core); }
		}, core.update_available ? _('升级') : _('重新安装'));

		if (running || !core.latest || core.latest_stale)
			upgradeBtn.disabled = true;

		var rollbackBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() { self.showRollback(core); }
		}, _('回滚'));

		if (running || !core.backups || !core.backups.length)
			rollbackBtn.disabled = true;

		var restartBtn = E('button', {
			'class': 'btn cbi-button',
			'click': function() { self.confirmRestart(core); }
		}, _('重启服务'));

		if (running || !core.service_exists)
			restartBtn.disabled = true;

		return E('tr', [
			E('td', compact([
				E('strong', core.title),
				E('div', { 'class': 'gtools-sub gtools-mono' }, core.binary),
				core.description ? E('div', { 'class': 'gtools-sub' }, core.description) : null
			])),
			E('td', compact([
				E('div', installed),
				core.installed_raw ? E('div', { 'class': 'gtools-sub gtools-mono' }, core.installed_raw) : null,
				(core.binary_exists && core.binary_size) ? E('div', { 'class': 'gtools-sub' }, fmtSize(core.binary_size)) : null
			])),
			E('td', compact([
				E('div', core.latest || '—'),
				core.latest_tag ? E('div', { 'class': 'gtools-sub gtools-mono' }, core.latest_tag) : null,
				core.latest_error ? E('div', { 'class': 'gtools-sub gtools-error' }, core.latest_error) : null,
				E('div', { 'class': 'gtools-sub' }, stateBadge)
			])),
			E('td', [ service ]),
			E('td', [ E('div', { 'class': 'gtools-actions' }, [ upgradeBtn, rollbackBtn, restartBtn ]) ])
		]);
	},

	renderSettings: function() {
		var self = this;
		var settings = this.status.settings || {};
		var cores = this.status.cores || [];

		var proxy = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'value': settings.download_proxy || '',
			'placeholder': 'https://ghfast.top'
		});

		var apiProxy = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'value': settings.api_proxy || '',
			'placeholder': _('留空则直连 api.github.com')
		});

		var token = E('input', {
			'class': 'cbi-input-text',
			'type': 'password',
			'value': '',
			'placeholder': settings.has_token ? _('已设置，留空保持不变') : _('可选，用于提高 API 限额')
		});

		var clearToken = E('input', { 'type': 'checkbox' });

		var keep = E('input', {
			'class': 'cbi-input-text',
			'type': 'number',
			'min': '1',
			'max': '10',
			'value': String(settings.keep_backups || 3)
		});

		var autoRollback = E('input', { 'type': 'checkbox' });
		autoRollback.checked = !!settings.auto_rollback;

		var verify = E('input', { 'type': 'checkbox' });
		verify.checked = !!settings.verify_sha256;

		var autoCheck = E('input', { 'type': 'checkbox' });
		autoCheck.checked = !!settings.auto_check;

		this.hasToken = !!settings.has_token;
		this.form = {
			download_proxy: proxy,
			api_proxy: apiProxy,
			api_token: token,
			clear_token: clearToken,
			keep_backups: keep,
			auto_rollback: autoRollback,
			verify_sha256: verify,
			auto_check: autoCheck,
			cores: {}
		};

		var globalSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', _('全局设置')),
			E('div', { 'class': 'cbi-section-node' }, [
				labelRow(_('下载加速地址'),
					_('可选，例如 https://ghfast.top，会拼在 GitHub 下载地址前面。'), proxy),
				labelRow(_('API 加速地址'),
					_('可选，仅用于访问 api.github.com；留空则直连。'), apiProxy),
				labelRow(_('GitHub Token'),
					_('可选，用于提高 GitHub API 的请求限额；Token 只保存在路由器上。'), token),
				labelRow(_('清除 Token'), '', clearToken),
				labelRow(_('保留备份数量'),
					_('每次升级前备份当前核心，保留最近 N 份（1-10）。'), keep),
				labelRow(_('SHA256 校验'),
					_('下载后校验上游 SHA256SUMS；上游未提供校验文件时会跳过。'), verify),
				labelRow(_('自动回滚'),
					_('升级后服务未能启动时，自动恢复上一个核心。'), autoRollback),
				labelRow(_('打开页面时自动检查'),
					_('缓存超过 10 分钟时自动检查一次。'), autoCheck)
			])
		]);

		var sections = [ globalSection ];

		for (var i = 0; i < cores.length; i++)
			sections.push(this.renderCoreSettings(cores[i]));

		sections.push(E('div', { 'class': 'gtools-page-actions' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': function(ev) { ev.preventDefault(); self.saveSettings(); }
			}, _('保存并应用')),
			E('span', { 'class': 'gtools-sub' },
				_('　修改后点击此按钮，立即写入配置并重新检查更新。'))
		]));

		return E('div', { 'class': 'gtools-settings' }, sections);
	},

	renderCoreSettings: function(core) {
		var enabled = E('input', { 'type': 'checkbox' });
		enabled.checked = !!core.enabled;

		var channel = E('select', { 'class': 'cbi-input-select' });
		var channels = core.channels || [ 'auto', 'stable', 'beta', 'debug' ];

		for (var i = 0; i < channels.length; i++) {
			var channelOption = E('option', { 'value': channels[i] }, this.channelName(channels[i]));

			if (channels[i] == core.channel)
				channelOption.selected = true;

			channel.appendChild(channelOption);
		}

		var variant = E('select', { 'class': 'cbi-input-select' });
		var variants = core.variants || [];

		for (var j = 0; j < variants.length; j++) {
			var variantOption = E('option', { 'value': variants[j] }, variants[j]);

			if (variants[j] == core.variant)
				variantOption.selected = true;

			variant.appendChild(variantOption);
		}

		var allocator = E('select', { 'class': 'cbi-input-select' });
		var allocators = core.allocators || [];

		for (var k = 0; k < allocators.length; k++) {
			var allocatorLabel = (allocators[k] == 'mimalloc')
				? _('mimalloc（吞吐优先）')
				: _('stock（内存优先）');
			var allocatorOption = E('option', { 'value': allocators[k] }, allocatorLabel);

			if (allocators[k] == core.allocator)
				allocatorOption.selected = true;

			allocator.appendChild(allocatorOption);
		}

		this.form.cores[core.id] = {
			enabled: enabled,
			channel: channel,
			variant: variant,
			allocator: allocator
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('%s 设置').format(core.title)),
			E('div', { 'class': 'cbi-section-node' }, [
				labelRow(_('启用更新检查'), '', enabled),
				labelRow(_('更新通道'),
					_('auto：最新正式版或测试版；stable：仅正式版；beta：仅测试版；debug：滚动调试版。'),
					channel),
				labelRow(_('核心变体'),
					_('full 包含 Clash API、原生 API 和内置面板；其余为精简版。'), variant),
				labelRow(_('内存分配器'),
					_('mimalloc 吞吐更好；stock 内存占用更低。'), allocator)
			])
		]);
	},

	renderLog: function() {
		var pre = E('pre', { 'class': 'gtools-log' }, '');

		this.nodes.log = pre;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('任务日志')),
			E('div', { 'class': 'cbi-section-node' }, [ pre ])
		]);
	},

	channelName: function(channel) {
		switch (channel) {
		case 'auto':
			return _('auto（最新正式/测试版）');
		case 'stable':
			return _('stable（仅正式版）');
		case 'beta':
			return _('beta（仅测试版）');
		case 'debug':
			return _('debug（滚动调试版）');
		default:
			return channel;
		}
	},

	actionName: function(action) {
		switch (action) {
		case 'check':
			return _('检查更新');
		case 'upgrade':
			return _('升级核心');
		case 'rollback':
			return _('回滚');
		case 'restart':
			return _('重启服务');
		default:
			return action || _('任务');
		}
	},

	updateStatus: function(status) {
		if (!status || status.error)
			return;

		this.status = status;

		var body = this.nodes.body;
		var cores = status.cores || [];

		while (body.firstChild)
			body.removeChild(body.firstChild);

		var lastChecked = 0;

		for (var i = 0; i < cores.length; i++) {
			body.appendChild(this.renderCoreRow(cores[i]));

			if (cores[i].latest_checked > lastChecked)
				lastChecked = cores[i].latest_checked;
		}

		this.nodes.checked.textContent = lastChecked
			? _('上次检查：%s').format(fmtTime(lastChecked))
			: _('尚未检查');

		var job = status.job || { state: 'idle' };
		var running = (job.state == 'running');

		if (this.nodes.checkBtn)
			this.nodes.checkBtn.disabled = running;

		while (this.nodes.job.firstChild)
			this.nodes.job.removeChild(this.nodes.job.firstChild);

		if (running) {
			this.nodes.job.appendChild(E('div', { 'class': 'gtools-job-running' }, [
				E('strong', _('任务进行中：%s').format(this.actionName(job.action))),
				E('div', { 'class': 'gtools-sub' }, job.message || _('请稍候，日志会实时刷新。'))
			]));
		}
		else if (job.state == 'ok' || job.state == 'fail') {
			this.nodes.job.appendChild(E('div', {
				'class': 'alert-message ' + (job.state == 'ok' ? 'success' : 'danger')
			}, job.message || (job.state == 'ok' ? _('任务完成') : _('任务失败'))));
		}

		if (this.lastJobState == 'running' && job.state != 'running') {
			if (job.state == 'ok')
				ui.addNotification(null, E('p', job.message || _('任务完成')), 'info');
			else if (job.state == 'fail')
				ui.addNotification(null, E('p', job.message || _('任务失败')), 'danger');

			var self = this;
			window.setTimeout(function() { self.refresh(); }, 300);
		}

		this.lastJobState = job.state;
	},

	updateLog: function(text) {
		var pre = this.nodes && this.nodes.log;

		if (!pre)
			return;

		var lines = (text || '').split('\n');

		if (lines.length > 200)
			lines = lines.slice(lines.length - 200);

		var value = lines.join('\n');
		var atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 24;

		if (pre.textContent != value) {
			pre.textContent = value;

			if (atBottom)
				pre.scrollTop = pre.scrollHeight;
		}
	},

	refresh: function() {
		var self = this;

		if (document.hidden)
			return Promise.resolve();

		return Promise.all([ execStatus(), readLog() ]).then(function(res) {
			self.updateStatus(res[0]);
			self.updateLog(res[1]);
		}).catch(function() {
			/* transient errors are ignored while polling */
		});
	},

	jobRunning: function() {
		return !!(this.status && this.status.job && this.status.job.state == 'running');
	},

	bindPageActions: function() {
		var tries = 0;

		var attach = function() {
			var bar = document.querySelector('.cbi-page-actions');

			if (!bar) {
				if (++tries < 20)
					window.setTimeout(attach, 100);

				return;
			}

			if (bar.getAttribute('data-gtools-bound'))
				return;

			bar.setAttribute('data-gtools-bound', '1');

			/*
			 * The theme renders its own "Save & Apply / Save / Reset" bar which
			 * operates on LuCI's change tracking. GTools writes its settings
			 * directly, so route those buttons to our save routine as well.
			 */
			bar.addEventListener('click', function(ev) {
				/* Leave other LuCI pages alone. */
				if (!document.querySelector('.gtools-settings'))
					return;

				ev.preventDefault();
				ev.stopPropagation();

				if (ev.target.closest && ev.target.closest('.cbi-button-reset')) {
					window.location.reload();
					return;
				}

				/* Always target the view instance that is currently rendered. */
				var view = window._gtoolsView;

				if (view)
					view.saveSettings();
			}, true);
		};

		window.setTimeout(attach, 0);
	},

	maybeAutoCheck: function() {
		if (this.autoCheckDone)
			return;

		this.autoCheckDone = true;

		if (!this.status || !this.status.settings || !this.status.settings.auto_check)
			return;

		var now = this.status.time || Math.floor(Date.now() / 1000);
		var cores = this.status.cores || [];

		for (var i = 0; i < cores.length; i++) {
			var core = cores[i];

			if (!core.enabled)
				continue;

			if (!core.latest_checked || (now - core.latest_checked) > 600) {
				this.checkUpdates(true);
				return;
			}
		}
	},

	checkUpdates: function(silent) {
		var self = this;

		if (this.jobRunning()) {
			if (!silent)
				ui.addNotification(null, E('p', _('已有任务正在运行')), 'warning');

			return Promise.resolve();
		}

		return fs.exec(SCRIPT, [ 'check' ]).then(function(res) {
			if (res.code != 0) {
				var message = (res.stderr || res.stdout || '').trim();

				if (message == 'busy')
					message = _('已有任务正在运行');

				throw new Error(message || _('无法启动检查'));
			}

			if (!silent)
				ui.addNotification(null, E('p', _('已开始检查更新')), 'info');

			return self.refresh();
		}).catch(function(err) {
			if (!silent)
				ui.addNotification(null, E('p', _('检查失败：%s').format(err.message || err)), 'danger');
		});
	},

	startJob: function(action, args) {
		var self = this;

		if (this.jobRunning()) {
			ui.addNotification(null, E('p', _('已有任务正在运行')), 'warning');
			return Promise.resolve();
		}

		return fs.exec(SCRIPT, [ action ].concat(args || [])).then(function(res) {
			if (res.code != 0) {
				var message = (res.stderr || res.stdout || '').trim();

				if (message == 'busy')
					message = _('已有任务正在运行');

				throw new Error(message || _('无法启动任务'));
			}

			return self.refresh();
		}).catch(function(err) {
			ui.addNotification(null, E('p', _('操作失败：%s').format(err.message || err)), 'danger');
		});
	},

	confirmUpgrade: function(core) {
		var self = this;
		var from = core.binary_exists ? (core.installed || _('未知')) : _('未安装');
		var to = core.latest || _('未知');

		ui.showModal(_('升级 %s').format(core.title), [
			E('p', _('将把 %s 从 %s 更新到 %s。').format(core.title, from, to)),
			E('p', _('升级会下载上游发布包、校验 SHA256、备份当前核心并重启服务，过程中网络可能短暂中断。')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': function() {
						ui.hideModal();
						self.startJob('upgrade', [ core.id ]);
					}
				}, _('开始升级'))
			])
		]);
	},

	showRollback: function(core) {
		var self = this;
		var rows = [];
		var backups = core.backups || [];

		for (var i = 0; i < backups.length; i++) {
			var backup = backups[i];

			rows.push(E('tr', [
				E('td', { 'class': 'gtools-mono' }, backup.version || _('未知')),
				E('td', fmtTime(backup.mtime)),
				E('td', fmtSize(backup.size)),
				E('td', E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': (function(item) {
						return function() {
							ui.hideModal();
							self.confirmRollback(core, item);
						};
					})(backup)
				}, _('恢复')))
			]));
		}

		var content = rows.length
			? E('table', { 'class': 'table' }, [
				E('thead', [
					E('tr', [
						E('th', _('版本')),
						E('th', _('备份时间')),
						E('th', _('大小')),
						E('th', '')
					])
				]),
				E('tbody', rows)
			])
			: E('p', _('暂无备份。'));

		ui.showModal(_('回滚 %s').format(core.title), [
			content,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('关闭'))
			])
		]);
	},

	confirmRollback: function(core, backup) {
		var self = this;

		ui.showModal(_('确认回滚'), [
			E('p', _('将把 %s 恢复到版本 %s，并重启服务。').format(core.title, backup.version || _('未知'))),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': function() {
						ui.hideModal();
						self.startJob('rollback', [ core.id, backup.file ]);
					}
				}, _('确认回滚'))
			])
		]);
	},

	confirmRestart: function(core) {
		var self = this;

		ui.showModal(_('重启服务'), [
			E('p', _('将重启 %s 服务，期间网络可能短暂中断。').format(core.title)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() {
						ui.hideModal();
						self.startJob('restart', [ core.id ]);
					}
				}, _('重启'))
			])
		]);
	},

	saveSettings: function() {
		var self = this;
		var form = this.form;
		var payload = { main: {} };
		var main = payload.main;

		main.download_proxy = form.download_proxy.value.trim();
		main.api_proxy = form.api_proxy.value.trim();

		if (form.clear_token.checked)
			main.api_token = '';
		else if (form.api_token.value.trim() != '')
			main.api_token = form.api_token.value.trim();

		var keep = parseInt(form.keep_backups.value, 10);

		if (!(keep >= 1 && keep <= 10))
			keep = 3;

		main.keep_backups = String(keep);
		main.verify_sha256 = form.verify_sha256.checked ? '1' : '0';
		main.auto_rollback = form.auto_rollback.checked ? '1' : '0';
		main.auto_check = form.auto_check.checked ? '1' : '0';

		for (var id in form.cores) {
			if (!form.cores.hasOwnProperty(id))
				continue;

			var core = form.cores[id];

			payload[id] = {
				enabled: core.enabled.checked ? '1' : '0',
				channel: core.channel.value,
				variant: core.variant.value,
				allocator: core.allocator.value
			};
		}

		return fs.exec(SCRIPT, [ 'config', JSON.stringify(payload) ]).then(function(res) {
			if (res.code != 0)
				throw new Error((res.stderr || res.stdout || '').trim() || _('无法保存设置'));

			if (payload.main.hasOwnProperty('api_token'))
				self.hasToken = (payload.main.api_token != '');

			form.api_token.value = '';
			form.api_token.placeholder = self.hasToken
				? _('已设置，留空保持不变')
				: _('可选，用于提高 GitHub API 限额');
			form.clear_token.checked = false;

			ui.addNotification(null, E('p', _('设置已保存并应用')), 'info');

			self.autoCheckDone = false;

			return self.refresh();
		}).then(function() {
			return self.checkUpdates(true);
		}).catch(function(err) {
			ui.addNotification(null,
				E('p', _('保存失败：%s').format(err && err.message ? err.message : err)), 'danger');
		});
	}
});
