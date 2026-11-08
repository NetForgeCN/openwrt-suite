/* SPDX-License-Identifier: GPL-3.0-only */
(function() {
    'use strict';
    var hint = document.getElementById('hint');
    if (!window.L) { hint.textContent = '地图组件未加载，请重新安装插件'; return; }
    var map = L.map('map', { scrollWheelZoom: false }).setView([28, 105], 3);
    var group = L.layerGroup().addTo(map), markers = {}, points = [], signature = '', userMoved = false, fitting = false;
    var tiles = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 18, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap</a> contributors'
    }).addTo(map);
    var tileFailed = false;
    function updateHint() {
        hint.hidden = points.length > 0 && !tileFailed;
        hint.textContent = tileFailed ? '地图瓦片暂不可用，路由节点仍可查看' : '等待有地理坐标的路由节点';
    }
    tiles.on('tileerror', function() { tileFailed = true; updateHint(); });
    tiles.on('tileload', function() { tileFailed = false; updateHint(); });
    map.on('dragstart zoomstart', function() { if (!fitting) userMoved = true; });
    function fit() {
        if (!points.length) return;
        fitting = true;
        map.fitBounds(points.map(function(p) { return [p.lat, p.lon]; }), { padding: [35, 35], maxZoom: 7, animate: false });
        fitting = false;
    }
    function popup(point) {
        var box = document.createElement('div'); box.className = 'ont-popup';
        var title = document.createElement('strong'); title.textContent = '#' + point.ttl + '  ' + point.ip; box.appendChild(title);
        [point.location || '暂无地理信息', point.owner, point.asn,
            (point.samples || []).map(function(v) { return Number(v).toFixed(2); }).join(' / ') + ' ms', point.hostname].filter(Boolean).forEach(function(text) {
                var line = document.createElement('div'); line.textContent = text; box.appendChild(line);
            });
        return box;
    }
    function update(data) {
        points = (Array.isArray(data.points) ? data.points : []).filter(function(p) {
            return Number.isFinite(p.lat) && Number.isFinite(p.lon) && Math.abs(p.lat) <= 90;
        });
        var nextSignature = JSON.stringify(points.map(function(p) { return [p.key, p.lat, p.lon]; }));
        group.clearLayers(); markers = {};
        points.forEach(function(point, index) {
            if (index) {
                var prev = points[index - 1];
                L.polyline([[prev.lat, prev.lon], [point.lat, point.lon]], {
                    color: '#438fc8', weight: 3, opacity: .8, dashArray: point.ttl - prev.ttl > 1 ? '7 7' : null
                }).addTo(group);
            }
            var marker = L.circleMarker([point.lat, point.lon], { radius: 7, color: '#2c79b5', weight: 2,
                fillColor: '#78b7e5', fillOpacity: .95 }).addTo(group);
            marker.bindPopup(popup(point));
            var label = document.createElement('span'); label.textContent = String(point.ttl);
            marker.bindTooltip(label, { permanent: true, direction: 'top', offset: [0, -6], className: 'ont-label' });
            marker.on('click', function() { parent.postMessage({ type: 'open-nexttrace-select', key: point.key }, location.origin); });
            markers[point.key] = marker;
        });
        if (data.fit) userMoved = false;
        if (data.fit || (!userMoved && signature !== nextSignature)) fit();
        signature = nextSignature;
        updateHint();
    }
    window.addEventListener('message', function(event) {
        if (event.origin !== location.origin || event.source !== parent || !event.data) return;
        if (event.data.type === 'open-nexttrace-update') update(event.data);
        if (event.data.type === 'open-nexttrace-focus') {
            var marker = markers[event.data.key], p = event.data.point;
            if (marker) { map.setView(marker.getLatLng(), Math.max(map.getZoom(), 5)); marker.openPopup(); }
            else if (p && Number.isFinite(p.lat) && Number.isFinite(p.lon)) {
                map.setView([p.lat, p.lon], 5);
                L.popup().setLatLng([p.lat, p.lon]).setContent(popup(p)).openOn(map);
            }
        }
    });
    new ResizeObserver(function() { map.invalidateSize(); }).observe(document.body);
}());
