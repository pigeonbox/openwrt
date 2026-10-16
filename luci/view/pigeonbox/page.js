'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require dom';
'require fs';
'require ui';

/*
 * PigeonBox LuCI 页(luci-app-pigeonbox 视图):服务状态/控制 + UCI 配置表单。
 *
 * - iframe 内嵌被否:core 安全基线全局下发 X-Frame-Options: SAMEORIGIN,
 *   LuCI(:80)内嵌业务端口(:12345)属跨源必被浏览器拦,故为状态页+新窗口打开。
 * - 运行状态数据源:ubus service list(取 instances[*].running)。
 *   勿用 luci getInitList——iStoreOS 的 LuCI 构建不返回 running 字段(真机实测,
 *   v0.3.0 踩坑,恒显"未运行")。
 * - 配置表单:form.Map 直绑 /etc/config/pigeonbox,应用后自动重启服务生效
 *   (init 经 UCI→PB_* env 注入,env 在进程启动时读取,改配置必须重启)。
 */

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	expect: { '': {} }
});

var INIT_script = '/etc/init.d/pigeonbox';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('pigeonbox'),
			L.resolveDefault(callServiceList(), {})
		]);
	},

	isRunning: function(services) {
		var svc = (services || {})['pigeonbox'];
		var instances = (svc && svc.instances) || {};
		return Object.keys(instances).some(function(k) {
			return instances[k] && instances[k].running;
		});
	},

	/* 服务动作(启动/停止/重启)后延时重取状态,只刷新状态面板 */
	handleAction: function(action, ev) {
		var self = this;
		return fs.exec(INIT_script, [action]).then(function() {
			return new Promise(function(resolve) { window.setTimeout(resolve, 2500); })
				.then(function() { return L.resolveDefault(callServiceList(), {}); })
				.then(function(services) {
					var node = document.getElementById('pigeonbox-status');
					if (node) {
						dom.content(node, self.renderStatusPanel(services));
					}
				});
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('操作失败: %s').format(e.message)));
		});
	},

	renderStatusPanel: function(services) {
		var self = this;
		var running = this.isRunning(services);

		var port = uci.get('pigeonbox', 'main', 'port') || '12345';
		var url = 'http://' + window.location.hostname + ':' + port + '/';

		var badge = running
			? E('span', { 'class': 'label label-success' }, _('运行中'))
			: E('span', { 'class': 'label label-important' }, _('未运行'));

		var ctlBtn = function(action, label, cls) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-' + (cls || 'neutral'),
				'click': ui.createHandlerFn(self, 'handleAction', action)
			}, [ label ]);
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' }, _('服务状态')),
			E('table', { 'class': 'table' }, [
				E('tr', {}, [
					E('td', { 'style': 'width:33%' }, _('运行状态')),
					E('td', {}, [badge])
				]),
				E('tr', {}, [
					E('td', {}, _('管理入口')),
					E('td', {}, [url])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				running ? ctlBtn('restart', _('重启'), 'restart') : null,
				running ? ctlBtn('stop', _('停止'), 'negative') : ctlBtn('start', _('启动'), 'positive'),
				running ? E('a', {
					'class': 'btn cbi-button cbi-button-apply',
					'href': url,
					'target': '_blank',
					'rel': 'noopener'
				}, [ _('打开 PigeonBox 界面 ↗') ]) : null,
				running ? E('a', {
					'class': 'btn cbi-button cbi-button-action',
					'href': url + 'beam',
					'target': '_blank',
					'rel': 'noopener'
				}, [ _('设备直传(PigeonBeam)↗') ]) : null
			])
		]);
	},

	render: function(results) {
		var self = this;
		var services = (results && results[1]) || {};

		var m = new form.Map('pigeonbox', _('PigeonBox 文件快递柜'),
			_('匿名口令分享文本/文件。下方配置保存并应用后自动重启服务生效;也可用上方面板手动启停。'));

		var s = m.section(form.NamedSection, 'main', 'main', _('服务'));
		s.addremove = false;

		var o;

		o = s.option(form.Flag, 'enabled', _('启用服务'), _('总开关;停用后开机不自启,当前进程不受影响(用上方"停止")'));
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('访问端口'), _('网页与 API 同端口;改动保存应用后服务自动重启并切换端口'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('监听地址'), _('0.0.0.0=所有接口;仅本机访问可改 127.0.0.1'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'data_dir', _('数据目录'), _('SQLite/上传文件/JWT 密钥所在;更改后新数据写入新目录,**已有数据不会自动迁移**;大量文件建议指到数据盘(如 /mnt/sda1/pigeonbox)'));
		o.rmempty = false;

		o = s.option(form.Flag, 'open_upload', _('允许匿名上传'), _('关闭后仅登录用户可创建分享'));

		o = s.option(form.Value, 'admin_password', _('管理员密码'), _('留空=不改动(首次启动走 /setup 向导创建管理员);非空=管理员口令以本项为准——已存在则就地更新并吊销旧会话,保存应用后服务自动重启生效'));
		o.password = true;

		o = s.option(form.Value, 'base_url', _('站点对外 URL'), _('直链下载/presign 用;局域网直访可留空(按请求头推断),反代/穿透场景必填,如 http://share.example.com'));

		s = m.section(form.NamedSection, 'redis', 'redis', _('Redis'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用 Redis'), _('匿名取件/直传会话依赖;关闭后按 core 钉版行为匿名取件不可用(内存模式列车后为重启丢映射)'));
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('Redis 地址'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Redis 端口'));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('Redis 密码'));
		o.password = true;

		/* 应用成功后自动重启服务,让新配置立即生效 */
		m.onafterapply = function() {
			return fs.exec(INIT_script, ['restart']).then(function() {
				return new Promise(function(resolve) { window.setTimeout(resolve, 2500); })
					.then(function() { return L.resolveDefault(callServiceList(), {}); })
					.then(function(services) {
						var node = document.getElementById('pigeonbox-status');
						if (node) {
							dom.content(node, self.renderStatusPanel(services));
						}
					});
			});
		};

		return m.render().then(function(mapEl) {
			return E([
				E('div', { 'id': 'pigeonbox-status' }, self.renderStatusPanel(services)),
				mapEl
			]);
		}).catch(function(e) {
			/* 保险:Map 渲染失败时至少给出可读错误而非白页 */
			return E([
				E('h2', {}, _('PigeonBox 文件快递柜')),
				E('p', {}, _('页面渲染失败: %s').format(e.message || e))
			]);
		});
	}
});
