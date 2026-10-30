// Browser tests for both NUI pages (headless Chromium via Playwright).
//
//   NODE_PATH=$(npm root -g) node tests/ui_test.js
//
// FiveM is replaced by a stub: messages from the game are sent with
// window.postMessage, calls back to the game (fetch https://<resource>/<name>)
// are intercepted and recorded. Screenshots go to $SHOTS_DIR (default: tmp).

'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const assert = require('assert');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '..');
const SHOTS = process.env.SHOTS_DIR || fs.mkdtempSync(path.join(os.tmpdir(), 'hitman-ui-'));
fs.mkdirSync(SHOTS, { recursive: true });

let passed = 0;
const failures = [];

async function test(name, fn) {
  try {
    await fn();
    passed += 1;
    process.stdout.write('.');
  } catch (err) {
    failures.push(`[${name}] ${err.stack || err}`);
    process.stdout.write('F');
  }
}

// ----------------------------------------------------------------- harness
async function openPage(browser, resource, viewport = { width: 1280, height: 720 }) {
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  const posts = [];
  const errors = [];

  page.on('pageerror', (err) => errors.push(String(err)));
  page.on('console', (msg) => { if (msg.type() === 'error') errors.push(msg.text()); });

  await page.route(`https://${resource}/**`, async (route) => {
    const request = route.request();
    posts.push({ name: new URL(request.url()).pathname.slice(1), data: JSON.parse(request.postData() || '{}') });
    await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });

  await page.goto(`file://${ROOT}/${resource}/html/index.html`);
  return {
    page,
    posts,
    errors,
    // resolves once the page has handled the message: a sentinel posted right
    // after it is seen by a listener that was registered later than the app's
    send: (message) => page.evaluate((m) => new Promise((resolve) => {
      const done = (event) => {
        if (event.data !== '__sentinel__') return;
        window.removeEventListener('message', done);
        resolve();
      };
      window.addEventListener('message', done);
      window.postMessage(m, '*');
      window.postMessage('__sentinel__', '*');
    }), message),
    // let the open animation finish so the picture shows the real page
    shot: async (name) => {
      await page.waitForTimeout(450);
      await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
    },
    lastPost: (name) => [...posts].reverse().find((p) => p.name === name),
    // the callback to the game is asynchronous: wait until it shows up
    waitPost: async (name) => {
      for (let i = 0; i < 100; i += 1) {
        const hit = [...posts].reverse().find((p) => p.name === name);
        if (hit) return hit;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      return undefined;
    },
    close: () => context.close(),
  };
}

// textContent: independent of CSS text-transform (labels are upper-cased on screen)
const text = async (page, selector) => (await page.locator(selector).first().textContent()).replace(/\s+/g, ' ').trim();

// deterministic time: start at a fixed instant and stand still until told to move
async function freezeClock(page) {
  const start = new Date('2026-01-01T12:00:00Z');
  await page.clock.install({ time: start });
  await page.clock.pauseAt(new Date(start.getTime() + 1000));
}

// ---------------------------------------------------------------- fixtures
const NPC_STRINGS = {
  ui_title: 'Contract Board', ui_subtitle: 'No names. No questions. Cash on delivery.',
  ui_level: 'Standing', ui_reputation: 'Reputation', ui_max_level: 'Top of the food chain',
  ui_next_level: 'Next: %s at %d rep', ui_kills: 'Kills', ui_earned: 'Earned', ui_failed: 'Failed',
  ui_location: 'Last seen', ui_time: 'Time limit', ui_guards: 'Guards', ui_guard_one: '1 guard',
  ui_guards_n: '%d guards', ui_no_guards: 'Alone', ui_bonuses: 'Bonus objectives', ui_no_bonuses: 'None',
  ui_accept: 'Accept contract', ui_abandon: 'Abandon contract', ui_active_title: 'Active contract',
  ui_active_hint: 'Find the target and finish the job. Abandoning costs reputation.',
  ui_no_offers: 'No contracts right now. Check back soon.', ui_cooldown: 'Next contract available in',
  ui_hud_title: 'Contract', ui_hud_time: 'Time left', ui_hud_travel: 'Head to the marked area',
  ui_hud_engage: 'Target in sight range - eliminate', ui_hud_done: 'Confirming kill...',
};

const bonus = (key, label, percent) => ({ key, label, percent });
const BONUSES = [bonus('fast', 'Quick work', 10), bonus('headshot', 'Headshot', 20), bonus('silent', 'Silent kill', 15)];

const NPC_BOARD = {
  currency: '$',
  cooldown: 0,
  profile: {
    rep: 140, kills: 12, earned: 86450, failed: 2, level: 'Enforcer', levelRep: 100, payMult: 1.1,
    nextName: 'Professional', nextRep: 300,
  },
  offers: [
    { id: 11, tier: 1, tierLabel: 'Low Profile', target: 'Marcus Webb', location: 'Vespucci Beach', reward: 3250, timeLimit: 900, guards: 0, bonuses: BONUSES },
    { id: 12, tier: 2, tierLabel: 'Connected', target: 'Elena Castellan', location: 'Legion Square', reward: 8400, timeLimit: 1200, guards: 3, bonuses: [BONUSES[1]] },
    { id: 13, tier: 3, tierLabel: 'High Value', target: 'Victor Kozlov', location: 'Port of Los Santos', reward: 21750, timeLimit: 1500, guards: 1, bonuses: [] },
  ],
};

const PLAYERS_STRINGS = {
  ui_title: 'Darknet Contracts', ui_subtitle: 'Everyone has a price.', ui_cash: 'Cash', ui_bank: 'Bank',
  ui_stat_kills: 'Kills', ui_stat_earned: 'Earned', ui_stat_placed: 'Posted',
  ui_duty: 'On duty', ui_tab_board: 'Board', ui_tab_active: 'Active',
  ui_tab_place: 'Post a contract', ui_tab_mine: 'My contracts', ui_not_worker: 'You are not connected to this trade.',
  ui_off_duty: 'You are off duty. Switch on duty at the top right to see open contracts.',
  ui_board_empty: 'No open contracts right now.', ui_expires: 'Open for', ui_accept: 'Take contract',
  ui_target_offline: 'Target offline', ui_no_description: 'No further details.',
  ui_active_empty: 'You are not hunting anyone.',
  ui_active_hint: 'The map shows a search area that refreshes about every %d seconds.',
  ui_time_left: 'Time left', ui_abandon: 'Drop contract', ui_abandon_cooldown: 'Dropping a contract locks you out for a while.',
  ui_target: 'Target', ui_target_filter: 'Search people...', ui_target_input: 'Server id or exact name',
  ui_target_none: 'Nobody to pick right now.', ui_reward: 'Reward', ui_description: 'Details for the hitman',
  ui_description_hint: 'Where they hang out...', ui_pay_from: 'Pay from', ui_summary_hitman: 'The hitman receives',
  ui_summary_cut: 'Broker keeps %d%%', ui_summary_hold: 'Held in escrow until the job is done.',
  ui_submit: 'Post contract', ui_wait: 'You can post another contract in', ui_mine_empty: 'You have no contracts posted.',
  ui_status_open: 'Waiting for a hitman', ui_status_claimed: 'A hitman is on it', ui_cancel: 'Cancel',
  ui_cancel_hint: 'Refund %s', ui_hud_title: 'Contract', ui_hud_time: 'Time left', ui_hud_signal: 'Signal',
  ui_hud_waiting: 'Waiting for intel...', ui_hud_ok: 'Area marked on the map', ui_hud_lost: 'Signal lost',
};

function playersState(overrides = {}) {
  return {
    currency: '$',
    canWork: true,
    duty: true,
    balances: { cash: 54200, bank: 130000 },
    stats: { kills: 7, earned: 96000, placed: 3, fulfilled: 1 },
    limits: {
      minReward: 5000, maxReward: 250000, maxDescription: 140, brokerCut: 10, cancelFee: 10,
      maxPerClient: 2, accounts: ['cash', 'bank'], selection: 'list',
    },
    cooldowns: { place: 0, abandon: 0 },
    open: [
      { id: 5, target: 'Dante Moreau', description: 'Drives a black Sultan, usually around Vinewood at night.', payout: 45000, expiresIn: 7380, targetOnline: true },
      { id: 6, target: 'Iris Novak', description: '', payout: 18000, expiresIn: 3100, targetOnline: false },
      { id: 7, target: 'Silas Duarte', description: 'Owns the bar on Eclipse Blvd.', payout: 9000, expiresIn: 600, targetOnline: true },
    ],
    placed: [
      { id: 8, target: 'Rafael Santoro', reward: 30000, status: 'open', expiresIn: 5400, refund: 27000 },
      { id: 9, target: 'Lydia Voss', reward: 12000, status: 'claimed', expiresIn: 900, refund: 10800 },
    ],
    active: null,
    ...overrides,
  };
}

const PEOPLE = [
  { id: 4, name: 'Anton Hartmann' }, { id: 9, name: 'Camille Okafor' }, { id: 12, name: 'Dominic Ricci' },
  { id: 15, name: 'Felix Lindqvist' }, { id: 21, name: 'Helena Ferreira' }, { id: 30, name: 'Julian Blackwood' },
];

// ================================================================== NPC UI
async function npcTests(browser) {
  await test('npc: board renders offers, profile and bonuses', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
    await ui.page.waitForSelector('.offer');

    assert.strictEqual(await ui.page.locator('.offer').count(), 3);
    assert.strictEqual(await text(ui.page, '.offer .reward'), '$3,250');
    assert.strictEqual(await text(ui.page, '.level-name'), 'Enforcer');
    assert.match(await text(ui.page, '.rep-line'), /Next: Professional at 300 rep/);
    assert.strictEqual(await ui.page.locator('.offer').first().locator('.chip').count(), 3);
    assert.match(await ui.page.locator('.offer').nth(0).innerText(), /Alone/);
    assert.match(await ui.page.locator('.offer').nth(1).innerText(), /3 guards/);
    assert.match(await ui.page.locator('.offer').nth(2).innerText(), /1 guard\b/);
    assert.match(await ui.page.locator('.offer').nth(2).innerText(), /None/);
    assert.strictEqual(await text(ui.page, 'h1'), 'Contract Board');
    // 45 of 200 rep to the next level
    const width = await ui.page.locator('.bar > i').evaluate((el) => el.style.width);
    assert.strictEqual(width, '20%');
    // tier colours differ
    const colours = await ui.page.locator('.tier').evaluateAll((els) => els.map((e) => getComputedStyle(e).color));
    assert.strictEqual(new Set(colours).size, 3);
    await ui.shot('npc-board');
    assert.deepStrictEqual(ui.errors, []);
    await ui.close();
  });

  await test('npc: accepting posts the offer id; Escape and the close button post close', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
    await ui.page.locator('.offer').nth(1).locator('button').click();
    await ui.page.waitForTimeout(100);
    assert.deepStrictEqual((await ui.waitPost('accept')).data, { id: 12 });

    await ui.page.keyboard.press('Escape');
    await ui.page.waitForTimeout(100);
    assert.ok((await ui.waitPost('close')), 'Escape posts close');
    assert.ok(await ui.page.locator('#backdrop').isHidden(), 'page hidden');

    ui.posts.length = 0;
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
    await ui.page.locator('#btn-close').click();
    await ui.page.waitForTimeout(100);
    assert.ok((await ui.waitPost('close')), 'close button posts close');

    await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
    await ui.page.mouse.click(5, 5); // outside the panel
    await ui.page.waitForTimeout(100);
    assert.ok(await ui.page.locator('#backdrop').isHidden(), 'click outside closes');

    // the game can close it too
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
    await ui.send({ action: 'closeBoard' });
    assert.ok(await ui.page.locator('#backdrop').isHidden());
    await ui.close();
  });

  await test('npc: cooldown disables accepting until it runs out', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    await freezeClock(ui.page);
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: { ...NPC_BOARD, cooldown: 90 } });
    await ui.page.clock.runFor(5000);
    assert.ok(await ui.page.locator('.offer button').first().isDisabled(), 'disabled during cooldown');
    assert.match(await text(ui.page, '#cooldown'), /Next contract available in 1:25/);
    await ui.shot('npc-cooldown');

    await ui.page.clock.runFor(95 * 1000);
    assert.ok(await ui.page.locator('.offer button').first().isEnabled(), 'enabled again');
    assert.ok(await ui.page.locator('#cooldown').isHidden(), 'cooldown line gone');
    await ui.close();
  });

  await test('npc: active contract view with live timer and abandon', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    await freezeClock(ui.page);
    const active = { id: 3, tier: 2, tierLabel: 'Connected', target: 'Elena Castellan', location: 'Legion Square', reward: 8400, timeLimit: 1200, remaining: 754, guards: 2, bonuses: [BONUSES[1]] };
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: { ...NPC_BOARD, active } });
    await ui.page.clock.runFor(1000);

    assert.ok(await ui.page.locator('#active').isVisible(), 'active panel');
    assert.ok(await ui.page.locator('#offers').isHidden(), 'offers hidden');
    assert.strictEqual(await text(ui.page, '#active .target-name'), 'Elena Castellan');
    assert.strictEqual(await text(ui.page, '#active-time'), '12:33');
    await ui.page.clock.runFor(60 * 1000);
    assert.strictEqual(await text(ui.page, '#active-time'), '11:33');
    await ui.shot('npc-active');

    await ui.page.locator('#active .btn').click();
    await ui.page.waitForTimeout(50);
    assert.ok((await ui.waitPost('abandon')));
    await ui.close();
  });

  await test('npc: empty board and maxed out reputation', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    const profile = { ...NPC_BOARD.profile, level: 'Ghost', levelRep: 700, nextName: null, nextRep: null, rep: 900 };
    await ui.send({ action: 'board', strings: NPC_STRINGS, data: { ...NPC_BOARD, offers: [], profile } });
    assert.match(await text(ui.page, '#offers'), /No contracts right now/);
    assert.match(await text(ui.page, '.rep-line'), /Top of the food chain/);
    assert.strictEqual(await ui.page.locator('.bar > i').evaluate((el) => el.style.width), '100%');
    await ui.close();
  });

  await test('npc: hud shows the running contract and hides again', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    await freezeClock(ui.page);
    await ui.send({
      action: 'hud', visible: true, strings: NPC_STRINGS, target: 'Marcus Webb', location: 'Vespucci Beach',
      remaining: 125, status: 'travel', bonuses: BONUSES.slice(0, 2),
    });
    await ui.page.clock.runFor(1000);
    assert.ok(await ui.page.locator('#hud').isVisible());
    assert.strictEqual(await text(ui.page, '#hud-target'), 'Marcus Webb');
    assert.strictEqual(await text(ui.page, '#hud-status'), 'Head to the marked area');
    assert.strictEqual(await text(ui.page, '#hud-time'), '2:04');
    await ui.page.clock.runFor(70 * 1000);
    assert.strictEqual(await text(ui.page, '#hud-time'), '0:54');
    assert.ok(await ui.page.locator('#hud-time.low').count() === 1, 'turns red under a minute');
    await ui.send({ action: 'hudStatus', status: 'engage' });
    assert.strictEqual(await text(ui.page, '#hud-status'), 'Target in sight range - eliminate');
    await ui.shot('npc-hud');
    await ui.send({ action: 'hud', visible: false });
    assert.ok(await ui.page.locator('#hud').isHidden());
    await ui.close();
  });

  await test('npc: text from the server is never interpreted as HTML', async () => {
    const ui = await openPage(browser, 'hitman_npc');
    const evil = '<img src=x onerror="window.__pwned=1"><b>bold</b>';
    const data = JSON.parse(JSON.stringify(NPC_BOARD));
    data.offers[0].target = evil;
    data.offers[0].location = evil;
    data.offers[0].bonuses = [bonus('x', evil, 5)];
    data.profile.level = evil;
    await ui.send({ action: 'board', strings: NPC_STRINGS, data });
    await ui.page.waitForTimeout(150);
    assert.strictEqual(await ui.page.evaluate(() => window.__pwned), undefined);
    assert.strictEqual(await ui.page.locator('.offer img, .profile img, .offer b').count(), 0);
    assert.strictEqual(await text(ui.page, '.offer .target-name'), evil);
    await ui.close();
  });

  await test('npc: layout holds on small and large screens', async () => {
    for (const [name, viewport] of [['npc-small', { width: 700, height: 600 }], ['npc-4k', { width: 2560, height: 1440 }]]) {
      const ui = await openPage(browser, 'hitman_npc', viewport);
      await ui.send({ action: 'board', strings: NPC_STRINGS, data: NPC_BOARD });
      const box = await ui.page.locator('#board').boundingBox();
      assert.ok(box.x >= 0 && box.x + box.width <= viewport.width + 1, `${name}: board fits horizontally`);
      assert.ok(box.y >= 0 && box.y + box.height <= viewport.height + 1, `${name}: board fits vertically`);
      await ui.shot(name);
      await ui.close();
    }
  });
}

// ============================================================== PLAYERS UI
async function playersTests(browser) {
  const open = async (state, viewport) => {
    const ui = await openPage(browser, 'hitman_players', viewport);
    await ui.send({ action: 'open', strings: PLAYERS_STRINGS, state });
    return ui;
  };

  await test('players: hitman on duty sees the board and takes a contract', async () => {
    const ui = await open(playersState());
    await ui.page.waitForSelector('.card');
    assert.strictEqual(await ui.page.locator('#tabs button[aria-selected="true"]').getAttribute('data-tab'), 'board');
    assert.strictEqual(await ui.page.locator('.card').count(), 3);
    assert.strictEqual(await text(ui.page, '.card .money'), '$45,000');
    assert.match(await ui.page.locator('.card').nth(0).innerText(), /Drives a black Sultan/);
    assert.match(await ui.page.locator('.card').nth(1).innerText(), /No further details/);
    assert.match(await ui.page.locator('.card').nth(1).innerText(), /target offline/i);
    assert.ok(await ui.page.locator('.card').nth(1).locator('button').isDisabled(), 'cannot take an offline target');
    assert.match(await ui.page.locator('.card').nth(0).locator('strong').innerText(), /^2:0[23]:\d\d$/);

    // strip: balances, stats, duty
    const strip = await text(ui.page, '#strip');
    assert.match(strip, /cash\s*\$54,200/i);
    assert.match(strip, /bank\s*\$130,000/i);
    assert.match(strip, /kills\s*7/i);
    assert.strictEqual(await ui.page.locator('#duty-switch').getAttribute('aria-checked'), 'true');
    await ui.shot('players-board');

    await ui.page.locator('.card').nth(0).locator('button').click();
    await ui.page.waitForTimeout(50);
    assert.deepStrictEqual((await ui.waitPost('claim')).data, { id: 5 });
    assert.deepStrictEqual(ui.errors, []);
    await ui.close();
  });

  await test('players: duty switch, off duty message and non-workers', async () => {
    let ui = await open(playersState({ duty: false, open: [] }));
    // people who are off duty land on the "post a contract" tab
    assert.strictEqual(await ui.page.locator('#tabs button[aria-selected="true"]').getAttribute('data-tab'), 'place');
    await ui.page.locator('#duty-switch').click();
    assert.deepStrictEqual((await ui.waitPost('duty')).data, { on: true });
    ui.posts.length = 0;
    await ui.page.locator('#tabs [data-tab="board"]').click();
    assert.ok((await text(ui.page, '#panel')).includes('You are off duty'));
    await ui.page.locator('#panel .btn').click();
    assert.deepStrictEqual((await ui.waitPost('duty')).data, { on: true });
    await ui.close();

    ui = await open(playersState({ canWork: false, duty: false }));
    await ui.page.locator('#tabs [data-tab="board"]').click();
    assert.ok((await text(ui.page, '#panel')).includes('not connected to this trade'));
    assert.ok(await ui.page.locator('#duty-switch').isDisabled(), 'cannot switch on duty');
    await ui.close();
  });

  await test('players: active contract with countdown, hint and drop', async () => {
    const active = { id: 5, target: 'Dante Moreau', description: 'Black Sultan, Vinewood.', payout: 45000, remaining: 3000, interval: 30 };
    const ui = await open(playersState({ active, open: [] }));
    await freezeClock(ui.page);
    assert.strictEqual(await ui.page.locator('#tabs button[aria-selected="true"]').getAttribute('data-tab'), 'active');
    assert.strictEqual(await ui.page.locator('#tabs [data-tab="active"]').getAttribute('data-dot'), 'true', 'dot on the tab');
    assert.match(await text(ui.page, '#panel'), /refreshes about every 30 seconds/);
    assert.strictEqual(await text(ui.page, '.card .name'), 'Dante Moreau');
    await ui.shot('players-active');
    await ui.page.locator('.btn.ghost').click();
    assert.ok((await ui.waitPost('abandon')));
    await ui.close();
  });

  await test('players: posting a contract (pick from the list)', async () => {
    const ui = await open(playersState());
    await ui.page.locator('#tabs [data-tab="place"]').click();
    await ui.page.waitForTimeout(50);
    assert.ok((await ui.waitPost('players')), 'asks the game for the player list');
    assert.ok(await ui.page.locator('.btn:has-text("Post contract")').isDisabled(), 'disabled without a target');

    await ui.send({ action: 'players', list: PEOPLE });
    assert.strictEqual(await ui.page.locator('select option').count(), 6);

    // filter
    await ui.page.locator('input[type="text"]').fill('li');
    assert.deepStrictEqual(
      await ui.page.locator('select option').allInnerTexts(),
      ['Felix Lindqvist', 'Julian Blackwood'],
    );
    await ui.page.locator('input[type="text"]').fill('');

    await ui.page.locator('select').selectOption('12');
    const submit = ui.page.locator('.btn:has-text("Post contract")');
    assert.ok(await submit.isEnabled(), 'enabled once a target is chosen');
    assert.strictEqual(await text(ui.page, '.summary .big'), '$4,500', 'default reward is the minimum (5,000 less 10%)');
    assert.strictEqual(await text(ui.page, '.summary .hint'), 'Broker keeps 10%', 'the escaped percent sign is shown once');

    // reward controls
    const reward = ui.page.locator('input[type="number"]');
    await ui.page.locator('.quick button:has-text("+10,000")').click();
    assert.strictEqual(await reward.inputValue(), '15000');
    assert.strictEqual(await text(ui.page, '.summary .big'), '$13,500');
    await ui.page.locator('.quick button:has-text("Max")').click();
    assert.strictEqual(await reward.inputValue(), '250000');
    assert.ok(await submit.isDisabled(), 'cannot afford 250,000 in cash (54,200)');
    await ui.page.locator('.account:has-text("Bank")').click();
    assert.ok(await submit.isDisabled(), 'nor from the bank (130,000)');
    await reward.fill('100000');
    await reward.press('Tab');
    assert.ok(await submit.isEnabled(), 'the bank covers 100,000');
    await ui.page.locator('.account:has-text("Cash")').click();
    assert.ok(await submit.isDisabled(), 'cash does not');
    await ui.page.locator('.account:has-text("Bank")').click();
    await reward.fill('20000');
    await reward.press('Tab');
    await ui.page.locator('textarea').fill('Black Sultan, Vinewood');
    assert.strictEqual(await text(ui.page, '.counter'), '22/140');
    await ui.shot('players-place');

    await submit.click();
    await ui.page.waitForTimeout(50);
    assert.deepStrictEqual((await ui.waitPost('place')).data, {
      targetId: '12', target: '', reward: 20000, account: 'bank', description: 'Black Sultan, Vinewood',
    });
    assert.ok(await submit.isDisabled(), 'locked while waiting for the server');

    // the server answers: toast + new state, form resets, tab jumps to "My contracts"
    await ui.send({
      action: 'state',
      toast: { ok: true, text: 'Contract placed on Dominic Ricci. $20,000 is held in escrow.' },
      state: playersState({ placed: [{ id: 20, target: 'Dominic Ricci', reward: 20000, status: 'open', expiresIn: 10800, refund: 18000 }] }),
    });
    assert.strictEqual(await ui.page.locator('#tabs button[aria-selected="true"]').getAttribute('data-tab'), 'mine');
    assert.match(await text(ui.page, '#toast'), /held in escrow/);
    assert.strictEqual(await ui.page.locator('.row').count(), 1);
    await ui.close();
  });

  await test('players: a rejected contract keeps the form', async () => {
    const ui = await open(playersState());
    await ui.page.locator('#tabs [data-tab="place"]').click();
    await ui.send({ action: 'players', list: PEOPLE });
    await ui.page.locator('select').selectOption('9');
    await ui.page.locator('textarea').fill('keep me');
    await ui.page.locator('.btn:has-text("Post contract")').click();
    await ui.send({
      action: 'state', toast: { ok: false, text: 'That person was hit recently and is off limits for now.' },
      state: playersState(),
    });
    assert.strictEqual(await ui.page.locator('#tabs button[aria-selected="true"]').getAttribute('data-tab'), 'place');
    assert.strictEqual(await ui.page.locator('textarea').inputValue(), 'keep me');
    assert.strictEqual(await ui.page.locator('select').inputValue(), '9');
    assert.ok(await ui.page.locator('#toast.err').isVisible(), 'error toast');
    assert.ok(await ui.page.locator('.btn:has-text("Post contract")').isEnabled(), 'can try again');
    await ui.close();
  });

  await test('players: typing a name when the list is disabled', async () => {
    const state = playersState();
    state.limits.selection = 'input';
    const ui = await open(state);
    await ui.page.locator('#tabs [data-tab="place"]').click();
    assert.strictEqual(await ui.page.locator('select').count(), 0, 'no list');
    assert.strictEqual(ui.lastPost('players'), undefined, 'does not ask for players');
    const submit = ui.page.locator('.btn:has-text("Post contract")');
    assert.ok(await submit.isDisabled());
    await ui.page.locator('input[type="text"]').fill('Dominic Ricci');
    await submit.click();
    await ui.page.waitForTimeout(50);
    assert.strictEqual((await ui.waitPost('place')).data.target, 'Dominic Ricci');
    await ui.close();
  });

  await test('players: refreshing the state does not wipe the form or steal focus', async () => {
    const ui = await open(playersState());
    await ui.page.locator('#tabs [data-tab="place"]').click();
    await ui.send({ action: 'players', list: PEOPLE });
    const area = ui.page.locator('textarea');
    await area.click();
    await area.pressSequentially('typing');
    await ui.send({ action: 'state', state: playersState({ balances: { cash: 60000, bank: 1 } }) });
    assert.strictEqual(await area.inputValue(), 'typing');
    assert.ok(await area.evaluate((el) => el === document.activeElement), 'still focused');
    assert.match(await text(ui.page, '#strip'), /cash\s*\$60,000/i);
    assert.match(await ui.page.locator('.account').first().innerText(), /\$60,000/);
    await ui.close();
  });

  await test('players: cooldown for posting is shown and blocks the button', async () => {
    const ui = await open(playersState({ cooldowns: { place: 200, abandon: 0 } }));
    await ui.page.locator('#tabs [data-tab="place"]').click();
    await ui.send({ action: 'players', list: PEOPLE });
    await ui.page.locator('select').selectOption('4');
    assert.match(await text(ui.page, '.notice'), /You can post another contract in\s+3:2\d/);
    assert.ok(await ui.page.locator('.btn:has-text("Post contract")').isDisabled());
    await ui.close();
  });

  await test('players: my contracts, cancelling and statuses', async () => {
    const ui = await open(playersState());
    await ui.page.locator('#tabs [data-tab="mine"]').click();
    assert.strictEqual(await ui.page.locator('.row').count(), 2);
    assert.match(await ui.page.locator('.row').nth(0).innerText(), /Rafael Santoro/);
    assert.match(await ui.page.locator('.row').nth(0).innerText(), /waiting for a hitman/i);
    assert.match(await ui.page.locator('.row').nth(1).innerText(), /a hitman is on it/i);
    assert.strictEqual(await ui.page.locator('.row').nth(1).locator('button').count(), 0, 'no cancel once claimed');
    const cancel = ui.page.locator('.row').nth(0).locator('button');
    assert.match(await cancel.innerText(), /cancel \(\$27,000\)/i);
    await ui.shot('players-mine');
    await cancel.click();
    await ui.page.waitForTimeout(50);
    assert.deepStrictEqual((await ui.waitPost('cancel')).data, { id: 8 });

    await ui.send({ action: 'state', state: playersState({ placed: [] }) });
    assert.match(await text(ui.page, '#panel'), /no contracts posted/);
    await ui.close();
  });

  await test('players: hud with countdown and signal changes', async () => {
    const ui = await openPage(browser, 'hitman_players');
    await freezeClock(ui.page);
    await ui.send({
      action: 'hud', visible: true, strings: PLAYERS_STRINGS,
      info: { id: 5, target: 'Dante Moreau', description: 'Black Sultan', payout: 45000, remaining: 3000, interval: 30 },
    });
    await ui.page.clock.runFor(1000);
    assert.ok(await ui.page.locator('#hud').isVisible());
    assert.strictEqual(await text(ui.page, '#hud-signal'), 'Waiting for intel...');
    await ui.send({ action: 'hudSignal', signal: 'ok' });
    assert.strictEqual(await text(ui.page, '#hud-signal'), 'Area marked on the map');
    assert.strictEqual(await ui.page.locator('#hud-signal').getAttribute('data-signal'), 'ok');
    await ui.send({ action: 'hudSignal', signal: 'lost' });
    assert.strictEqual(await text(ui.page, '#hud-signal'), 'Signal lost');
    assert.strictEqual(await text(ui.page, '#hud-time'), '49:5' + (await text(ui.page, '#hud-time')).slice(-1));
    await ui.shot('players-hud');
    await ui.send({ action: 'hud', visible: false });
    assert.ok(await ui.page.locator('#hud').isHidden());
    await ui.close();
  });

  await test('players: text from other players is never interpreted as HTML', async () => {
    const evil = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=2</script>';
    const state = playersState();
    state.open[0].description = evil;
    state.open[0].target = evil;
    state.placed[0].target = evil;
    const ui = await open(state);
    await ui.page.waitForTimeout(100);
    assert.strictEqual(await text(ui.page, '.card .quote'), evil);
    await ui.page.locator('#tabs [data-tab="place"]').click();
    await ui.send({ action: 'players', list: [{ id: 1, name: evil }] });
    await ui.page.locator('#tabs [data-tab="mine"]').click();
    await ui.send({ action: 'state', toast: { ok: true, text: evil }, state });
    assert.strictEqual(await ui.page.evaluate(() => window.__pwned), undefined);
    assert.strictEqual(await ui.page.locator('#panel img, #toast img, .quote img').count(), 0);
    await ui.close();
  });

  await test('players: Escape, close button and tab keyboard use', async () => {
    const ui = await open(playersState());
    await ui.page.keyboard.press('Escape');
    await ui.page.waitForTimeout(50);
    assert.ok((await ui.waitPost('close')));
    assert.ok(await ui.page.locator('#backdrop').isHidden());

    await ui.send({ action: 'open', strings: PLAYERS_STRINGS, state: playersState() });
    await ui.page.locator('#btn-refresh').click();
    assert.ok((await ui.waitPost('refresh')));
    await ui.send({ action: 'close' });
    assert.ok(await ui.page.locator('#backdrop').isHidden(), 'the game can close it');
    await ui.close();
  });

  await test('players: layout holds on small and large screens', async () => {
    for (const [name, viewport] of [['players-small', { width: 700, height: 600 }], ['players-4k', { width: 2560, height: 1440 }]]) {
      const ui = await open(playersState(), viewport);
      const box = await ui.page.locator('#app').boundingBox();
      assert.ok(box.x >= 0 && box.x + box.width <= viewport.width + 1, `${name}: fits horizontally`);
      assert.ok(box.y >= 0 && box.y + box.height <= viewport.height + 1, `${name}: fits vertically`);
      await ui.shot(name);
      await ui.close();
    }
  });
}

// ------------------------------------------------------------------- main
(async () => {
  const browser = await chromium.launch();
  try {
    await npcTests(browser);
    await playersTests(browser);
  } finally {
    await browser.close();
  }
  console.log(`\n${passed} passed, ${failures.length} failed  (screenshots: ${SHOTS})`);
  for (const failure of failures) console.log(`\nFAIL ${failure}`);
  process.exit(failures.length ? 1 : 0);
})();
