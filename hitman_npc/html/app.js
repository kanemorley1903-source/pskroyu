(() => {
  'use strict';

  const RESOURCE = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'hitman_npc';
  const $ = (id) => document.getElementById(id);

  let strings = {};
  let currency = '$';
  let board = null;      // last payload from the server
  let cooldownEnd = 0;   // epoch ms
  let activeEnd = 0;     // epoch ms
  let hudEnd = 0;        // epoch ms
  let ticker = null;

  // ---------------------------------------------------------------- utils
  function post(name, data) {
    return fetch(`https://${RESOURCE}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {}),
    }).catch(() => {});
  }

  // Translate a key; %s / %d are filled from the extra arguments.
  function t(key, ...args) {
    const text = strings[key] !== undefined ? String(strings[key]) : key;
    let i = 0;
    return text.replace(/%%|%[ds]/g, (m) => (m === '%%' ? '%' : (i < args.length ? args[i++] : '')));
  }

  function applyStrings() {
    document.querySelectorAll('[data-i18n]').forEach((el) => {
      const key = el.getAttribute('data-i18n');
      if (strings[key] !== undefined) el.textContent = strings[key];
    });
  }

  function money(n) {
    const value = Math.round(Number(n) || 0);
    return currency + value.toLocaleString('en-US');
  }

  function clock(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  }

  // Tiny DOM builder. Text always goes through textContent, never innerHTML.
  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const [key, value] of Object.entries(props)) {
        if (value === undefined || value === null || value === false) continue;
        if (key === 'text') el.textContent = value;
        else if (key === 'class') el.className = value;
        else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
        else el.setAttribute(key, value === true ? '' : value);
      }
    }
    for (const child of children.flat()) {
      if (child === undefined || child === null || child === false) continue;
      el.append(child.nodeType ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  // ------------------------------------------------------------- rendering
  function stat(label, value) {
    return h('div', { class: 'stat' }, h('span', { class: 'label', text: label }), h('b', { text: value }));
  }

  function renderProfile() {
    const p = board.profile;
    const span = p.nextRep ? p.nextRep - p.levelRep : 0;
    const pct = p.nextRep && span > 0 ? Math.max(0, Math.min(100, ((p.rep - p.levelRep) / span) * 100)) : 100;

    $('profile').replaceChildren(
      h('div', { class: 'card' },
        h('span', { class: 'label', text: t('ui_level') }),
        h('strong', { class: 'level-name', text: p.level }),
        h('div', { class: 'bar' }, h('i', { style: `width:${pct}%` })),
        h('div', { class: 'rep-line' },
          h('span', { text: `${t('ui_reputation')}: ${p.rep}` }),
          h('span', { text: p.nextRep ? t('ui_next_level', p.nextName, p.nextRep) : t('ui_max_level') }),
        ),
      ),
      h('div', { class: 'card stats' },
        stat(t('ui_kills'), p.kills),
        stat(t('ui_earned'), money(p.earned)),
        stat(t('ui_failed'), p.failed),
      ),
    );
  }

  function guardText(n) {
    if (n <= 0) return t('ui_no_guards');
    return n === 1 ? t('ui_guard_one') : t('ui_guards_n', n);
  }

  function facts(c, live) {
    return h('dl', { class: 'facts' },
      h('dt', { text: t('ui_location') }), h('dd', { text: c.location }),
      h('dt', { text: live ? t('ui_hud_time') : t('ui_time') }),
      h('dd', { id: live ? 'active-time' : null, text: clock(live ? c.remaining : c.timeLimit) }),
      h('dt', { text: t('ui_guards') }), h('dd', { text: guardText(c.guards) }),
    );
  }

  function bonusChips(bonuses) {
    const list = bonuses || [];
    return h('div', {},
      h('span', { class: 'label', text: t('ui_bonuses') }),
      list.length
        ? h('ul', { class: 'chips' }, list.map((b) => h('li', { class: 'chip', text: `${b.label} +${b.percent}%` })))
        : h('div', { class: 'muted', text: t('ui_no_bonuses') }),
    );
  }

  function offerCard(offer, locked) {
    return h('article', { class: 'offer', 'data-tier': offer.tier },
      h('div', { class: 'offer-top' },
        h('span', { class: 'tier', text: offer.tierLabel }),
        h('span', { class: 'reward', text: money(offer.reward) }),
      ),
      h('div', { class: 'target-name', text: offer.target }),
      facts(offer, false),
      bonusChips(offer.bonuses),
      h('button', {
        class: 'btn',
        type: 'button',
        disabled: locked,
        text: t('ui_accept'),
        onclick: () => post('accept', { id: offer.id }),
      }),
    );
  }

  function renderActive() {
    const a = board.active;
    const root = $('active');
    root.dataset.tier = a.tier;
    root.replaceChildren(
      h('h2', { text: t('ui_active_title') }),
      h('div', { class: 'offer-top' },
        h('div', { class: 'target-name', text: a.target }),
        h('span', { class: 'reward', text: money(a.reward) }),
      ),
      facts(a, true),
      bonusChips(a.bonuses),
      h('div', { class: 'actions' },
        h('span', { class: 'muted', text: t('ui_active_hint') }),
        h('button', {
          class: 'btn ghost',
          type: 'button',
          text: t('ui_abandon'),
          onclick: () => post('abandon'),
        }),
      ),
    );
  }

  function renderBoard() {
    if (!board) return;
    renderProfile();

    const hasActive = !!board.active;
    $('active').hidden = !hasActive;
    $('offers').hidden = hasActive;
    $('cooldown').hidden = true;

    if (hasActive) {
      renderActive();
      return;
    }

    const locked = Date.now() < cooldownEnd;
    const offers = board.offers || [];
    $('offers').replaceChildren(
      ...(offers.length
        ? offers.map((o) => offerCard(o, locked))
        : [h('div', { class: 'empty', text: t('ui_no_offers') })]),
    );
    updateTimers();
  }

  // ---------------------------------------------------------------- timers
  function updateTimers() {
    // board: cooldown line + live remaining time of the active contract
    if (board && !board.active) {
      const left = Math.ceil((cooldownEnd - Date.now()) / 1000);
      const box = $('cooldown');
      if (left > 0) {
        box.hidden = false;
        box.replaceChildren(`${t('ui_cooldown')} `, h('strong', { text: clock(left) }));
      } else if (!box.hidden) {
        box.hidden = true;
        renderBoard(); // enable the accept buttons again
        return;
      }
    }
    const live = $('active-time');
    if (live && board && board.active) live.textContent = clock((activeEnd - Date.now()) / 1000);

    // hud
    if (!$('hud').hidden && hudEnd) {
      const seconds = (hudEnd - Date.now()) / 1000;
      const el = $('hud-time');
      el.textContent = clock(seconds);
      el.classList.toggle('low', seconds < 60);
    }
  }

  function ensureTicker() {
    if (!ticker) ticker = setInterval(updateTimers, 500);
  }

  // ------------------------------------------------------------------- hud
  const HUD_STATUS = { travel: 'ui_hud_travel', engage: 'ui_hud_engage', done: 'ui_hud_done' };

  function setHudStatus(status) {
    const key = HUD_STATUS[status];
    $('hud-status').textContent = key ? t(key) : '';
  }

  function showHud(m) {
    if (!m.visible) {
      $('hud').hidden = true;
      hudEnd = 0;
      return;
    }
    $('hud-target').textContent = m.target || '';
    $('hud-loc').textContent = m.location || '';
    $('hud-bonuses').replaceChildren(
      ...(m.bonuses || []).map((b) => h('li', { class: 'chip', text: `${b.label} +${b.percent}%` })),
    );
    hudEnd = Date.now() + (Number(m.remaining) || 0) * 1000;
    setHudStatus(m.status);
    $('hud').hidden = false;
    updateTimers();
    ensureTicker();
  }

  // ----------------------------------------------------------- open / close
  function openBoard(payload) {
    board = payload;
    currency = payload.currency || currency;
    cooldownEnd = Date.now() + (Number(payload.cooldown) || 0) * 1000;
    activeEnd = payload.active ? Date.now() + (Number(payload.active.remaining) || 0) * 1000 : 0;
    $('backdrop').hidden = false;
    renderBoard();
    ensureTicker();
  }

  function hideBoard() {
    $('backdrop').hidden = true;
  }

  function closeBoard() {
    hideBoard();
    post('close');
  }

  $('btn-close').addEventListener('click', closeBoard);
  $('backdrop').addEventListener('mousedown', (event) => {
    if (event.target === $('backdrop')) closeBoard();
  });
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !$('backdrop').hidden) closeBoard();
  });

  window.addEventListener('message', (event) => {
    const m = event.data;
    if (!m || typeof m !== 'object') return;
    switch (m.action) {
      case 'board':
        if (m.strings) {
          strings = m.strings;
          applyStrings();
        }
        openBoard(m.data);
        break;
      case 'closeBoard':
        hideBoard();
        break;
      case 'hud':
        if (m.strings) {
          strings = m.strings;
          applyStrings();
        }
        showHud(m);
        break;
      case 'hudStatus':
        setHudStatus(m.status);
        break;
      default:
        break;
    }
  });
})();
