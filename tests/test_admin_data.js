'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('../admin-data.js');
const { TABLES, PAGE_SIZE, escapeHtml, parseObject, pageRange, updatePatch } = admin._private;

test('allowlist contains requested tables with schema primary keys and omits audit_log', () => {
  const expected = {
    profiles: 'id', customers: 'profile_id', workshops: 'id', workshop_members: 'id',
    workshop_services: 'id', workshop_hours: 'id', vehicles: 'id', service_requests: 'id',
    booking_updates: 'id', booking_status_history: 'id', booking_intake: 'id',
    additional_work_requests: 'id', service_records: 'id', marketplace_listings: 'id'
  };
  assert.deepEqual(Object.fromEntries(Object.entries(TABLES).map(([table, info]) => [table, info.pk])), expected);
  assert.equal(TABLES.audit_log, undefined);
  assert.equal(TABLES.notifications, undefined);
  assert.equal(TABLES.workshop_receipt_settings, undefined);
  assert.equal(TABLES.workshop_receipts, undefined);
});

test('escapeHtml protects text inserted into markup', () => {
  assert.equal(escapeHtml('<script>alert("x")</script> & \'quoted\''),
    '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;quoted&#39;');
});

test('parseObject accepts objects and rejects invalid/non-object JSON', () => {
  assert.deepEqual(parseObject('{"name":"ok"}').value, { name: 'ok' });
  assert.match(parseObject('{bad}').error, /invalid/i);
  assert.match(parseObject('[]').error, /JSON object/i);
  assert.match(parseObject('null').error, /JSON object/i);
});

test('pageRange is fixed-size and never accepts arbitrary ranges', () => {
  assert.deepEqual(pageRange(0), { from: 0, to: PAGE_SIZE - 1 });
  assert.deepEqual(pageRange(2), { from: PAGE_SIZE * 2, to: PAGE_SIZE * 3 - 1 });
  assert.deepEqual(pageRange(-4), { from: 0, to: PAGE_SIZE - 1 });
  assert.deepEqual(pageRange('2'), { from: 0, to: PAGE_SIZE - 1 });
});

test('updatePatch protects primary keys and removes unchanged key from update payload', () => {
  assert.deepEqual(updatePatch({ id: 'a', name: 'new' }, 'id', 'a').value, { name: 'new' });
  assert.match(updatePatch({ id: 'b', name: 'new' }, 'id', 'a').error, /cannot be changed/i);
  assert.deepEqual(updatePatch({ name: 'new' }, 'id', 'a').value, { name: 'new' });
});
