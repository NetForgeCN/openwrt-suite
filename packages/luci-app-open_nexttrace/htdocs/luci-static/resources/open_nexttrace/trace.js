'use strict';
'require baseclass';

// NextTrace traditional RAW: ttl|ip|ptr|ms|asn|country|province|city|district|owner|lat|lon
// One record per probe, including the historical compact timeout record.
return baseclass.extend({
    parse: function(raw) {
        var hops = {}, rows = [];
        String(raw || '').split('\n').slice(0, -1).forEach(function(line) {
            var p = line.replace(/\r$/, '').split('|');
            if (!/^\d{1,2}$/.test(p[0])) return;
            var ttl = Number(p[0]), timeout = p[1] === '*';
            if (ttl < 1 || ttl > 64 || (timeout ? p.length < 8 : p.length !== 12)) return;
            if (!timeout && (!/^[0-9a-fA-F:.]+$/.test(p[1]) || !p[3].trim() || !isFinite(Number(p[3])) || Number(p[3]) < 0)) return;
            var hop = hops[ttl] || (hops[ttl] = { total: 0, lost: 0, paths: {} });
            hop.total++;
            if (timeout) { hop.lost++; return; }
            var row = hop.paths[p[1]] || (hop.paths[p[1]] = {
                key: ttl + ':' + p[1], ttl: ttl, ip: p[1], hostname: p[2],
                asn: p[4] ? 'AS' + p[4].replace(/^AS/i, '') : '',
                location: p.slice(5, 9).filter(Boolean).join(' '), owner: p[9], samples: []
            });
            row.samples.push(Number(p[3]));
            var lat = Number(p[10]), lon = Number(p[11]);
            if (p[10].trim() && p[11].trim() && isFinite(lat) && isFinite(lon) &&
                Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(lat === 0 && lon === 0)) {
                row.lat = lat; row.lon = lon;
            }
        });
        Object.keys(hops).sort(function(a, b) { return a - b; }).forEach(function(ttl) {
            var hop = hops[ttl], paths = Object.keys(hop.paths);
            if (!paths.length) {
                rows.push({ key: ttl + ':*', ttl: Number(ttl), ip: '*', samples: [], loss: 100,
                    total: hop.total, location: '请求超时', hostname: '', asn: '', owner: '' });
            }
            paths.forEach(function(ip) {
                var row = hop.paths[ip];
                row.total = hop.total;
                row.loss = Math.round(hop.lost * 100 / hop.total);
                row.average = row.samples.reduce(function(a, b) { return a + b; }, 0) / row.samples.length;
                rows.push(row);
            });
        });
        return rows;
    },

    points: function(rows) {
        var seen = {}, previous = null;
        return rows.filter(function(row) {
            // ECMP: show every path in the table; the map connects the first
            // geolocated responder per TTL, rather than inventing branch edges.
            if (row.lat == null || row.lon == null || seen[row.ttl]) return false;
            seen[row.ttl] = true;
            return true;
        }).map(function(row) {
            var point = Object.assign({}, row), lon = row.lon;
            if (previous != null) {
                while (lon - previous > 180) lon -= 360;
                while (lon - previous < -180) lon += 360;
            }
            previous = lon;
            point.lon = lon;
            return point;
        });
    },

    csv: function(rows) {
        function quote(value) {
            var s = String(value == null ? '' : value);
            // Prevent formula execution when a hostname/owner is opened in Excel.
            if (/^[=+@\-\t\r]/.test(s)) s = "'" + s;
            return '"' + s.replace(/"/g, '""') + '"';
        }
        return '\ufeff' + [['跳数', 'IP', 'RTT (ms)', '地理位置', '组织', 'ASN', '主机名', '本跳未响应 (%)']].concat(
            rows.map(function(r) { return [r.ttl, r.ip, r.samples.join(' / '), r.location, r.owner, r.asn, r.hostname, r.loss]; })
        ).map(function(row) { return row.map(quote).join(','); }).join('\r\n');
    }
});
