/* Bhat Network local service receipt generator. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BhatReceipt = factory();
})(typeof self !== 'undefined' ? self : (typeof globalThis !== 'undefined' ? globalThis : this), function () {
  'use strict';

  var PAGE_W = 595.28, PAGE_H = 841.89, MARGIN = 42, CONTENT_W = PAGE_W - 2 * MARGIN;
  var FONT = 'Helvetica', BOLD = 'Helvetica-Bold';

  function text(value) {
    return value == null ? '' : String(value).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
  }
  function hasNonWinAnsi(value) {
    return /[^\x20-\x7E\xA0-\xFF\r\n]/.test(text(value));
  }
  function money(value, currency) {
    if (value == null || value === '') return '';
    var n = Number(value);
    return isFinite(n) ? (currency || 'INR') + ' ' + n.toFixed(2) : text(value);
  }
  function escPdf(value) {
    return text(value).replace(/[\u0080-\u009F]/g, '?').replace(/[^\x20-\x7E\xA0-\xFF\r\n]/g, '?')
      .replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
  }
  function wrap(value, maxChars) {
    var source = text(value), out = [], limit = Math.max(1, maxChars || 80);
    if (!source) return [];
    source.split(/\r?\n/).forEach(function (paragraph) {
      var words = paragraph.split(/\s+/).filter(Boolean), line = '';
      if (!words.length) { out.push(''); return; }
      words.forEach(function (word) {
        while (word.length > limit) {
          if (line) { out.push(line); line = ''; }
          out.push(word.slice(0, limit)); word = word.slice(limit);
        }
        if (!word) return;
        var next = line ? line + ' ' + word : word;
        if (next.length > limit && line) { out.push(line); line = word; } else line = next;
      });
      if (line) out.push(line);
    });
    return out;
  }
  function snapshotCopy(snapshot) {
    if (!snapshot || typeof snapshot !== 'object') throw new TypeError('snapshot must be an object');
    try { return JSON.parse(JSON.stringify(snapshot)); } catch (_) { throw new TypeError('snapshot must be serializable'); }
  }
  function eachValue(s, fn) {
    var groups = [s.workshop || {}, s.customer || {}, s.vehicle || {}, s.service || {}, { message: s.message }];
    groups.forEach(function (group) { Object.keys(group).forEach(function (key) { if (hasNonWinAnsi(group[key])) fn(); }); });
  }

  function pdfFromText(pages) {
    var objects = [], offsets = [], header = '%PDF-1.4\n%\xE2\xE3\xCF\xD3\n';
    function obj(body) { objects.push((objects.length + 1) + ' 0 obj\n' + body + '\nendobj\n'); }
    obj('<< /Type /Catalog /Pages 2 0 R >>'); obj('<< /Type /Pages /Kids [] /Count 0 >>');
    obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
    obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    var kids = [];
    pages.forEach(function (page) {
      var stream = 'q\n';
      page.forEach(function (op) {
        if (op.type === 'line') stream += '0.75 w 0.75 0.75 0.75 RG ' + op.x1.toFixed(2) + ' ' + op.y1.toFixed(2) + ' m ' + op.x2.toFixed(2) + ' ' + op.y2.toFixed(2) + ' l S\n';
        else { var color = op.color || [0, 0, 0]; stream += color[0] + ' ' + color[1] + ' ' + color[2] + ' rg BT /' + (op.font === BOLD ? 'F2' : 'F1') + ' ' + op.size + ' Tf ' + op.x + ' ' + op.y.toFixed(2) + ' Td (' + escPdf(op.value) + ') Tj ET\n'; }
      });
      stream += 'Q\n'; obj('<< /Length ' + stream.length + ' >>\nstream\n' + stream + 'endstream'); var content = objects.length;
      obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + PAGE_W + ' ' + PAGE_H + '] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ' + content + ' 0 R >>'); kids.push(objects.length);
    });
    objects[1] = '2 0 obj\n<< /Type /Pages /Kids [' + kids.map(function (n) { return n + ' 0 R'; }).join(' ') + '] /Count ' + kids.length + ' >>\nendobj\n';
    var body = header; objects.forEach(function (o) { offsets.push(body.length); body += o; }); var xref = body.length;
    body += 'xref\n0 ' + (objects.length + 1) + '\n0000000000 65535 f \n'; offsets.forEach(function (n) { body += String(n).padStart(10, '0') + ' 00000 n \n'; });
    body += 'trailer\n<< /Size ' + (objects.length + 1) + ' /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF';
    var bytes = new Uint8Array(body.length); for (var i = 0; i < body.length; i++) bytes[i] = body.charCodeAt(i) & 255;
    return typeof Blob !== 'undefined' ? new Blob([bytes], { type: 'application/pdf' }) : bytes;
  }

  function jpegPdf(images, width, height) {
    var objects = [], offsets = [], header = '%PDF-1.4\n%\xE2\xE3\xCF\xD3\n';
    function obj(body) { objects.push((objects.length + 1) + ' 0 obj\n' + body + '\nendobj\n'); }
    function binaryString(bytes) { var out = '', chunk = 0x8000; for (var i = 0; i < bytes.length; i += chunk) out += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + chunk, bytes.length))); return out; }
    obj('<< /Type /Catalog /Pages 2 0 R >>'); obj('<< /Type /Pages /Kids [] /Count 0 >>');
    var kids = [];
    images.forEach(function (jpeg) {
      var imageBytes = atob(jpeg.split(',')[1]), data = new Uint8Array(imageBytes.length);
      for (var i = 0; i < imageBytes.length; i++) data[i] = imageBytes.charCodeAt(i);
      obj('<< /Type /XObject /Subtype /Image /Width ' + width + ' /Height ' + height + ' /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ' + data.length + ' >>\nstream\n' + binaryString(data) + '\nendstream');
      var imageObj = objects.length;
      var stream = 'q ' + PAGE_W.toFixed(2) + ' 0 0 ' + PAGE_H.toFixed(2) + ' 0 0 cm /Im' + imageObj + ' Do Q';
      obj('<< /Length ' + stream.length + ' >>\nstream\n' + stream + '\nendstream'); var contentObj = objects.length;
      obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + PAGE_W + ' ' + PAGE_H + '] /Resources << /XObject << /Im' + imageObj + ' ' + imageObj + ' 0 R >> >> /Contents ' + contentObj + ' 0 R >>'); kids.push(objects.length);
    });
    objects[1] = '2 0 obj\n<< /Type /Pages /Kids [' + kids.map(function (n) { return n + ' 0 R'; }).join(' ') + '] /Count ' + kids.length + ' >>\nendobj\n';
    var body = header, offsets = []; objects.forEach(function (o) { offsets.push(body.length); body += o; }); var xref = body.length;
    body += 'xref\n0 ' + (objects.length + 1) + '\n0000000000 65535 f \n'; offsets.forEach(function (n) { body += String(n).padStart(10, '0') + ' 00000 n \n'; });
    body += 'trailer\n<< /Size ' + (objects.length + 1) + ' /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF';
    var bytes = new Uint8Array(body.length); for (var j = 0; j < body.length; j++) bytes[j] = body.charCodeAt(j) & 255;
    return new Blob([bytes], { type: 'application/pdf' });
  }

  function browserUnicodePdf(s) {
    if (typeof document === 'undefined' || !document.createElement) throw new Error('Unicode receipt rendering requires a browser canvas');
    var scale = 2, width = Math.round(PAGE_W * scale), height = Math.round(PAGE_H * scale), canvas = document.createElement('canvas');
    canvas.width = width; canvas.height = height; var ctx = canvas.getContext('2d');
    if (!ctx || typeof canvas.toDataURL !== 'function') throw new Error('Unicode receipt rendering requires canvas');
    var pages = [], y, firstPage = true;
    function page() { ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, width, height); y = MARGIN * scale; pages.push(canvas.toDataURL('image/jpeg', 0.92)); }
    function ensure(h) { if (y + h > (PAGE_H - MARGIN) * scale) { pages[pages.length - 1] = canvas.toDataURL('image/jpeg', 0.92); page(); } }
    function draw(value, size, bold, color) { ensure((size + 6) * scale); ctx.font = (bold ? '700 ' : '') + (size * scale) + 'px sans-serif'; ctx.fillStyle = color || '#111'; ctx.fillText(text(value), MARGIN * scale, y); y += (size + 5) * scale; }
    function lines(label, value, size) { if (value == null || value === '') return; ctx.font = (size * scale) + 'px sans-serif'; var prefix = label || '', available = CONTENT_W * scale - ctx.measureText(prefix).width, parts = [], source = text(value).split(/\r?\n/);
      source.forEach(function (paragraph) { var words = paragraph.split(/\s+/).filter(Boolean), line = '', max = available; words.forEach(function (word) { var candidate = line ? line + ' ' + word : word; if (ctx.measureText(candidate).width > max && line) { parts.push(line); line = word; max = CONTENT_W * scale; } else if (ctx.measureText(candidate).width > max) { while (word && ctx.measureText(word).width > max) { var cut = 1; while (cut < word.length && ctx.measureText(word.slice(0, cut + 1)).width <= max) cut++; parts.push(word.slice(0, cut)); word = word.slice(cut); } line = word; max = CONTENT_W * scale; } else line = candidate; }); if (line || !words.length) parts.push(line); });
      parts.forEach(function (part, i) { draw((i === 0 ? prefix : ' '.repeat(Math.max(1, prefix.length))) + part, size, false); }); }
    function section(title) { ensure(25 * scale); ctx.strokeStyle = '#777'; ctx.beginPath(); ctx.moveTo(MARGIN * scale, y - 5 * scale); ctx.lineTo((PAGE_W - MARGIN) * scale, y - 5 * scale); ctx.stroke(); y += 8 * scale; draw(title, 11, true, '#1a4066'); }
    page(); draw((s.workshop || {}).name || 'BHAT NETWORK', 18, true, '#0d3356'); var w = s.workshop || {}, c = s.customer || {}, v = s.vehicle || {}, sv = s.service || {};
    lines('', [w.address_text, w.area, w.district, w.city, w.state, w.postal_code, w.phone].filter(function (x) { return x != null && x !== ''; }).join('  | '), 8); draw('SERVICE RECEIPT', 13, true, '#1a4066'); lines('Record: ', sv.record_id, 9); lines('Booking: ', sv.booking_id, 9); lines('Date: ', sv.date, 9);
    section('CUSTOMER'); lines('Name: ', c.name, 9); lines('Phone: ', c.phone, 9); lines('Address: ', c.address_text, 9);
    section('VEHICLE'); lines('Vehicle: ', [v.make, v.model, v.year].filter(function (x) { return x != null && x !== ''; }).join(' '), 9); lines('Color: ', v.color, 9); lines('Plate: ', v.plate, 9);
    section('SERVICE DETAILS'); lines('Name: ', sv.name, 9); lines('Category: ', sv.category, 9); lines('Work performed: ', sv.work_performed, 9); lines('Parts: ', sv.parts, 9); lines('Mileage (km): ', sv.mileage_km, 9); lines('Cost: ', money(sv.cost, s.currency), 9); lines('Notes: ', sv.notes, 9);
    if (s.message != null && s.message !== '') { section('MESSAGE FROM THE WORKSHOP'); lines('', s.message, 10); }
    draw('Generated locally on request. This receipt contains the service snapshot provided by the workshop.', 7, false, '#666'); pages[pages.length - 1] = canvas.toDataURL('image/jpeg', 0.92);
    return jpegPdf(pages, width, height);
  }

  function generatePdf(snapshot) {
    var s = snapshotCopy(snapshot), unicode = false; eachValue(s, function () { unicode = true; });
    if (unicode) return browserUnicodePdf(s);
    var pages = [], ops = [], y = PAGE_H - MARGIN;
    function newPage() { if (ops.length) pages.push(ops); ops = []; y = PAGE_H - MARGIN; }
    function ensure(height) { if (y - height < MARGIN) newPage(); }
    function line(value, size, bold, color) { ensure((size || 10) + 6); ops.push({ type: 'text', x: MARGIN, y: y, value: value, size: size || 10, font: bold ? BOLD : FONT, color: color }); y -= (size || 10) + 5; }
    function wrapped(label, value, max, size) { if (value == null || value === '') return; var first = true; wrap(value, max || 86).forEach(function (part) { line((first ? label : '     ') + part, size || 9); first = false; }); }
    function section(title) { ensure(25); ops.push({ type: 'line', x1: MARGIN, y1: y + 3, x2: PAGE_W - MARGIN, y2: y + 3 }); y -= 10; line(title, 11, true, [0.10, 0.25, 0.40]); }
    var w = s.workshop || {}, c = s.customer || {}, v = s.vehicle || {}, sv = s.service || {};
    line(w.name || 'BHAT NETWORK', 18, true, [0.05, 0.20, 0.34]); wrapped('', [w.address_text, w.area, w.district, w.city, w.state, w.postal_code, w.phone].filter(function (x) { return x != null && x !== ''; }).join('  | '), 92, 8); line('SERVICE RECEIPT', 13, true, [0.10, 0.25, 0.40]); wrapped('Record: ', sv.record_id, 76, 9); wrapped('Booking: ', sv.booking_id, 76, 9); wrapped('Date: ', sv.date, 76, 9);
    section('CUSTOMER'); wrapped('Name: ', c.name, 78); wrapped('Phone: ', c.phone, 78); wrapped('Address: ', c.address_text, 72);
    section('VEHICLE'); wrapped('Vehicle: ', [v.make, v.model, v.year].filter(function (x) { return x != null && x !== ''; }).join(' '), 78); wrapped('Color: ', v.color, 78); wrapped('Plate: ', v.plate, 78);
    section('SERVICE DETAILS'); wrapped('Name: ', sv.name, 78); wrapped('Category: ', sv.category, 78); wrapped('Work performed: ', sv.work_performed, 70); wrapped('Parts: ', sv.parts, 78); if (sv.mileage_km != null && sv.mileage_km !== '') wrapped('Mileage (km): ', sv.mileage_km, 70); if (sv.cost != null && sv.cost !== '') wrapped('Cost: ', money(sv.cost, s.currency), 78); wrapped('Notes: ', sv.notes, 70);
    if (s.message != null && s.message !== '') { section('MESSAGE FROM THE WORKSHOP'); wrap(s.message, 84).forEach(function (part) { line(part, 10, false, [0.12, 0.12, 0.12]); }); }
    line('Generated locally on request. This receipt contains the service snapshot provided by the workshop.', 7, false, [0.35, 0.35, 0.35]); if (ops.length) pages.push(ops); return pdfFromText(pages);
  }

  function download(blob, filename) { filename = filename || 'bhat-service-receipt.pdf'; if (typeof document === 'undefined' || !document.createElement) return { status: 'unavailable', reason: 'download requires a browser' }; var urlApi = URL, url = urlApi.createObjectURL(blob), a = document.createElement('a'); a.href = url; a.download = filename; a.rel = 'noopener'; a.click(); setTimeout(function () { urlApi.revokeObjectURL(url); }, 1000); return { status: 'downloaded', filename: filename }; }
  async function share(blob, filename, options) { filename = filename || 'bhat-service-receipt.pdf'; options = options || {}; var nav = options.navigator || (typeof navigator !== 'undefined' ? navigator : null); if (!nav || typeof nav.share !== 'function') return Object.assign(download(blob, filename), { status: 'downloaded', reason: 'file sharing is not supported' }); var file = typeof File !== 'undefined' ? new File([blob], filename, { type: 'application/pdf' }) : blob; if (typeof nav.canShare === 'function' && !nav.canShare({ files: [file] })) return Object.assign(download(blob, filename), { status: 'downloaded', reason: 'file sharing is not supported' }); try { await nav.share({ files: [file], title: options.title || 'Bhat Network service receipt' }); return { status: 'shared', filename: filename }; } catch (err) { if (err && err.name === 'AbortError') return { status: 'cancelled', filename: filename }; return Object.assign(download(blob, filename), { status: 'downloaded', reason: 'share failed' }); } }
  return { generatePdf: generatePdf, download: download, share: share, wrapText: wrap };
});
