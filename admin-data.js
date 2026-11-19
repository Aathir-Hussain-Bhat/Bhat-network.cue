(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.BhatAdminData = factory();
}(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  var PAGE_SIZE = 20;
  var TABLES = Object.freeze({
    profiles: { label: 'Profiles', pk: 'id' },
    customers: { label: 'Customers', pk: 'profile_id' },
    workshops: { label: 'Workshops', pk: 'id' },
    workshop_members: { label: 'Workshop members', pk: 'id' },
    workshop_services: { label: 'Workshop services', pk: 'id' },
    workshop_hours: { label: 'Workshop hours', pk: 'id' },
    vehicles: { label: 'Vehicles', pk: 'id' },
    service_requests: { label: 'Service requests', pk: 'id' },
    booking_updates: { label: 'Booking updates', pk: 'id' },
    booking_status_history: { label: 'Booking status history', pk: 'id' },
    booking_intake: { label: 'Booking intake', pk: 'id' },
    additional_work_requests: { label: 'Additional work requests', pk: 'id' },
    service_records: { label: 'Service records', pk: 'id' },
    marketplace_listings: { label: 'Marketplace listings', pk: 'id' }
  });

  var state = null;
  var mountedContainer = null;
  var cleanup = null;

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function tableInfo(table) {
    return Object.prototype.hasOwnProperty.call(TABLES, table) ? TABLES[table] : null;
  }

  function parseObject(text) {
    var parsed;
    try { parsed = JSON.parse(text); } catch (e) { return { error: 'JSON is invalid.' }; }
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
      return { error: 'Value must be a JSON object.' };
    }
    return { value: parsed };
  }

  function pageRange(page) {
    var p = Number.isInteger(page) && page >= 0 ? page : 0;
    return { from: p * PAGE_SIZE, to: p * PAGE_SIZE + PAGE_SIZE - 1 };
  }

  function identifier(row, pk) {
    return row && Object.prototype.hasOwnProperty.call(row, pk) ? String(row[pk]) : '';
  }

  function updatePatch(input, pk, originalId) {
    var copy = Object.assign({}, input);
    if (Object.prototype.hasOwnProperty.call(copy, pk) && String(copy[pk]) !== String(originalId)) {
      return { error: 'The primary key cannot be changed while editing a row.' };
    }
    delete copy[pk];
    return { value: copy };
  }

  function jsonText(value) {
    try { return JSON.stringify(value || {}, null, 2); } catch (e) { return '{}'; }
  }

  function messageOf(error) {
    if (!error) return 'Unknown database error.';
    return error.message || error.details || String(error);
  }

  function status(text, kind) {
    if (!state || !state.container) return;
    var node = state.container.querySelector('[data-admin-status]');
    if (node) {
      node.className = 'bhat-admin-status ' + (kind || '');
      node.textContent = text || '';
    }
  }

  function render() {
    var s = state;
    if (!s || !s.container) return;
    var info = tableInfo(s.table);
    var rows = s.rows || [];
    var options = Object.keys(TABLES).map(function (name) {
      return '<option value="' + escapeHtml(name) + '"' + (name === s.table ? ' selected' : '') + '>' + escapeHtml(TABLES[name].label) + '</option>';
    }).join('');
    var rowList = rows.length ? rows.map(function (row, index) {
      var id = identifier(row, info.pk);
      return '<li><button type="button" data-admin-edit="' + index + '">Edit</button> <code>' + escapeHtml(id || '(no identifier)') + '</code> <span>' + escapeHtml(jsonText(row).slice(0, 220)) + '</span></li>';
    }).join('') : '<li>No rows on this page.</li>';
    var formTitle = s.editIndex === null ? 'Create row' : 'Edit row ' + escapeHtml(identifier(rows[s.editIndex] || {}, info.pk));
    s.container.innerHTML = '<div class="bhat-admin-data" data-admin-root>' +
      '<label>Data table <select data-admin-table>' + options + '</select></label>' +
      '<p class="bhat-admin-status" data-admin-status role="status"></p>' +
      '<p><small>Page ' + (s.page + 1) + ' · ' + escapeHtml(info.label) + ' · primary key: ' + escapeHtml(info.pk) + '</small></p>' +
      '<ol data-admin-rows>' + rowList + '</ol>' +
      '<p><button type="button" data-admin-prev' + (s.page === 0 ? ' disabled' : '') + '>Previous</button> <button type="button" data-admin-next' + (rows.length < PAGE_SIZE ? ' disabled' : '') + '>Next</button></p>' +
      '<hr><h3>' + formTitle + '</h3>' +
      '<form data-admin-form><label>Row JSON<br><textarea data-admin-json rows="12" cols="70" spellcheck="false">' + escapeHtml(s.editIndex === null ? '{}' : jsonText(rows[s.editIndex])) + '</textarea></label><br>' +
      '<button type="submit">' + (s.editIndex === null ? 'Create' : 'Update') + '</button> ' +
      (s.editIndex === null ? '' : '<button type="button" data-admin-delete>Delete</button> <button type="button" data-admin-cancel>Cancel</button>') +
      '</form><p><small>Database constraints, foreign keys, triggers, system-managed fields, and RLS still apply. Mutations may be rejected.</small></p></div>';
    if (s.notice) status(s.notice.text, s.notice.kind);
  }

  function queryRows() {
    var s = state, info = tableInfo(s.table), range = pageRange(s.page);
    var seq = ++s.querySeq;
    status('Loading…');
    var query;
    try {
      query = s.sb.from(s.table).select('*').order(info.pk, { ascending: true }).range(range.from, range.to);
    } catch (e) { status('Read failed: ' + messageOf(e), 'error'); return Promise.resolve(); }
    return Promise.resolve(query).then(function (result) {
      if (state !== s || seq !== s.querySeq) return;
      if (result && result.error) throw result.error;
      s.rows = (result && result.data) || [];
      s.editIndex = null;
      render();
      s.notice = null;
    }).catch(function (error) { if (state === s && seq === s.querySeq) { s.rows = []; render(); status('Read failed: ' + messageOf(error), 'error'); } });
  }

  function mutate(kind, payload, pkValue) {
    var s = state, info = tableInfo(s.table), request;
    if (kind === 'insert') request = s.sb.from(s.table).insert(payload);
    else if (kind === 'update') request = s.sb.from(s.table).update(payload).eq(info.pk, pkValue);
    else request = s.sb.from(s.table).delete().eq(info.pk, pkValue);
    return Promise.resolve(request.select(info.pk)).then(function (result) {
      if (result && result.error) throw result.error;
      if (!result || !result.data || result.data.length !== 1) throw new Error('No row was changed. Check access and whether the row still exists.');
      if (state !== s) return;
      s.editIndex = null;
      s.notice = { text: kind === 'insert' ? 'Row created.' : kind === 'update' ? 'Row updated.' : 'Row deleted.', kind: 'success' };
      return queryRows();
    }).catch(function (error) { if (state === s) status('Mutation failed: ' + messageOf(error), 'error'); });
  }

  function onEvent(event) {
    var s = state, target = event.target, info = tableInfo(s.table);
    if (!target) return;
    if (event.type === 'change' && target.matches('[data-admin-table]')) {
      if (!tableInfo(target.value)) return;
      s.table = target.value; s.page = 0; s.editIndex = null; queryRows(); return;
    }
    if (target.matches('[data-admin-prev]') && s.page > 0) { s.page--; s.editIndex = null; queryRows(); return; }
    if (target.matches('[data-admin-next]') && s.rows.length === PAGE_SIZE) { s.page++; s.editIndex = null; queryRows(); return; }
    if (target.matches('[data-admin-edit]')) { s.editIndex = Number(target.getAttribute('data-admin-edit')); render(); return; }
    if (target.matches('[data-admin-cancel]')) { s.editIndex = null; render(); return; }
    if (target.matches('[data-admin-delete]')) {
      var row = s.rows[s.editIndex], id = identifier(row, info.pk);
      if (!row || !id) { status('Cannot delete a row without its primary key.', 'error'); return; }
      var confirmed = typeof rootConfirm === 'function' ? rootConfirm('Delete ' + info.label + ' row with ' + info.pk + ' = ' + id + '?') : false;
      if (confirmed) mutate('delete', null, id);
      return;
    }
    if (target.matches('[data-admin-form]')) {
      event.preventDefault();
      var parsed = parseObject(s.container.querySelector('[data-admin-json]').value);
      if (parsed.error) { status(parsed.error, 'error'); return; }
      if (s.editIndex === null) { mutate('insert', parsed.value); return; }
      var row = s.rows[s.editIndex], id = identifier(row, info.pk), patch = updatePatch(parsed.value, info.pk, id);
      if (patch.error) { status(patch.error, 'error'); return; }
      mutate('update', patch.value, id);
    }
  }

  // Resolve confirm at call time so tests and host applications can provide it safely.
  function rootConfirm(text) {
    return typeof window !== 'undefined' && typeof window.confirm === 'function' ? window.confirm(text) : false;
  }

  function mount(container, options) {
    if (!container || typeof container.addEventListener !== 'function') throw new TypeError('A mount container is required.');
    options = options || {};
    if (!options.sb || typeof options.sb.from !== 'function') throw new TypeError('A Supabase client is required.');
    unmount();
    state = { container: container, sb: options.sb, esc: options.esc || escapeHtml, toast: options.toast, table: 'profiles', page: 0, rows: [], editIndex: null, notice: null, querySeq: 0 };
    mountedContainer = container;
    cleanup = function () { container.removeEventListener('click', onEvent); container.removeEventListener('change', onEvent); container.removeEventListener('submit', onEvent); };
    container.addEventListener('click', onEvent);
    container.addEventListener('change', onEvent);
    container.addEventListener('submit', onEvent);
    render();
    queryRows();
  }

  function unmount() {
    if (cleanup) cleanup();
    if (mountedContainer) mountedContainer.textContent = '';
    cleanup = null; mountedContainer = null; state = null;
  }

  var api = { mount: mount, unmount: unmount };
  if (typeof module === 'object' && module.exports) {
    api._private = { TABLES: TABLES, PAGE_SIZE: PAGE_SIZE, escapeHtml: escapeHtml, parseObject: parseObject, pageRange: pageRange, updatePatch: updatePatch };
  }
  return api;
}));
