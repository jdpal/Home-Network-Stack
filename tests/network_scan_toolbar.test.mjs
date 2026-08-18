import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const FIXED_NOW = Date.parse('2026-08-18T09:30:00+01:00');
const LAST_SCAN = '2026-08-18T02:30:00+01:00';

const scriptCases = [
  {
    name: 'clean installer',
    path: new URL('../install.sh', import.meta.url),
    start: `cat >"${'${HOMEPAGE_DIR}'}/config/custom.js" <<'HOMEPAGE_CUSTOM_JS'`,
    end: 'HOMEPAGE_CUSTOM_JS',
  },
  {
    name: 'v3.8.1 upgrade',
    path: new URL('../upgrades/upgrade-v3.8.1.sh', import.meta.url),
    start: `cat >"$DEST" <<'V37_JS'`,
    end: 'V37_JS',
  },
];

function extractHeredoc(source, start, end) {
  const startAt = source.indexOf(`${start}\n`);
  assert.notEqual(startAt, -1, `missing heredoc start: ${start}`);
  const bodyStart = startAt + start.length + 1;
  const endAt = source.indexOf(`\n${end}\n`, bodyStart);
  assert.notEqual(endAt, -1, `missing heredoc end: ${end}`);
  return source.slice(bodyStart, endAt).replace('__STATUS_API_PORT__', '9108');
}

function hasClass(element, className) {
  return String(element.className || '').split(/\s+/).includes(className);
}

class FakeElement {
  constructor(tagName, ownerDocument) {
    this.tagName = tagName.toUpperCase();
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.parentElement = null;
    this.className = '';
    this.style = {};
    this.textContent = '';
    this.disabled = false;
    this.listeners = new Map();
    this._id = '';
    this._innerHTML = '';
  }

  set id(value) {
    this._id = String(value);
    if (this._id) this.ownerDocument.elementsById.set(this._id, this);
  }

  get id() { return this._id; }

  set innerHTML(value) {
    this._innerHTML = String(value);
    this.children = [];

    if (this._innerHTML.includes('kuma-device-grid')) {
      const grid = this.ownerDocument.createElement('div');
      grid.className = 'kuma-device-grid';
      this.appendChild(grid);
    }

    if (this._innerHTML.includes('network-manage-button')) {
      const copy = this.ownerDocument.createElement('div');
      copy.className = 'network-scan-copy';

      const title = this.ownerDocument.createElement('span');
      title.className = 'network-scan-title';
      title.textContent = 'Device status';
      copy.appendChild(title);

      const age = this.ownerDocument.createElement('span');
      age.className = 'network-scan-age';
      age.textContent = 'Last scan unavailable';
      copy.appendChild(age);

      const message = this.ownerDocument.createElement('span');
      message.className = 'network-scan-message';
      copy.appendChild(message);

      const actions = this.ownerDocument.createElement('div');
      actions.className = 'network-scan-actions';

      const manage = this.ownerDocument.createElement('a');
      manage.className = 'network-manage-button';
      manage.textContent = 'Manage devices';
      actions.appendChild(manage);

      const button = this.ownerDocument.createElement('button');
      button.className = 'network-refresh-button';
      const match = this._innerHTML.match(/class="network-refresh-button"[^>]*>([^<]*)<\/button>/);
      button.textContent = match ? match[1].trim() : '';
      actions.appendChild(button);

      this.appendChild(copy);
      this.appendChild(actions);
    }
  }

  get innerHTML() { return this._innerHTML; }
  get firstChild() { return this.children[0] || null; }

  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  insertBefore(child, before) {
    child.parentElement = this;
    if (!before) this.children.push(child);
    else {
      const index = this.children.indexOf(before);
      this.children.splice(index < 0 ? this.children.length : index, 0, child);
    }
    return child;
  }

  querySelector(selector) {
    const matches = selector.startsWith('.')
      ? (element) => hasClass(element, selector.slice(1))
      : selector.startsWith('#')
        ? (element) => element.id === selector.slice(1)
        : (element) => element.tagName.toLowerCase() === selector.toLowerCase();

    for (const child of this.children) {
      if (matches(child)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }

  addEventListener(type, listener) { this.listeners.set(type, listener); }
  getBoundingClientRect() { return { left: 0, right: 1200, width: 1200 }; }
}

class FakeDocument {
  constructor() {
    this.elementsById = new Map();
    this.readyState = 'complete';
    this.documentElement = new FakeElement('html', this);
    const page = this.createElement('main');
    page.id = 'page_container';
    this.documentElement.appendChild(page);
  }

  createElement(tagName) { return new FakeElement(tagName, this); }
  getElementById(id) { return this.elementsById.get(id) || null; }
  querySelector(selector) {
    if (selector.startsWith('#')) return this.getElementById(selector.slice(1));
    return this.documentElement.querySelector(selector);
  }
  addEventListener() {}
}

class FixedDate extends Date {
  constructor(value) { super(value === undefined ? FIXED_NOW : value); }
  static now() { return FIXED_NOW; }
}

async function runDashboardScript(script) {
  const document = new FakeDocument();
  const responsePayload = {
    configured: true,
    groups: [],
    summary: { total: 37, up: 26, down: 11, pending: 0, maintenance: 0, unknown: 0 },
    kuma_summary: {},
    last_scan: LAST_SCAN,
  };
  const window = {
    location: { protocol: 'http:', hostname: '192.168.0.10' },
    requestAnimationFrame(callback) { callback(); },
    setInterval() { return 1; },
    setTimeout(callback) { callback(); return 1; },
    addEventListener() {},
  };
  class MutationObserver { observe() {} }
  const fetch = async () => ({ ok: true, json: async () => responsePayload });
  const context = vm.createContext({
    console,
    Date: FixedDate,
    document,
    encodeURIComponent,
    fetch,
    MutationObserver,
    Promise,
    window,
  });

  vm.runInContext(script, context);
  await new Promise((resolve) => setImmediate(resolve));
  return document;
}

for (const scriptCase of scriptCases) {
  test(`${scriptCase.name}: scan control renders with the device section when Homepage has no services block`, async () => {
    const source = fs.readFileSync(scriptCase.path, 'utf8');
    const script = extractHeredoc(source, scriptCase.start, scriptCase.end);
    const document = await runDashboardScript(script);

    assert.equal(document.getElementById('services'), null, 'fixture must not provide a services section');
    const section = document.getElementById('kuma-monitored-devices');
    assert.ok(section, 'device-status section should render');

    const toolbar = document.getElementById('network-action-row');
    assert.ok(toolbar, 'scan toolbar should render whenever the device-status section renders');
    assert.equal(toolbar.parentElement, section, 'scan toolbar should be attached directly to the device-status section');

    const button = toolbar.querySelector('.network-refresh-button');
    assert.ok(button, 'scan button should be present');
    assert.match(button.textContent, /scan network/i);
    assert.ok(button.listeners.has('click'), 'scan button should start the existing scan workflow');

    const age = toolbar.querySelector('.network-scan-age');
    assert.equal(age?.textContent, 'Last scanned 7h ago');
  });
}
