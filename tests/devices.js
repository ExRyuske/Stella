// Run with node tests/devices.js. Exercise the actual LuCI device merge with RPC fixtures.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('htdocs/luci-static/resources/stella/common.js', 'utf8');
const body = source.split('\tdevices() {\n')[1].split('\n\t},')[0];

async function check(netmask) {
	const hints = {
		'AA:00:00:00:00:01': { name: 'phone', ipaddrs: [ '192.168.2.189' ] },
		'AA:00:00:00:00:02': { ipaddrs: [], ip6addrs: [ 'fe80::2' ] },
		'AA:00:00:00:00:03': { ipaddrs: [ '203.0.113.1' ] },
		'AA:00:00:00:00:04': { ipaddrs: [ '192.168.2.1' ] },
		'AA:00:00:00:00:05': { name: 'known' }
	};
	const net = { 'br-lan': { mac: 'AA:00:00:00:00:04', ipaddrs: [ { address: '192.168.2.1', netmask } ] } };
	const uci = {
		load: async () => {},
		sections: () => [ { '.name': 'saved', mac: 'AA:00:00:00:00:01', name: 'My phone', policy: 'vpn' },
			{ '.name': 'offline', mac: 'aa:00:00:00:00:06' } ]
	};
	const devices = new Function('callHostHints', 'callNetDevices', 'callSettings', 'uci', 'L', body);
	const result = await devices(async () => hints, async () => net,
		async () => ({ lan_devices: [ 'br-lan' ] }), uci, { toArray: (x) => [ x ] });
	assert.equal(result.length, 4);
	assert.equal(result.find((d) => d.hostname == 'phone').name, 'My phone');
	assert.equal(result.find((d) => d.hostname == 'phone').policy, 'vpn');
	assert.equal(result.find((d) => d.hostname == 'phone').ip, '192.168.2.189');
	assert.equal(result.find((d) => d.mac.endsWith(':02')).ip, 'fe80::2');
	assert.ok(result.find((d) => d.hostname == 'known'));
	assert.ok(result.find((d) => d.id == 'offline'));
}
Promise.all([ check('255.255.255.0'), check(24) ]).then(() => console.log('devices: OK')).catch((err) => {
	console.error(err);
	process.exitCode = 1;
});
