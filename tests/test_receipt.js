const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const receipt = require('../receipt.js');

const snapshot = {
  workshop: { name: 'Bhat Auto Works', address_text: 'Srinagar', area: 'Lal Chowk', district: 'Srinagar', city: 'Srinagar', state: 'Jammu & Kashmir', postal_code: '190001', phone: '+91 70000 00000' },
  customer: { name: 'Amina Khan', phone: '+91 99999 11111', address_text: 'Long customer address that must wrap within the page without truncation.' },
  vehicle: { make: 'Maruti', model: 'Swift', year: 2020, color: 'White', plate: 'JK01AB1234' },
  service: {
    record_id: 'SR-2026-001', booking_id: 'BK-2026-001', name: 'Brake service', category: 'Maintenance', date: '2026-11-19',
    work_performed: 'Front brake pad replacement and inspection. A long paragraph that must wrap across multiple lines in the generated receipt.',
    parts: 'Front brake pads', mileage_km: 0, cost: 0, notes: 'Road tested after service.'
  },
  message: 'Thank you for trusting our workshop. Please return after 5,000 km for a check-up.'
};

async function blobBytes(blob) { return Buffer.from(await blob.arrayBuffer()); }

(async () => {
  const blob = receipt.generatePdf(snapshot);
  assert.strictEqual(blob.type, 'application/pdf');
  const bytes = await blobBytes(blob);
  assert.ok(bytes.slice(0, 8).toString().startsWith('%PDF-1.4'), 'PDF header');
  assert.ok(bytes.toString('latin1').includes('/Type /Page'), 'has a page object');

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bhat-receipt-'));
  const pdf = path.join(tmp, 'receipt.pdf');
  fs.writeFileSync(pdf, bytes);
  try {
    const extracted = execFileSync('pdftotext', [pdf, '-'], { encoding: 'utf8' });
    assert.match(extracted, /Bhat Auto Works/);
    assert.match(extracted, /MESSAGE FROM THE WORKSHOP/);
    assert.match(extracted, /Thank you for trusting our workshop/);
    assert.match(extracted, /Front brake pad replacement/);
    assert.match(extracted, /Record: SR-2026-001/);
    assert.match(extracted, /Booking: BK-2026-001/);
    assert.match(extracted, /Mileage \(km\): 0/);
    assert.match(extracted, /Cost: INR 0\.00/);
  } catch (err) { if (err.code !== 'ENOENT') throw err; }

  assert.ok(receipt.wrapText('one two three four five', 8).length > 1, 'wraps long text');
  assert.ok(receipt.wrapText('line one\nline two', 80).length === 2, 'preserves explicit line breaks');

  let shared = false;
  const sharingNavigator = { canShare: ({ files }) => files.length === 1, share: async ({ files, title }) => { shared = files.length === 1 && title.includes('receipt'); } };
  const sharedResult = await receipt.share(blob, 'service-receipt.pdf', { navigator: sharingNavigator });
  assert.strictEqual(sharedResult.status, 'shared'); assert.ok(shared, 'uses native file share only when called');

  let clicked = false;
  global.document = { createElement: () => ({ click: () => { clicked = true; } }) };
  global.URL = { createObjectURL: () => 'blob:local-only', revokeObjectURL: () => {} };
  const fallbackResult = await receipt.share(blob, 'service-receipt.pdf', { navigator: {} });
  assert.strictEqual(fallbackResult.status, 'downloaded'); assert.ok(clicked, 'unsupported sharing falls back to local download');
  delete global.document; delete global.URL;

  const source = fs.readFileSync(path.join(__dirname, '..', 'receipt.js'), 'utf8');
  assert.ok(!/wa\.me|whatsapp/i.test(source), 'does not construct WhatsApp links or send automatically');
  assert.ok(!/fetch\s*\(|XMLHttpRequest|navigator\.sendBeacon/i.test(source), 'does not upload or track receipt data');

  // Browser regression: real canvas rendering for Hindi and Urdu must produce an image PDF,
  // not WinAnsi question-mark substitutions. The check runs entirely offline from a temp file.
  const browserHtml = `<!doctype html><script>${source.replace(/<\/script>/gi, '<\\/script>')}</script><script>
    (async () => {
      try {
        const s = { workshop: { name: 'बहत नेटवर्क', address_text: 'श्रीनगर जम्मू और कश्मीर', phone: '+91 70000' }, customer: { name: 'आमिना खान', phone: '٠٩٩٩٩', address_text: 'پتہ سری نگر' }, vehicle: { make: 'मारुति', model: 'Swift', year: 2020, color: 'سفید', plate: 'JK01AB1234' }, service: { record_id: 'ह-1', booking_id: 'ب-1', name: 'ब्रेक सर्विस', category: 'مرمت', date: '2026-11-19', work_performed: 'ब्रेक पैड बदले गए और परीक्षण किया गया। هذا نص طويل يجب أن يلتف داخل الصفحة دون اقتطاع.', parts: 'ब्रेक पैड', mileage_km: 0, cost: 0, notes: 'تم الاختبار' }, message: 'धन्यवाद / شکریہ' };
        const b = BhatReceipt.generatePdf(s); const bytes = new Uint8Array(await b.arrayBuffer()); const latin = new TextDecoder('latin1').decode(bytes);
        document.body.dataset.result = b.type === 'application/pdf' && latin.includes('/Subtype /Image') && !latin.includes('????') ? 'pass' : 'fail';
      } catch (e) { document.body.dataset.result = 'error:' + e.message; }
    })();
  </script>`;
  const html = path.join(tmp, 'unicode.html'); fs.writeFileSync(html, browserHtml);
  try {
    const dom = execFileSync('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--allow-file-access-from-files', '--virtual-time-budget=4000', '--dump-dom', 'file://' + html], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
    assert.match(dom, /data-result="pass"/, 'Hindi and Urdu render to a local image-backed PDF');
  } catch (err) {
    if (err.code === 'ENOENT') console.warn('chromium unavailable; browser receipt test skipped'); else throw err;
  }
  console.log('receipt tests passed');
})().catch((error) => { console.error(error); process.exitCode = 1; });
